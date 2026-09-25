import Foundation
import AppKit
import Combine
import UserNotifications
import Core

/// SwiftUI 与 SyncEngine 之间的桥:引擎回调(主线程)→ @Published 状态。
final class AppModel: ObservableObject, SyncEngine.Delegate {
    let engine: SyncEngine
    let store: IdentityStore

    @Published var onlinePeers: [PeerConnection.PeerInfo] = []
    @Published var pairedDevices: [IdentityStore.PairedDevice] = []
    @Published var discoveredUnpaired: [String] = []
    @Published var activities: [ActivityEntry] = []
    @Published var inboxFiles: [URL] = []
    @Published var pairingRequest: PairingRequest?
    @Published var deviceName: String = ""
    @Published var isRefreshing = false

    struct PairingRequest: Identifiable {
        let id = UUID()
        let info: PeerConnection.PeerInfo
        let reply: (Bool) -> Void
    }

    struct ActivityEntry: Identifiable, Equatable {
        enum Kind { case text, image, file }
        enum Direction { case incoming, outgoing }
        let id: UUID
        var kind: Kind
        var direction: Direction
        var title: String
        var detail: String
        var time: Date
        var progress: Double?     // 传输中 0...1,完成/失败为 nil
        var failed: Bool
    }

    private var transferIds: [String: UUID] = [:]  // 传输 id → 活动条目 id
    private var refreshTimer: Timer?

    init(engine: SyncEngine, store: IdentityStore) {
        self.engine = engine
        self.store = store
        deviceName = store.identity.name
        refresh()
        engine.delegate = self
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        onlinePeers = engine.onlinePeers()
        pairedDevices = store.pairedDevices
        discoveredUnpaired = engine.discoveredUnpaired()
        refreshInbox()
    }

    /// 手动刷新设备:重启 Bonjour 并短暂显示刷新中状态。
    func refreshDevices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        engine.refreshDiscovery()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.isRefreshing = false
            self?.refresh()
        }
    }

    func refreshInbox() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: engine.inboxDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        inboxFiles = files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { date($0) > date($1) }
    }

    private func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - 操作(视图调用)

    func sendFile(to peerFp: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要发送的文件"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.sendFile(at: url, to: peerFp)
    }

    func pairWith(shortFp: String) {
        engine.pairWith(shortFp: shortFp)
    }

    func removePaired(fingerprint: String) {
        engine.removePairedDevice(fingerprint: fingerprint)
        refresh()
    }

    func acceptPairing(_ request: PairingRequest) {
        request.reply(true)
        pairingRequest = nil
        refresh()
    }

    func rejectPairing(_ request: PairingRequest) {
        request.reply(false)
        pairingRequest = nil
    }

    func revealInbox() {
        NSWorkspace.shared.open(engine.inboxDirectory)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 内部:活动流

    private func appendActivity(_ mutate: (inout ActivityEntry) -> Void, base: ActivityEntry) {
        var entry = base
        mutate(&entry)
        activities.insert(entry, at: 0)
        if activities.count > 60 { activities.removeLast(activities.count - 60) }
    }

    // MARK: - SyncEngine.Delegate(主线程)

    func engine(_ engine: SyncEngine, peerConnected info: PeerConnection.PeerInfo) {
        refresh()
        appendActivity({ $0.detail = "已连接" }, base: ActivityEntry(
            id: UUID(), kind: .text, direction: .incoming,
            title: info.name, detail: "已连接", time: Date(), progress: nil, failed: false))
    }

    func engine(_ engine: SyncEngine, peerDisconnected info: PeerConnection.PeerInfo, error: String?) {
        refresh()
    }

    func engine(_ engine: SyncEngine, pairingRequested info: PeerConnection.PeerInfo,
                reply: @escaping (Bool) -> Void) {
        pairingRequest = PairingRequest(info: info, reply: reply)
        // 不调用 NSApp.activate:菜单栏应用激活自己会把当前前台 App 顶成失焦
        // (多端互连时未配对连接频繁到达,表现为"每几秒被隐形窗口抢走焦点")。
        // 主窗口不可见时改用系统通知提醒,不抢焦点。
        if NSApp.mainWindow == nil {
            let content = UNMutableNotificationContent()
            content.title = "ProtoSync 配对请求"
            content.body = "设备「\(info.name)」请求配对,打开主窗口处理"
            let request = UNNotificationRequest(identifier: "pairing-request", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardText text: String) {
        ClipboardMonitor.write(text: text)
        appendActivity({ $0.detail = "文本 · \(text.count) 字" }, base: ActivityEntry(
            id: UUID(), kind: .text, direction: .incoming,
            title: String(text.prefix(60)), detail: "已复制到剪贴板", time: Date(), progress: nil, failed: false))
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardImage png: Data) {
        ClipboardMonitor.write(png: png)
        appendActivity({ $0.detail = "图片 · \(png.count / 1024) KB" }, base: ActivityEntry(
            id: UUID(), kind: .image, direction: .incoming,
            title: "图片", detail: "已复制到剪贴板", time: Date(), progress: nil, failed: false))
    }

    func engine(_ engine: SyncEngine, fileTransferStarted id: String, name: String, direction: SyncEngine.Direction) {
        let entry = ActivityEntry(
            id: UUID(), kind: .file,
            direction: direction == .incoming ? .incoming : .outgoing,
            title: name, detail: direction == .incoming ? "接收中…" : "发送中…",
            time: Date(), progress: 0, failed: false)
        transferIds[id] = entry.id
        activities.insert(entry, at: 0)
        if activities.count > 60 { activities.removeLast(activities.count - 60) }
        refreshInbox()
    }

    func engine(_ engine: SyncEngine, fileProgress id: String, name: String, fraction: Double, direction: SyncEngine.Direction) {
        guard let entryId = transferIds[id],
              let idx = activities.firstIndex(where: { $0.id == entryId }) else { return }
        activities[idx].progress = fraction
    }

    func engine(_ engine: SyncEngine, fileTransferFinished id: String, name: String, url: URL?, error: String?, direction: SyncEngine.Direction) {
        defer { refresh() }
        guard let entryId = transferIds.removeValue(forKey: id),
              let idx = activities.firstIndex(where: { $0.id == entryId }) else { return }
        activities[idx].progress = nil
        if let error {
            activities[idx].failed = true
            activities[idx].detail = "失败:\(error)"
        } else if let url {
            activities[idx].detail = "已保存到收件箱"
        } else {
            activities[idx].detail = "发送完成"
        }
    }
}
