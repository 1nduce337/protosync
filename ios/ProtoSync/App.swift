import SwiftUI
import Core
import QuickLook
import UniformTypeIdentifiers

@main
struct ProtoSyncApp: App {
    @StateObject private var model = IOSAppModel()

    var body: some Scene {
        WindowGroup { RootView(model: model) }
    }
}

/// 单屏面板(设计方向 B 的 iPhone 版,见 docs/design/MENUBAR_PANEL.md):
/// 设备头像 → 待决请求 → 传输 → 剪贴板历史 → 收到的文件;底部固定“发送剪贴板”。
/// 固定深色外观,Lime 只用于主按钮、在线点与进度。
struct RootView: View {
    @ObservedObject var model: IOSAppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showFilePicker = false
    @State private var showPeerPicker = false
    @State private var showSettings = false
    @State private var showNearby = false
    @State private var fileTarget: PeerConnection.PeerInfo?
    @State private var pickedURL: URL?
    @State private var previewURL: URL?
    @State private var copiedID: UUID?

    private static let canvas = Color(signal: 0x141416)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if let err = model.initError { errorCard(err) }
                devices
                if showNearby { nearby }
                if let request = model.pairing { pairingCard(request) }
                if let outgoing = model.outgoingPairing { outgoingPairingCard(outgoing) }
                if let notice = model.pairingNotice {
                    Text(notice).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if let offer = model.fileOffers.first { offerCard(offer) }
                if !model.transfers.isEmpty { transfers }
                history
                inbox
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Self.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { actionBar }
        .preferredColorScheme(.dark)
        .tint(Panel.accent)
        .animation(.easeInOut(duration: 0.2), value: showNearby)
        .animation(.easeInOut(duration: 0.2), value: model.pairing?.id)
        .animation(.easeInOut(duration: 0.2), value: model.outgoingPairing?.fingerprint)
        .animation(.easeInOut(duration: 0.2), value: model.fileOffers.first?.id)
        .onAppear {
            model.refresh()
            model.refreshNearby()
            model.refreshInbox()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshInbox() }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], onCompletion: handlePickedFile)
        .confirmationDialog("发送给哪台设备？", isPresented: $showPeerPicker, titleVisibility: .visible) {
            ForEach(model.peers, id: \.fingerprint) { peer in
                Button(peer.name) { sendPickedFile(to: peer) }
            }
            Button("取消", role: .cancel) {}
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showSettings) { IOSSettingsSheet(model: model) }
    }

    // MARK: - 标题行

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ProtoSync").font(.system(size: 17, weight: .semibold))
                if !model.ready {
                    Text(model.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)   // 不继承 Lime 强调色:Lime 只给主按钮
            .accessibilityLabel("设置")
            .disabled(!model.ready)
        }
    }

    private func errorCard(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("初始化失败")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(signal: 0xFF6B66))
            Text(err)
                .font(.system(size: 11).monospaced())
                .textSelection(.enabled)
            Button("复制错误信息") { UIPasteboard.general.string = err }
                .buttonStyle(PanelButtonStyle(height: 44, fontSize: 15))
        }
        .padding(16)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 设备头像

    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                ForEach(model.pairedRows) { row in avatar(row) }
                pairTile
            }
            if model.paired.isEmpty && model.ready {
                Text("还没有配对的设备。点 + 查找附近的设备。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func avatar(_ row: DeviceRow) -> some View {
        Button {
            guard let peer = model.peer(for: row.fingerprint) else { return }
            fileTarget = peer
            showFilePicker = true
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(row.online ? Panel.fillStrong : Panel.fill)
                        .overlay(Image(systemName: Panel.glyph(for: row.name))
                            .font(.system(size: 26))
                            .foregroundStyle(row.online ? Color.primary : Color.secondary.opacity(0.6)))
                        .frame(width: 76, height: 76)
                    if row.online {
                        Circle()
                            .fill(Panel.accent)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().strokeBorder(Self.canvas, lineWidth: 2.5))
                            .offset(x: -4, y: -4)
                    }
                }
                Text(row.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(row.online ? Color.primary : Color.secondary)
                Text(row.online ? (row.filesTrusted ? "在线" : "在线 · 文件需确认") : "离线")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, -4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if row.online, let peer = model.peer(for: row.fingerprint) {
                Button("发送文件…", systemImage: "doc") {
                    fileTarget = peer
                    showFilePicker = true
                }
            }
            Toggle("自动接收文件", isOn: Binding(
                get: { row.filesTrusted },
                set: { model.setFileTrust(.init(fingerprint: row.fingerprint, name: row.name), trusted: $0) }))
            Button("移除此设备", systemImage: "trash", role: .destructive) { model.removePaired(row) }
        }
        .accessibilityLabel("\(row.name)，\(row.online ? "在线，点按发送文件" : "离线")")
    }

    private var pairTile: some View {
        Button {
            showNearby.toggle()
            if showNearby { model.scan() }
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(showNearby ? Panel.accent : Color.secondary)
                    .overlay(Image(systemName: showNearby ? "xmark" : "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary))
                    .frame(width: 76, height: 76)
                Text("配对").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.ready)
        .accessibilityLabel(showNearby ? "收起附近的设备" : "配对新设备")
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("附近的设备")
            if model.nearby.isEmpty {
                Text(model.isScanning ? "正在查找…" : "没有发现新设备。确认对方已打开 ProtoSync 且在同一网络。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.nearby, id: \.self) { shortFp in
                HStack {
                    Text("设备 \(shortFp)").font(.system(size: 15).monospacedDigit())
                    Spacer()
                    Button("配对") { model.pairWith(shortFp: shortFp) }
                        .buttonStyle(PanelButtonStyle(height: 36, fontSize: 14))
                        .frame(width: 76)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Panel.fill, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - 配对请求 / 文件请求

    private func pairingCard(_ request: IOSAppModel.PairingRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("「\(request.info.name)」请求配对").font(.system(size: 15, weight: .semibold))
            sasCode(request.info.sas ?? shortFPText(request.info.fingerprint))
            Text("确认两台设备显示同一配对码后再接受。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("接受") { model.pairAccepted(request, true) }
                    .buttonStyle(PanelButtonStyle(prominent: true, height: 44, fontSize: 15))
                Button("拒绝") { model.pairAccepted(request, false) }
                    .buttonStyle(PanelButtonStyle(height: 44, fontSize: 15))
            }
        }
        .padding(16)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sasCode(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("配对码").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(code).font(.system(size: 28, weight: .medium).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    /// 本机主动发起的配对:本机已同意,等对方核对同一配对码并接受
    private func outgoingPairingCard(_ info: PeerConnection.PeerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在与「\(info.name)」配对").font(.system(size: 15, weight: .semibold))
            }
            sasCode(info.sas ?? shortFPText(info.fingerprint))
            Text("请在对方设备上确认同一配对码并接受。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 16))
    }

    private func offerCard(_ prompt: IOSAppModel.FileOfferPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            (Text(prompt.offer.from.name).fontWeight(.semibold) + Text(" 想发送「\(prompt.offer.name)」"))
                .font(.system(size: 15))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: prompt.offer.size, countStyle: .file))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, -6)
            HStack(spacing: 10) {
                Button("接收") { model.decideFileOffer(prompt, accept: true) }
                    .buttonStyle(PanelButtonStyle(prominent: true, height: 44, fontSize: 15))
                Button("拒绝") { model.decideFileOffer(prompt, accept: false) }
                    .buttonStyle(PanelButtonStyle(height: 44, fontSize: 15))
            }
            Button("接收，并始终信任此设备的文件") {
                model.decideFileOffer(prompt, accept: true, alwaysTrust: true)
            }
            .font(.system(size: 13))
            .foregroundStyle(Panel.accent)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .padding(16)
        .background(Panel.fill, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 传输

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.transfers) { t in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: t.incoming ? "arrow.down" : "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(t.name).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int(t.fraction * 100))%")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressBar(fraction: t.fraction, fill: Panel.accent, height: 3)
                }
            }
        }
    }

    // MARK: - 剪贴板历史

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("剪贴板历史")
                Spacer()
                if !model.clipHistory.isEmpty {
                    Text("点按即复制").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if model.clipHistory.isEmpty {
                Text("收到或发出的剪贴板会出现在这里。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.clipHistory) { item in
                Button {
                    model.copyFromHistory(item)
                    copiedID = item.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copiedID == item.id { copiedID = nil }
                    }
                } label: {
                    HStack(spacing: 12) {
                        if case .image(let png) = item.content, let image = UIImage(data: png) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preview(item)).font(.system(size: 15)).lineLimit(1)
                            Text("\(item.source) · \(item.time.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if copiedID == item.id {
                            Text("已复制").font(.system(size: 13)).foregroundStyle(Panel.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Panel.fill, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制：\(preview(item))")
            }
        }
    }

    private func preview(_ item: IOSAppModel.ClipItem) -> String {
        switch item.content {
        case .text(let text):
            return text.replacingOccurrences(of: "\n", with: " ")
        case .image(let png):
            guard let image = UIImage(data: png) else { return "图片" }
            return "图片 · \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))"
        }
    }

    // MARK: - 收到的文件

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("收到的文件")
            if model.inbox.isEmpty {
                Text("收到的文件会保存在这里，也可以在“文件”App › 我的 iPhone › ProtoSync 中管理。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.inbox.prefix(5), id: \.absoluteString) { url in
                Button {
                    previewURL = url
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 15))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Panel.fill, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("发送剪贴板") { model.sendClipboard() }
                .buttonStyle(PanelButtonStyle(prominent: true, height: 54, fontSize: 17))
                .disabled(!model.ready)
            Button {
                fileTarget = nil
                showFilePicker = true
            } label: {
                Image(systemName: "doc")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.primary)
                    .frame(width: 54, height: 54)
                    .background(Panel.fillStrong, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!model.ready || model.peers.isEmpty)
            .accessibilityLabel("发送文件")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Self.canvas.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }

    // MARK: - 文件选择

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { fileTarget = nil; return }
        pickedURL = url
        if let target = fileTarget {
            fileTarget = nil
            sendPickedFile(to: target)
        } else if model.peers.count == 1 {
            sendPickedFile(to: model.peers[0])
        } else if model.peers.isEmpty {
            model.events.insert(IOSAppModel.Event(line: "没有在线设备，发送取消"), at: 0)
        } else {
            showPeerPicker = true
        }
    }

    private func sendPickedFile(to peer: PeerConnection.PeerInfo) {
        guard let url = pickedURL else { return }
        model.sendFile(at: url, to: peer)
    }
}

// MARK: - 设置

struct IOSSettingsSheet: View {
    @ObservedObject var model: IOSAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if model.ready {
                    Section {
                        LabeledContent("设备名", value: model.store.identity.name)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("指纹")
                            Text(groupedFPText(model.store.identity.fingerprint))
                                .font(.system(size: 12).monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        LabeledContent("端口", value: "\(model.port)")
                    } header: {
                        Text("本机")
                    } footer: {
                        Text("设备名跟随 iPhone 名称（设置 › 通用 › 关于本机 › 名称）。配对时双方核对指纹前 8 位。")
                    }
                }

                Section {
                    if model.pairedRows.isEmpty {
                        Text("还没有配对的设备").foregroundStyle(.secondary)
                    }
                    ForEach(model.pairedRows) { row in
                        Toggle(isOn: Binding(
                            get: { row.filesTrusted },
                            set: { model.setFileTrust(.init(fingerprint: row.fingerprint, name: row.name), trusted: $0) })
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text("\(row.online ? "在线" : "离线") · \(shortFPText(row.fingerprint))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let rows = model.pairedRows
                        offsets.map { rows[$0] }.forEach { model.removePaired($0) }
                    }
                } header: {
                    Text("已配对设备 · 自动接收文件")
                } footer: {
                    Text("关闭开关后，这台设备发来的每个文件都需要你确认。左滑可移除设备。")
                }

                Section("日志") {
                    if model.events.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary)
                    }
                    ForEach(model.events) { event in
                        Text(event.line)
                            .font(.system(size: 13))
                            .foregroundStyle(event.line.hasPrefix("文件失败") ? Color(signal: 0xFF6B66) : Color.primary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Panel.accent)
    }
}
