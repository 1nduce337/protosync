import Foundation
import CryptoKit
import Network

/// 同步引擎:管理发现、连接、配对策略、剪贴板去重与文件收发。
/// 所有 delegate 回调都 marshal 到主线程;引擎内部串行队列保护状态。
public final class SyncEngine: NSObject, PeerConnection.Delegate {
    public protocol Delegate: AnyObject {
        func engine(_ engine: SyncEngine, peerConnected info: PeerConnection.PeerInfo)
        func engine(_ engine: SyncEngine, peerDisconnected info: PeerConnection.PeerInfo, error: String?)
        func engine(_ engine: SyncEngine, pairingRequested info: PeerConnection.PeerInfo,
                    reply: @escaping (Bool) -> Void)
        func engine(_ engine: SyncEngine, didReceiveClipboardText text: String)
        func engine(_ engine: SyncEngine, didReceiveClipboardImage png: Data)
        func engine(_ engine: SyncEngine, fileTransferStarted id: String, name: String, direction: Direction)
        func engine(_ engine: SyncEngine, fileProgress id: String, name: String, fraction: Double, direction: Direction)
        func engine(_ engine: SyncEngine, fileTransferFinished id: String, name: String, url: URL?, error: String?, direction: Direction)
    }

    public enum Direction: String {
        case outgoing = "↑"
        case incoming = "↓"
        public init() { self = .outgoing }
    }

    public let store: IdentityStore
    public weak var delegate: Delegate?
    /// 测试便利:发现未配对设备时直接发起连接(配对仍走确认流程)。
    public var autoConnectUnpaired = false

    private let engineQueue = DispatchQueue(label: "protosync.engine")
    /// 文件哈希/落盘等慢 I/O 专用队列:慢盘上哈希十几秒也不会阻塞心跳与协议收发
    private let ioQueue = DispatchQueue(label: "protosync.io")
    private var heartbeatTimer: DispatchSourceTimer?
    private let listener = ServiceListener()
    private let browser = ServiceBrowser()
    private var connections: [String: PeerConnection] = [:]    // 完整指纹 → 已建立连接
    private var pending: [PeerConnection] = []                 // 握手未完成,强引用防释放
    private var discovered: [String: DiscoveredService] = [:]  // shortFp → 服务
    private var connectAttempts: [String: Date] = [:]          // shortFp → 上次连接尝试
    private var seen = SeenCache()
    private var outgoing: [String: OutgoingTransfer] = [:]
    private var incoming: [String: IncomingTransfer] = [:]
    public let inboxDirectory: URL

    /// 每个传输会话的在途分块上限,防止大文件撑爆发送缓冲。
    public static let windowSize = 16
    public static let chunkSize = 192 * 1024

    private struct OutgoingTransfer {
        let id: String
        let name: String
        let size: Int64
        var sha256: String
        let handle: FileHandle
        let targetFp: String
        var nextIndex: Int = 0
        var inFlight: Int = 0
        var doneSent = false
        var offerAttempts = 0
    }

    private struct IncomingTransfer {
        let id: String
        let name: String
        let size: Int64
        let sha256: String
        let tempURL: URL
        let handle: FileHandle
        let sourceFp: String
        var receivedBytes: Int64 = 0
        var expectedIndex = 0
        var chunksReceived = 0
        var finished = false
    }

    public init(store: IdentityStore, inboxDirectory: URL? = nil) throws {
        self.store = store
        let inbox = inboxDirectory ?? FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtoSync", isDirectory: true)
        self.inboxDirectory = inbox
        super.init()
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        listener.onNewConnection = { [weak self] connection in
            guard let self else { return }
            self.engineQueue.async {
                let peer = PeerConnection(nw: connection, role: .responder, identity: self.store.identity,
                                          pairingPolicy: self.pairingPolicy, delegate: self,
                                          queue: self.engineQueue)
                self.pending.append(peer)
                peer.start()
            }
        }
        browser.onServicesChanged = { [weak self] services in
            self?.engineQueue.async {
                self?.handleDiscovered(services)
            }
        }
    }

    // MARK: - 生命周期

    public func start() throws {
        try listener.start(shortFp: DeviceIdentity.shortFingerprint(identity.fingerprint))
        browser.start()
        startHeartbeat()
    }

    public func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        engineQueue.sync {
            connections.values.forEach { $0.shutdown() }
            connections.removeAll()
        }
        browser.stop()
        listener.stop()
    }

    /// 心跳:每 5s 双向 ping;15s 无入站帧即判定死连;顺带重连已配对的掉线设备。
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func heartbeatTick() {
        let now = Date()
        // 握手超过 10s 未建立的连接(对端不可达/AP 隔离)直接清理,防止泄漏与重复堆积
        for connection in pending where connection.state == .handshaking {
            let timeout: TimeInterval = connection.awaitingPairingDecision ? 120 : 10
            if now.timeIntervalSince(connection.handshakeProgressAt) > timeout {
                connection.shutdown()
            }
        }
        for connection in connections.values {
            if connection.state == .established {
                connection.send(Message(type: MessageType.ping))
            }
            if now.timeIntervalSince(connection.lastInboundAt) > 15 {
                connection.shutdown() // connectionDidClose 会清理并通知 UI
            }
        }
        // 已配对但掉线的设备:借助发现缓存立即重试(5s 防抖仍生效)
        if !discovered.isEmpty {
            handleDiscovered(Array(discovered.values))
        }
    }

    private var identity: DeviceIdentity { store.identity }

    // MARK: - 查询

    /// 监听端口(供“复制本机地址”用)。
    public var listeningPort: UInt16 { listener.port }

    public var myInfo: PeerConnection.PeerInfo {
        PeerConnection.PeerInfo(fingerprint: identity.fingerprint, name: identity.name)
    }

    public func onlinePeers() -> [PeerConnection.PeerInfo] {
        engineQueue.sync {
            connections.values.compactMap { $0.peerInfo }
        }
    }

    /// 已发现但未配对的服务 shortFp 列表(供 UI 发起配对)。
    public func discoveredUnpaired() -> [String] {
        engineQueue.sync {
            let ownShortFp = DeviceIdentity.shortFingerprint(identity.fingerprint)
            return discovered.keys.filter { short in
                !short.hasPrefix(ownShortFp)
                    && !store.pairedDevices.contains { $0.fingerprint.hasPrefix(short) }
            }
        }
    }

    /// 手动刷新:重启 Bonjour 浏览与注册,清除连接重试防抖,立即重试已配对设备。
    public func refreshDiscovery() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            PLog.info("ProtoSync: manual discovery refresh")
            self.browser.restart()
            try? self.listener.restart(shortFp: DeviceIdentity.shortFingerprint(self.identity.fingerprint))
            self.connectAttempts.removeAll()
            // 浏览器重启后结果回来会自动触发 handleDiscovered;
            // 对已知服务立即再走一遍,让"已配对重连"不用等下一次浏览回调。
            let services = Array(self.discovered.values)
            if !services.isEmpty { self.handleDiscovered(services) }
        }
    }

    /// 用户主动连接一个未配对的已发现设备以发起配对。
    public func pairWith(shortFp: String) {
        engineQueue.async { [weak self] in
            guard let self, let service = self.discovered[shortFp] else { return }
            self.openConnection(to: service.endpoint, role: .initiator)
        }
    }

    // MARK: - 剪贴板

    public func broadcastClipboardText(_ text: String) {
        let hash = Self.sha256Hex(Data(text.utf8))
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.seen.insert(hash)
            let message = Message.clipboardText(text, hash: hash)
            self.connections.values.forEach { $0.send(message) }
        }
    }

    public func broadcastClipboardImage(png: Data) {
        let hash = Self.sha256Hex(png)
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.seen.insert(hash)
            let message = Message.clipboardImage(png, hash: hash)
            self.connections.values.forEach { $0.send(message) }
        }
    }

    public func seenContains(_ hash: String) -> Bool {
        engineQueue.sync { seen.contains(hash) }
    }

    // MARK: - 文件发送(定向单目标)

    public func sendFile(at url: URL, to peerFp: String) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            guard self.connections[peerFp] != nil else {
                self.notifyMain { $0.engine(self, fileTransferFinished: "", name: url.lastPathComponent,
                                            url: nil, error: "设备不在线", direction: .outgoing) }
                return
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let id = UUID().uuidString
                let name = url.lastPathComponent
                let handle = try FileHandle(forReadingFrom: url)
                let transfer = OutgoingTransfer(id: id, name: name, size: size, sha256: "",
                                                handle: handle, targetFp: peerFp)
                self.outgoing[id] = transfer
                self.notifyMain { $0.engine(self, fileTransferStarted: id, name: name, direction: .outgoing) }
                // 慢哈希走 I/O 队列,完成后回 engineQueue 重新核对再发 offer
                let fileURL = url
                self.ioQueue.async { [weak self] in
                    let sha = (try? Self.fileSHA256(at: fileURL)) ?? ""
                    self?.engineQueue.async { [weak self] in
                        guard let self else { return }
                        guard var transfer = self.outgoing[id], !transfer.doneSent else { return }
                        guard self.connections[transfer.targetFp] != nil else {
                            self.finishOutgoing(id: id, error: "设备已离线")
                            return
                        }
                        guard !sha.isEmpty else {
                            self.finishOutgoing(id: id, error: "文件哈希失败")
                            return
                        }
                        transfer.sha256 = sha
                        self.outgoing[id] = transfer
                        self.connections[transfer.targetFp]?
                            .send(.fileOffer(id: id, name: transfer.name, size: transfer.size, sha256: sha))
                        // offer 可能落在被重复连接收敛替换掉的旧连接上,ack 永远不来;
                        // 看门狗在当前连接上重发 offer(对端幂等 re-ack),最多 2 次
                        self.scheduleOfferWatchdog(id: id)
                    }
                }
            } catch {
                self.notifyMain { $0.engine(self, fileTransferFinished: "", name: url.lastPathComponent,
                                            url: nil, error: error.localizedDescription, direction: .outgoing) }
            }
        }
    }

    /// offer 看门狗:6s 内没进入传输(nextIndex==0 且未 done)就在当前连接重发 offer。
    private func scheduleOfferWatchdog(id: String) {
        engineQueue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, var transfer = self.outgoing[id],
                  transfer.nextIndex == 0, !transfer.doneSent else { return }
            guard transfer.offerAttempts < 2 else {
                self.finishOutgoing(id: id, error: "对方未响应文件请求")
                return
            }
            transfer.offerAttempts += 1
            self.outgoing[id] = transfer
            guard let connection = self.connections[transfer.targetFp] else {
                self.finishOutgoing(id: id, error: "设备已离线")
                return
            }
            PLog.info("ProtoSync: re-offering \(transfer.name) to \(transfer.targetFp.prefix(8))")
            connection.send(.fileOffer(id: id, name: transfer.name, size: transfer.size, sha256: transfer.sha256))
            self.scheduleOfferWatchdog(id: id)
        }
    }

    // MARK: - PeerConnection.Delegate(在 engineQueue 上回调)

    public func connection(_ connection: PeerConnection, didEstablishPeer peer: PeerConnection.PeerInfo) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            // 防御:连上的对端就是自己(同机双实例/同名身份),立即断开。
            guard peer.fingerprint != identity.fingerprint else {
                connection.shutdown()
                return
            }
            self.pending.removeAll { $0 === connection }
            if let existing = self.connections[peer.fingerprint], existing !== connection {
                // 双方同时发起导致的重复连接:双方按同一规则收敛——
                // fp 较小一方发起的连接获胜。
                let preferredRole: SecureChannel.Role =
                    self.identity.fingerprint < peer.fingerprint ? .initiator : .responder
                if connection.role == preferredRole {
                    // 替换连接不重复通知(首条连接已通知过)
                    existing.shutdown()
                    self.connections[peer.fingerprint] = connection
                } else {
                    connection.shutdown()
                }
                return
            }
            guard self.connections[peer.fingerprint] == nil else { return }
            self.connections[peer.fingerprint] = connection
            self.notifyMain { $0.engine(self, peerConnected: peer) }
        }
    }

    public func connection(_ connection: PeerConnection, didAcceptPairing peer: PeerConnection.PeerInfo) {
        // Runs on engineQueue. Persist trust only after PeerConnection confirms
        // the request is still live, so accepting a stale UI banner cannot pair.
        store.addPaired(fingerprint: peer.fingerprint, name: peer.name)
    }

    public func removePairedDevice(fingerprint: String) {
        engineQueue.sync {
            store.removePaired(fingerprint: fingerprint)
            connections[fingerprint]?.shutdown()
            for connection in pending where connection.peerInfo?.fingerprint == fingerprint {
                connection.shutdown()
            }
            connectAttempts = connectAttempts.filter { !$0.key.hasPrefix(DeviceIdentity.shortFingerprint(fingerprint)) }
        }
    }

    public func connection(_ connection: PeerConnection, didReceive message: Message) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.handleMessage(message, from: connection)
        }
    }

    public func connection(_ connection: PeerConnection, pairingRequested peer: PeerConnection.PeerInfo,
                    reply: @escaping (Bool) -> Void) {
        notifyMain { $0.engine(self, pairingRequested: peer, reply: reply) }
    }

    public func connectionDidClose(_ connection: PeerConnection, error: String?) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll { $0 === connection }
            if let info = connection.peerInfo, self.connections[info.fingerprint] === connection {
                self.connections.removeValue(forKey: info.fingerprint)
                self.cancelTransfers(for: info.fingerprint, reason: error ?? "连接已关闭")
                self.notifyMain { $0.engine(self, peerDisconnected: info, error: error) }
            }
        }
    }

    // MARK: - 消息分发

    private func handleMessage(_ message: Message, from connection: PeerConnection) {
        switch message.type {
        case MessageType.clipboard:
            // 手动发送(force)是用户明确意图,不受去重限制;自动同步仍按
            // seen 缓存丢弃 5 分钟内的重复内容。两种情况都要插入 seen 防回环。
            let forced = message.force == true
            guard let hash = message.hash, forced || !seen.contains(hash) else { return }
            seen.insert(hash)
            switch message.kind {
            case "text":
                if let text = message.data {
                    notifyMain { $0.engine(self, didReceiveClipboardText: text) }
                }
            case "image":
                if let b64 = message.data, let png = Data(base64Encoded: b64) {
                    notifyMain { $0.engine(self, didReceiveClipboardImage: png) }
                }
            default:
                break
            }

        case MessageType.fileOffer:
            handleFileOffer(message, from: connection)
        case MessageType.fileChunk:
            handleFileChunk(message, from: connection)
        case MessageType.fileDone:
            handleFileDone(message, from: connection)
        case MessageType.fileAck:
            handleFileAck(message)
        case MessageType.ping:
            break // 判活只看 lastInboundAt,无需回复
        default:
            break
        }
    }

    // MARK: - 文件:接收侧

    private func handleFileOffer(_ message: Message, from connection: PeerConnection) {
        // 对端发来的 wire 字段全部不可信:逐项校验,任何一项不合格直接拒绝
        guard let id = FileTransferGuard.sanitizedTransferID(message.id),
              let name = FileTransferGuard.sanitizedFileName(message.fileName),
              let size = message.size, FileTransferGuard.isValidSize(size),
              FileTransferGuard.isValidSHA256Hex(message.sha256), let sha = message.sha256,
              let sourceFp = connection.peerInfo?.fingerprint,
              incoming[id] == nil, outgoing[id] == nil
        else {
            connection.send(.fileAck(id: message.id ?? "?", accept: false, done: true))
            return
        }
        // 临时文件名只用本机 UUID,绝不使用远端提供的名字
        let tempURL = inboxDirectory.appendingPathComponent(".incoming-\(UUID().uuidString).part")
        do {
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            incoming[id] = IncomingTransfer(id: id, name: name, size: size, sha256: sha,
                                            tempURL: tempURL, handle: handle,
                                            sourceFp: sourceFp)
            connection.send(.fileAck(id: id, accept: true, done: false))
            notifyMain { $0.engine(self, fileTransferStarted: id, name: name, direction: .incoming) }
        } catch {
            connection.send(.fileAck(id: id, accept: false, done: true))
            notifyMain { $0.engine(self, fileTransferFinished: id, name: name, url: nil,
                                   error: error.localizedDescription, direction: .incoming) }
        }
    }

    private func handleFileChunk(_ message: Message, from connection: PeerConnection) {
        guard let id = message.id,
              var transfer = incoming[id],
              let b64 = message.data,
              let chunk = Data(base64Encoded: b64)
        else { return }
        // 来源连接、序号、单块大小、累计大小逐项校验:防跨连接注入/乱序/超写
        guard connection.peerInfo?.fingerprint == transfer.sourceFp else { return }
        guard message.index == transfer.expectedIndex else {
            connection.send(.fileAck(id: id, accept: false, done: true))
            finishIncoming(id: id, error: "分块序号错位(收到 \(message.index ?? -1),期望 \(transfer.expectedIndex))")
            return
        }
        guard chunk.count <= Self.chunkSize,
              transfer.receivedBytes + Int64(chunk.count) <= transfer.size else {
            connection.send(.fileAck(id: id, accept: false, done: true))
            finishIncoming(id: id, error: "分块超出声明大小")
            return
        }
        do {
            try transfer.handle.write(contentsOf: chunk)
            transfer.receivedBytes += Int64(chunk.count)
            transfer.expectedIndex += 1
            transfer.chunksReceived += 1
            incoming[id] = transfer
            let fraction = transfer.size > 0 ? Double(transfer.receivedBytes) / Double(transfer.size) : 1.0
            notifyMain { $0.engine(self, fileProgress: id, name: transfer.name,
                                   fraction: fraction, direction: .incoming) }
            // 流控:每收满一个窗口回一个 ack,发送方才继续发下一窗。
            if transfer.chunksReceived % Self.windowSize == 0 {
                connection.send(.fileAck(id: id, accept: true, done: false))
            }
        } catch {
            connection.send(.fileAck(id: id, accept: false, done: true))
            finishIncoming(id: id, error: error.localizedDescription)
        }
    }

    private func handleFileDone(_ message: Message, from connection: PeerConnection) {
        guard let id = message.id, var transfer = incoming[id], !transfer.finished else { return }
        // done 必须来自原连接,且实际字节数必须与声明严格一致
        guard connection.peerInfo?.fingerprint == transfer.sourceFp else { return }
        guard transfer.receivedBytes == transfer.size else {
            connection.send(.fileAck(id: id, accept: false, done: true))
            finishIncoming(id: id, error: "字节数不匹配(收 \(transfer.receivedBytes)/声明 \(transfer.size))")
            return
        }
        // 标记校验中,防止重复 done;句柄在 engineQueue 关闭,慢哈希挪 I/O 队列
        transfer.finished = true
        try? transfer.handle.close()
        incoming[id] = transfer
        let tempURL = transfer.tempURL
        ioQueue.async { [weak self] in
            let actual = (try? Self.fileSHA256(at: tempURL)) ?? ""
            self?.engineQueue.async { [weak self] in
                guard let self else { return }
                // 回跳后重新核对:任务仍存在且未被打断(断线/取消会把它移除)
                guard let transfer = self.incoming[id], transfer.finished else { return }
                guard actual == transfer.sha256 else {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.incoming.removeValue(forKey: id)
                    connection.send(.fileAck(id: id, accept: false, done: true))
                    self.notifyMain { $0.engine(self, fileTransferFinished: id, name: transfer.name, url: nil,
                                           error: "校验失败(传输损坏)", direction: .incoming) }
                    return
                }
                do {
                    // 最终名经 sanitizedFileName 清洗过,且 availableURL 只在收件箱内生成,无逃逸可能
                    let finalURL = Self.availableURL(in: self.inboxDirectory, forName: transfer.name)
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                    self.incoming.removeValue(forKey: id)
                    connection.send(.fileAck(id: id, accept: true, done: true))
                    self.notifyMain { $0.engine(self, fileTransferFinished: id, name: transfer.name,
                                           url: finalURL, error: nil, direction: .incoming) }
                } catch {
                    connection.send(.fileAck(id: id, accept: false, done: true))
                    self.finishIncoming(id: id, error: error.localizedDescription)
                }
            }
        }
    }

    private func handleFileAck(_ message: Message) {
        guard let id = message.id, var transfer = outgoing[id] else { return }
        if message.done == true {
            // 接收方最终确认(成功或校验失败),发送侧收尾。
            finishOutgoing(id: id, error: message.accept == false ? "接收方校验失败" : nil)
            return
        }
        if message.accept == false {
            finishOutgoing(id: id, error: "接收方拒绝文件")
            return
        }
        guard message.accept == true, transfer.inFlight > 0 || transfer.nextIndex == 0 else { return }
        transfer.inFlight = 0
        outgoing[id] = transfer
        pumpChunks(id: id)
    }

    // MARK: - 文件:发送侧流控

    private func pumpChunks(id: String) {
        guard var transfer = outgoing[id] else { return }
        do {
            while transfer.inFlight < Self.windowSize
                    && Int64(transfer.nextIndex) * Int64(Self.chunkSize) < transfer.size {
                let remaining = transfer.size - Int64(transfer.nextIndex) * Int64(Self.chunkSize)
                let length = min(Int64(Self.chunkSize), remaining)
                guard let chunk = try transfer.handle.read(upToCount: Int(length)),
                      chunk.count == Int(length) else {
                    finishOutgoing(id: id, error: "读取文件失败")
                    return
                }
                connections[transfer.targetFp]?
                    .send(.fileChunk(id: id, index: transfer.nextIndex, data: chunk))
                transfer.nextIndex += 1
                transfer.inFlight += 1
            }
            if Int64(transfer.nextIndex) * Int64(Self.chunkSize) >= transfer.size && !transfer.doneSent {
                transfer.doneSent = true
                connections[transfer.targetFp]?.send(.fileDone(id: id))
            }
            outgoing[id] = transfer
            let fraction = transfer.size > 0
                ? Double(min(Int64(transfer.nextIndex) * Int64(Self.chunkSize), transfer.size)) / Double(transfer.size)
                : 1.0
            notifyMain { $0.engine(self, fileProgress: id, name: transfer.name,
                                   fraction: fraction, direction: .outgoing) }
        } catch {
            finishOutgoing(id: id, error: error.localizedDescription)
        }
    }

    private func finishOutgoing(id: String, error: String?) {
        guard let transfer = outgoing.removeValue(forKey: id) else { return }
        try? transfer.handle.close()
        notifyMain { $0.engine(self, fileTransferFinished: id, name: transfer.name,
                               url: nil, error: error, direction: .outgoing) }
    }

    private func finishIncoming(id: String, error: String) {
        guard let transfer = incoming.removeValue(forKey: id) else { return }
        try? transfer.handle.close()
        try? FileManager.default.removeItem(at: transfer.tempURL)
        notifyMain { $0.engine(self, fileTransferFinished: id, name: transfer.name,
                               url: nil, error: error, direction: .incoming) }
    }

    private func cancelTransfers(for peerFp: String, reason: String) {
        let outgoingIDs = outgoing.compactMap { $0.value.targetFp == peerFp ? $0.key : nil }
        for id in outgoingIDs { finishOutgoing(id: id, error: reason) }

        let incomingIDs = incoming.compactMap { $0.value.sourceFp == peerFp ? $0.key : nil }
        for id in incomingIDs { finishIncoming(id: id, error: reason) }
    }

    // MARK: - 发现与连接

    private func handleDiscovered(_ services: [DiscoveredService]) {
        discovered = Dictionary(uniqueKeysWithValues: services.map { ($0.shortFp, $0) })
        let ownShortFp = DeviceIdentity.shortFingerprint(identity.fingerprint)
        #if DEBUG
        PLog.info("ProtoSync: discovered \(services.count) services, paired=\(store.pairedDevices.count), auto=\(autoConnectUnpaired ? 1 : 0)")
        #endif
        for service in services {
            // 跳过自己的广播(前缀匹配:mDNS 遇同名冲突会改名为 "xxxx (2)");
            // 已有连接(含握手中的尝试)则跳过;同一服务 5 秒内不重复尝试。
            guard !service.shortFp.hasPrefix(ownShortFp) else { continue }
            // 已建立或握手中(含配对弹窗未决)的连接都算数,否则会连环重开连接
            if connections.keys.contains(where: { $0.hasPrefix(service.shortFp) }) { continue }
            if pending.contains(where: { $0.peerInfo?.fingerprint.hasPrefix(service.shortFp) == true }) { continue }
            if let last = connectAttempts[service.shortFp],
               last.timeIntervalSinceNow > -5 { continue }
            connectAttempts[service.shortFp] = Date()
            // 已配对设备自动重连;未配对默认等用户在 UI 里主动发起
            // (CLI 测试对端可开 autoConnectUnpaired 跳过手动步骤)。
            if store.pairedDevices.contains(where: { $0.fingerprint.hasPrefix(service.shortFp) })
                || autoConnectUnpaired {
                openConnection(to: service.endpoint, role: .initiator)
            }
        }
        connectAttempts = connectAttempts.filter { $0.value.timeIntervalSinceNow > -30 }
    }

    private func openConnection(to endpoint: NWEndpoint, role: SecureChannel.Role) {
        PLog.info("ProtoSync: openConnection role=\(role == .initiator ? "initiator" : "responder") endpoint=\(endpoint)")
        let nw = NWConnection(to: endpoint, using: .tcp)
        let peer = PeerConnection(nw: nw, role: role, identity: identity,
                                  pairingPolicy: pairingPolicy, delegate: self,
                                  queue: engineQueue)
        pending.append(peer)
        peer.start()
        // 建立成功前不登记进 connections;失败由 connectionDidClose 收尾。
    }

    private var pairingPolicy: PeerConnection.PairingPolicy {
        { [weak self] info, reply in
            guard let self else { reply(false); return }
            if self.store.isPaired(info.fingerprint) {
                reply(true)
            } else {
                self.notifyMain { $0.engine(self, pairingRequested: info, reply: reply) }
            }
        }
    }

    // MARK: - 工具

    private func notifyMain(_ body: @escaping (Delegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            body(delegate)
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func availableURL(in directory: URL, forName name: String) -> URL {
        let candidate = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        var result: URL
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            result = directory.appendingPathComponent(newName)
            n += 1
        } while FileManager.default.fileExists(atPath: result.path)
        return result
    }
}

/// 接收侧文件传输的输入校验(对不可信 wire 数据的防线)。
public enum FileTransferGuard {
    public static let maxFileNameLength = 200
    public static let maxFileSize: Int64 = 4 * 1024 * 1024 * 1024  // 4 GiB 产品上限

    /// 传输 id:限字母/数字/连字符,1...64 位
    public static func sanitizedTransferID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) } ? raw : nil
    }

    /// SHA-256 必须是 64 位十六进制
    public static func isValidSHA256Hex(_ raw: String?) -> Bool {
        guard let raw, raw.count == 64 else { return false }
        return raw.allSatisfy { $0.isHexDigit }
    }

    /// 大小:非负且不超过产品上限
    public static func isValidSize(_ size: Int64) -> Bool {
        size >= 0 && size <= maxFileSize
    }

    /// 远端文件名:只保留 basename,拒绝空/./..、路径分隔符、控制字符;超长截断后在落盘时再查重
    public static func sanitizedFileName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.count <= maxFileNameLength
        else { return nil }
        if name.contains("/") || name.contains("\\") || name.contains(":") { return nil }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        name = (name as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }
}

/// 剪贴板去重缓存:哈希 → 时间戳,过期清理,容量上限。
public struct SeenCache {
    public init() {}
    private var entries: [String: Date] = [:]
    private let maxEntries = 512
    private let maxAge: TimeInterval = 300

    public mutating func insert(_ hash: String) {
        entries[hash] = Date()
        prune()
    }

    public func contains(_ hash: String) -> Bool {
        guard let date = entries[hash] else { return false }
        return date.timeIntervalSinceNow > -maxAge
    }

    private mutating func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries = entries.filter { $0.value > cutoff }
        if entries.count > maxEntries {
            let sorted = entries.sorted { $0.value < $1.value }
            for (key, _) in sorted.prefix(entries.count - maxEntries) {
                entries.removeValue(forKey: key)
            }
        }
    }
}
