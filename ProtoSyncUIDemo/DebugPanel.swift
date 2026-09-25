import SwiftUI

// 调试台:一键注入各种场景,验证交互逻辑与状态表现。

struct DebugPanel: View {
    @ObservedObject var model: MockModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("设备") {
                    debugButton("添加在线设备", "circle.dotted") { model.addDevice(status: .online) }
                    debugButton("添加离线设备", "moon.zzz") { model.addDevice(status: .offline) }
                    debugButton("添加附近设备(未配对)", "antenna.radiowaves.left.and.right") { model.addNearbyDevice() }
                    debugButton("随机一台上下线", "arrow.triangle.2.circlepath") {
                        guard let d = model.devices.randomElement() else { model.flashHUD(symbol: "wifi.slash", text: "没有设备"); return }
                        model.toggleOnline(d)
                    }
                    debugButton("全部离线", "moon.zzz") {
                        for i in model.devices.indices { model.devices[i].status = .offline }
                    }
                }
                group("配对") {
                    debugButton("模拟配对请求(6 位码)", "person.crop.circle.badge.exclamationmark") {
                        withAnimation { model.simulatePairingRequest() }
                    }
                    Text("弹出横幅后可点接受/拒绝;接受会添加一台在线手机。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                group("剪贴板") {
                    debugButton("收到文本", "doc.on.doc.fill") { model.simulateIncomingText() }
                    debugButton("收到图片", "photo.fill") { model.simulateIncomingImage() }
                    debugButton("模拟发送剪贴板", "arrow.up.doc") { model.simulateSendClipboard() }
                    Text("发送后立即出现在活动流(协议当前无送达回执)。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                group("文件传输") {
                    debugButton("接收文件 · 正常(6s)", "arrow.down.doc") {
                        model.simulateFileTransfer(direction: .incoming, duration: 6, failAt: nil)
                    }
                    debugButton("发送文件 · 正常(6s)", "arrow.up.doc") {
                        model.simulateFileTransfer(direction: .outgoing, duration: 6, failAt: nil)
                    }
                    debugButton("接收 · 大文件慢速(20s)", "tortoise") {
                        model.simulateFileTransfer(direction: .incoming, duration: 20, failAt: nil)
                    }
                    debugButton("接收 · 中途失败(40%)", "exclamationmark.triangle") {
                        model.simulateFileTransfer(direction: .incoming, duration: 6, failAt: 0.4)
                    }
                    debugButton("3 个任务并发 · 总进度(8s)", "square.stack.3d.up") {
                        model.simulateFileTransfer(direction: .incoming, duration: 8, failAt: nil, parallel: 3)
                    }
                }
                group("杂项") {
                    debugButton("清空活动流", "eraser") { withAnimation { model.clearActivities() } }
                    debugButton("重置整个演示", "arrow.counterclockwise") { withAnimation { model.resetDemo() } }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            content()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func debugButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
    }
}
