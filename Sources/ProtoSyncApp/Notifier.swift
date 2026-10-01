import AppKit
import UserNotifications
import Core

/// 系统通知统一入口。
///
/// 之前通知"开了也不弹"的两个原因:
/// 1. 没有 UNUserNotificationCenterDelegate —— App 处于激活状态(刚点过菜单栏面板)时,
///    系统默认直接吞掉通知;实现 willPresent 返回 .banner 才会显示。
/// 2. add() 的错误被忽略(未授权时静默失败),设置里也看不到原因。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// "同步时发送通知"开关(设置窗口与右键菜单共用这个键)
    static let syncNotifyKey = "syncSuccessNotification"
    static var syncNotifyEnabled: Bool { UserDefaults.standard.bool(forKey: syncNotifyKey) }

    /// 没有 bundle(swift run 直接跑可执行文件)时 UNUserNotificationCenter.current() 会崩,一律跳过
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// 启动时调用:挂代理并申请权限(系统只会问一次)
    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { PLog.error("通知授权失败: \(error.localizedDescription)") }
            else if !granted { PLog.info("通知未获授权") }
        }
    }

    func post(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { PLog.error("发送通知失败: \(error.localizedDescription)") }
        }
    }

    /// 只在"同步时发送通知"打开时发送
    func postSync(id: String, title: String, body: String) {
        guard Self.syncNotifyEnabled else { return }
        post(id: id, title: title, body: body)
    }

    func remove(ids: [String]) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// 系统是否允许本 App 发通知;未决定时顺便发起申请。结果回到主线程。
    func checkAuthorization(_ done: @escaping (Bool) -> Void) {
        guard available else { done(false); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { done(granted) }
                }
            case .denied:
                DispatchQueue.main.async { done(false) }
            default:
                // 已授权但横幅样式被设为"无"时也算不可见
                let visible = settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled
                DispatchQueue.main.async { done(visible) }
            }
        }
    }

    /// 打开"系统设置 › 通知"
    func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.notifications"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也显示横幅(否则点过面板之后的通知全被吞掉)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
