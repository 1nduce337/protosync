import SwiftUI
import AppKit
import Core

// “设备与设置”窗口:低频操作(改名、管理已配对设备、配对、剪贴板与文件设置)。
// 与菜单栏面板同一套视觉语言(见 docs/design/MENUBAR_PANEL.md):固定深色、填充分组而非描边、
// 系统字体;Lime 只用于开启的开关、在线点与主按钮。窗口外观由 AppDelegate 设为 darkAqua。

struct SettingsView: View {
    @ObservedObject var model: AppModel
    // 与 AppDelegate / 右键菜单读写同一组 UserDefaults 键
    @AppStorage("backgroundClipboardReading") private var backgroundReading = true
    @AppStorage(Notifier.syncNotifyKey) private var syncNotify = false
    /// 系统设置里关掉了本 App 的通知(开关打开也不会弹),显示去设置的提示
    @State private var notificationsBlocked = false
    @State private var pendingRemoval: DeviceRow?
    @State private var copiedFingerprint = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let request = model.pairingRequest { PanelPairingCard(model: model, request: request) }
                if let outgoing = model.outgoingPairing { PanelOutgoingPairingCard(info: outgoing) }
                if let notice = model.pairingNotice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let offer = model.fileOffers.first {
                    PanelOfferCard(model: model, prompt: offer, queued: model.fileOffers.count - 1)
                }
                pairedSection
                nearbySection
                clipboardSection
                filesSection
            }
            .padding(24)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 660)
        .tint(Panel.accent)
        .animation(.easeInOut(duration: 0.15), value: model.pairingRequest == nil)
        .animation(.easeInOut(duration: 0.15), value: model.fileOffers.first?.id)
        .confirmationDialog("移除这台设备？", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { row in
            Button("移除「\(row.name)」", role: .destructive) {
                model.removePaired(fingerprint: row.fingerprint)
            }
        } message: { _ in
            Text("移除后需要重新配对才能互传剪贴板和文件。")
        }
    }

    // MARK: - 本机(窗口标题区)

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Panel.fillStrong)
                    .overlay(Image(systemName: "laptopcomputer").font(.system(size: 22)))
                    .frame(width: 56, height: 56)
                Circle()
                    .fill(Panel.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2))
                    .offset(x: -2, y: -2)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("设备名", text: $model.deviceName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .onSubmit { model.store.renameDevice(model.deviceName) }
                    .help("改名后按回车保存，新名字在下次连接时生效")
                HStack(spacing: 6) {
                    Text("指纹").foregroundStyle(.secondary)
                    Text(shortFPText(model.store.identity.fingerprint))
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .help(groupedFPText(model.store.identity.fingerprint))
                    Button(copiedFingerprint ? "已复制" : "复制完整指纹") {
                        copyToPasteboard(model.store.identity.fingerprint)
                        copiedFingerprint = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFingerprint = false }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copiedFingerprint ? Panel.accent : Color.secondary)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.onlinePeers.isEmpty ? "没有设备在线" : "\(model.onlinePeers.count) 台设备在线")
                    .font(.system(size: 12))
                    .foregroundStyle(model.onlinePeers.isEmpty ? Color.secondary : Color.primary)
                if let localAddress {
                    Button {
                        copyToPasteboard(localAddress)
                    } label: {
                        HStack(spacing: 4) {
                            Text(localAddress).monospacedDigit()
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("复制本机地址(手动连接时使用)")
                } else {
                    Text("未连接网络").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var localAddress: String? {
        guard let ip = LanAddress.primaryIPv4(), model.engine.listeningPort > 0 else { return nil }
        return "\(ip):\(model.engine.listeningPort)"
    }

    // MARK: - 已配对设备

    private var pairedSection: some View {
        SettingsSection("已配对设备",
                        footnote: "关闭“自动接收”后，这台设备发来的每个文件都需要你确认，2 分钟未处理自动拒绝。") {
            if model.pairedDevices.isEmpty {
                SettingsRow {
                    Text("还没有配对的设备。在下方“附近的设备”里发起配对。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(model.pairedRowsSorted.enumerated()), id: \.element.id) { index, row in
                if index > 0 { SettingsDivider() }
                SettingsRow {
                    PanelSmallAvatar(name: row.name, online: row.online)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .foregroundStyle(row.online ? Color.primary : Color.secondary)
                        Text("\(row.online ? "在线" : "离线") · \(shortFPText(row.fingerprint))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("自动接收").font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("自动接收 \(row.name) 的文件", isOn: fileTrustBinding(row))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Menu {
                        Button("移除此设备…", role: .destructive) { pendingRemoval = row }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(row.name) 的更多操作")
                }
                .contextMenu {
                    Toggle("自动接收文件", isOn: fileTrustBinding(row))
                    Divider()
                    Button("移除此设备…", role: .destructive) { pendingRemoval = row }
                }
            }
        }
    }

    // MARK: - 附近的设备

    private var nearbySection: some View {
        SettingsSection("附近的设备", trailing: {
            Button(model.isRefreshing ? "正在查找…" : "重新查找") { model.refreshDevices() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(model.isRefreshing)
        }) {
            if model.discoveredUnpaired.isEmpty {
                SettingsRow {
                    Text(model.isRefreshing ? "正在查找…" : "没有发现新设备。确认对方已打开 ProtoSync 且在同一网络。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(model.discoveredUnpaired.enumerated()), id: \.element) { index, shortFp in
                if index > 0 { SettingsDivider() }
                SettingsRow {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                    Text("设备 \(shortFp)").monospacedDigit()
                    Spacer()
                    Button("配对") { model.pairWith(shortFp: shortFp) }
                        .buttonStyle(PanelButtonStyle(prominent: true))
                        .frame(width: 64)
                }
            }
        }
    }

    // MARK: - 剪贴板

    private var clipboardSection: some View {
        SettingsSection("剪贴板",
                        footnote: "密码管理器复制的内容（如 1Password、钥匙串）不会被同步，也不会进入历史。") {
            toggleRow("同步本机剪贴板", detail: "关闭后仍会接收其他设备的剪贴板",
                      isOn: $model.clipboardSyncEnabled)
            SettingsDivider()
            toggleRow("在后台读取剪贴板", detail: "关闭后只在面板或本窗口打开时同步",
                      isOn: $backgroundReading)
            SettingsDivider()
            toggleRow("同步时发送通知", detail: "发出或收到剪贴板、收到文件时提醒；菜单栏图标始终会短暂提示",
                      isOn: $syncNotify)
            if syncNotify && notificationsBlocked {
                SettingsDivider()
                SettingsRow {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                    Text("系统设置里关闭了 ProtoSync 的通知")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开通知设置") { Notifier.shared.openSystemSettings() }
                        .buttonStyle(PanelButtonStyle(prominent: false))
                        .fixedSize()
                }
            }
        }
        .onAppear(perform: checkNotifications)
        .onChange(of: syncNotify) { _ in checkNotifications() }
        // 从系统设置改完回来时刷新提示
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkNotifications()
        }
    }

    private func checkNotifications() {
        guard syncNotify else { notificationsBlocked = false; return }
        Notifier.shared.checkAuthorization { allowed in notificationsBlocked = !allowed }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    // MARK: - 收到的文件

    private var filesSection: some View {
        SettingsSection("收到的文件") {
            SettingsRow {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 34)
                Text(abbreviatedPath(model.engine.inboxDirectory))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示") { model.revealInbox() }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
            }
            ForEach(model.inboxFiles.prefix(5), id: \.self) { url in
                SettingsDivider()
                SettingsRow {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                        .frame(width: 34)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("显示") { model.reveal(url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 工具

    private func fileTrustBinding(_ row: DeviceRow) -> Binding<Bool> {
        Binding(get: { row.filesTrusted },
                set: { model.setFileTrust(fingerprint: row.fingerprint, trusted: $0) })
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - 分组组件(填充底、无描边,与面板一致)

struct SettingsSection<Content: View, Trailing: View>: View {
    let title: String
    var footnote: String?
    let trailing: Trailing
    let content: Content

    init(_ title: String, footnote: String? = nil,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(Panel.fill, in: RoundedRectangle(cornerRadius: 10))
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footnote: footnote, trailing: { EmptyView() }, content: content)
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 56)
    }
}

/// 设置窗口里的小号设备头像(34 pt),与面板头像同一形态
struct PanelSmallAvatar: View {
    let name: String
    let online: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(online ? Panel.fillStrong : Panel.fill)
                .overlay(Image(systemName: Panel.glyph(for: name))
                    .font(.system(size: 14))
                    .foregroundStyle(online ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary))
                .frame(width: 34, height: 34)
            if online {
                Circle()
                    .fill(Panel.accent)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5))
            }
        }
    }
}
