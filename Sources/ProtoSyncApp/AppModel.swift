import Foundation
import AppKit
import Combine
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
    /// 本机主动发起、等对方确认的配对(展示同一配对码)
    @Published var outgoingPairing: PeerConnection.PeerInfo?
    /// 主动配对失败时的简短提示,几秒后自动消失
    @Published var pairingNotice: String?
    /// 待确认的文件请求(来自未开启自动接收的设备),按到达顺序,界面展示第一个
    @Published var fileOffers: [FileOfferPrompt] = []
    @Published var deviceName: String = ""
    /// 剪贴板历史:只在内存里,不落盘;密码管理器标记的内容在监听层就被跳过,不会进来
    @Published var clipHistory: [ClipItem] = []
    /// 同步本机剪贴板到其他设备。关闭后仍接收其他设备发来的剪贴板。
    @Published var clipboardSyncEnabled: Bool =
        UserDefaults.standard.object(forKey: "clipboardSyncEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(clipboardSyncEnabled, forKey: "clipboardSyncEnabled") }
    }

    struct ClipItem: Identifiable {
        enum Content {
            case text(String)
            case image(Data)
        }
        let id = UUID()
        let content: Content
        let source: String      // 来源设备名;本机复制为 ClipItem.localSource
        let time: Date

        static let localSource = "这台 Mac"
    }

    /// 菜单栏面板展示的条数,也是内存里保留的上限
    static let clipHistoryLimit = 6
    @Published var isRefreshing = false
    /// 固定菜单栏面板:切到其他应用(如在访达里选文件)时不自动收起
    @Published var panelPinned = false

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

    /// 收到其他设备的剪贴板或文件时调用(菜单栏图标切换为"已接收"指示),参数为提示文字
    var onReceived: ((String) -> Void)?

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

    /// 选择文件发送(可多选)
    func sendFile(to peerFp: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要发送的文件（可多选）"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        sendFiles(panel.urls, to: peerFp)
    }

    /// 发送多个文件;文件夹暂不支持(单文件协议),返回实际发出的个数
    @discardableResult
    func sendFiles(_ urls: [URL], to peerFp: String) -> Int {
        let files = urls.filter { url in
            url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        files.forEach { engine.sendFile(at: $0, to: peerFp) }
        return files.count
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

    /// alwaysTrust:接受并对该设备开启文件自动接收,以后不再询问
    func acceptFileOffer(_ prompt: FileOfferPrompt, alwaysTrust: Bool = false) {
        if alwaysTrust { setFileTrust(fingerprint: prompt.offer.from.fingerprint, trusted: true) }
        prompt.reply(true)
        fileOffers.removeAll { $0.id == prompt.id }
    }

    func declineFileOffer(_ prompt: FileOfferPrompt) {
        prompt.reply(false)
        fileOffers.removeAll { $0.id == prompt.id }
    }

    func setFileTrust(fingerprint: String, trusted: Bool) {
        engine.setFileTrust(fingerprint: fingerprint, trusted: trusted)
        refresh()
    }

    func recordClip(_ content: ClipItem.Content, source: String) {
        clipHistory.insert(ClipItem(content: content, source: source, time: Date()), at: 0)
        if clipHistory.count > Self.clipHistoryLimit {
            clipHistory.removeLast(clipHistory.count - Self.clipHistoryLimit)
        }
    }

    /// 写回系统剪贴板。若内容已超出 5 分钟去重窗口,剪贴板监听会照常把它再同步一次(与手动复制一致)。
    func copyFromHistory(_ item: ClipItem) {
        switch item.content {
        case .text(let text): ClipboardMonitor.write(text: text)
        case .image(let png): ClipboardMonitor.write(png: png)
        }
    }

    func clearClipHistory() {
        clipHistory.removeAll()
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
        if outgoingPairing?.fingerprint == info.fingerprint { outgoingPairing = nil }
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
            Notifier.shared.post(id: "pairing-request", title: "ProtoSync 配对请求",
                                 body: "设备「\(info.name)」请求配对，点菜单栏图标处理")
        }
    }

    func engine(_ engine: SyncEngine, pairingAwaitingPeer info: PeerConnection.PeerInfo) {
        outgoingPairing = info
        pairingNotice = nil
    }

    func engine(_ engine: SyncEngine, pairingFailed info: PeerConnection.PeerInfo, error: String) {
        if outgoingPairing?.fingerprint == info.fingerprint { outgoingPairing = nil }
        let notice = "未能与「\(info.name)」配对：\(error)"
        pairingNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.pairingNotice == notice { self?.pairingNotice = nil }
        }
        refresh()
    }

    func engine(_ engine: SyncEngine, peerUnpaired info: PeerConnection.PeerInfo) {
        let notice = "「\(info.name)」移除了与这台 Mac 的配对"
        pairingNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.pairingNotice == notice { self?.pairingNotice = nil }
        }
        refresh()
    }

    func engine(_ engine: SyncEngine, fileOfferRequested offer: SyncEngine.FileOfferRequest,
                reply: @escaping (Bool) -> Void) {
        fileOffers.append(FileOfferPrompt(offer: offer, reply: reply))
        // 与配对请求一致:不抢焦点,主窗口不可见时发系统通知
        if NSApp.mainWindow == nil {
            Notifier.shared.post(id: "file-offer-\(offer.id)", title: "ProtoSync 文件请求",
                                 body: "「\(offer.from.name)」想发送「\(offer.name)」，点菜单栏图标处理")
        }
    }

    func engine(_ engine: SyncEngine, fileOfferExpired id: String) {
        fileOffers.removeAll { $0.id == id }
        Notifier.shared.remove(ids: ["file-offer-\(id)"])
    }

    func engine(_ engine: SyncEngine, fileAwaitingApproval id: String, name: String) {
        guard let entryId = transferIds[id],
              let idx = activities.firstIndex(where: { $0.id == entryId }) else { return }
        activities[idx].detail = "等待对方确认…"
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardText text: String, from peer: PeerConnection.PeerInfo) {
        ClipboardMonitor.write(text: text)
        recordClip(.text(text), source: peer.name)
        onReceived?("已收到「\(peer.name)」的剪贴板")
        Notifier.shared.postSync(id: "clipboard-received", title: "收到「\(peer.name)」的剪贴板",
                                 body: String(text.prefix(80)))
        appendActivity({ $0.detail = "文本 · \(text.count) 字" }, base: ActivityEntry(
            id: UUID(), kind: .text, direction: .incoming,
            title: String(text.prefix(60)), detail: "已复制到剪贴板", time: Date(), progress: nil, failed: false))
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardImage png: Data, from peer: PeerConnection.PeerInfo) {
        ClipboardMonitor.write(png: png)
        recordClip(.image(png), source: peer.name)
        onReceived?("已收到「\(peer.name)」的图片")
        Notifier.shared.postSync(id: "clipboard-received", title: "收到「\(peer.name)」的剪贴板",
                                 body: "图片 · \(png.count / 1024) KB，已复制到剪贴板")
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
        if activities[idx].detail == "等待对方确认…" { activities[idx].detail = "发送中…" }
    }

    func engine(_ engine: SyncEngine, fileTransferFinished id: String, name: String, url: URL?, error: String?, direction: SyncEngine.Direction) {
        defer { refresh() }
        guard let entryId = transferIds.removeValue(forKey: id),
              let idx = activities.firstIndex(where: { $0.id == entryId }) else { return }
        activities[idx].progress = nil
        if let error {
            activities[idx].failed = true
            activities[idx].detail = "失败:\(error)"
        } else if url != nil {
            activities[idx].detail = "已保存到收件箱"
            onReceived?("已收到文件「\(name)」")
            Notifier.shared.postSync(id: "file-received-\(id)", title: "已收到文件",
                                     body: "「\(name)」已保存到收件箱")
        } else {
            activities[idx].detail = "发送完成"
        }
    }
}
