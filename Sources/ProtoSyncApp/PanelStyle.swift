import SwiftUI
import Core

// 面板设计(方向 B,docs/design/MENUBAR_PANEL.md)的共用令牌与小组件。
// macOS 与 iOS 共用本文件(ios/project.yml 直接引用),请勿在 ios/ 下另存拷贝。
// 面板固定深色外观:fill 透明度按深色底取值。

enum Panel {
    static let accent = Color(signal: 0xE7FF16)
    static let onAccent = Signal.ink900
    static let fill = Color.white.opacity(0.06)
    static let fillStrong = Color.white.opacity(0.11)
    static let mono = Font.system(size: 11).monospacedDigit()

    /// 设备类型图标:协议不携带设备类型,按设备名推断(只影响图标)
    static func glyph(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") || n.contains("mac pro") {
            return "desktopcomputer"
        }
        // 其他(多为 Android):用现代直板手机图标;smartphone 需 macOS 14 / iOS 17,旧系统退回 iphone 轮廓
        if #available(macOS 14, iOS 17, *) { return "smartphone" }
        return "iphone"
    }
}

struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 28
    var fontSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Panel.onAccent : Color.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(prominent ? Panel.accent : Panel.fillStrong,
                        in: RoundedRectangle(cornerRadius: height > 36 ? 12 : 6))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct DeviceRow: Identifiable, Equatable {
    let id: String          // 完整指纹
    let name: String
    let fingerprint: String
    let online: Bool
    var filesTrusted = true
}

/// 短指纹(前 8 位,4+4 分组):配对核对用
func shortFPText(_ fp: String) -> String {
    let p = DeviceIdentity.shortFingerprint(fp)
    return "\(p.prefix(4)) \(p.suffix(4))"
}

/// 完整指纹按 4 位分组
func groupedFPText(_ fp: String) -> String {
    stride(from: 0, to: fp.count, by: 4).map { start -> String in
        let from = fp.index(fp.startIndex, offsetBy: start)
        let to = fp.index(from, offsetBy: 4, limitedBy: fp.endIndex) ?? fp.endIndex
        return String(fp[from..<to])
    }.joined(separator: " ")
}

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
