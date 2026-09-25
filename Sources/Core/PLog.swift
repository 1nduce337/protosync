import Foundation
import os

/// 统一日志入口。新 SDK(Swift 6.2 / macOS 27)已把变参 NSLog 标记为对 Swift 不可用,
/// 全项目统一走这里(os.Logger,macOS 11+ / iOS 14+ 可用,iOS 移植直接复用)。
///
/// 实时查看:`log stream --predicate 'subsystem == "app.protosync"'`
public enum PLog {
    private static let logger = Logger(subsystem: "app.protosync", category: "core")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
