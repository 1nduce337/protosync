# ProtoSync Visual Direction

版本：0.1 / 2026-09-18  
方向代号：**SIGNAL FOUNDRY / 信号工坊**  
用途：供后续设计、UI 实现、图像生成与评审 Agent 共同使用

![ProtoSync Logo Concept](assets/protosync-logo-concept-v1.png)

> 一句话准则：**以编辑排版的清晰度组织信息，以工业控制台的精密感表达连接，用克制的信号色让数据流动可被感知。**

---

## 1. 设计目标

ProtoSync 是一个跨生态、本地优先、点对点加密的设备同步工具。它不是云盘，也不是聊天软件；核心体验是：

1. 看见附近或已信任的设备。
2. 明确知道连接是否可信、是否在线。
3. 看见剪贴板或文件从哪台设备流向哪台设备。
4. 出错时知道停在哪里、下一步能做什么。
5. 平时安静驻留，需要时快速操作。

视觉需要传达四种品质：

- **Local**：连接发生在身边的设备之间，而非抽象云端。
- **Verified**：配对与加密是可理解、可确认的。
- **Directional**：数据始终有来源、目标与方向。
- **Operational**：像可靠工具和仪表，不像装饰性科幻概念图。

推荐气质比例：

- 70% 精密生产力工具
- 20% 工业信息设计
- 10% 编辑式科幻氛围

如果“像游戏 UI”和“像可靠工具”发生冲突，永远优先后者。

---

## 2. 参考图应该如何使用

所附《明日方舟：终末地》截图仅作为以下视觉语言的参考：

- 黑、白、石墨灰构成的大面积中性底色。
- 单一高亮信号色标记选中、进行中和关键动作。
- 大数字与微型标签形成的编辑排版反差。
- 模块化面板、轨道线、节点、刻度与局部斜切。
- 深色负空间与浅色“文档面板”并置。
- 高密度信息中仍存在明确主舞台。

不得复制：

- 游戏 Logo、阵营徽章、关闭按钮或任何具体图标轮廓。
- 原截图的页面结构、栏位比例、卡片排列和文字内容。
- 特定世界观术语、军事编号或无意义伪技术文字。
- 原作独有的装饰纹样、符号组合或精确色彩搭配。
- 让结果看起来像游戏换皮的任何设计。

正确的结果应该首先被识别为 **ProtoSync 的设备同步系统**。

---

## 3. 核心创意：把同步表现成“可信路由”

整套视觉围绕一个简单模型展开：

```text
DEVICE NODE  →  VERIFIED ROUTE  →  DEVICE NODE
```

对应的基础图形语汇：

- **Node / 节点**：设备、身份、收件箱、数据包。
- **Route / 轨道**：连接、方向、传输进度。
- **Gate / 闸门**：配对确认、权限、可信边界。
- **Pulse / 脉冲**：正在搜索、发送、接收或校验。
- **Receipt / 回执**：完成、拒绝、失败或离线。

不要用大面积云朵、Wi-Fi 波纹或传统循环箭头作为主要隐喻。ProtoSync 的独特性是“两端之间的本地可信通道”。

---

## 4. 品牌标识方向

### 4.1 推荐概念：Protocol Gate / 协议闸门

当前概念稿位于：

`design/assets/protosync-logo-concept-v1.png`

构成含义：

- 两个相向、略不对称的几何端口代表两台不同生态的设备。
- 两端围合成连续通道，表达双向流动。
- 中央小菱形代表经过验证的数据包或握手点。
- 负空间可以轻微暗示 P / S，但不能成为直白字母 Logo。

### 4.2 当前资产定位

该 PNG 是 **方向稿，不是最终生产 Logo**。它由图像模型生成，适合确定轮廓与概念，但上线前应人工重绘为 SVG/PDF，并完成小尺寸光学校正。

生产版必须提供：

1. 单色模板版：菜单栏、通知栏、系统小图标。
2. 深色底版：Paper White 或 Signal Lime 图形。
3. 浅色底版：Carbon 图形，可用一个 Signal Lime 数据点。
4. macOS App Icon 版：保留足够安全区，不把 Logo 直接顶到圆角方形边缘。
5. Android Adaptive Icon：前景与背景分层，兼容系统遮罩。
6. 16、20、24、32 px 简化版：删去无法稳定显示的内部细节。

几何约束：

- 24×24 或 32×32 基础网格。
- 主干宽度约为图标宽度的 8%–12%。
- 使用直线、45° 切角与小半径圆角。
- 主体占安全区约 68%–72%。
- 必须先通过纯黑白测试，再添加信号色。
- 不用盾牌、锁、云、翅膀、六边形徽章或回收式双箭头。

---

## 5. 色彩系统

### 5.1 基础色

| Token | Hex | 用途 |
|---|---:|---|
| `Carbon 950` | `#080A0C` | 最深背景、菜单栏图标深色版 |
| `Carbon 900` | `#111417` | 深色主画布 |
| `Graphite 800` | `#1B2025` | 主面板 |
| `Graphite 700` | `#2C333A` | 次级面板、悬停 |
| `Steel 500` | `#707980` | 次级文字、离线状态 |
| `Paper 100` | `#F2F3EE` | 浅色主画布、深底主文字 |
| `Paper 200` | `#DDE0DA` | 分割线、浅色次级面板 |
| `Ink 900` | `#15181B` | 浅底正文、信号色按钮文字 |

### 5.2 语义信号色

| Token | Hex | 语义 |
|---|---:|---|
| `Signal Lime` | `#E7FF16` | 已连接、当前选中、主要动作、成功路由 |
| `Transfer Cyan` | `#25C7E8` | 正在传输、接收方向、扫描 |
| `Pairing Amber` | `#FFB020` | 等待确认、配对请求、需要注意 |
| `Fault Coral` | `#FF5B55` | 失败、中断、危险操作 |

### 5.3 使用规则

- 单个页面只允许一种信号色成为视觉主角。
- Lime 是品牌主色，不等于“所有成功信息都涂黄”。
- Cyan 只表达数据正在流动，不拿来装饰标题。
- Amber 只用于需要用户决定的状态。
- Coral 只用于错误与破坏性操作。
- Lime 背景上使用 `Ink 900`，不要使用白字。
- 状态不能只依赖颜色，必须同时使用文字和图标。
- 不采用常见蓝紫渐变 SaaS 配色，也不做霓虹赛博朋克发光。

### 5.4 双表面，而非“满屏纯黑”

推荐同时使用两类表面：

- **Control Surface**：Carbon / Graphite，承载导航、设备状态和环境信息。
- **Document Surface**：Paper，承载文件、活动记录、配对说明和可读长文本。

深浅表面的并置比大量阴影更能建立层级。系统浅色模式下可反转面积关系，但语义色保持一致。

---

## 6. 字体与排版

### 6.1 字体

首版不引入额外字体包：

- macOS：SF Pro / 系统字体；数字与指纹使用 SF Mono 或 `.monospacedDigit()`。
- Android：Roboto / 系统字体；地址、速率、指纹使用 Roboto Mono 或 monospace。
- 中文使用系统黑体，保证跨平台清晰和动态字体兼容。

### 6.2 层级

| 层级 | 建议 | 示例 |
|---|---|---|
| Display Number | 36–52 px，Regular/Medium，等宽数字 | `02` 台在线、`68%` |
| Page Title | 22–28 px，Semibold | 设备、流转、收件箱 |
| Section Title | 12–14 px，Semibold，略加字距 | `// DEVICES` |
| Body | 14–16 px，Regular | 文件名、设备名、说明 |
| Metadata | 11–13 px，Monospaced where useful | 指纹、时间、大小、IP |

原则：

- 中文主标签优先，英文微标签只作导航提示，例如 `// DEVICES`。
- 大数字可以制造技术编辑感，关键说明不能缩成 HUD 小字。
- 指纹按 4 位分组或显示前 8 位；需要安全确认时提供完整值。
- 文件名允许截断，但必须能悬停/点按查看完整名称。
- 不滥用全大写、斜体或伪代码。

---

## 7. 几何、材质与图标

### 7.1 几何

- 主体以矩形、轨道线、节点圆环、方向箭头和 45° 缺角构成。
- 标准面板圆角 4–8 px；不要让所有容器都是 12–20 px 的悬浮圆角卡片。
- 胶囊只用于状态、筛选器和单行紧凑按钮。
- 1 px 边线负责分层，阴影只在浮层/HUD 使用。
- 选中态必须明显：信号色底边、整块浅填充或高对比描边，不能只改变文字颜色。

### 7.2 背景纹理

可使用：

- 2%–5% 透明度的点阵或细网格。
- 极淡的拓扑线、连接路径或设备轮廓。
- 局部斜向细纹、登记刻度和裁切标记。

限制：

- 纹理只出现在大背景或空态，不穿过正文。
- 不使用破损、污渍、重胶片颗粒或强 glitch。
- 不让装饰线看起来像可交互控件。

### 7.3 图标

- macOS 优先 SF Symbols，Android 使用语义一致的 Material/自绘矢量。
- 核心图标统一成几何线面混合风格：设备、双向通道、剪贴板、文件、可信节点、断开、加密。
- 16–20 px 仍需清楚，线宽一致。
- 同一页面不混用线性图标、彩色插画和拟物图标。
- 菜单栏和通知栏必须使用纯单色模板图标。

---

## 8. 信息架构

### 8.1 macOS 主窗口

现实约束：当前窗口约 `520 × 680`，最小约 `480 × 620`。不要照搬参考图的横向三栏。

推荐使用紧凑的四模式结构：

1. **总览 / OVERVIEW**
   - 服务状态与在线设备数量。
   - 当前或最近一次数据流。
   - 在线设备快捷操作。
   - 正在进行的文件传输。
2. **设备 / DEVICES**
   - 已配对设备。
   - 附近未配对设备。
   - 刷新、配对、取消配对。
3. **流转 / ACTIVITY**
   - 文本、图片、文件的统一时间流。
   - 方向、时间、进度与失败原因。
4. **收件箱 / INBOX**
   - 最近文件。
   - 在 Finder 中显示、打开收件箱。

设备名、完整指纹、本机 IP:端口和诊断放入 **System / 设置抽屉**，不要长期占用主流程。

主窗口结构建议：

```text
┌──────────────────────────────────────┐
│ Logo  ProtoSync   02 ONLINE    Scan  │  64–72
├──────────────────────────────────────┤
│ OVERVIEW  DEVICES  ACTIVITY  INBOX   │  36–40
├──────────────────────────────────────┤
│                                      │
│  Primary Stage / 当前状态或传输      │
│                                      │
├──────────────────────────────────────┤
│  Secondary rows / contextual detail  │
└──────────────────────────────────────┘
```

菜单栏菜单保持原生且极简：在线数量、打开窗口、发送文件、打开收件箱、复制地址、退出。不要把完整视觉系统硬塞进系统菜单。

### 8.2 Android 首版

当前是纯 Java 程序化 View，并非 Compose。首版应是单页指挥面板，而非立刻引入复杂底栏：

1. 顶部服务状态与在线数量。
2. 两个主操作：发送剪贴板、发送文件。
3. 在线/已配对设备。
4. 附近设备与配对入口。
5. 当前传输，有任务时出现。
6. **高级连接与诊断** 折叠区：刷新、手动 IP、指纹、原始日志。

等 Android 有结构化活动模型和收件箱查询后，再扩成 Home / Devices / Activity / Settings。

Android 注意：

- 触控目标至少 48 dp。
- 支持窄屏、字体放大、横竖屏与系统深浅色。
- 文件选择器、系统通知和部分配对流程属于系统 UI，不要强行套皮。
- 原始日志不能继续作为普通用户首页主体。
- 手动 IP 是 mDNS 失败时的重要后备，但应默认折叠。

---

## 9. 核心组件规范

### 9.1 System Header

显示 Logo、ProtoSync、本机服务状态、在线数量和刷新动作。

- 在线数量使用大数字或高对比计数。
- 刷新状态使用短扫描动效和文字，不只旋转图标。
- 启动失败时将主状态替换成可恢复的错误动作。

### 9.2 Device Node Row

必须显示：

- 设备名。
- 在线 / 离线 / 连接中 / 等待配对。
- 短指纹。
- 在线时允许的主要动作。

不要假定协议已经知道设备平台；没有真实平台字段时，使用通用节点图标，不凭名称猜手机或电脑。

### 9.3 Pairing Gate

配对是安全决策，不是普通 Toast。

- 显示对方设备名和 6 位配对码，配对码用大字号展示便于核对。
- 6 位配对码是 SAS（短认证串）：两端各自从握手 transcript 推导出同一码值并展示给用户比对；一致才可接受，不一致即存在中间人。这是产品必需的安全功能，不是装饰——真实协议（Swift/Android）需要实现该推导（如 HKDF(transcript) → 6 位数字），落地前 UI Demo 以模拟数据先行。
- 同时显示短指纹作为辅助核对。
- “接受”与“拒绝”同时可见。
- 使用 Amber 表示等待用户确认。
- 配对请求到达时，横幅必须立即可见于任何标签页（不允许只在自己页面里悄悄出现）。
- 接受后用闭合轨道/稳定节点反馈完成。

### 9.4 Transfer Track

文件传输卡是最能体现品牌语言的组件：

- 左端来源节点，右端目标节点。
- 中间轨道承载进度。
- 大百分比与小型文件元数据分层。
- 清楚区分准备摘要、等待接收、传输、校验、完成、拒绝和失败。
- 进行中使用 Cyan 脉冲；完成后轨道转为 Lime 实线；失败为 Coral 断点。

不显示当前数据模型没有提供的 ETA 或 MB/s，除非代码先补齐。

### 9.5 Activity Rail

- 按时间倒序。
- 每行必须有方向、类型、摘要、时间和结果。
- 文本内容只显示短预览，避免泄露大量剪贴板隐私。
- 失败行提供明确原因，不以一串原始异常替代用户说明。
- 可用细纵向轨道串起事件，但不要做成社交聊天气泡。

### 9.6 Inbox Item

- 文件名、类型、大小/时间（有真实数据时）、来源设备（有真实数据时）。
- 主动作是打开或在 Finder/文件管理器中定位。
- 空态应解释文件保存位置。

### 9.7 Status Tag

状态标签由三部分组成：图标 + 文本 + 色彩。

推荐文案：

- `已连接 CONNECTED`
- `正在传输 SYNCING`
- `等待确认 VERIFY`
- `离线 OFFLINE`
- `已中断 INTERRUPTED`
- `已完成 DONE`(传输完成短暂停留期使用,轨道转 Lime 实线)

无需所有地方都中英双写；英文微标签只用于形成一致的系统语气。

---

## 10. 动效语言

### 10.1 建议动效

- **发现**：节点由低透明度进入，短扫描线经过一次。
- **连接**：两端节点依次点亮，通道从两端向中央闭合。
- **配对**：扫描环收束为稳定边线。
- **传输**：一段短亮条沿轨道移动，数字平滑更新。
- **校验**：中央数据点短暂停顿，然后切换为完成状态。
- **面板切换**：8–16 px 短距离滑入或边线展开。

### 10.2 节奏

- Hover / Press：80–140 ms。
- 普通状态切换：140–240 ms。
- 完成反馈：240–320 ms。
- 不使用持续闪烁、随机 glitch、强抖动或大量粒子。
- 支持 Reduce Motion；关闭位移动效后，颜色、图标和文字仍能完整传达状态。

---

## 11. 无障碍与易用性底线

- 正文和关键控件达到 WCAG AA 对比度。
- 桌面点击目标至少约 32×32 pt；Android 至少 48×48 dp。
- 连接、失败、等待不能只靠红绿差异。
- 键盘焦点必须清楚可见。
- 支持系统字体放大，不把正文锁死成微型 HUD 字号。
- 长文件名有截断策略和完整名称查看方式。
- 动画不是唯一反馈，屏幕阅读器应获得相同状态变化。
- 装饰性网格、刻度和微标签不承载必要信息。
- 剪贴板预览默认克制，避免在公共环境泄露敏感内容。

---

## 12. 真实能力边界：不要设计成已经实现

后续 Agent 必须以源码而非 UI Demo 的假数据为准。当前不能默认存在：

- 6 位配对码的协议推导（两端从握手材料推导同一 SAS 码）：已定为产品必需的安全能力，真实协议（Swift/Android）**尚未实现**；UI Demo 以模拟数据先行展示交互。协议落地前，不能把推导逻辑当成现有接口。
- 协议提供的设备平台类型。
- 文件传输 MB/s、ETA、暂停、恢复或取消。
- 剪贴板送达 ACK 或绿色送达勾。
- Android 图片剪贴板同步。
- 持久化活动历史。
- 发现阶段的友好设备名称。
- 多文件或文件夹发送。
- 信号强度、延迟、云端状态。

设计稿若展示上述能力，必须标注为 **Future / 概念能力**，不能直接交给实现 Agent 当成现有接口。

当前真实差异：

- macOS 自动监听并广播文本和图片剪贴板。
- Android 需要用户点击发送，当前仅支持文本。
- 文件为单文件、单目标。
- macOS 有结构化活动与进度；Android 目前主要是日志文本。
- macOS 有收件箱列表；Android 文件保存到 Downloads/ProtoSync，但尚无完整收件箱页面。

---

## 13. 视觉禁区

不要：

- 满屏半透明玻璃卡片。
- 蓝紫渐变、霓虹辉光或赛博朋克城市感。
- 过量六边形、瞄准镜、军事徽章和警戒条。
- 用很小的灰字制造“技术感”。
- 每个角落都塞编号、刻度或伪日志。
- 把主要操作隐藏在装饰性图标里。
- 给所有按钮都用 Signal Lime。
- 让配对、离线和失败只依赖颜色。
- 照搬参考游戏的符号、构图或关闭按钮。
- 为了视觉效果伪造不存在的协议数据。

---

## 14. 实施顺序

### Phase 1：设计沙盒

优先在 `ProtoSyncUIDemo/` 迭代视觉，不触碰传输层：

1. 建立 SwiftUI Design Tokens。
2. 先实现 System Header、Device Node、Pairing Gate、Transfer Track。
3. 用 MockModel 覆盖正常、空态、离线、失败、大文件与配对场景。
4. 分别检查 480×620 与 1060×760。
5. 通过可读性评审后再移植到真实 App。

### Phase 2：macOS 真实 UI

1. 只替换视图层，不改协议行为。
2. 所有视觉状态必须由 AppModel 的真实字段驱动。
3. 未实现字段不在生产 UI 出现。
4. 菜单栏保持系统原生风格。

### Phase 3：Android

1. 先把原始日志移入高级折叠区。
2. 建立基础颜色、Shape Drawable、间距与文字 token。
3. 重做顶部状态、主动作、设备列表和配对流程。
4. 再补结构化传输卡和收件箱数据模型。
5. 若后续迁移 Compose，再考虑更复杂的轨道动画。

---

## 15. 给后续 AI Agent 的 Master Prompt

下面内容可直接复制。将方括号变量替换成具体任务。

```text
You are designing [PLATFORM: macOS / Android] UI for ProtoSync, a privacy-first local peer-to-peer utility that securely synchronizes clipboard content and single files between trusted devices on the same LAN.

Art direction: “Signal Foundry.” Create an original production-ready productivity interface that combines editorial information design with a restrained industrial control-console language. The product must feel precise, trustworthy, directional, and quiet—not like a game skin, cyberpunk dashboard, or generic blue-purple SaaS app.

Core visual metaphor: DEVICE NODE → VERIFIED ROUTE → DEVICE NODE. Express discovery, pairing, transfer, verification, and completion through nodes, tracks, gates, short pulses, and clear directional markers.

Palette:
- Carbon #111417 and Deep Carbon #080A0C for control surfaces
- Paper #F2F3EE for readable document surfaces
- Signal Lime #E7FF16 for the primary selected/connected/action state
- Transfer Cyan #25C7E8 only for active data movement
- Pairing Amber #FFB020 for decisions awaiting confirmation
- Fault Coral #FF5B55 for errors and destructive actions
Use only one dominant signal color per screen. Put dark text on Signal Lime.

Typography: native system sans-serif for body content; monospaced digits only for fingerprints, IP addresses, file sizes, percentages, and timestamps. Use strong contrast between large status numbers, clear section titles, readable body text, and small metadata. Never put essential instructions in tiny HUD text.

Geometry: mostly rectangular panels, 4–8 px corner radii, 1 px dividers, restrained 45-degree notches, tracks and nodes. Avoid a screen made entirely of floating rounded cards. Use subtle dot grids or topology lines only at 2–5% opacity in background regions.

Interaction: selected states must be unmistakable. Every status uses icon + text + color. Motion lasts roughly 140–240 ms: nodes light in sequence, routes close, and short pulses travel along a transfer track. Support Reduce Motion and keyboard/screen-reader access.

Product truth:
- Pairing currently confirms device name + fingerprint; there is no implemented six-digit pairing code.
- Device platform type is not currently provided by the protocol.
- Clipboard has no delivery receipt.
- Transfer ETA/MBps, pause/resume/cancel, folders, and multi-file sending are not implemented.
- macOS syncs text and image clipboard automatically; Android currently sends text manually.
- Files are single-file, single-target transfers.
Do not invent unsupported data. Mark future concepts explicitly.

Task: [SCREEN OR COMPONENT TO DESIGN]
State to show: [DEFAULT / EMPTY / CONNECTING / PAIRING / TRANSFERRING / VERIFYING / COMPLETE / FAILED / OFFLINE]
Required real actions and content: [LIST]
Target dimensions and platform constraints: [LIST]

Reference images, if supplied, are mood references only. Extract high-level contrast, hierarchy, modularity, and industrial editorial rhythm. Do not copy their logos, emblems, icons, layout, text, decorative patterns, or game-specific visual identity.

Output a practical shippable interface, not concept art. Include default, hover/focus/pressed/disabled, empty, loading, error, and accessibility states. Preserve native macOS or Android behavior where the system owns the interaction.
```

---

## 16. Screen-specific Prompt Add-ons

### macOS 总览

```text
Design the ProtoSync macOS Overview for a 520 × 680 window, with a usable minimum of 480 × 620. Use a compact top system header and a four-mode rail: Overview, Devices, Activity, Inbox. The primary stage shows service health, real online-device count, and an active transfer only when one exists. Below it, show trusted device rows and recent real activity. Keep settings, full fingerprint, and IP:port in a secondary system drawer. Do not use a desktop-wide three-column layout.
```

### Android 单页首页

```text
Design the first ProtoSync Android home screen as a vertically scrolling native utility panel, feasible in Java Views on API 28–34. Show foreground-service health, online count, two clear actions for Send Clipboard and Send File, paired devices, nearby devices, and an active transfer section that appears only when needed. Put refresh, manual IP connection, local fingerprint, and raw logs inside a collapsed Advanced Connection & Diagnostics section. Use 48 dp touch targets and support large text. Do not assume Compose-only effects.
```

### Logo 生成 Prompt

```text
Use case: logo-brand
Asset type: original app icon and logo-mark concept for ProtoSync, a privacy-first local peer-to-peer clipboard and file synchronization utility connecting Mac and Android devices
Primary request: create one compact “Protocol Gate” symbol communicating two devices, bidirectional exchange, secure pairing, and a continuous sync route; construct it from two opposing angular endpoint forms around one protected central packet; let the negative space only subtly suggest P and S
Style/medium: vector-friendly flat geometric logo, precise industrial utility identity, strong silhouette, readable at 16 px and 32 px
Color palette: carbon black #111417 and signal lime #E7FF16; monochrome must also work
Composition/framing: centered isolated mark, generous transparent safe area
Constraints: original design only; genuinely transparent background; no text; no gradients; no shadow; no glow; no 3D; no texture; no mockup; no shield; no lock; no cloud; no Wi-Fi symbol; no recycle arrows; no hexagonal badge; no game logo or faction-emblem resemblance; no watermark
```

---

## 17. 评审清单

每次设计提交必须回答：

- [ ] 第一眼能看出当前是否在线吗？
- [ ] 能看出数据从哪里到哪里吗？
- [ ] 当前最重要的动作是否只有一个明显主级？
- [ ] 颜色是否承担明确语义，而非装饰？
- [ ] 去掉背景纹理后，信息结构仍成立吗？
- [ ] 是否使用了真实可获得的数据？
- [ ] 配对决定是否足够安全、明确？
- [ ] 错误是否告诉用户发生了什么和能做什么？
- [ ] 480×620 macOS 小窗口与窄 Android 屏幕是否仍可用？
- [ ] 键盘、屏幕阅读器、字体放大和 Reduce Motion 是否可用？
- [ ] 是否明显区别于参考游戏，而保留了高层视觉气质？
- [ ] Logo 和核心图标在 16–20 px 是否仍清楚？

---

## 18. 项目内相关文件

- macOS 真实主界面：`Sources/ProtoSyncApp/DashboardView.swift`
- macOS UI 状态：`Sources/ProtoSyncApp/AppModel.swift`
- macOS 菜单栏与窗口：`Sources/ProtoSyncApp/main.swift`
- UI 设计沙盒：`ProtoSyncUIDemo/DemoViews.swift`
- UI 模拟状态：`ProtoSyncUIDemo/MockModel.swift`
- Android 当前界面：`android/src/com/protosync/app/MainActivity.java`
- Android 后台与通知：`android/src/com/protosync/app/SyncService.java`
- 协议与真实状态：`Sources/Core/SyncEngine.swift`

本文优先级高于任何只展示“漂亮理想态”的单张概念图。后续 Agent 应先遵守产品真实性与无障碍约束，再扩展视觉表现。

