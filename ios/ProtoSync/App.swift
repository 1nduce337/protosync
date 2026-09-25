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

/// Signal Foundry 单页指挥面板(对齐 Android 端布局,设计文档 §8/§9):
/// System Header → 配对闸门 → 传输轨道 → 已连接设备 → 附近的设备 → 主操作 → 收件箱 → 活动流。
/// 深浅双主题跟随系统(SP 调色板),点阵背景 + 45° 缺角面板。
struct RootView: View {
    @ObservedObject var model: IOSAppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var showFilePicker = false
    @State private var showPeerPicker = false
    @State private var pickedURL: URL?
    @State private var previewURL: URL?

    var body: some View {
        let P = SP.make(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(P)
                if let err = model.initError { initErrorCard(err, P) }
                if let request = model.pairing { pairingGate(request, P) }
                if !model.transfers.isEmpty { transferCard(P) }
                if !model.peers.isEmpty { connectedCard(P) }
                nearbyCard(P)
                actions(P)
                inboxCard(P)
                activityCard(P)
            }
            .padding(16)
        }
        .background(P.canvas.ignoresSafeArea())
        .overlay(SignalUI.DotGrid().ignoresSafeArea())
        .environment(\.sp, P)
        .onAppear {
            model.refresh()
            model.refreshNearby()
            model.refreshInbox()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshInbox() }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], onCompletion: handlePickedFile)
        .confirmationDialog("发送给哪台设备?", isPresented: $showPeerPicker, titleVisibility: .visible) {
            ForEach(model.peers, id: \.fingerprint) { peer in
                Button(peer.name) { sendPickedFile(to: peer) }
            }
            Button("取消", role: .cancel) {}
        }
        .quickLookPreview($previewURL)
    }

    // MARK: - System Header(logo + 大数字在线数 + SCAN)

    private func header(_ P: SP) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(scheme == .dark ? "protosync-logo-dark" : "protosync-logo-light")
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("ProtoSync").font(.system(size: 16, weight: .bold)).foregroundStyle(P.text)
                Text(model.ready ? "\(model.statusText) · 指纹 \(model.fingerprint)" : model.statusText)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(P.textDim)
                    .lineLimit(model.initError == nil ? 1 : 3)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%02d", model.peers.count))
                    .font(.system(size: 36, weight: .medium).monospacedDigit())
                    .foregroundStyle(P.text)
                Text("台在线 // ONLINE")
                    .font(.system(size: 9, weight: .semibold).monospaced())
                    .kerning(0.8)
                    .foregroundStyle(P.textDim)
            }
            Button {
                model.scan()
            } label: {
                Text(model.isScanning ? "SCAN…" : "SCAN")
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .foregroundStyle(P.text)
            }
            .buttonStyle(ScanButtonStyle(P: P))
            .disabled(model.isScanning)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(SignalUI.NotchCorner().fill(P.headerBg))
        .overlay(SignalUI.NotchCorner().stroke(P.panelStroke, lineWidth: 1))
    }

    // MARK: - 初始化错误(完整展示 + 一键复制,便于回传诊断)

    private func initErrorCard(_ err: String, _ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SignalUI.SectionHeader(zh: "初始化失败", en: "ERROR", P: P)
                .foregroundStyle(P.coralText)
            Text(err)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(P.text)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = err
            } label: {
                Text("复制错误信息").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(OutlinedButtonStyle(P: P))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.coralText.opacity(0.55), lineWidth: 1))
    }

    // MARK: - 配对闸门(Amber,安全决策不是 Toast;§9.3)

    private func pairingGate(_ request: IOSAppModel.PairingRequest, _ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "配对请求", en: "PAIRING", P: P)
                .foregroundStyle(P.amberText)
            Text("设备「\(request.info.name)」请求配对")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(P.text)
            Text(String(request.info.fingerprint.prefix(16)))
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .foregroundStyle(P.amberText)
            Text("核对两台设备显示的指纹一致后再接受")
                .font(.system(size: 11)).foregroundStyle(P.textDim)
            HStack(spacing: 10) {
                Button {
                    model.pairAccepted(request, true)
                } label: {
                    Text("接受").frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(P: P, fill: P.amberText))
                Button {
                    model.pairAccepted(request, false)
                } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlinedButtonStyle(P: P))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.amberText.opacity(0.55), lineWidth: 1))
    }

    // MARK: - 传输轨道(Cyan 进行 / Lime 完成;§9.4)

    private func transferCard(_ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "传输任务", en: "TRANSFER", P: P)
            ForEach(model.transfers) { t in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(t.incoming ? "↓" : "↑")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(t.incoming ? P.cyanText : P.limeText)
                        Text(t.name).font(.system(size: 13)).foregroundStyle(P.text).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(Int(t.fraction * 100))%")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(t.incoming ? P.cyanText : P.limeText)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(P.divider)
                            Capsule().fill(t.incoming ? P.cyanFill : P.limeFill)
                                .frame(width: max(4, geo.size.width * t.fraction))
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }

    // MARK: - 已连接设备

    private func connectedCard(_ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "已连接设备", en: "CONNECTED", P: P)
            ForEach(model.peers, id: \.fingerprint) { peer in
                HStack(spacing: 10) {
                    Circle().fill(P.nodeOnline).frame(width: 8, height: 8)
                    Text(peer.name).font(.system(size: 14)).foregroundStyle(P.text)
                    Spacer()
                    Text(String(peer.fingerprint.prefix(8)))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(P.textDim)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }

    // MARK: - 附近的设备(未配对;点按发起配对)

    private func nearbyCard(_ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "附近的设备", en: "NEARBY", P: P)
            if model.nearby.isEmpty {
                Text("  暂无,点 SCAN 刷新;发现新设备后会出现在这里")
                    .font(.system(size: 12)).foregroundStyle(P.textDim)
            }
            ForEach(model.nearby, id: \.self) { shortFp in
                HStack(spacing: 10) {
                    Circle().strokeBorder(P.textDim, lineWidth: 1.5).frame(width: 8, height: 8)
                    Text("设备 \(shortFp)")
                        .font(.system(size: 13).monospaced())
                        .foregroundStyle(P.text)
                    Spacer()
                    Button {
                        model.pairWith(shortFp: shortFp)
                    } label: {
                        Text("配对").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    .buttonStyle(OutlinedButtonStyle(P: P))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }

    // MARK: - 主操作(Lime 主按钮 + Ink 深字;§5.3)

    private func actions(_ P: SP) -> some View {
        HStack(spacing: 10) {
            Button {
                model.sendClipboard()
            } label: {
                Text("发送剪贴板").frame(maxWidth: .infinity).frame(height: 26)
            }
            .buttonStyle(AccentButtonStyle(P: P, fill: P.limeFill))
            .disabled(!model.ready)

            Button {
                showFilePicker = true
            } label: {
                Text("发送文件").frame(maxWidth: .infinity).frame(height: 26)
            }
            .buttonStyle(OutlinedButtonStyle(P: P))
            .disabled(!model.ready || model.peers.isEmpty)
        }
    }

    // MARK: - 收件箱

    private func inboxCard(_ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "收件箱", en: "INBOX", P: P)
            Text("文件 App → 我的 iPhone → ProtoSync → Received，可查看或删除")
                .font(.system(size: 11)).foregroundStyle(P.textDim)
            if model.inbox.isEmpty {
                Text("  暂无文件,收到的文件保存在本机收件箱")
                    .font(.system(size: 12)).foregroundStyle(P.textDim)
            }
            ForEach(model.inbox, id: \.absoluteString) { url in
                Button {
                    previewURL = url
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.system(size: 12))
                            .foregroundStyle(P.cyanText)
                        Text(url.lastPathComponent)
                            .font(.system(size: 13)).foregroundStyle(P.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(P.textDim)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }

    // MARK: - 活动流(方向/类型/摘要/结果;§9.5)

    private func activityCard(_ P: SP) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SignalUI.SectionHeader(zh: "流转记录", en: "ACTIVITY", P: P)
            if model.events.isEmpty {
                Text("  暂无流转记录").font(.system(size: 12)).foregroundStyle(P.textDim)
            }
            ForEach(model.events) { event in
                Text(event.line)
                    .font(.system(size: 12))
                    .foregroundStyle(event.line.hasPrefix("文件失败") ? P.coralText : P.text)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }

    // MARK: - 文件选择

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        pickedURL = url
        if model.peers.count == 1 {
            sendPickedFile(to: model.peers[0])
        } else if model.peers.isEmpty {
            model.events.insert(IOSAppModel.Event(line: "没有在线设备,发送取消"), at: 0)
        } else {
            showPeerPicker = true
        }
    }

    private func sendPickedFile(to peer: PeerConnection.PeerInfo) {
        guard let url = pickedURL else { return }
        model.sendFile(at: url, to: peer)
    }
}

// MARK: - 按钮样式(4-8px 圆角、1px 边线、无大面积阴影;§7.1)

private struct AccentButtonStyle: ButtonStyle {
    let P: SP
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(P.onAccentText)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct OutlinedButtonStyle: ButtonStyle {
    let P: SP

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(P.text)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(P.panel.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }
}

private struct ScanButtonStyle: ButtonStyle {
    let P: SP

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(P.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(P.panelStroke, lineWidth: 1))
    }
}
