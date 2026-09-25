import Foundation

#if os(macOS)
import AppKit

/// 剪贴板轮询监听:changeCount 变化时提取文本或 PNG 图片。
/// 独立于引擎:监听者只负责"读",去重与广播由 SyncEngine 处理。
public final class ClipboardMonitor {
    public enum Content {
        case text(String)
        case image(Data)
        case none
    }

    /// 在主线程回调。
    public var onClipboardChanged: ((Content) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    public init() {}

    public func start(interval: TimeInterval = 0.4) {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // 优先取 PNG 原始数据(写入侧能原样读回,哈希才稳定);否则尝试 TIFF→PNG;
        // 最后取纯文本。文件 URL 在 v1 里不当作剪贴板内容广播。
        if let png = pasteboard.data(forType: .png) {
            onClipboardChanged?(.image(png))
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            onClipboardChanged?(.image(png))
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            onClipboardChanged?(.text(string))
        } else {
            onClipboardChanged?(.none)
        }
    }

    /// 把内容写回系统剪贴板。
    public static func write(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public static func write(png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        // 同时提供 TIFF,让多数应用能直接粘贴
        if let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }
}
#endif
