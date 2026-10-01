import SwiftUI
import Core

// 菜单栏面板与“设备与设置”窗口共用的数据适配和小组件。

extension AppModel {
    /// 已配对设备,在线优先(各自保持原有顺序;离线设备回上线时移到顶部)
    var pairedRowsSorted: [DeviceRow] {
        let rows = pairedDevices.map { d -> DeviceRow in
            let live = onlinePeers.first { $0.fingerprint == d.fingerprint }
            return DeviceRow(id: d.fingerprint, name: live?.name ?? d.name,
                             fingerprint: d.fingerprint, online: live != nil,
                             filesTrusted: d.filesTrusted)
        }
        return rows.filter { $0.online } + rows.filter { !$0.online }
    }

    /// 进行中的传输(活动流里带进度条目的就是真实传输状态)
    var activeTransfers: [ActivityEntry] { activities.filter { $0.progress != nil } }
}
