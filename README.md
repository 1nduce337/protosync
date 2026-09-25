<p align="center">
  <img src="design/assets/protosync-logo-concept-v1.png" width="120" alt="ProtoSync logo">
</p>

<h1 align="center">ProtoSync</h1>

<p align="center">
  跨生态多设备联动:局域网点对点、端到端加密的剪贴板与文件同步<br>
  Local-first, end-to-end encrypted clipboard &amp; file sync across macOS · iOS · Android
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20iOS%20%7C%20Android-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license">
  <img src="https://img.shields.io/badge/P2P-no%20server-E7FF16" alt="p2p">
</p>

---

ProtoSync 让同一局域网内的设备**自动互相发现**,在两两之间建立**端到端加密**通道,同步剪贴板、收发文件——不经过任何服务器,数据只在你的设备之间流动。

```text
  DEVICE NODE ──verified route──> DEVICE NODE
```

## 功能

| | macOS | iOS | Android |
|---|---|---|---|
| 自动发现(Bonjour/mDNS) | ✅ | ✅ | ✅ |
| 设备配对(TOFU 指纹核对) | ✅ | ✅ | ✅ |
| 剪贴板同步(文本) | ✅ 自动 | ✅ 手动发送¹ | ✅ 手动发送¹ |
| 剪贴板同步(图片) | ✅ 自动 | ✅ 手动发送 | 🚧 计划中 |
| 文件收发(单文件,SHA-256 校验) | ✅ | ✅ | ✅ |
| 后台保活 | ✅ 菜单栏常驻 | —(iOS 前台使用) | ✅ 前台服务 |
| 收到内容通知 | ✅ | ✅ | ✅ 横幅 + 一键复制 |
| 结构化活动流 / 收件箱 | ✅ | ✅ | ✅ |
| 双主题(Signal Foundry 设计) | ✅ | ✅ | ✅ |

> ¹ Android 10+ / iOS 系统限制:剪贴板只能前台手动发送,接收自动。

## 截图

| iOS | macOS |
|---|---|
| ![iOS](docs/img/ios-simulator.png) | *待补充* |

## 安全模型

- 每台设备持有两把静态 P256 密钥(签名 + ECDH),指纹 = `SHA256(signPub ‖ dhPub)`
- 握手:临时密钥三轮 ECDH(`eph×eph ‖ eph×static ‖ static×eph`)→ HKDF-256 → 会话密钥,前向安全
- 所有业务消息 ChaCha20-Poly1305 AEAD 加密,nonce 为方向独立单调计数器
- 配对采用 **TOFU + 指纹人工核对**(两端展示指纹,一致才接受)
- 协议为平台无关的二进制线协议(4 字节大端分帧 + JSON),Swift 与 Java 双实现真机互验

## 各端构建

### macOS(SwiftPM,Command Line Tools 即可)

```bash
swift build
swift run protosync-tests   # 单元测试
./scripts/make-app.sh       # 生成 ProtoSync.app(菜单栏应用)
```

### iOS(xcodegen + Xcode 15+)

```bash
cd ios && xcodegen generate
open ProtoSync.xcodeproj    # 选模拟器 ⌘R;真机部署见 docs/DEPLOY_TO_IPHONE.md
```

### Android(无 Gradle:javac + d8 + aapt2 + apksigner)

```bash
./android/build_apk.sh      # 需 JAVA_HOME + ANDROID_HOME(build-tools 35)
adb install -r android/build/ProtoSync-android.apk
```

## 仓库结构

```text
Sources/            Swift 协议栈(Core,平台无关)+ macOS App + CLI 测试对端 + 测试
ios/                iOS App(xcodegen 工程 + SwiftUI)
android/            Android 客户端(纯 Java,无 Gradle 工具链)
design/             Signal Foundry 设计规范与 logo 资产
scripts/            图标生成 / macOS 打包脚本
docs/               平台前置条件调研、真机部署指南
ProtoSyncUIDemo/    UI 设计沙盒(模拟数据)
```

## 路线图

- [ ] 6 位 SAS 配对码(两端从握手材料推导,防中间人)
- [ ] Android 剪贴板图片
- [ ] Windows 客户端
- [ ] HarmonyOS NEXT 客户端
- [ ] 蓝牙就近发现(无 Wi-Fi 场景)

## 设计

UI 遵循自研的 **Signal Foundry** 设计语言:工业控制台式的精密感 + 编辑排版的清晰度,
Carbon/Paper 双表面 + Lime/Cyan/Amber/Coral 四语义信号色。详见
[design/PROTO_SYNC_VISUAL_DIRECTION.md](design/PROTO_SYNC_VISUAL_DIRECTION.md)。

## License

[MIT](LICENSE)
