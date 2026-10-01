import SwiftUI

// Signal Foundry 主界面:总览 / 设备 / 流转 / 收件箱 四模式。
// 双主题:深色 = Carbon/Graphite 控制面 + Paper 文档面;浅色 = Paper 画布 + 白色面板,信号色换深色变体保证对比度。

// MARK: - 调色板

struct SP {
    let canvas: Color          // 窗口画布
    let headerBg: Color        // System Header
    let railBg: Color          // 模式轨道
    let panel: Color           // 面板底
    let panelStroke: Color     // 面板描边
    let divider: Color
    let text: Color            // 主文字
    let textDim: Color         // 次级文字
    let nodeOnline: Color      // 节点在线色
    let progressFill: Color    // 进度条填充
    let limeText: Color        // 选中/主状态文字(浅色下用深色变体)
    let cyanText: Color
    let amberText: Color
    let coralText: Color
    let limeFill: Color        // 进度/填充用亮 Lime
    let cyanFill: Color
    let docBg: Color           // 文档表面画布
    let docText: Color
    let docTextDim: Color
    let docDivider: Color
    let onAccentText: Color    // 信号色填充上的文字(Ink 900)

    static func make(_ scheme: ColorScheme) -> SP {
        if scheme == .dark {
            return SP(
                canvas: Color(signal: 0x111417), headerBg: Color(signal: 0x080A0C),
                railBg: Color(signal: 0x1B2025), panel: Color(signal: 0x1B2025),
                panelStroke: Color(signal: 0x2C333A).opacity(0.7),
                divider: Color(signal: 0x2C333A),
                text: Color(signal: 0xF2F3EE), textDim: Color(signal: 0x707980),
                nodeOnline: Color(signal: 0xE7FF16), progressFill: Color(signal: 0x25C7E8),
                limeText: Color(signal: 0xE7FF16), cyanText: Color(signal: 0x25C7E8),
                amberText: Color(signal: 0xFFB020), coralText: Color(signal: 0xFF5B55),
                limeFill: Color(signal: 0xE7FF16), cyanFill: Color(signal: 0x25C7E8),
                docBg: Color(signal: 0x111417), docText: Color(signal: 0xF2F3EE),
                docTextDim: Color(signal: 0x707980), docDivider: Color(signal: 0x2C333A),
                onAccentText: Color(signal: 0x15181B)
            )
        }
        // 浅色:亮 Lime 在白底可读性差 → 文字/细线用深色变体,填充用降亮度变体
        return SP(
            canvas: Color(signal: 0xF2F3EE), headerBg: Color(signal: 0xFFFFFF),
            railBg: Color(signal: 0xFFFFFF), panel: Color(signal: 0xFFFFFF),
            panelStroke: Color(signal: 0xDDE0DA),
            divider: Color(signal: 0xDDE0DA),
            text: Color(signal: 0x15181B), textDim: Color(signal: 0x5A6167),
            nodeOnline: Color(signal: 0x7A8A00), progressFill: Color(signal: 0xA8B400),
            limeText: Color(signal: 0x5C6600), cyanText: Color(signal: 0x0E7A94),
            amberText: Color(signal: 0x9A6700), coralText: Color(signal: 0xC93A34),
            limeFill: Color(signal: 0xC5D400), cyanFill: Color(signal: 0x1BA6C4),
            docBg: Color(signal: 0xFFFFFF), docText: Color(signal: 0x15181B),
            docTextDim: Color(signal: 0x5A6167), docDivider: Color(signal: 0xDDE0DA),
            onAccentText: Color(signal: 0x15181B)
        )
    }
}

// 环境注入:子视图直接 @Environment(\.palette) 取用
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = SP.make(.dark)
}
extension EnvironmentValues {
    var sp: SP {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - 根视图

struct DemoRootView: View {
    @ObservedObject var model: MockModel
    @Environment(\.colorScheme) private var scheme
    @State private var showDebug = true

    var body: some View {
        let P = SP.make(scheme)
        HStack(spacing: 0) {
            DashboardPreview(model: model)
                .frame(maxWidth: .infinity)
                .frame(minWidth: 480)
            if showDebug {
                Divider().overlay(P.divider)
                DebugPanel(model: model)
                    .frame(width: 290)
                    .background(P.panel)
            }
        }
        .environment(\.sp, P)
        .overlay(alignment: .top) {
            if let hud = model.hud {
                HUDCapsule(message: hud, P: P)
                    .padding(.top, 76)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.hud)
        .background(P.canvas)
        .preferredColorScheme(scheme == .dark ? .dark : .light)
    }
}

// MARK: - System Header + 模式轨道

struct DashboardPreview: View {
    @ObservedObject var model: MockModel
    @Environment(\.sp) private var P
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            systemHeader
            modeRail
            Rectangle().fill(P.divider).frame(height: 1)
            if let req = model.pairingRequest {
                // 配对闸门横跨主区:任何标签页下都立即可见、必须处理
                PairingGateBanner(model: model, request: req)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch model.mode {
            case .overview: OverviewMode(model: model)
            case .devices:  DevicesMode(model: model)
            case .activity: ActivityMode(model: model)
            case .inbox:    InboxMode(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(P.canvas)
    }

    private static let logoCache: [String: NSImage] = {
        var m: [String: NSImage] = [:]
        for n in ["protosync-logo-dark", "protosync-logo-light"] {
            if let u = Bundle.module.url(forResource: n, withExtension: "png"),
               let img = NSImage(contentsOf: u) { m[n] = img }
        }
        return m
    }()

    private var systemHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if let logo = Self.logoCache[scheme == .dark ? "protosync-logo-dark" : "protosync-logo-light"] {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
            }
            Text("ProtoSync")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(P.text)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%02d", model.onlineCount))
                    .font(.system(size: 26, weight: .medium).monospacedDigit())
                    .foregroundStyle(model.onlineCount > 0 ? P.limeText : P.textDim)
                Text("ONLINE")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(1.6)
                    .foregroundStyle(P.textDim)
            }
            Button {
                model.scan()
            } label: {
                Text(model.isScanning ? "扫描中…" : "SCAN")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(model.isScanning ? P.cyanText : P.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(P.textDim.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
        .background(P.headerBg)
    }

    private var modeRail: some View {
        HStack(spacing: 0) {
            ForEach(MockModel.Mode.allCases, id: \.self) { mode in
                let active = model.mode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { model.mode = mode }
                } label: {
                    VStack(spacing: 5) {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? P.limeText : P.textDim)
                        Rectangle()
                            .fill(active ? P.limeText : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.top, 8)
                    // 整个标签格(全宽 × 轨道全高)都是可点热区,不必精确点中文字
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

struct OverviewMode: View {
    @ObservedObject var model: MockModel
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

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalUI.SectionHeader(zh: "已连接设备", en: "CONNECTED", P: P)
            ForEach(model.connectedDevices) { d in
                DeviceNodeRow(device: d, showUnpair: false, model: model)
            }
            if model.connectedDevices.isEmpty {
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
            ForEach(model.activities.prefix(3)) { a in
                ActivityRailRow(activity: a)
                if a.id != model.activities.prefix(3).last?.id {
                    Divider().overlay(P.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(P.panel, in: SignalUI.NotchCorner())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
    }

    /// 主舞台状态:任一失败 → 已中断;仍有活跃任务 → 正在传输;
    /// 全部完成(短暂停留期)→ 已完成;空 → 已连接(空闲)
    private var stageStatus: NodeStatus {
        if model.jobs.contains(where: { $0.failed }) { return .interrupted }
        if model.jobs.contains(where: { !$0.completed }) { return .syncing }
        return model.jobs.isEmpty ? .connected : .done
    }

    /// 主舞台:无任务=空闲;单任务=单轨道;多任务=总进度 + 每任务紧凑行
    @ViewBuilder
    private var primaryStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SignalUI.StatusTag(status: stageStatus, P: P)
                Spacer()
                Button {
                    model.scan()
                } label: {
                    Text(model.isScanning ? "扫描中 SCANNING" : "重新扫描 SCAN")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.isScanning ? P.cyanText : P.textDim)
                }
                .buttonStyle(.plain)
            }
            if model.jobs.isEmpty {
                idleStage
            } else if model.jobs.count == 1, let job = model.jobs.first {
                singleTrack(job: job)
            } else {
                multiJobStage
            }
        }
        .padding(14)
        .background(P.panel, in: SignalUI.NotchCorner())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
    }

    private var idleStage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%02d", model.onlineCount))
                .font(.system(size: 44, weight: .medium).monospacedDigit())
                .foregroundStyle(model.onlineCount > 0 ? P.text : P.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text("台设备在线 · 通道空闲").font(.callout).foregroundStyle(P.text.opacity(0.85))
                Text("IDLE").font(.system(size: 8, weight: .semibold)).kerning(1.4)
                    .foregroundStyle(P.textDim)
            }
            Spacer()
            SignalUI.DotGrid().frame(width: 72, height: 44)
        }
    }

    @ViewBuilder
    private var multiJobStage: some View {
        if let ov = model.overallProgress {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%d%%", Int(ov.fraction * 100)))
                    .font(.system(size: 34, weight: .medium).monospacedDigit())
                    .foregroundStyle(P.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text("总进度 TOTAL").font(.caption).foregroundStyle(P.textDim)
                    Text(String(format: "%.1f / %.1f MB", ov.doneMB, ov.totalMB))
                        .font(.caption.monospacedDigit()).foregroundStyle(P.textDim)
                }
                Spacer()
                Text("\(model.jobs.count) 个任务")
                    .font(.caption).foregroundStyle(P.textDim)
            }
            ProgressBar(fraction: ov.fraction, fill: P.progressFill, height: 5)
            ForEach(model.jobs) { job in
                jobRow(job)
            }
        }
    }

    private func jobRow(_ job: MockModel.TransferJob) -> some View {
        let frac = job.sizeMB > 0 ? job.doneMB / job.sizeMB : 0
        return HStack(spacing: 8) {
            Image(systemName: job.direction == .incoming ? "arrow.down" : "arrow.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(job.failed ? P.coralText : (job.completed ? P.limeText : P.textDim))
                .frame(width: 12)
            Text(job.name).font(.caption).lineLimit(1).foregroundStyle(P.text)
            Spacer()
            if job.failed {
                Text("已中断").font(.caption2).foregroundStyle(P.coralText)
            } else if job.completed {
                Text("已完成").font(.caption2).foregroundStyle(P.limeText)
            } else {
                Text(String(format: "%d%%", Int(frac * 100)))
                    .font(.caption.monospacedDigit()).foregroundStyle(P.textDim)
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            ProgressBar(fraction: frac,
                        fill: job.failed ? P.coralText : (job.completed ? P.limeFill : P.progressFill),
                        height: 3)
                .padding(.bottom, -2)
        }
    }

    private func singleTrack(job: MockModel.TransferJob) -> some View {
        let frac = job.sizeMB > 0 ? job.doneMB / job.sizeMB : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%d%%", Int(frac * 100)))
                    .font(.system(size: 34, weight: .medium).monospacedDigit())
                    .foregroundStyle(P.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(String(format: "%.1f / %.1f MB", job.doneMB, job.sizeMB))
                        .font(.caption.monospacedDigit()).foregroundStyle(P.textDim)
                }
                Spacer()
                SignalUI.StatusTag(status: job.failed ? .interrupted : (job.completed ? .done : .syncing), P: P)
            }
            ProgressBar(fraction: frac,
                        fill: job.failed ? P.coralText : (job.completed ? P.limeFill : P.progressFill),
                        height: 4)
            HStack {
                nodeDot
                Spacer()
                nodeDot
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

struct DevicesMode: View {
    @ObservedObject var model: MockModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SignalUI.SectionHeader(zh: "已配对", en: "PAIRED", P: P)
                VStack(spacing: 8) {
                    ForEach(model.pairedSorted) { d in
                        DeviceNodeRow(device: d, showUnpair: true, model: model)
                    }
                    if !model.devices.contains(where: { $0.isPaired }) {
                        Text("暂无已配对设备。下方附近的设备可以发起配对。")
                            .font(.callout).foregroundStyle(P.textDim)
                            .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(P.panel, in: SignalUI.NotchCorner())
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.panelStroke))
                // 在线状态变化(含离线设备回上线移到顶部)时平滑重排
                .animation(.easeInOut(duration: 0.25), value: model.pairedSorted)

                SignalUI.SectionHeader(zh: "附近的设备", en: "NEARBY", P: P)
                VStack(spacing: 8) {
                    ForEach(model.devices.filter { !$0.isPaired }) { d in
                        DeviceNodeRow(device: d, showPair: true, model: model)
                    }
                    if !model.devices.contains(where: { !$0.isPaired }) {
                        Text("未发现新设备。点按右上 SCAN 重新扫描。")
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

// MARK: - 模式:流转(Paper 文档表面;深色下用深色文档面)

struct ActivityMode: View {
    @ObservedObject var model: MockModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SignalUI.SectionHeader(zh: "流转记录", en: "ACTIVITY RAIL", P: P)
                    .padding(.bottom, 10)
                if model.activities.isEmpty {
                    Text("暂无记录。复制内容或传输文件后会显示在这里。")
                        .font(.callout).foregroundStyle(P.textDim)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(model.activities.enumerated()), id: \.element.id) { index, a in
                        ActivityRailRow(activity: a)
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

struct InboxMode: View {
    @ObservedObject var model: MockModel
    @Environment(\.sp) private var P

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SignalUI.SectionHeader(zh: "收到的文件", en: "INBOX", P: P)
                    .padding(.bottom, 10)
                ForEach(Array(model.inboxFiles.enumerated()), id: \.element.id) { index, f in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .foregroundStyle(P.text.opacity(0.65))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(P.text)
                                .lineLimit(1)
                            Text(f.meta)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(P.textDim)
                        }
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(P.text.opacity(0.65))
                            .help("在 Finder 中显示")
                    }
                    .padding(.vertical, 9)
                    if index != model.inboxFiles.count - 1 {
                        Rectangle().fill(P.divider).frame(height: 1)
                    }
                }
                Button {
                    model.flashHUD(symbol: "folder", text: "已在 Finder 中显示收件箱")
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(P.text.opacity(0.8))
                .padding(.top, 10)
                if model.inboxFiles.isEmpty {
                    Text("收到的文件保存在下载目录的 ProtoSync 文件夹。")
                        .font(.callout).foregroundStyle(P.textDim)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .background(P.canvas)
        }
    }
}

// MARK: - 通用组件

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

struct DeviceNodeRow: View {
    let device: DemoDevice
    var showUnpair = false
    var showPair = false
    @ObservedObject var model: MockModel
    @Environment(\.sp) private var P

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(device.status == .online ? P.nodeOnline.opacity(0.85) : P.textDim.opacity(0.5),
                                  lineWidth: 1.5)
                Circle()
                    .fill(device.status == .online ? P.nodeOnline : P.textDim.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(.body, design: .default).weight(.medium))
                    .foregroundStyle(P.text)
                Text(DemoFormat.fingerprintText(device.fingerprint))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(P.textDim)
            }
            Spacer()
            SignalUI.StatusTag(status: device.status == .online ? .connected : .offline, P: P)
            if showPair {
                Button("配对") { model.pairNearby(device) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
            if showUnpair {
                Button("取消配对") { model.removeDevice(device) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 5)
    }
}

struct ActivityRailRow: View {
    let activity: DemoActivity
    @Environment(\.sp) private var P

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activity.direction == .incoming ? "arrow.down" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(activity.direction == .incoming ? P.cyanText : P.textDim)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(activity.failed ? P.coralText : P.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.statusText(activity))
                    Text(activity.time.formatted(date: .omitted, time: .standard))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(activity.failed ? P.coralText : P.textDim)
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private static func statusText(_ a: DemoActivity) -> String {
        if a.progress != nil { return "正在传输… \(a.bytesText)" }
        if a.failed { return a.failedReason ?? "已中断" }
        return a.detail.isEmpty ? a.bytesText : "\(a.bytesText) · \(a.detail)"
    }
}

// MARK: - 组件:配对闸门(Pairing Gate,Amber)

struct PairingGateBanner: View {
    @ObservedObject var model: MockModel
    let request: MockModel.PairingRequest
    @Environment(\.sp) private var P

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.title2)
                .foregroundStyle(P.amberText)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("「\(request.name)」请求配对").font(.headline).foregroundStyle(P.text)
                    SignalUI.StatusTag(status: .verifying, P: P)
                }
                Text("配对码 PAIRING CODE")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(P.amberText)
                // 6 位 SAS 配对码:两端应显示相同码值,不一致 = 存在中间人
                Text(DemoFormat.pairingCode(request.code))
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(P.amberText)
                Text("核对两台设备显示相同配对码后再接受 · 指纹 \(DemoFormat.fingerprintText(request.fingerprint))")
                    .font(.caption).foregroundStyle(P.textDim)
            }
            Spacer()
            Button("拒绝") { withAnimation { model.rejectPairing() } }
                .controlSize(.small)
            Button("接受") { withAnimation { model.acceptPairing() } }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(P.amberText.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(P.amberText.opacity(0.45)))
        .padding(.horizontal, 14)
    }
}

// MARK: - 组件:HUD 胶囊

struct HUDCapsule: View {
    let message: MockModel.HUDMessage
    let P: SP

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.symbol)
                .foregroundStyle(P.limeText)
            Text(message.text)
                .font(.callout.weight(.medium))
                .foregroundStyle(P.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(P.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(P.textDim.opacity(0.45)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}
