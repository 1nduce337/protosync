import SwiftUI
import AppKit
import Core

// 主窗口:菜单栏面板的完整版(设计方向 B,见 docs/design/MENUBAR_PANEL.md)。
// 面板里能做的事这里都能做,空间更大:设备大号拖放区(可一次拖多个文件)、配对、请求、
// 传输列表、剪贴板历史、收到的文件。普通窗口,切到访达选文件不会收起。
// 视觉与面板一致:固定深色、填充分组而非描边、系统字体;Lime 只用于在线点、拖放高亮、进度与主按钮。

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    @State private var showNearby = false
    @State private var pendingRemoval: DeviceRow?

    private let deviceColumns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                requests
                devicesSection
                if showNearby { nearbySection }
                // 宽窗口两栏(传输 | 剪贴板历史),窄窗口上下排
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        transfersSection.frame(minWidth: 300, maxWidth: .infinity)
                        historySection.frame(minWidth: 300, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        transfersSection
                        historySection
                    }
                }
                filesSection
            }
            .padding(24)
        }
        .frame(minWidth: 460, idealWidth: 760, minHeight: 520, idealHeight: 680)
        .tint(Panel.accent)
        .animation(.easeInOut(duration: 0.15), value: showNearby)
        .animation(.easeInOut(duration: 0.15), value: model.pairingRequest == nil)
        .animation(.easeInOut(duration: 0.15), value: model.outgoingPairing?.fingerprint)
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

    // MARK: - 标题区

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(Panel.fillStrong)
                .overlay(Image(systemName: "laptopcomputer").font(.system(size: 20)))
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.deviceName.isEmpty ? "ProtoSync" : model.deviceName)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $model.clipboardSyncEnabled) {
                Text("同步剪贴板").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("关闭后本机复制的内容不再发给其他设备，仍会接收其他设备的剪贴板")
            Button("设备与设置…", action: openSettings)
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
        }
    }

    private var statusLine: String {
        let online = model.onlinePeers.count
        let devices = online == 0 ? "没有设备在线" : "\(online) 台设备在线"
        return devices + (model.clipboardSyncEnabled ? " · 复制即同步" : " · 剪贴板同步已暂停")
    }

    // MARK: - 请求(配对 / 文件)

    @ViewBuilder private var requests: some View {
        if let request = model.pairingRequest { PanelPairingCard(model: model, request: request) }
        if let outgoing = model.outgoingPairing { PanelOutgoingPairingCard(info: outgoing) }
        if let notice = model.pairingNotice {
            Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if let offer = model.fileOffers.first {
            PanelOfferCard(model: model, prompt: offer, queued: model.fileOffers.count - 1)
        }
    }

    // MARK: - 设备

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("设备", trailing: "拖文件到设备上即可发送，可以一次拖多个")
            LazyVGrid(columns: deviceColumns, alignment: .leading, spacing: 12) {
                ForEach(model.pairedRowsSorted) { row in
                    WindowDeviceTile(row: row, model: model) { pendingRemoval = row }
                }
                WindowPairTile(active: showNearby) {
                    showNearby.toggle()
                    if showNearby { model.refreshDevices() }
                }
            }
        }
    }

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
                    PanelSmallAvatar(name: "", online: false)
                    Text("设备 \(shortFp)").monospacedDigit()
                    Spacer()
                    Button("配对") { model.pairWith(shortFp: shortFp) }
                        .buttonStyle(PanelButtonStyle(prominent: true))
                        .frame(width: 64)
                }
            }
        }
    }

    // MARK: - 传输

    private var transfersSection: some View {
        let entries = model.recentFileTransfers
        return SettingsSection("传输") {
            if entries.isEmpty {
                SettingsRow {
                    Text("发送和收到的文件会显示在这里。").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 34) }
                WindowTransferRow(entry: entry)
            }
        }
    }

    // MARK: - 剪贴板历史

    private var historySection: some View {
        SettingsSection("剪贴板历史", footnote: "只保存在内存里，退出后清空。", trailing: {
            if !model.clipHistory.isEmpty {
                Button("清空") { model.clearClipHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }) {
            if model.clipHistory.isEmpty {
                SettingsRow {
                    Text(model.clipboardSyncEnabled
                         ? "复制的内容会出现在这里，并同步到在线设备。"
                         : "剪贴板同步已暂停。其他设备发来的内容仍会出现在这里。")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(model.clipHistory) { item in
                        PanelClipRow(item: item) { model.copyFromHistory(item) }
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: - 收到的文件

    private var filesSection: some View {
        SettingsSection("收到的文件", trailing: {
            Button("打开收件箱") { model.revealInbox() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Panel.accent)
        }) {
            if model.inboxFiles.isEmpty {
                SettingsRow {
                    Text("其他设备发来的文件会保存在收件箱里。").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(model.inboxFiles.prefix(8).enumerated()), id: \.element) { index, url in
                if index > 0 { SettingsDivider() }
                WindowFileRow(url: url, reveal: { model.reveal(url) })
            }
        }
    }

    private func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 设备拖放区

struct WindowDeviceTile: View {
    let row: DeviceRow
    @ObservedObject var model: AppModel
    var requestRemoval: () -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        Button {
            if row.online { model.sendFile(to: row.fingerprint) }
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(row.online ? Panel.fillStrong : Panel.fill)
                        .overlay(Image(systemName: Panel.glyph(for: row.name))
                            .font(.system(size: 22))
                            .foregroundStyle(row.online ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary))
                        .frame(width: 56, height: 56)
                    if row.online {
                        Circle()
                            .fill(Panel.accent)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2))
                            .offset(x: -2, y: -2)
                    }
                }
                .scaleEffect(targeted ? 1.08 : 1)
                VStack(spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(row.online ? Color.primary : Color.secondary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(targeted ? AnyShapeStyle(Panel.accent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(targeted || (hovering && row.online) ? Panel.fillStrong : Panel.fill,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Panel.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard row.online else { return false }
            return model.sendFiles(urls, to: row.fingerprint) > 0
        } isTargeted: { over in
            targeted = over && row.online
        }
        .contextMenu {
            if row.online {
                Button("发送文件…") { model.sendFile(to: row.fingerprint) }
            }
            Toggle("自动接收文件", isOn: Binding(
                get: { row.filesTrusted },
                set: { model.setFileTrust(fingerprint: row.fingerprint, trusted: $0) }))
            Divider()
            Button("移除此设备…", role: .destructive, action: requestRemoval)
        }
        .help(row.online ? "把文件拖到这里发送给 \(row.name)，可一次拖多个；右键查看更多选项" : "\(row.name) 当前离线")
        .accessibilityLabel("\(row.name)，\(row.online ? "在线" : "离线")")
    }

    private var subtitle: String {
        guard row.online else { return "离线" }
        if targeted { return "松开即发送" }
        return row.filesTrusted ? "拖入或点按选择文件" : "拖入或点按选择 · 需对方确认"
    }
}

struct WindowPairTile: View {
    let active: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 10) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(active ? Panel.accent : Color.secondary)
                    .overlay(Image(systemName: active ? "xmark" : "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary))
                    .frame(width: 56, height: 56)
                VStack(spacing: 2) {
                    Text("配对新设备").font(.system(size: 13, weight: .medium))
                    Text(active ? "收起附近的设备" : "查找同一网络里的设备")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "收起附近的设备" : "配对新设备")
    }
}

// MARK: - 传输行 / 文件行

struct WindowTransferRow: View {
    let entry: AppModel.ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.direction == .incoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(status)
                    .font(showsPercent ? Panel.mono : .system(size: 11))
                    .foregroundStyle(entry.failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if let progress = entry.progress {
                ProgressBar(fraction: progress, fill: Panel.accent, height: 3)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var waiting: Bool { entry.detail == "等待对方确认…" }
    private var showsPercent: Bool { entry.progress != nil && !waiting }

    private var status: String {
        if entry.progress != nil {
            return waiting ? "等待对方确认" : "\(Int((entry.progress ?? 0) * 100))%"
        }
        return entry.detail
    }
}

struct WindowFileRow: View {
    let url: URL
    let reveal: () -> Void
    @State private var hovering = false

    var body: some View {
        SettingsRow {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = modified {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hovering {
                Button("打开") { NSWorkspace.shared.open(url) }
                    .buttonStyle(PanelButtonStyle(height: 24, fontSize: 11))
                    .fixedSize()
                Button("显示") { reveal() }
                    .buttonStyle(PanelButtonStyle(height: 24, fontSize: 11))
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help("双击打开")
    }

    private var modified: Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
