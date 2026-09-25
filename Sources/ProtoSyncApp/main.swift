import AppKit
import SwiftUI
import UserNotifications
import Darwin
import Core

// ProtoSync 菜单栏 + 主窗口(LSUIElement,无 Dock 图标)。

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: AppModel!
    var window: NSWindow!
    private let monitor = ClipboardMonitor()
    private var statusItem: NSStatusItem!
    private var lockFD: Int32 = -1

    // MARK: - 剪贴板读取与同步反馈设置

    /// 全局读取剪贴板(App 在后台/主窗口关闭时也持续监听)。关闭时只在主窗口可见时同步。
    private var backgroundReading: Bool {
        get { UserDefaults.standard.object(forKey: "backgroundClipboardReading") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundClipboardReading") }
    }
    /// 同步成功时发系统通知(默认关:每次复制都会弹,嫌吵就关;菜单栏 ✓ 闪烁始终提供轻量反馈)。
    private var syncNotify: Bool {
        get { UserDefaults.standard.bool(forKey: "syncSuccessNotification") }
        set { UserDefaults.standard.set(newValue, forKey: "syncSuccessNotification") }
    }

    /// App Nap 抑制:菜单栏应用窗口关掉后会被系统节流,0.4s 的剪贴板轮询可能被推迟到数分钟,
    /// 表现为"挂在后台不读剪贴板"。持有 user-initiated activity 令牌即可豁免。
    private var napActivity: NSObjectProtocol?
    private func updateNapActivity() {
        if let napActivity { ProcessInfo.processInfo.endActivity(napActivity); self.napActivity = nil }
        guard backgroundReading else { return }
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "ProtoSync clipboard monitoring")
    }

    /// 主窗口可见才允许读取(仅当全局读取关闭时参与判断)。
    private var windowVisible: Bool { window?.isVisible == true }

    // MARK: - 同步成功反馈

    private var tickResetTimer: Timer?
    private func clipboardDidSync(peerCount: Int) {
        guard peerCount > 0 else { return }
        flashTick()
        guard syncNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "剪贴板已同步"
        content.body = "已同步至 \(peerCount) 台设备"
        let request = UNNotificationRequest(identifier: "clipboard-sync", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 菜单栏图标短暂切换为对勾,提示同步成功。
    private func flashTick() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                               accessibilityDescription: "剪贴板已同步")
        button.appearance = NSAppearance(named: .darkAqua) // 浅色菜单栏上保持可见
        tickResetTimer?.invalidate()
        tickResetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle",
                                   accessibilityDescription: "ProtoSync")
            button.appearance = nil
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
        updateNapActivity()
        showMainWindow()

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
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
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle",
                                           accessibilityDescription: "ProtoSync")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupClipboardMonitor() {
        monitor.onClipboardChanged = { [weak self] content in
            guard let self, let engine = self.model?.engine else { return }
            // 全局读取关闭时:主窗口不可见就不同步(changeCount 仍被消费,避免重新开启时倾倒旧内容)
            if !self.backgroundReading && !self.windowVisible { return }
            let peers = engine.onlinePeers().count
            switch content {
            case .text(let text):
                guard !engine.seenContains(SyncEngine.sha256Hex(Data(text.utf8))) else { return }
                engine.broadcastClipboardText(text)
            case .image(let png):
                guard !engine.seenContains(SyncEngine.sha256Hex(png)) else { return }
                engine.broadcastClipboardImage(png: png)
            case .none:
                return
            }
            self.clipboardDidSync(peerCount: peers)
        }
        monitor.start()
    }

    func showMainWindow() {
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = "ProtoSync"
            window.contentView = NSHostingView(rootView: makeRootView())
            window.center()
            window.isReleasedWhenClosed = false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 界面选择(Signal Foundry 新版 / 旧版卡片,UserDefaults 持久化)

    private var legacyUI: Bool {
        UserDefaults.standard.bool(forKey: "useLegacyUI")
    }

    private func makeRootView() -> AnyView {
        legacyUI ? AnyView(DashboardView(model: model))
                 : AnyView(SignalFoundryRootView(model: model))
    }

    @objc private func toggleUI() {
        UserDefaults.standard.set(!legacyUI, forKey: "useLegacyUI")
        if let window {
            window.contentView = NSHostingView(rootView: makeRootView())
        }
    }

    @objc private func toggleBackgroundReading() {
        backgroundReading.toggle()
        updateNapActivity()
    }

    @objc private func toggleSyncNotify() {
        syncNotify.toggle()
    }

    // MARK: - 菜单栏

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let online = model?.onlinePeers ?? []
        menu.addItem(withTitle: "\(online.count) 台设备在线", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开主窗口", action: #selector(showWindow), keyEquivalent: "n")
        menu.addItem(withTitle: legacyUI ? "切换到新版界面" : "切换到旧版界面",
                     action: #selector(toggleUI), keyEquivalent: "")
        let bgItem = menu.addItem(withTitle: "后台读取剪贴板(全局)",
                                  action: #selector(toggleBackgroundReading), keyEquivalent: "")
        bgItem.state = backgroundReading ? .on : .off
        let notifyItem = menu.addItem(withTitle: "同步成功时系统通知",
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
