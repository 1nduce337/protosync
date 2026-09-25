import SwiftUI
import Core

// Signal Foundry 生产界面(自 ProtoSyncUIDemo 移植,设计规范 §14 Phase 2:只换视图层)。
// 全部状态由 AppModel 真实字段驱动;协议未实现的能力(6 位配对码、ETA、MB/s、送达回执)不出现。

// MARK: - 数据适配

struct SignalDeviceRow: Identifiable, Equatable {
    let id: String          // 完整指纹
    let name: String
    let fingerprint: String
    let online: Bool
}

extension AppModel {
    /// 当前已连接(在线)的全部设备
    var connectedRows: [SignalDeviceRow] {
        onlinePeers.map { SignalDeviceRow(id: $0.fingerprint, name: $0.name,
                                          fingerprint: $0.fingerprint, online: true) }
    }

    /// 已配对设备,在线优先(各自保持原有顺序;离线设备回上线时移到顶部)
    var pairedRowsSorted: [SignalDeviceRow] {
        let rows = pairedDevices.map { d -> SignalDeviceRow in
            let live = onlinePeers.first { $0.fingerprint == d.fingerprint }
            return SignalDeviceRow(id: d.fingerprint, name: live?.name ?? d.name,
                                   fingerprint: d.fingerprint, online: live != nil)
        }
        return rows.filter { $0.online } + rows.filter { !$0.online }
    }

    /// 进行中的传输(活动流里带进度条目的就是真实传输状态)
    var activeTransfers: [ActivityEntry] { activities.filter { $0.progress != nil } }
}

func signalFPText(_ fp: String) -> String {
    let p = DeviceIdentity.shortFingerprint(fp)
    return "\(p.prefix(4)) \(p.suffix(4))"
}

// MARK: - 根视图

struct SignalFoundryRootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var mode: Mode = .overview

    enum Mode: String, CaseIterable {
        case overview = "总览"
        case devices = "设备"
        case activity = "流转"
        case inbox = "收件箱"
    }

    var body: some View {
        let P = SP.make(scheme)
        DashboardChrome(model: model, mode: $mode)
            .environment(\.sp, P)
            .frame(minWidth: 480, minHeight: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(P.canvas)
            .preferredColorScheme(scheme == .dark ? .dark : .light)
    }
}

// MARK: - 主框架:System Header + 模式轨道 + 模式内容

struct DashboardChrome: View {
    @ObservedObject var model: AppModel
    @Binding var mode: SignalFoundryRootView.Mode
    @Environment(\.sp) private var P
    @Environment(\.colorScheme) private var scheme

    private static let logoCache: [String: NSImage] = {
        var m: [String: NSImage] = [:]
        for n in ["protosync-logo-dark", "protosync-logo-light"] {
            if let u = Bundle.module.url(forResource: n, withExtension: "png"),
               let img = NSImage(contentsOf: u) { m[n] = img }
        }
        return m
    }()

    private var headerLogo: NSImage? {
        Self.logoCache[scheme == .dark ? "protosync-logo-dark" : "protosync-logo-light"]
    }

    var body: some View {
        VStack(spacing: 0) {
            systemHeader
            modeRail
            Rectangle().fill(P.divider).frame(height: 1)
            if let request = model.pairingRequest {
                // 配对闸门横跨主区:任何标签页下都立即可见、必须处理
                SignalPairingGate(model: model, request: request)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch mode {
            case .overview: OverviewPane(model: model)
            case .devices:  DevicesPane(model: model)
            case .activity: ActivityPane(model: model)
            case .inbox:    InboxPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(P.canvas)
        .animation(.easeInOut(duration: 0.2), value: model.pairingRequest == nil)
    }

    // System Header:logo + 本机身份 + 在线数 + 扫描
    private var systemHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if let logo = headerLogo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(P.limeText)
            }
            Text("ProtoSync")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(P.text)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                TextField("设备名", text: $model.deviceName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                    .onSubmit { model.store.renameDevice(model.deviceName) }
                Text("本机 \(signalFPText(model.store.identity.fingerprint))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(P.textDim)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%02d", model.onlinePeers.count))
                    .font(.system(size: 26, weight: .medium).monospacedDigit())
                    .foregroundStyle(model.onlinePeers.isEmpty ? P.textDim : P.limeText)
                Text("ONLINE")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(1.6)
                    .foregroundStyle(P.textDim)
            }
            Button {
                model.refreshDevices()
            } label: {
                Text(model.isRefreshing ? "扫描中…" : "SCAN")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(model.isRefreshing ? P.cyanText : P.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(P.textDim.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
        .background(P.headerBg)
    }

    // 模式轨道:整个标签格都是热区
    private var modeRail: some View {
        HStack(spacing: 0) {
            ForEach(SignalFoundryRootView.Mode.allCases, id: \.self) { m in
                let active = mode == m
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                } label: {
                    VStack(spacing: 5) {
                        Text(m.rawValue)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? P.limeText : P.textDim)
                        Rectangle()
                            .fill(active ? P.limeText : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(P.railBg)
    }
}

// MARK: - 模式:总览

struct OverviewPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                primaryStage
                devicesCard
                recentCard
            }
            .padding(12)
        }
    }

    // 已连接设备卡:全部在线设备,不限数量
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "已连接设备", en: "CONNECTED", P: P)
            ForEach(model.connectedRows) { row in
                SignalDeviceNodeRow(row: row, showRemove: false, model: model)
            }
            if model.connectedRows.isEmpty {
                Text("没有已连接的设备。")
                    .font(.callout)
                    .foregroundStyle(P.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(P.panel, in: SignalUI.NotchCorner())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "最近流转", en: "RECENT", P: P)
            ForEach(model.activities.prefix(3)) { entry in
                SignalActivityRailRow(entry: entry)
                if entry.id != model.activities.prefix(3).last?.id {
                    Divider().overlay(P.divider)
                }
            }
            if model.activities.isEmpty {
                Text("剪贴板与文件流转会显示在这里。")
                    .font(.callout)
                    .foregroundStyle(P.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(P.panel, in: SignalUI.NotchCorner())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
    }

    /// 主舞台:无活动传输=空闲(在线数);单任务=单轨道;多任务=平均总进度+每任务行
    @ViewBuilder
    private var primaryStage: some View {
        let active = model.activeTransfers
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SignalUI.StatusTag(status: active.isEmpty ? .connected : .syncing, P: P)
                Spacer()
                Button {
                    model.refreshDevices()
                } label: {
                    Text(model.isRefreshing ? "扫描中 SCANNING" : "重新扫描 SCAN")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.isRefreshing ? P.cyanText : P.textDim)
                }
                .buttonStyle(.plain)
            }
            if active.isEmpty {
                idleStage
            } else if active.count == 1, let entry = active.first {
                singleTrack(entry)
            } else {
                multiTrack(active)
            }
        }
        .padding(14)
        .background(P.panel, in: SignalUI.NotchCorner())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
    }

    private var idleStage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%02d", model.onlinePeers.count))
                .font(.system(size: 44, weight: .medium).monospacedDigit())
                .foregroundStyle(model.onlinePeers.isEmpty ? P.textDim : P.text)
            VStack(alignment: .leading, spacing: 2) {
                Text("台设备在线 · 通道空闲").font(.callout).foregroundStyle(P.text.opacity(0.85))
                Text("IDLE").font(.system(size: 8, weight: .semibold)).kerning(1.4)
                    .foregroundStyle(P.textDim)
            }
            Spacer()
            SignalUI.DotGrid().frame(width: 72, height: 44)
        }
    }

    private func singleTrack(_ entry: AppModel.ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%d%%", Int((entry.progress ?? 0) * 100)))
                    .font(.system(size: 34, weight: .medium).monospacedDigit())
                    .foregroundStyle(P.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(entry.detail)
                        .font(.caption.monospacedDigit()).foregroundStyle(P.textDim)
                }
                Spacer()
                SignalUI.StatusTag(status: .syncing, P: P)
            }
            ProgressBar(fraction: entry.progress ?? 0, fill: P.progressFill, height: 4)
            HStack {
                nodeDot
                Spacer()
                nodeDot
            }
        }
    }

    private func multiTrack(_ active: [AppModel.ActivityEntry]) -> some View {
        let avg = active.map { $0.progress ?? 0 }.reduce(0, +) / Double(active.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%d%%", Int(avg * 100)))
                    .font(.system(size: 34, weight: .medium).monospacedDigit())
                    .foregroundStyle(P.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text("总进度 TOTAL").font(.caption).foregroundStyle(P.textDim)
                    Text("\(active.count) 个任务在传")
                        .font(.caption.monospacedDigit()).foregroundStyle(P.textDim)
                }
                Spacer()
                SignalUI.StatusTag(status: .syncing, P: P)
            }
            ProgressBar(fraction: avg, fill: P.progressFill, height: 5)
            ForEach(active) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.direction == .incoming ? "arrow.down" : "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(P.textDim)
                        .frame(width: 12)
                    Text(entry.title).font(.caption).lineLimit(1).foregroundStyle(P.text)
                    Spacer()
                    Text(String(format: "%d%%", Int((entry.progress ?? 0) * 100)))
                        .font(.caption.monospacedDigit()).foregroundStyle(P.textDim)
                }
            }
        }
    }

    private var nodeDot: some View {
        ZStack {
            Circle().strokeBorder(P.textDim.opacity(0.7), lineWidth: 1.2)
            Circle().fill(P.textDim).frame(width: 3, height: 3)
        }
        .frame(width: 9, height: 9)
    }
}

// MARK: - 模式:设备

struct DevicesPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SignalUI.SectionHeader(zh: "已配对", en: "PAIRED", P: P)
                VStack(spacing: 8) {
                    ForEach(model.pairedRowsSorted) { row in
                        SignalDeviceNodeRow(row: row, showRemove: true, model: model)
                    }
                    if model.pairedDevices.isEmpty {
                        Text("还没有配对设备。下方发现的设备可以发起配对。")
                            .font(.callout).foregroundStyle(P.textDim)
                            .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(P.panel, in: SignalUI.NotchCorner())
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
                // 在线状态变化(含离线设备回上线移到顶部)时平滑重排
                .animation(.easeInOut(duration: 0.25), value: model.pairedRowsSorted)

                SignalUI.SectionHeader(zh: "发现的设备", en: "NEARBY", P: P)
                VStack(spacing: 8) {
                    ForEach(model.discoveredUnpaired, id: \.self) { shortFp in
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(P.textDim.opacity(0.5), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                            Text("设备 \(shortFp)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(P.text)
                            Spacer()
                            Button("配对") { model.pairWith(shortFp: shortFp) }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 5)
                    }
                    if model.discoveredUnpaired.isEmpty {
                        Text("未发现新设备。点右上 SCAN 重新扫描。")
                            .font(.callout).foregroundStyle(P.textDim)
                            .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(P.panel, in: SignalUI.NotchCorner())
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
            }
            .padding(12)
        }
    }
}

// MARK: - 模式:流转

struct ActivityPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SignalUI.SectionHeader(zh: "流转记录", en: "ACTIVITY RAIL", P: P)
                    .padding(.bottom, 10)
                if model.activities.isEmpty {
                    Text("剪贴板与文件流转会显示在这里。")
                        .font(.callout).foregroundStyle(P.textDim)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(model.activities.enumerated()), id: \.element.id) { index, entry in
                        SignalActivityRailRow(entry: entry, showProgress: true)
                        if index != model.activities.count - 1 {
                            Rectangle().fill(P.divider).frame(height: 1)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .background(P.canvas)
        }
    }
}

// MARK: - 模式:收件箱

struct InboxPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SignalUI.SectionHeader(zh: "收到的文件", en: "INBOX", P: P)
                    .padding(.bottom, 10)
                ForEach(Array(model.inboxFiles.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .foregroundStyle(P.text.opacity(0.65))
                        Text(url.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(P.text)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.reveal(url)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(P.text.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示")
                    }
                    .padding(.vertical, 9)
                    if index != model.inboxFiles.count - 1 {
                        Rectangle().fill(P.divider).frame(height: 1)
                    }
                }
                if model.inboxFiles.isEmpty {
                    Text("收到的文件保存在 ~/Downloads/ProtoSync/。")
                        .font(.callout).foregroundStyle(P.textDim)
                }
                Button {
                    model.revealInbox()
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(P.text.opacity(0.8))
                .padding(.top, 10)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .background(P.canvas)
        }
    }
}

// MARK: - 通用组件(生产数据版)

struct ProgressBar: View {
    let fraction: Double
    let fill: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(height: height)
                Capsule().fill(fill).frame(width: max(2, geo.size.width * min(1, max(0, fraction))), height: height)
            }
        }
        .frame(height: height)
    }
}

struct SignalDeviceNodeRow: View {
    let row: SignalDeviceRow
    var showRemove = false
    @ObservedObject var model: AppModel
    @Environment(\.sp) private var P

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(row.online ? P.nodeOnline.opacity(0.85) : P.textDim.opacity(0.5),
                                  lineWidth: 1.5)
                Circle()
                    .fill(row.online ? P.nodeOnline : P.textDim.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(.body, design: .default).weight(.medium))
                    .foregroundStyle(P.text)
                Text(signalFPText(row.fingerprint))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(P.textDim)
            }
            Spacer()
            SignalUI.StatusTag(status: row.online ? .connected : .offline, P: P)
            if row.online {
                Button {
                    model.sendFile(to: row.fingerprint)
                } label: {
                    Label("发送文件", systemImage: "paperplane")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            if showRemove {
                Menu {
                    Button("移除此设备", role: .destructive) {
                        model.removePaired(fingerprint: row.fingerprint)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }
        }
        .padding(.vertical, 5)
    }
}

struct SignalActivityRailRow: View {
    let entry: AppModel.ActivityEntry
    var showProgress = false
    @Environment(\.sp) private var P

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.direction == .incoming ? "arrow.down" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(entry.direction == .incoming ? P.cyanText : P.textDim)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(entry.failed ? P.coralText : P.text)
                    .lineLimit(1)
                Text("\(entry.detail) · \(entry.time.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry.failed ? P.coralText : P.textDim)
                if showProgress, let progress = entry.progress {
                    ProgressBar(fraction: progress,
                                fill: entry.failed ? P.coralText : P.progressFill, height: 3)
                }
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }
}

// MARK: - 配对闸门(Pairing Gate,Amber)
// 真实协议当前为指纹确认;SAS 配对码待协议实现后加入(不得在无推导逻辑时展示假码)。

struct SignalPairingGate: View {
    @ObservedObject var model: AppModel
    let request: AppModel.PairingRequest
    @Environment(\.sp) private var P

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.title2)
                .foregroundStyle(P.amberText)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("「\(request.info.name)」请求配对").font(.headline).foregroundStyle(P.text)
                    SignalUI.StatusTag(status: .verifying, P: P)
                }
                Text("指纹 \(signalFPText(request.info.fingerprint)) — 核对对方屏幕显示同一指纹后接受")
                    .font(.caption).foregroundStyle(P.textDim)
            }
            Spacer()
            Button("拒绝") { withAnimation { model.rejectPairing(request) } }
                .controlSize(.small)
            Button("接受") { withAnimation { model.acceptPairing(request) } }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(P.amberText.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.amberText.opacity(0.45)))
        .padding(.horizontal, 14)
    }
}
