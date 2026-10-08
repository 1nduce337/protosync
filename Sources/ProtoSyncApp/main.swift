import AppKit
import SwiftUI
import Darwin
import Combine
import Core

// ProtoSync 菜单栏应用(LSUIElement,无 Dock 图标)。
// 左键菜单栏图标:弹出面板(日常操作,MenuBarPanel);右键:传统菜单;
// 主窗口降级为“设备与设置”,不再随启动弹出。

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate, NSWindowDelegate,
                         NSDraggingDestination {
    var model: AppModel!
    var window: NSWindow!
    private var sendWindow: NSWindow?
    private var pinObserver: AnyCancellable?
    private let monitor = ClipboardMonitor()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let contextMenu = NSMenu()
    private var lockFD: Int32 = -1

    // MARK: - 剪贴板读取与同步反馈设置

    /// 全局读取剪贴板(App 在后台/主窗口关闭时也持续监听)。关闭时只在主窗口可见时同步。
    private var backgroundReading: Bool {
        get { UserDefaults.standard.object(forKey: "backgroundClipboardReading") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundClipboardReading") }
    }
    /// 同步时发系统通知(默认关:每次复制都会弹,嫌吵就关;菜单栏图标的发出/收到指示始终提供轻量反馈)。
    private var syncNotify: Bool {
        get { Notifier.syncNotifyEnabled }
        set { UserDefaults.standard.set(newValue, forKey: Notifier.syncNotifyKey) }
    }

    /// App Nap 抑制:菜单栏应用窗口关掉后会被系统节流,0.4s 的剪贴板轮询可能被推迟到数分钟,
    /// 表现为"挂在后台不读剪贴板"。持有 user-initiated activity 令牌即可豁免。
    private var napActivity: NSObjectProtocol?
    private func updateNapActivity() {
        // 设置窗口经 @AppStorage 改这个键,任何默认值变化都会触发这里:状态没变就不动
        if backgroundReading == (napActivity != nil) { return }
        if let napActivity { ProcessInfo.processInfo.endActivity(napActivity); self.napActivity = nil }
        guard backgroundReading else { return }
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "ProtoSync clipboard monitoring")
    }

    /// 主窗口或弹出面板可见才允许读取(仅当全局读取关闭时参与判断)。
    private var windowVisible: Bool {
        window?.isVisible == true || sendWindow?.isVisible == true || popover?.isShown == true
    }

    // MARK: - 同步反馈

    private func clipboardDidSync(peerCount: Int) {
        guard peerCount > 0 else { return }
        showPulse(.sent, tooltip: "剪贴板已同步至 \(peerCount) 台设备")
        Notifier.shared.postSync(id: "clipboard-sync", title: "剪贴板已同步",
                                 body: "已同步至 \(peerCount) 台设备")
    }

    /// 菜单栏图标:logo 剪影模板图(系统按菜单栏深浅自动着色),由 scripts/make-app-icons.swift 生成;
    /// 资源缺失时退回系统符号。
    private static let logoStatusImage: NSImage? = {
        func url(_ name: String) -> URL? {
            Bundle.module.url(forResource: name, withExtension: "png")
                ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources")
        }
        guard let url1x = url("MenuBarIcon"), let rep1x = NSImageRep(contentsOf: url1x) else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        rep1x.size = image.size
        image.addRepresentation(rep1x)
        if let url2x = url("MenuBarIcon@2x"), let rep2x = NSImageRep(contentsOf: url2x) {
            rep2x.size = image.size
            image.addRepresentation(rep2x)
        }
        image.isTemplate = true
        image.accessibilityDescription = "ProtoSync"
        return image
    }()

    private var defaultStatusImage: NSImage? {
        Self.logoStatusImage ?? NSImage(systemSymbolName: "arrow.left.arrow.right.circle",
                                        accessibilityDescription: "ProtoSync")
    }

    /// 菜单栏图标的短暂指示:
    /// - 发出(本机复制已同步):上箭头,跟随菜单栏颜色,1.5 秒;
    /// - 收到(其他设备的剪贴板或文件):Lime 圆底 + 深色下箭头,深浅菜单栏都醒目,3 秒,悬停显示来源。
    private enum Pulse { case sent, received }
    private var pulseResetTimer: Timer?

    private static let receivedImage: NSImage? = {
        let ink = NSColor(srgbRed: 0x15 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0, alpha: 1)
        let lime = NSColor(srgbRed: 0xE7 / 255.0, green: 0xFF / 255.0, blue: 0x16 / 255.0, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink, lime]))   // [箭头, 圆底]
        let image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "已收到")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }()

    private static let sentImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "已同步")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()

    private func showPulse(_ pulse: Pulse, tooltip: String) {
        guard let button = statusItem?.button else { return }
        button.image = (pulse == .received ? Self.receivedImage : Self.sentImage) ?? defaultStatusImage
        button.toolTip = tooltip
        button.setAccessibilityLabel("ProtoSync，\(tooltip)")
        pulseResetTimer?.invalidate()
        pulseResetTimer = Timer.scheduledTimer(withTimeInterval: pulse == .received ? 3 : 1.5,
                                               repeats: false) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            button.image = self.defaultStatusImage
            button.toolTip = "ProtoSync"
            button.setAccessibilityLabel("ProtoSync")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store: IdentityStore
        let engine: SyncEngine
        do {
            store = try IdentityStore()
            engine = try SyncEngine(store: store)
        } catch {
            fatalAlert("初始化失败: \(error.localizedDescription)")
            return
        }
        // 单实例保护:同一身份(identity key 文件)flock。双开会因 mDNS 同名改名
        // 而"发现自己"、双重注册,必须阻止第二个实例。
        let keyFile = store.directory.appendingPathComponent("device.key")
        let fd = open(keyFile.path, O_RDWR)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                fatalAlert("ProtoSync 已在运行(菜单栏图标),请勿重复启动。")
                return
            }
            lockFD = fd // 持有到进程退出,OS 自动释放
        }
        model = AppModel(engine: engine, store: store)

        do {
            try engine.start()
        } catch {
            fatalAlert("启动服务失败: \(error.localizedDescription)")
            return
        }

        setupStatusItem()
        setupClipboardMonitor()
        model.onReceived = { [weak self] text in self?.showPulse(.received, tooltip: text) }
        updateNapActivity()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.updateNapActivity()
        }

        Notifier.shared.setUp()
        PLog.info("ProtoSync 已启动 (fp \(DeviceIdentity.shortFingerprint(model.store.identity.fingerprint)))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        engineRef?.stop()
    }

    private weak var engineRef: SyncEngine? { model?.engine }

    // MARK: - 装配

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = defaultStatusImage
        statusItem.button?.toolTip = "ProtoSync"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        contextMenu.delegate = self

        let panel = MenuBarPanel(
            model: model,
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showMainWindow()
            },
            openSendWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSendWindow()
            },
            quit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize   // 面板高度随内容(请求卡片、传输)变化
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = hosting
        popover.delegate = self
        // 固定后点面板外(例如去访达里选文件)不收起;只有再点菜单栏图标或取消固定才收起
        pinObserver = model.$panelPinned.sink { [weak self] pinned in
            self?.popover.behavior = pinned ? .applicationDefined : .transient
        }

        // 把文件拖到菜单栏图标上:自动弹出面板,接着拖到设备头像上即可发送。
        // 状态栏按钮不能直接子类化,改由它所在窗口登记拖放类型、拖放消息交给窗口代理(本类)
        if let buttonWindow = statusItem.button?.window {
            buttonWindow.registerForDraggedTypes([.fileURL])
            buttonWindow.delegate = self
        }
    }

    /// 面板收起时取消固定:下次打开恢复默认行为
    func popoverDidClose(_ notification: Notification) {
        if model.panelPinned { model.panelPinned = false }
    }

    // MARK: - 拖文件到菜单栏图标(窗口代理转发的 NSDraggingDestination 消息)

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let button = statusItem.button, !popover.isShown else { return [] }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        return []   // 图标本身不接收文件,只负责弹出面板
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    /// 左键开关弹出面板;右键临时挂上传统菜单并弹出,用完摘掉(否则左键也会出菜单)。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem.menu = contextMenu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func setupClipboardMonitor() {
        monitor.onClipboardChanged = { [weak self] content in
            guard let self, let engine = self.model?.engine else { return }
            // 全局读取关闭时:主窗口不可见就不同步(changeCount 仍被消费,避免重新开启时倾倒旧内容)
            if !self.backgroundReading && !self.windowVisible { return }
            // 面板里的“同步剪贴板”开关:关闭时本机复制不外发(接收不受影响)
            guard self.model.clipboardSyncEnabled else { return }
            let peers = engine.onlinePeers().count
            switch content {
            case .text(let text):
                // seen 命中 = 刚从其他设备收到并写入的内容,已在历史里,不重复记录
                guard !engine.seenContains(SyncEngine.sha256Hex(Data(text.utf8))) else { return }
                engine.broadcastClipboardText(text)
                self.model.recordClip(.text(text), source: AppModel.ClipItem.localSource)
            case .image(let png):
                guard !engine.seenContains(SyncEngine.sha256Hex(png)) else { return }
                engine.broadcastClipboardImage(png: png)
                self.model.recordClip(.image(png), source: AppModel.ClipItem.localSource)
            case .none:
                return
            }
            self.clipboardDidSync(peerCount: peers)
        }
        monitor.start()
    }

    func showMainWindow() {
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = "ProtoSync · 设备与设置"
            window.appearance = NSAppearance(named: .darkAqua)   // 与菜单栏面板同为深色
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            window.isReleasedWhenClosed = false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// “发送文件”窗口:普通窗口,切换应用不会收起,适合一次发多个文件
    func showSendWindow() {
        if sendWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "ProtoSync · 发送文件"
            w.appearance = NSAppearance(named: .darkAqua)   // 与菜单栏面板同为深色
            w.contentView = NSHostingView(rootView: SendWindowView(model: model))
            w.center()
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ProtoSyncSendWindow")
            sendWindow = w
        }
        model.refresh()
        sendWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleBackgroundReading() {
        backgroundReading.toggle()
        updateNapActivity()
    }

    @objc private func toggleSyncNotify() {
        syncNotify.toggle()
        guard syncNotify else { return }
        Notifier.shared.checkAuthorization { allowed in
            if !allowed { Notifier.shared.openSystemSettings() }
        }
    }

    // MARK: - 菜单栏

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let online = model?.onlinePeers ?? []
        menu.addItem(withTitle: "\(online.count) 台设备在线", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "发送文件窗口…", action: #selector(openSendWindowFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "设备与设置…", action: #selector(showWindow), keyEquivalent: ",")
        let bgItem = menu.addItem(withTitle: "后台读取剪贴板(全局)",
                                  action: #selector(toggleBackgroundReading), keyEquivalent: "")
        bgItem.state = backgroundReading ? .on : .off
        let notifyItem = menu.addItem(withTitle: "同步时发送通知",
                                      action: #selector(toggleSyncNotify), keyEquivalent: "")
        notifyItem.state = syncNotify ? .on : .off
        menu.addItem(.separator())
        if !online.isEmpty {
            let sendItem = NSMenuItem(title: "发送文件到…", action: nil, keyEquivalent: "")
            let sendMenu = NSMenu()
            sendMenu.autoenablesItems = false
            for peer in online {
                let item = NSMenuItem(title: peer.name,
                                      action: #selector(sendFileToPeer(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = peer.fingerprint
                sendMenu.addItem(item)
            }
            sendItem.submenu = sendMenu
            sendItem.isEnabled = true
            menu.addItem(sendItem)
        }
        menu.addItem(withTitle: "打开收件箱", action: #selector(openInbox), keyEquivalent: "")
        menu.addItem(withTitle: "复制本机地址(IP:端口)", action: #selector(copyAddress), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = $0.action != nil ? self : nil }
    }

    @objc private func showWindow() { showMainWindow() }
    @objc private func openSendWindowFromMenu() { showSendWindow() }

    @objc private func sendFileToPeer(_ sender: NSMenuItem) {
        guard let fp = sender.representedObject as? String else { return }
        model.sendFile(to: fp)
    }

    @objc private func openInbox() { model?.revealInbox() }

    @objc private func copyAddress() {
        guard let engine = model?.engine,
              let ip = LanAddress.primaryIPv4(), engine.listeningPort > 0 else {
            PLog.info("ProtoSync: no LAN address"); return
        }
        let text = "\(ip):\(engine.listeningPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        PLog.info("ProtoSync: copied address \(text)")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func fatalAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ProtoSync"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
