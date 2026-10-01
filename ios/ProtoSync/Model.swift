import Foundation
import Core
import UIKit

/// 只把用户收到的文件放在 Documents；身份和配对记录留在应用私有目录。
private enum IOSStorage {
    static func prepare() throws -> (identity: URL, inbox: URL) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = docs.appendingPathComponent("ProtoSync", isDirectory: true)
        let identity = support.appendingPathComponent("ProtoSync", isDirectory: true)
        let inbox = docs.appendingPathComponent("Received", isDirectory: true)

        try fm.createDirectory(at: identity, withIntermediateDirectories: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)

        if fm.fileExists(atPath: legacy.path) {
            // 老版本将 device.key、paired.json 和收件箱放在 Documents/ProtoSync。
            // 迁移可重复执行：中断后下次启动会继续处理尚未移动的文件。
            for item in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
            where item.lastPathComponent != "Received" {
                let target = identity.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    guard try Data(contentsOf: item) == Data(contentsOf: target) else {
                        throw NSError(domain: "ProtoSyncStorage", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "旧身份文件与新目录中的文件冲突：\(item.lastPathComponent)"])
                    }
                    try fm.removeItem(at: item)
                } else {
                    try fm.moveItem(at: item, to: target)
                }
            }
        }

        for oldInbox in [legacy.appendingPathComponent("Received", isDirectory: true),
                         identity.appendingPathComponent("Received", isDirectory: true)]
        where fm.fileExists(atPath: oldInbox.path) {
            for item in try fm.contentsOfDirectory(at: oldInbox, includingPropertiesForKeys: nil) {
                let stem = item.deletingPathExtension().lastPathComponent
                let ext = item.pathExtension
                var target = inbox.appendingPathComponent(item.lastPathComponent)
                var number = 2
                while fm.fileExists(atPath: target.path) {
                    let name = "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
                    target = inbox.appendingPathComponent(name)
                    number += 1
                }
                try fm.moveItem(at: item, to: target)
            }
            try fm.removeItem(at: oldInbox)
        }

        if fm.fileExists(atPath: legacy.path),
           try fm.contentsOfDirectory(atPath: legacy.path).isEmpty {
            try fm.removeItem(at: legacy)
        }
        return (identity, inbox)
    }
}

/// iOS 端引擎桥:与 macOS AppModel 同一引擎,粘贴板桥换成 UIPasteboard。
/// SyncEngine 的 delegate 回调都在主线程,@Published 可直接改。
@MainActor
final class IOSAppModel: ObservableObject, @preconcurrency SyncEngine.Delegate {
    private(set) var store: IdentityStore!
    private(set) var engine: SyncEngine!

    @Published var ready = false
    @Published var statusText = "引擎启动中…"
    /// 初始化失败时的完整错误(界面完整展示 + 可复制)
    @Published var initError: String?
    @Published var fingerprint = ""
    @Published var port = 0
    @Published var peers: [PeerConnection.PeerInfo] = []
    @Published var nearby: [String] = []       // 未配对已发现设备的短指纹
    @Published var isScanning = false
    @Published var pairing: PairingRequest?
    /// 本机主动发起、等对方确认的配对(展示同一配对码)
    @Published var outgoingPairing: PeerConnection.PeerInfo?
    /// 主动配对失败时的简短提示,几秒后自动消失
    @Published var pairingNotice: String?
    /// 待确认的文件请求(来自未开启自动接收的设备),界面展示第一个
    @Published var fileOffers: [FileOfferPrompt] = []
    /// 已关闭“自动接收文件”的已配对设备指纹
    @Published var filesNeedApproval: Set<String> = []
    /// 已配对设备(头像网格的数据源)
    @Published var paired: [IdentityStore.PairedDevice] = []
    /// 剪贴板历史:只在内存里,不落盘
    @Published var clipHistory: [ClipItem] = []

    struct ClipItem: Identifiable {
        enum Content {
            case text(String)
            case image(Data)
        }
        let id = UUID()
        let content: Content
        let source: String      // 来源设备名;本机发出为 ClipItem.localSource
        let time: Date

        static let localSource = "这台设备"
    }

    static let clipHistoryLimit = 6

    /// 头像网格:已配对设备,在线优先
    var pairedRows: [DeviceRow] {
        let rows = paired.map { d -> DeviceRow in
            let live = peers.first { $0.fingerprint == d.fingerprint }
            return DeviceRow(id: d.fingerprint, name: live?.name ?? d.name,
                             fingerprint: d.fingerprint, online: live != nil,
                             filesTrusted: d.filesTrusted)
        }
        return rows.filter { $0.online } + rows.filter { !$0.online }
    }
    @Published var events: [Event] = []
    @Published var receivedImage: Data?
    @Published var transfers: [TransferRow] = []
    @Published var inbox: [URL] = []

    struct TransferRow: Identifiable {
        let id: String
        let name: String
        var fraction: Double
        let incoming: Bool
    }

    /// 文件选择器给的是安全作用域 URL,作用域保持到传输结束
    var sendingScopeURL: URL?

    /// 状态轮询(与 macOS AppModel 相同节奏):在线/附近/收件箱 3 秒刷一次
    private var pollTimer: Timer?

    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.refreshNearby()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    struct PairingRequest: Identifiable {
        let id = UUID()
        let info: PeerConnection.PeerInfo
        let reply: (Bool) -> Void
    }

    struct FileOfferPrompt: Identifiable {
        let offer: SyncEngine.FileOfferRequest
        let reply: (Bool) -> Void
        var id: String { offer.id }
    }

    struct Event: Identifiable {
        let id = UUID()
        let line: String
    }

    init() {
        do {
            let storage = try IOSStorage.prepare()
            store = try IdentityStore(directory: storage.identity,
                                      deviceName: UIDevice.current.name)
            engine = try SyncEngine(store: store, inboxDirectory: storage.inbox)
            engine.delegate = self
            try engine.start()
            fingerprint = String(store.identity.fingerprint.prefix(8))
            port = Int(engine.listeningPort)
            statusText = "运行中"
            ready = true
            startPolling()
        } catch {
            // 完整错误:Swift 的 LocalizedError 常被截断,把 error 本体也带上
            let detail = String(describing: error)
            initError = "\(error.localizedDescription)\n\(detail)"
            statusText = "初始化失败"
            PLog.error("ProtoSync iOS init failed: \(detail)")
            print("ProtoSync iOS_INIT_ERROR: \(detail)")
        }
    }

    func refresh() {
        guard ready else { return }
        peers = engine.onlinePeers()
        let latestPaired = store.pairedDevices
        if latestPaired != paired { paired = latestPaired }
        let untrusted = Set(latestPaired.filter { !$0.filesTrusted }.map(\.fingerprint))
        if untrusted != filesNeedApproval { filesNeedApproval = untrusted }
    }

    func recordClip(_ content: ClipItem.Content, source: String) {
        clipHistory.insert(ClipItem(content: content, source: source, time: Date()), at: 0)
        if clipHistory.count > Self.clipHistoryLimit {
            clipHistory.removeLast(clipHistory.count - Self.clipHistoryLimit)
        }
    }

    /// 写回系统剪贴板(iOS 不自动外发,只有点“发送剪贴板”才同步)
    func copyFromHistory(_ item: ClipItem) {
        switch item.content {
        case .text(let text): UIPasteboard.general.string = text
        case .image(let png): UIPasteboard.general.image = UIImage(data: png)
        }
    }

    func removePaired(_ row: DeviceRow) {
        guard ready else { return }
        engine.removePairedDevice(fingerprint: row.fingerprint)
        refresh()
        log("已移除 \(row.name)")
    }

    func peer(for fingerprint: String) -> PeerConnection.PeerInfo? {
        peers.first { $0.fingerprint == fingerprint }
    }

    func setFileTrust(_ peer: PeerConnection.PeerInfo, trusted: Bool) {
        guard ready else { return }
        engine.setFileTrust(fingerprint: peer.fingerprint, trusted: trusted)
        refresh()
        log(trusted ? "已开启自动接收:\(peer.name)" : "\(peer.name) 的文件将先询问")
    }

    func decideFileOffer(_ prompt: FileOfferPrompt, accept: Bool, alwaysTrust: Bool = false) {
        if accept && alwaysTrust { setFileTrust(prompt.offer.from, trusted: true) }
        prompt.reply(accept)
        fileOffers.removeAll { $0.id == prompt.id }
        if !accept { log("已拒绝文件:\(prompt.offer.name)") }
    }

    func refreshNearby() {
        guard ready else { return }
        let latest = engine.discoveredUnpaired()
        if latest != nearby { nearby = latest }
    }

    /// SCAN:重启发现 + 清重试防抖(与 Mac refreshDevices 一致)
    func scan() {
        guard ready, !isScanning else { return }
        isScanning = true
        engine.refreshDiscovery()
        refresh()
        refreshNearby()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.isScanning = false
            self?.refreshNearby()
        }
    }

    /// 向附近设备发起配对连接(握手后对端会收到配对请求)
    func pairWith(shortFp: String) {
        guard ready else { return }
        engine.pairWith(shortFp: shortFp)
        log("→ 正在连接 \(shortFp)…")
    }

    func pairAccepted(_ request: PairingRequest, _ accept: Bool) {
        request.reply(accept)
        pairing = nil
        refresh()
    }

    func sendClipboard() {
        guard ready else { return }
        let pasteboard = UIPasteboard.general
        if let text = pasteboard.string, !text.isEmpty {
            engine.broadcastClipboardText(text)
            recordClip(.text(text), source: ClipItem.localSource)
            log("↑ 已发送剪贴板(\(text.count) 字)")
        } else if let image = pasteboard.image, let png = image.pngData() {
            engine.broadcastClipboardImage(png: png)
            recordClip(.image(png), source: ClipItem.localSource)
            log("↑ 已发送图片(\(png.count / 1024) KB)")
        } else {
            log("剪贴板是空的")
        }
    }

    var inboxDirectory: URL? {
        guard ready else { return nil }
        return engine.inboxDirectory
    }

    func refreshInbox() {
        guard ready, let dir = inboxDirectory else { return }
        // 用户可在“文件”App 删除整个 Received 文件夹；返回应用时恢复空收件箱。
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        inbox = items
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { ($0.lastPathComponent) < ($1.lastPathComponent) }
    }

    func sendFile(at url: URL, to peer: PeerConnection.PeerInfo) {
        guard ready else { return }
        // 文件选择器 URL 需要显式取得访问权;作用域在传输结束时释放
        let scoped = url.startAccessingSecurityScopedResource()
        sendingScopeURL = url
        engine.sendFile(at: url, to: peer.fingerprint)
        if !scoped { log("提示: 文件访问权限异常,可能发送失败") }
    }

    private func endSendingScope() {
        sendingScopeURL?.stopAccessingSecurityScopedResource()
        sendingScopeURL = nil
    }

    private func log(_ line: String) {
        events.insert(Event(line: line), at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
    }

    // MARK: - SyncEngine.Delegate(主线程回调)

    func engine(_ engine: SyncEngine, peerConnected info: PeerConnection.PeerInfo) {
        if outgoingPairing?.fingerprint == info.fingerprint { outgoingPairing = nil }
        refresh()
        refreshNearby()
        log("↓ 已连接 \(info.name)(\(info.fingerprint.prefix(8)))")
    }

    func engine(_ engine: SyncEngine, peerDisconnected info: PeerConnection.PeerInfo, error: String?) {
        refresh()
        log("断开 \(info.name)\(error.map { "(\($0))" } ?? "")")
    }

    func engine(_ engine: SyncEngine, pairingRequested info: PeerConnection.PeerInfo,
                reply: @escaping (Bool) -> Void) {
        #if targetEnvironment(simulator)
        // 模拟器调试钩子:无法远程点按 UI,模拟器构建自动接受配对(真机构建无此分支)
        reply(true)
        log("✅ 自动接受配对 \(info.name)(模拟器调试模式)")
        #else
        pairing = PairingRequest(info: info, reply: reply)
        log("配对请求 \(info.name)")
        #endif
    }

    func engine(_ engine: SyncEngine, fileOfferRequested offer: SyncEngine.FileOfferRequest,
                reply: @escaping (Bool) -> Void) {
        fileOffers.append(FileOfferPrompt(offer: offer, reply: reply))
        log("文件请求:\(offer.from.name) → \(offer.name)")
    }

    func engine(_ engine: SyncEngine, fileOfferExpired id: String) {
        fileOffers.removeAll { $0.id == id }
    }

    func engine(_ engine: SyncEngine, fileAwaitingApproval id: String, name: String) {
        log("↑ 等待对方确认:\(name)")
    }

    func engine(_ engine: SyncEngine, pairingAwaitingPeer info: PeerConnection.PeerInfo) {
        outgoingPairing = info
        pairingNotice = nil
        log("等待 \(info.name) 确认配对(配对码 \(info.sas ?? "—"))")
    }

    func engine(_ engine: SyncEngine, pairingFailed info: PeerConnection.PeerInfo, error: String) {
        if outgoingPairing?.fingerprint == info.fingerprint { outgoingPairing = nil }
        let notice = "未能与「\(info.name)」配对：\(error)"
        pairingNotice = notice
        log(notice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.pairingNotice == notice { self?.pairingNotice = nil }
        }
        refresh()
    }

    func engine(_ engine: SyncEngine, peerUnpaired info: PeerConnection.PeerInfo) {
        let notice = "「\(info.name)」移除了与本机的配对"
        pairingNotice = notice
        log(notice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.pairingNotice == notice { self?.pairingNotice = nil }
        }
        refresh()
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardText text: String, from peer: PeerConnection.PeerInfo) {
        UIPasteboard.general.string = text
        recordClip(.text(text), source: peer.name)
        log("↓ 收到文本(\(text.count) 字)已进剪贴板")
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardImage png: Data, from peer: PeerConnection.PeerInfo) {
        UIPasteboard.general.image = UIImage(data: png)
        receivedImage = png
        recordClip(.image(png), source: peer.name)
        log("↓ 收到图片(\(png.count / 1024) KB)已进剪贴板")
    }

    func engine(_ engine: SyncEngine, fileTransferStarted id: String, name: String, direction: SyncEngine.Direction) {
        transfers.append(TransferRow(id: id, name: name, fraction: 0, incoming: direction == .incoming))
    }

    func engine(_ engine: SyncEngine, fileProgress id: String, name: String, fraction: Double, direction: SyncEngine.Direction) {
        if let idx = transfers.firstIndex(where: { $0.id == id }) {
            transfers[idx].fraction = fraction
        }
    }

    func engine(_ engine: SyncEngine, fileTransferFinished id: String, name: String, url: URL?,
                error: String?, direction: SyncEngine.Direction) {
        transfers.removeAll { $0.id == id }
        if let error {
            log("文件失败:\(name) — \(error)")
        } else if url != nil {
            log("↓ 文件已存收件箱:\(name)")
        } else {
            log("↑ 文件发送完成:\(name)")
        }
        if sendingScopeURL != nil { endSendingScope() }
        refreshInbox()
        refresh()
    }
}
