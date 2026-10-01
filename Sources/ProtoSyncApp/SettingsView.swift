import SwiftUI
import AppKit
import Core

// “设备与设置”窗口:低频操作(改名、管理已配对设备、配对、剪贴板与文件设置)。
// 日常操作在菜单栏面板里;这里用系统 Form 控件,跟随系统深浅色,不使用 Lime(Lime 只属于面板)。

struct SettingsView: View {
    @ObservedObject var model: AppModel
    // 与 AppDelegate / 右键菜单读写同一组 UserDefaults 键
    @AppStorage("backgroundClipboardReading") private var backgroundReading = true
    @AppStorage("syncSuccessNotification") private var syncNotify = false
    @State private var pendingRemoval: DeviceRow?

    var body: some View {
        Form {
            if let request = model.pairingRequest { pairingSection(request) }
            if let offer = model.fileOffers.first { offerSection(offer) }
            identitySection
            pairedSection
            nearbySection
            clipboardSection
            filesSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 660)
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

    // MARK: - 待处理请求(面板关着时也能在这里处理)

    private func pairingSection(_ request: AppModel.PairingRequest) -> some View {
        Section("配对请求") {
            VStack(alignment: .leading, spacing: 8) {
                Text("「\(request.info.name)」请求配对").font(.headline)
                HStack(spacing: 6) {
                    Text("指纹").foregroundStyle(.secondary)
                    Text(shortFPText(request.info.fingerprint))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                }
                Text("确认对方屏幕上显示同一指纹后再接受。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("拒绝") { model.rejectPairing(request) }
                    Button("接受") { model.acceptPairing(request) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func offerSection(_ prompt: AppModel.FileOfferPrompt) -> some View {
        Section("文件请求") {
            VStack(alignment: .leading, spacing: 8) {
                Text("「\(prompt.offer.from.name)」想发送「\(prompt.offer.name)」")
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: prompt.offer.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("始终接收此设备的文件") { model.acceptFileOffer(prompt, alwaysTrust: true) }
                        .buttonStyle(.link)
                    Spacer()
                    Button("拒绝") { model.declineFileOffer(prompt) }
                    Button("接收") { model.acceptFileOffer(prompt) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 本机

    private var identitySection: some View {
        Section {
            LabeledContent("设备名") {
                TextField("设备名", text: $model.deviceName)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { model.store.renameDevice(model.deviceName) }
            }
            LabeledContent("指纹") {
                HStack(spacing: 8) {
                    // 配对时核对的是前 8 位;完整值放在悬停提示和复制按钮里,不占版面
                    Text(shortFPText(model.store.identity.fingerprint))
                        .font(.body.monospacedDigit())
                        .textSelection(.enabled)
                    Button("复制完整指纹") { copyToPasteboard(model.store.identity.fingerprint) }
                        .controlSize(.small)
                }
                .help(groupedFPText(model.store.identity.fingerprint))
            }
            LabeledContent("本机地址") {
                HStack(spacing: 8) {
                    Text(localAddress ?? "未连接网络")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(localAddress == nil ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                    if let localAddress {
                        Button("复制") { copyToPasteboard(localAddress) }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("本机")
        } footer: {
            footnote("改名后按回车保存，新名字在下次连接时生效。配对时双方核对的是指纹的前 8 位。")
        }
    }

    private var localAddress: String? {
        guard let ip = LanAddress.primaryIPv4(), model.engine.listeningPort > 0 else { return nil }
        return "\(ip):\(model.engine.listeningPort)"
    }

    // MARK: - 已配对设备

    private var pairedSection: some View {
        Section {
            if model.pairedDevices.isEmpty {
                Text("还没有配对的设备。在下方“附近的设备”里发起配对。")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.pairedRowsSorted) { row in
                HStack(spacing: 10) {
                    Image(systemName: Panel.glyph(for: row.name))
                        .font(.system(size: 16))
                        .foregroundStyle(row.online ? Color.primary : Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(row.online ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text("\(row.online ? "在线" : "离线") · \(shortFPText(row.fingerprint))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("自动接收")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle("自动接收 \(row.name) 的文件", isOn: fileTrustBinding(row))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Menu {
                        Button("移除此设备…", role: .destructive) { pendingRemoval = row }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(row.name) 的更多操作")
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Toggle("自动接收文件", isOn: fileTrustBinding(row))
                    Divider()
                    Button("移除此设备…", role: .destructive) { pendingRemoval = row }
                }
            }
        } header: {
            Text("已配对设备")
        } footer: {
            footnote("关闭“自动接收”后，这台设备发来的每个文件都需要你确认，2 分钟未处理自动拒绝。")
        }
    }

    // MARK: - 附近的设备

    private var nearbySection: some View {
        Section {
            if model.discoveredUnpaired.isEmpty {
                Text(model.isRefreshing ? "正在查找…" : "没有发现新设备。确认对方已打开 ProtoSync 且在同一网络。")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.discoveredUnpaired, id: \.self) { shortFp in
                HStack {
                    Text("设备 \(shortFp)").font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("配对") { model.pairWith(shortFp: shortFp) }
                }
            }
        } header: {
            HStack {
                Text("附近的设备")
                Spacer()
                Button(model.isRefreshing ? "正在查找…" : "重新查找") { model.refreshDevices() }
                    .controlSize(.small)
                    .disabled(model.isRefreshing)
            }
        }
    }

    // MARK: - 剪贴板

    private var clipboardSection: some View {
        Section {
            Toggle("同步本机剪贴板", isOn: $model.clipboardSyncEnabled)
            Toggle("在后台读取剪贴板", isOn: $backgroundReading)
            Toggle("同步成功时发送通知", isOn: $syncNotify)
        } header: {
            Text("剪贴板")
        } footer: {
            footnote("关闭后台读取后，只在菜单栏面板或本窗口打开时同步。密码管理器复制的内容（如 1Password、钥匙串）不会被同步，也不会进入历史。")
        }
    }

    // MARK: - 收到的文件

    private var filesSection: some View {
        Section("收到的文件") {
            LabeledContent("保存位置") {
                HStack(spacing: 8) {
                    Text(abbreviatedPath(model.engine.inboxDirectory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("在 Finder 中显示") { model.revealInbox() }
                        .controlSize(.small)
                }
            }
            ForEach(model.inboxFiles.prefix(5), id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("显示") { model.reveal(url) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - 工具

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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
