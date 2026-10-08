import SwiftUI
import Core

// “发送文件”窗口:菜单栏面板的大号版本,适合一次发送多个文件。
// 普通窗口,切到访达选文件不会收起;每台设备一块大号拖放区,点按可多选文件。
// 视觉与面板一致(docs/design/MENUBAR_PANEL.md):固定深色、填充分组、Lime 只用于在线点、拖放高亮与进度。

struct SendWindowView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发送文件").font(.system(size: 17, weight: .semibold))
                    Text("把文件拖到设备上即可发送，可以一次拖多个；也可以点设备选择文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let request = model.pairingRequest { PanelPairingCard(model: model, request: request) }
                if let offer = model.fileOffers.first {
                    PanelOfferCard(model: model, prompt: offer, queued: model.fileOffers.count - 1)
                }

                if model.pairedDevices.isEmpty {
                    Text("还没有配对的设备。在菜单栏面板里点 + 配对新设备。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.pairedRowsSorted) { row in
                            SendDeviceTile(row: row, model: model)
                        }
                    }
                }

                transfers
            }
            .padding(20)
        }
        .frame(minWidth: 420, minHeight: 380)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("文件夹暂不支持，请先压缩。").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("打开收件箱") { model.revealInbox() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Panel.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - 传输列表

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("传输").font(.system(size: 11)).foregroundStyle(.secondary)
            let entries = model.recentFileTransfers
            if entries.isEmpty {
                Text("发送和收到的文件会显示在这里。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                        SendTransferRow(entry: entry)
                    }
                }
                .background(Panel.fill, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - 设备拖放区

struct SendDeviceTile: View {
    let row: DeviceRow
    @ObservedObject var model: AppModel
    @State private var targeted = false

    var body: some View {
        Button {
            if row.online { model.sendFile(to: row.fingerprint) }
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: Panel.glyph(for: row.name))
                        .font(.system(size: 28))
                        .foregroundStyle(row.online ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
                        .frame(width: 56, height: 56)
                    if row.online {
                        Circle()
                            .fill(Panel.accent)
                            .frame(width: 10, height: 10)
                            .offset(x: -4, y: -6)
                    }
                }
                VStack(spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(row.online ? Color.primary : Color.secondary)
                    Text(row.online ? (targeted ? "松开即发送" : "拖文件到这里，或点按选择") : "离线")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(targeted ? Panel.fillStrong : Panel.fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Panel.accent : Color.clear, lineWidth: 2))
            .opacity(row.online ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!row.online)
        .animation(.easeOut(duration: 0.12), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard row.online else { return false }
            return model.sendFiles(urls, to: row.fingerprint) > 0
        } isTargeted: { hovering in
            targeted = hovering && row.online
        }
        .help(row.online ? "把文件拖到这里发送给 \(row.name)，可一次拖多个" : "\(row.name) 当前离线")
        .accessibilityLabel("\(row.name)，\(row.online ? "在线" : "离线")")
    }
}

// MARK: - 传输行

struct SendTransferRow: View {
    let entry: AppModel.ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.direction == .incoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(status)
                    .font(entry.progress != nil && entry.detail != "等待对方确认…" ? Panel.mono : .system(size: 11))
                    .foregroundStyle(entry.failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if let progress = entry.progress {
                ProgressBar(fraction: progress, fill: Panel.accent, height: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var status: String {
        if entry.progress != nil {
            return entry.detail == "等待对方确认…" ? "等待对方确认" : "\(Int((entry.progress ?? 0) * 100))%"
        }
        return entry.detail
    }
}
