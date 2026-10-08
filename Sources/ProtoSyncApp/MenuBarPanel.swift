import SwiftUI
import Core

// 菜单栏弹出面板(设计方向 B,见 docs/design/MENUBAR_PANEL.md)。
// 日常操作都在这里完成:设备头像(拖文件即发送)、配对、文件请求、传输进度、剪贴板历史。
// 弹出面板固定深色外观(AppDelegate 设置 darkAqua),Lime 只用于主按钮、在线点与拖放高亮。

struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    var openMainWindow: () -> Void
    var quit: () -> Void
    @State private var showNearby = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            devices
            if showNearby { nearby }
            if let request = model.pairingRequest { PanelPairingCard(model: model, request: request) }
            if let outgoing = model.outgoingPairing { PanelOutgoingPairingCard(info: outgoing) }
            if let notice = model.pairingNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let offer = model.fileOffers.first {
                PanelOfferCard(model: model, prompt: offer, queued: model.fileOffers.count - 1)
            }
            if !model.activeTransfers.isEmpty { transfers }
            history
            footer
        }
        .padding(16)
        .frame(width: 360)
        .animation(.easeInOut(duration: 0.15), value: showNearby)
        .animation(.easeInOut(duration: 0.15), value: model.pairingRequest == nil)
        .animation(.easeInOut(duration: 0.15), value: model.outgoingPairing?.fingerprint)
        .animation(.easeInOut(duration: 0.15), value: model.fileOffers.first?.id)
    }

    // MARK: - 标题行

    private var header: some View {
        HStack(spacing: 8) {
            Text("ProtoSync").font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle(isOn: $model.clipboardSyncEnabled) {
                Text("同步剪贴板").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Panel.accent)
            .help("关闭后本机复制的内容不再发给其他设备，仍会接收其他设备的剪贴板")
            Menu {
                Button("打开主窗口…", action: openMainWindow)
                Button("设备与设置…", action: openSettings)
                Button("打开收件箱") { model.revealInbox() }
                Divider()
                Button("退出 ProtoSync", action: quit)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("设置")
        }
    }

    // MARK: - 设备头像(拖放目标)

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.pairedRowsSorted) { row in
                        PanelDeviceAvatar(row: row, model: model)
                    }
                    pairButton
                }
            }
            .fixedSize(horizontal: false, vertical: true)  // 自适应高度的弹出面板里,横向滚动区按内容定高
            if model.pairedDevices.isEmpty {
                Text("还没有配对的设备。点 + 查找附近的设备。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairButton: some View {
        Button {
            showNearby.toggle()
            if showNearby { model.refreshDevices() }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(showNearby ? Panel.accent : Color.secondary)
                    .overlay(Image(systemName: showNearby ? "xmark" : "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary))
                    .frame(width: 52, height: 52)
                Text("配对").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showNearby ? "收起附近的设备" : "配对新设备")
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("附近的设备").font(.system(size: 11)).foregroundStyle(.secondary)
            if model.discoveredUnpaired.isEmpty {
                Text(model.isRefreshing ? "正在查找…" : "没有发现新设备。确认对方已打开 ProtoSync 且在同一网络。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(model.discoveredUnpaired, id: \.self) { shortFp in
                HStack {
                    Text("设备 \(shortFp)").font(.system(size: 12).monospacedDigit())
                    Spacer()
                    Button("配对") { model.pairWith(shortFp: shortFp) }
                        .buttonStyle(PanelButtonStyle())
                        .frame(width: 64)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Panel.fill, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - 传输

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.activeTransfers) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.direction == .incoming ? "arrow.down" : "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(entry.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if entry.detail == "等待对方确认…" {
                            Text("等待对方确认").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Text("\(Int((entry.progress ?? 0) * 100))%")
                                .font(Panel.mono)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressBar(fraction: entry.progress ?? 0, fill: Panel.accent, height: 3)
                }
            }
        }
    }

    // MARK: - 剪贴板历史

    private var history: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("剪贴板历史").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !model.clipHistory.isEmpty {
                    Button("清空") { model.clearClipHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)
            if model.clipHistory.isEmpty {
                Text(model.clipboardSyncEnabled
                     ? "复制的内容会出现在这里，并同步到在线设备。"
                     : "剪贴板同步已暂停。其他设备发来的内容仍会出现在这里。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(model.clipHistory) { item in
                PanelClipRow(item: item) { model.copyFromHistory(item) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("拖文件到头像即可发送").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("打开窗口", action: openMainWindow)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("在完整窗口里查看设备、传输、剪贴板历史与收到的文件")
            Button("打开收件箱") { model.revealInbox() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Panel.accent)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

// MARK: - 设备头像

struct PanelDeviceAvatar: View {
    let row: DeviceRow
    @ObservedObject var model: AppModel
    @State private var targeted = false

    var body: some View {
        Button {
            if row.online { model.sendFile(to: row.fingerprint) }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(row.online ? Panel.fillStrong : Panel.fill)
                        .overlay(Circle().strokeBorder(targeted ? Panel.accent : Color.clear, lineWidth: 2))
                        .overlay(Image(systemName: Panel.glyph(for: row.name))
                            .font(.system(size: 19))
                            .foregroundStyle(row.online ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary))
                        .frame(width: 52, height: 52)
                    if row.online {
                        Circle()
                            .fill(Panel.accent)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2))
                            .offset(x: -2, y: -2)
                    }
                }
                .scaleEffect(targeted ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: targeted)
                Text(row.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(row.online ? Color.primary : Color.secondary)
            }
            .frame(width: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.online ? "点按选择文件，或把文件拖到这里发送给 \(row.name)" : "\(row.name) 当前离线")
        .dropDestination(for: URL.self) { urls, _ in
            guard row.online else { return false }
            return model.sendFiles(urls, to: row.fingerprint) > 0
        } isTargeted: { hovering in
            targeted = hovering && row.online
        }
        .contextMenu {
            if row.online {
                Button("发送文件…") { model.sendFile(to: row.fingerprint) }
            }
            Toggle("自动接收文件", isOn: Binding(
                get: { row.filesTrusted },
                set: { model.setFileTrust(fingerprint: row.fingerprint, trusted: $0) }))
            Divider()
            Button("移除此设备", role: .destructive) {
                model.removePaired(fingerprint: row.fingerprint)
            }
        }
        .accessibilityLabel("\(row.name),\(row.online ? "在线" : "离线")")
    }
}

// MARK: - 配对请求 / 文件请求

struct PanelPairingCard: View {
    @ObservedObject var model: AppModel
    let request: AppModel.PairingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("「\(request.info.name)」请求配对")
                .font(.system(size: 12, weight: .semibold))
            PanelSASCode(code: request.info.sas ?? shortFPText(request.info.fingerprint))
            Text("确认两台设备显示同一配对码后再接受。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("接受") { model.acceptPairing(request) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                Button("拒绝") { model.rejectPairing(request) }
                    .buttonStyle(PanelButtonStyle())
            }
        }
        .padding(12)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 配对码:两端相同的 6 位数字,大号等宽数字
struct PanelSASCode: View {
    let code: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("配对码").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 本机主动发起的配对:本机已同意,等对方核对同一配对码并接受
struct PanelOutgoingPairingCard: View {
    let info: PeerConnection.PeerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在与「\(info.name)」配对")
                    .font(.system(size: 12, weight: .semibold))
            }
            PanelSASCode(code: info.sas ?? shortFPText(info.fingerprint))
            Text("请在对方设备上确认同一配对码并接受。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PanelOfferCard: View {
    @ObservedObject var model: AppModel
    let prompt: AppModel.FileOfferPrompt
    var queued = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text(prompt.offer.from.name).fontWeight(.semibold)
             + Text(" 想发送「\(prompt.offer.name)」· ")
             + Text(ByteCountFormatter.string(fromByteCount: prompt.offer.size, countStyle: .file)))
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
            if queued > 0 {
                Text("另有 \(queued) 个请求").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("接收") { model.acceptFileOffer(prompt) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                Button("拒绝") { model.declineFileOffer(prompt) }
                    .buttonStyle(PanelButtonStyle())
                Button("总是") { model.acceptFileOffer(prompt, alwaysTrust: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("接收，并以后自动接收 \(prompt.offer.from.name) 的文件")
                    .padding(.horizontal, 6)
            }
        }
        .padding(12)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 剪贴板历史行

struct PanelClipRow: View {
    let item: AppModel.ClipItem
    let copy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 10) {
                if case .image(let png) = item.content, let image = NSImage(data: png) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(item.source) · \(item.time.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if copied {
                    Text("已复制").font(.system(size: 11)).foregroundStyle(Panel.accent)
                } else if hovering {
                    Text("复制")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Panel.fillStrong, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Panel.fill : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("复制:\(preview)")
    }

    private var preview: String {
        switch item.content {
        case .text(let text):
            return text.replacingOccurrences(of: "\n", with: " ")
        case .image(let png):
            if let rep = NSBitmapImageRep(data: png) { return "图片 · \(rep.pixelsWide)×\(rep.pixelsHigh)" }
            return "图片"
        }
    }
}
