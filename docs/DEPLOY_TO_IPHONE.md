# iOS 测试版部署到自己 iPhone 指南

> 适用:把 `ios/` 这个 Xcode 工程装到自己的 iPhone 上做真机测试。
> 免费 Apple ID 即可(不需要 $99 开发者账号),限制见文末。
> 项目位置:`ios/ProtoSync.xcodeproj`,工程由 `ios/project.yml`(xcodegen)生成。

---

## 0. 前置条件

| 项 | 状态 |
|---|---|
| Mac 上装好 Xcode 27(含 iOS SDK) | ✅ 已完成 |
| Xcode 登录 Apple ID | ✅ 你已完成(Settings → Accounts) |
| iPhone + 数据线 | 需要一根能传数据的线 |
| iPhone 系统 | iOS 17+(本工程 deploymentTarget = 17.0) |

## 1. iPhone 端一次性准备

1. **开启开发者模式**(iOS 16+ 必须):
   设置 → 隐私与安全性 → 开发者模式 → 打开 → 按提示重启手机
   > 找不到"开发者模式"选项?先把手机连上 Mac 打开一次 Xcode 再回来看就有了。
2. 数据线连接 iPhone → 手机弹「信任此电脑?」→ 输入锁屏密码点**信任**

## 2. Xcode 内配置(一次性)

1. `open ios/ProtoSync.xcodeproj`(或 Xcode → File → Recent 打开)
2. 顶部设备选择器:点 `ProtoSync > iPhone 17 Simulator`,改成**你的 iPhone**
3. 左侧文件树点最顶上蓝色的 **ProtoSync 工程图标** → 中间选 **TARGETS: ProtoSync** → **Signing & Capabilities** 标签:
   - ✅ 勾选 **Automatically manage signing**
   - **Team** 下拉选你的 Apple ID(名字后面带 `(Personal Team)` 的那个)
   - Bundle Identifier 保持 `app.protosync.ProtoSync` 即可(免费账号要求全网唯一,冲突就改成 `app.protosync.<你的后缀>`)
   - 无红色报错即配置成功;黄色警告可忽略

## 3. 编译安装

- 手机**解锁状态**下按 **⌘R**(或左上角 ▶)
- 第一次大概率在手机上**装完但点开提示"不受信任的开发者"**:
  手机 → 设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → **信任**
- 回到手机桌面点开 ProtoSync → 首次会弹**「本地网络」权限** → 点允许(核心功能依赖它!)

## 4. 验证

- App 显示:运行中 · 指纹 xxxxxxxx · 端口 xxxx
- 让 Mac 端(MacProtoSync.app 或 CLI)也在同一 Wi-Fi 下运行 → 几秒内互相发现
- **注意与模拟器的差异**:真机构建没有"自动接受配对"的调试钩子,Mac 端连过来时 iPhone 会正常弹**配对闸门**,核对指纹后点接受——这正是产品应有的行为

## 5. 免费账号的限制(重要)

| 限制 | 说明 |
|---|---|
| **签名 7 天有效** | 7 天后 App 打不开,连手机重新 ⌘R 一次即续期 |
| 最多 3 个 App ID / 2-3 台设备 | 个人测试足够 |
| 无推送、无 iCloud 等高级能力 | 本 App 用不到,无影响 |

## 6. 常见问题

| 报错/现象 | 处理 |
|---|---|
| `Failed to register bundle identifier` | Bundle ID 被占,改成 `app.protosync.<后缀>` |
| `No profiles for 'xxx' were found` | Signing 里重新选一次 Team,或 Xcode → Settings → Accounts → Download Manual Profiles |
| `Device not connected` / 转圈连不上 | 解锁手机、换线/换 USB 口、手机上点信任;或重启 Xcode |
| `Developer Mode disabled` | 回到第 1 步 |
| 装上了但闪退在启动 | Xcode 底部日志(⌘⇧Y)看红色报错,发给 Claude |
| App 过 7 天打不开 | 连手机重新 ⌘R |

## 7. 省线:无线调试

首次 USB 配对成功后:Xcode 顶部 Window → Devices and Simulators → 勾选 **Connect via network**,以后拔线也能 ⌘R(同一 Wi-Fi 下)。

## 8. 更新版本

Claude 这边改完代码后,你只需:切到 Xcode 按 **⌘R**——Xcode 会自动重编译并覆盖安装到手机(签名不变,数据保留)。

> 工程结构变化时(Claude 会说明)需要先 `cd ios && xcodegen generate` 再 ⌘R。
