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
        guard ready, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        engine.broadcastClipboardText(text)
        events.insert(Event(line: "↑ 已发送剪贴板(\(text.count) 字)"), at: 0)
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

    func engine(_ engine: SyncEngine, didReceiveClipboardText text: String) {
        UIPasteboard.general.string = text
        log("↓ 收到文本(\(text.count) 字)已进剪贴板")
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardImage png: Data) {
        UIPasteboard.general.image = UIImage(data: png)
        receivedImage = png
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
