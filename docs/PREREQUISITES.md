# ProtoSync 新平台前置条件:iOS 与 HarmonyOS NEXT

> 调研时间:2026-09-22。目标:为 iOS 客户端与鸿蒙 NEXT 客户端开发整理环境/账号/系统能力边界,
> 并对照本项目(局域网 P2P TCP + mDNS 发现 + ChaChaPoly 加密 + 剪贴板/文件)给出移植可行性。
> 结论先行:**iOS 是四端里移植成本最低的(Sources/Core 几乎直接复用);鸿蒙需要全套新工具链与账号,
> 但系统 API(@ohos.net.socket + @ohos.net.mdns)与协议完美对齐**。

---

## 0. 两平台速览对比(对照本机现状)

| 项目 | iOS | HarmonyOS NEXT |
|---|---|---|
| IDE | **Xcode 26**(2026 年 App Store 提交强制要求) | **DevEco Studio 6.1.0 Release**(2026-04 发布,API 23;6.0 为 HarmonyOS 6) |
| 本机可装? | ✅ Xcode 26 要求 macOS 15.6+,本机 15.7.7 满足 | ✅ 支持 macOS(Apple Silicon),本机 M4 Pro 满足 |
| 下载/磁盘 | 下载 ~12.6GB,装完 30–40GB+ | 安装器 + SDK + 模拟器镜像,预留 ≥50GB 稳妥 |
| 语言 | Swift(现有 Core 直接复用) | **ArkTS**(TypeScript 超集)+ ArkUI 声明式 UI |
| 账号 | Apple ID 免费(7 天签名)/ **$99/年** 开发者计划(商店分发) | 华为开发者账号 + **实名认证**(免费);上架走 AppGallery Connect |
| 真机调试 | 免费账号可装自己的设备(7 天重签);付费 1 年 | 调试证书必须包含**在 AGC 注册的设备 UDID**(数量有限额) |
| 模拟器 | iOS Simulator(含在 Xcode) | Mac **Apple Silicon** 支持手机/折叠/平板/2-in-1 模拟器(Intel Mac 已不支持) |
| 剪贴板自动同步 | ❌ **做不到**(见 §1.3) | ⚠️ 受限类似 Android 10+(前台/手动为主) |
| 后台保持连接 | ❌ 退后台秒级挂起,socket 即断 | ⚠️ 需**长时任务**,否则退后台系统断网(电池优化) |
| 协议契合度 | ★★★★★ Network.framework + CryptoKit 现成 | ★★★★☆ `@ohos.net.socket` + `@ohos.net.mdns` 对应现成 |

---

## 1. iOS 客户端

### 1.1 工具链与环境

1. **完整版 Xcode 26**(当前机器只有 Command Line Tools,SwiftPM 纯 CLI 编译对 iOS 真机不够:
   签名、entitlements、provisioning、模拟器运行都依赖 Xcode)
   - 安装:App Store 或 developer.apple.com/download;装完首次启动装 iOS 26 Simulator
   - 要求 macOS 15.6+(本机 15.7.7 ✅);Swift 6.2 / iOS 26 SDK
   - 注意:**2026 年起 App Store 提交强制 Xcode 26 + 最新 SDK**
   - 装完后保留 CLT(`xcode-select` 指向 Xcode 即可,SwiftPM 的 macOS 端构建不受影响)
2. **Apple ID**:免费账号即可真机调试(个人团队),限制:描述文件 **7 天过期**需重签、最多 3 个 App ID、
   不含推送等受限能力
3. **Apple Developer Program($99/年)**:仅在要上 App Store / TestFlight 长期分发时需要;开发期可先不买
4. **硬件**:一台 iPhone(iOS 17+ 即可,Xcode 26 支持 iOS 26 及以下版本的设备调试);没有 iPhone 时
   可先用模拟器验证协议(模拟器可与 Mac 本机 App 互通,同一局域网栈)

### 1.2 本项目移植路径(成本最低的一端)

- `Sources/Core` 用的都是 **Foundation + Network.framework(NWConnection/NWBrowser)+ CryptoKit**——
  三者在 iOS 上 API 一致,预计**除 UI 外几乎零改动复用**(SwiftPM Package 的 platform 加 `.iOS(.v17)`)
- 需要替换的只有:`ClipboardMonitor`(NSPasteboard/AppKit → UIPasteboard/UIKit)、
  `SignalFoundryView`(SwiftUI 大部分可复用,注意 UIKit 桥 `NSHostingView` → `UIHostingController`)
- 工程形态:Xcode 新建 iOS App target 引入现有 SwiftPM 包,或 `swift generate-xcodeproj` 时代方案已废弃,
  直接在 Xcode 里 Add Package Dependency 指向本地仓库

### 1.3 系统能力边界(产品设计的硬约束,务必写进 §12"真实能力边界")

- **后台剪贴板同步在 iOS 上不可能**:剪贴板读取仅限前台 + 用户动作;iOS 16+ 是"读取前弹权限询问"
  (Allow X to paste from Y?);后台静默读取被系统拦截
  → iOS 端产品形态 = **「粘贴发送」按钮(前台手动)+ 收到内容写入 UIPasteboard(前台时)+
  文件传输为主干**(与 Android 端「手动发送」策略一致)
- **后台连接不可保持**:退后台数秒进程即挂起,socket 断;合规的保活手段(VoIP/audio 模式、
  PushKit)审核极严,不适合本产品 → iOS 端 = **前台使用型设计,回到前台时快速重连**
  (BGTaskScheduler `BGAppRefreshTask` 做唤醒后自动重连兜底)
- **本地网络权限(iOS 14+)**:Info.plist 必须声明
  `NSLocalNetworkUsageDescription`(用途说明)+ `NSBonjourServices`(`_protosync._tcp`);
  权限弹窗由实际的 Bonjour 活动(NWBrowser/NWListener)触发——**首次启动要引导用户点允许**
  (与 macOS 端 repack 后弹权限是同一类问题)

### 1.4 步骤清单(建议顺序)

1. App Store 装 Xcode 26(大下载,网络好的时候装)
2. 新建 iOS target 引入 `Sources/Core`,先在 **iOS 模拟器 ↔ Mac 本机 App** 跑通发现/配对/文件
   (模拟器和 Mac 同网,可直接互相发现,不用真机即可验证协议)
3. iOS UI(SwiftUI 复用 Signal Foundry,`UIPasteboard` 桥接 + 手动发送按钮)
4. 真机调试(免费账号 + 7 天签名即可),验证本地网络权限引导、真机↔Mac↔Android 三方互通
5. 长期分发需要时再买 $99/年 开发者计划

---

## 2. HarmonyOS NEXT 客户端

### 2.1 工具链与环境

1. **DevEco Studio 6.1.0 Release**(当前版本线;6.0.0 Release 为 HarmonyOS 6)
   - 下载:developer.huawei.com/consumer/cn/deveco-studio/;**仅 Windows/macOS**,macOS 需 Apple Silicon
   - 内存 16GB 推荐;磁盘预留 ≥50GB(IDE + SDK + 模拟器镜像)
2. **华为开发者账号 + 实名认证**:真机调试和 AGC 任何操作前必须完成实名(个人身份证即可);
   ⚠️ 此前记录过"智谱平台未实名"——**华为这边同样绕不开,先把实名办了**
3. **签名三件套**(在 AppGallery Connect 里管理):
   - `.p12` 密钥库(DevEco 可自动生成)
   - `.cer` 调试证书(数量有限额;上架需 release 证书)
   - `.p7b` Provisioning Profile(**必须包含已注册设备的 UDID**)
   - 流程:AGC 建项目 → 建 HarmonyOS App(packageName 与工程一致)→ 证书/设备/Profile →
     DevEco `File > Project Structure > Signing Configs` 自动签名
4. **设备**:Mac Apple Silicon 模拟器已支持**手机/折叠/平板/2-in-1**(早期"仅穿戴"限制已成历史),
   可先零硬件起步;但**最终必须有真机**(HarmonyOS NEXT 实体手机,如 Mate/Pura 系列)做联调,
   真机通过 hdc 连接;上架 AppGallery 仅接受 **API 12+** 应用
5. **hdc**:DevEco 自带(对标 adb),真机开 USB 调试后部署 `.hap`

### 2.2 本项目移植路径(协议完美对齐)

| 本项目需要 | HarmonyOS NEXT API |
|---|---|
| TCP 收发(4B 分帧 + JSON) | `@ohos.net.socket`(`TCPSocket` / `TCPSocketServer`) |
| 局域网发现(`_protosync._tcp`) | `@ohos.net.mdns`(LAN 服务添加/发现/解析,正对应 Bonjour/NSD) |
| 加密(P256×2/ECDH/HKDF/ChaChaPoly/ECDSA r‖s) | `@ohos.security.cryptoFramework` + Crypto Architecture Kit
  (⚠️ **待核实** ChaCha20-Poly1305 与 HKDF 的覆盖面;缺口部分可照 Android 端做法纯手写 ~300 行,逻辑已有 Java 参照) |
| 固定端口监听(52526) | TCPSocketServer bind(需处理端口占用回退) |
| 剪贴板 | `@ohos.pasteboard`(系统剪贴板;前后台策略接近 Android,按"手动发送"设计) |
| 文件落盘 | `@ohos.file.fs` + 用户目录 Picker(对标 Android MediaStore) |
| 后台保持 | **长时任务(Continuous Task)**:不申请的 App 退后台会被系统**主动断网**(电池优化);
  需 `ContinuousTaskExtensionAbility` + 通知栏常驻,另引导用户加电池白名单(同 OnePlus 经验) |

- 协议蓝本:直接对照 `android/src/com/protosync/core`(最新的逐字节对齐实现)翻译成 ArkTS;
  `HANDOFF.md` §5 的线协议描述 + Android 端 9 个文件就是完整的移植规格
- UI:ArkUI 声明式重画 Signal Foundry 单页(色板照抄 `res/values(-night)/colors.xml` 的 token)

### 2.3 风险与待核实项

- [ ] cryptoFramework 是否原生支持 ChaCha20-Poly1305 AEAD 与 HKDF-expand(决定加密层工作量)
- [ ] `@ohos.net.mdns` 能否**注册**自定义服务类型并携带 TXT(发现协议的服务名 = 指纹前 8 位,兼容性关键)
- [ ] 长时任务的审核门槛(个人开发者能否申请"设备连接"类长时任务)
- [ ] 真机:需要一台 HarmonyOS NEXT 手机;二手/借用均可,先模拟器把协议跑通
- [ ] AppGallery 上架审核(仅分发需要;侧载调试不受限)

### 2.4 步骤清单(建议顺序)

1. 华为账号**实名认证**(先办,不阻塞模拟器开发但阻塞真机)
2. 装 DevEco Studio 6.1,跑通 Hello World + 手机模拟器
3. AGC 建项目/App,配调试签名(自动签名向导)
4. ArkTS 版协议核心:`Frame/Crypto/PeerLink` 对照 Android 端移植,模拟器 ↔ Mac CLI 联调
5. 真机注册 + 长时任务 + 与 Mac/Android 三方互通
6. (可选)AppGallery 上架

---

## 3. 建议总顺序

1. **先 iOS**:零新账号成本起步(免费 Apple ID)、Core 几乎白拿、本机就是开发机——最快见效
2. **并行办**华为实名认证(流程可能要等)
3. **后鸿蒙**:装 DevEco + 模拟器起步,真机到位后联调(项目最大差异化,值得完整投入)

---

## 4. 参考来源

- [Xcode 26 Release Notes(Apple)](https://developer.apple.com) — macOS 15.6+ 要求
- [Xcode on the App Store](https://apps.apple.com) — ~12.6GB 下载
- [Apple:Mandates Xcode 26 for App Store in 2026(seasiainfotech)](https://www.seasiainfo.com) — 2026 提交强制
- [New limitations on free Apple Developer account(mybyways)](https://mybyways.com) — 免费 7 天签名
- [UIPasteboard(Apple)](https://developer.apple.com) / [iOS 16 pasteboard privacy(sarunw)](https://sarunw.com) /
  [clipboard privacy guidance(PTKD)](https://ptkd.com) — 前台限定 + 读取前询问
- [Keeping TCP connection alive in background(Apple Forums)](https://developer.apple.com) /
  [Configuring background execution modes(Apple)](https://developer.apple.com) — 后台挂起与后台模式
- [NWBrowser(Apple)](https://developer.apple.com) /
  [Request and check local network permission(nonstrict.eu)](https://nonstrict.eu) — 本地网络权限两个 Info.plist 键
- [DevEco Studio 下载页(华为)](https://developer.huawei.com/consumer/cn/deveco-studio/)
- [HarmonyOS 6 开发者版本体验招募(华为)](https://developer.huawei.com) — DevEco Studio 6.0/6.1 发布信息
- [@ohos.net.socket(华为)](https://developer.huawei.com) / [@ohos.net.mdns 解读(CSDN)](https://blog.csdn.net) — TCP 与 mDNS API
- [AGC 证书与指纹管理 FAQ(华为)](https://developer.huawei.com) — 调试/发布证书与 Profile
- [HarmonyOS 长时任务技术详解(CSDN)](https://harmonyosdev.csdn.net) — 退后台断网与长时任务
- [uni-app 运行和发行(HarmonyOS)](https://en.uniapp.dcloud.io) — 调试证书需包含注册设备 UDID
- [Mac ARM 模拟器支持讨论(itying)](https://bbs.itying.com) / [模拟器使用(cnblogs)](https://www.cnblogs.com) — 模拟器机型与安装

> 注:以上版本号/配额以官方页面实时为准;标注"待核实"的项在动手当天复查一次。
