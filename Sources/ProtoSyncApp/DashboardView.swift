import SwiftUI
import Core

// 主窗口仪表盘:头部状态 / 配对请求 / 设备列表 / 活动流 / 收件箱。

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    if let request = model.pairingRequest {
                        PairingBanner(model: model, request: request)
                    }
                    deviceSection
                    if !model.discoveredUnpaired.isEmpty {
                        discoveredSection
                    }
                    activitySection
                    inboxSection
                }
                .padding(14)
            }
        }
        .frame(minWidth: 480, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("ProtoSync")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.onlinePeers.isEmpty ? Color.gray : Color.green)
                        .frame(width: 7, height: 7)
                    Text(model.onlinePeers.isEmpty ? "未连接任何设备" : "\(model.onlinePeers.count) 台设备在线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.refreshDevices()
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("重新搜索局域网设备")
            VStack(alignment: .trailing, spacing: 4) {
                TextField("设备名", text: $model.deviceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit {
                        model.store.renameDevice(model.deviceName)
                    }
                Text("本机指纹 \(DeviceIdentity.shortFingerprint(model.store.identity.fingerprint))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    // MARK: - 已配对设备

    private var deviceSection: some View {
        GroupBox(label: Label("设备", systemImage: "laptopcomputer.and.ipad")) {
            VStack(spacing: 0) {
                if model.pairedDevices.isEmpty {
                    Text("还没有配对设备。在另一台设备上运行 ProtoSync,点右上角 ↻ 刷新搜索,再从“发现的设备”发起配对。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.pairedDevices, id: \.fingerprint) { device in
                        pairedRow(device)
                        if device.fingerprint != model.pairedDevices.last?.fingerprint {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func pairedRow(_ device: IdentityStore.PairedDevice) -> some View {
        let online = model.onlinePeers.first { $0.fingerprint == device.fingerprint }
        return HStack(spacing: 10) {
            Circle()
                .fill(online != nil ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(.body, design: .default).weight(.medium))
                HStack(spacing: 6) {
                    Text(DeviceIdentity.shortFingerprint(device.fingerprint))
                        .font(.caption2.monospaced())
                    if online != nil {
                        Text("在线")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if online != nil {
                Button {
                    model.sendFile(to: device.fingerprint)
                } label: {
                    Label("发送文件", systemImage: "paperplane")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
            }
            Menu {
                Button("移除此设备", role: .destructive) {
                    model.removePaired(fingerprint: device.fingerprint)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.vertical, 7)
    }

    // MARK: - 发现的未配对设备

    private var discoveredSection: some View {
        GroupBox(label: Label("发现的设备", systemImage: "antenna.radiowaves.left.and.right")) {
            VStack(spacing: 0) {
                ForEach(model.discoveredUnpaired, id: \.self) { shortFp in
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        Text("设备 \(shortFp)")
                            .font(.callout.monospaced())
                        Spacer()
                        Button("配对…") {
                            model.pairWith(shortFp: shortFp)
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    // MARK: - 活动流

    private var activitySection: some View {
        GroupBox(label: Label("活动", systemImage: "clock.arrow.circlepath")) {
            VStack(spacing: 0) {
                if model.activities.isEmpty {
                    Text("剪贴板与文件流转会显示在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.activities) { entry in
                        ActivityRow(entry: entry)
                        if entry.id != model.activities.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    // MARK: - 收件箱

    private var inboxSection: some View {
        GroupBox(label: Label("收件箱", systemImage: "tray.full")) {
            VStack(spacing: 0) {
                if model.inboxFiles.isEmpty {
                    Text("收到的文件保存在 ~/Downloads/ProtoSync/")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.inboxFiles.prefix(6), id: \.self) { url in
                        HStack {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                model.reveal(url)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("在 Finder 中显示")
                        }
                        .padding(.vertical, 6)
                    }
                }
                HStack {
                    Spacer()
                    Button("打开收件箱文件夹") {
                        model.revealInbox()
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 子视图

struct PairingBanner: View {
    @ObservedObject var model: AppModel
    let request: AppModel.PairingRequest

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("「\(request.info.name)」请求配对")
                    .font(.headline)
                Text("指纹 \(DeviceIdentity.shortFingerprint(request.info.fingerprint)) — 确认这是你的设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("拒绝") { model.rejectPairing(request) }
                .controlSize(.small)
            Button("接受") { model.acceptPairing(request) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActivityRow: View {
    let entry: AppModel.ActivityEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.failed ? Color.red : Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(entry.detail) · \(entry.time.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(entry.failed ? Color.red : Color.secondary)
                if let progress = entry.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            Image(systemName: entry.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    private var icon: String {
        switch entry.kind {
        case .text: return "doc.on.doc"
        case .image: return "photo"
        case .file: return entry.failed ? "exclamationmark.triangle" : "doc"
        }
    }
}
