import SwiftUI

// Signal Foundry 设计令牌(见 design/PROTO_SYNC_VISUAL_DIRECTION.md §5-§6)

extension Color {
    init(signal hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

enum Signal {
    // 基础色
    static let carbon950  = Color(signal: 0x080A0C)
    static let carbon900  = Color(signal: 0x111417)
    static let graphite800 = Color(signal: 0x1B2025)
    static let graphite700 = Color(signal: 0x2C333A)
    static let steel500   = Color(signal: 0x707980)
    static let paper100   = Color(signal: 0xF2F3EE)
    static let paper200   = Color(signal: 0xDDE0DA)
    static let ink900     = Color(signal: 0x15181B)

    // 语义信号色
    static let lime   = Color(signal: 0xE7FF16)   // 已连接 / 选中 / 主动作
    static let cyan   = Color(signal: 0x25C7E8)   // 正在传输 / 接收
    static let amber  = Color(signal: 0xFFB020)   // 等待确认 / 配对
    static let coral  = Color(signal: 0xFF5B55)   // 失败 / 中断

    // 信号色上的文字用 Ink 900
    static let onLime = ink900
}

// 状态标签:图标 + 文本 + 色彩 三件套(不依赖单一颜色传达状态)
enum NodeStatus: Equatable {
    case connected
    case syncing
    case verifying
    case offline
    case interrupted
    case done

    var text: String {
        switch self {
        case .connected: return "已连接 CONNECTED"
        case .syncing: return "正在传输 SYNCING"
        case .verifying: return "等待确认 VERIFY"
        case .offline: return "离线 OFFLINE"
        case .interrupted: return "已中断 INTERRUPTED"
        case .done: return "已完成 DONE"
        }
    }

    var short: String {
        switch self {
        case .connected: return "已连接"
        case .syncing: return "正在传输"
        case .verifying: return "等待确认"
        case .offline: return "离线"
        case .interrupted: return "已中断"
        case .done: return "已完成"
        }
    }

    var color: Color {
        switch self {
        case .connected: return Signal.lime
        case .syncing: return Signal.cyan
        case .verifying: return Signal.amber
        case .offline: return Signal.steel500
        case .interrupted: return Signal.coral
        case .done: return Signal.lime
        }
    }

    var icon: String {
        switch self {
        case .connected: return "checkmark.circle"
        case .syncing: return "arrow.left.arrow.right.circle"
        case .verifying: return "hourglass"
        case .offline: return "moon.zzz"
        case .interrupted: return "exclamationmark.triangle"
        case .done: return "checkmark.seal"
        }
    }
}

/// Signal Foundry 通用组件
enum SignalUI {
    /// 分区标题:中文主标签 + 英文微标签(如 `// DEVICES`)
    struct SectionHeader: View {
        let zh: String
        let en: String
        let P: SP

        var body: some View {
            HStack(spacing: 6) {
                Text(zh)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(P.text.opacity(0.92))
                Text("// \(en)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(P.textDim)
            }
            .kerning(0.8)
        }
    }

    /// 状态标签:图标 + 中文 + 英文微标签
    struct StatusTag: View {
        let status: NodeStatus
        let P: SP

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(status.short)
                    .font(.system(size: 10, weight: .medium))
                Text(status.text.split(separator: " ").dropFirst().first.map(String.init) ?? "")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(textColor(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(textColor(status).opacity(0.45)))
            .background(textColor(status).opacity(0.10), in: Capsule())
        }

        private func textColor(_ st: NodeStatus) -> Color {
            // 深色主题用亮信号色文字;浅色主题换深色变体保证对比度
            P.limeText == Signal.lime ? st.color : lightVariant(st)
        }

        private func lightVariant(_ st: NodeStatus) -> Color {
            switch st {
            case .connected: return Color(signal: 0x5C6600)
            case .syncing: return Color(signal: 0x0E7A94)
            case .verifying: return Color(signal: 0x9A6700)
            case .offline: return Color(signal: 0x5A6167)
            case .interrupted: return Color(signal: 0xC93A34)
            case .done: return Color(signal: 0x5C6600)
            }
        }
    }

    /// 点阵背景(4% 不透明度,只作氛围)
    struct DotGrid: View {
        var opacity: Double = 0.05
        var body: some View {
            Canvas { context, size in
                let spacing: CGFloat = 22
                var y: CGFloat = spacing / 2
                while y < size.height {
                    var x: CGFloat = spacing / 2
                    while x < size.width {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                            with: .color(Color.primary.opacity(opacity))
                        )
                        x += spacing
                    }
                    y += spacing
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 45° 缺角矩形(主舞台面板)
    struct NotchCorner: Shape {
        var notch: CGFloat = 12
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let r: CGFloat = 4
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + notch))
            p.addLine(to: CGPoint(x: rect.minX + notch, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                     tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + notch))
            p.closeSubpath()
            return p
        }
    }
}
