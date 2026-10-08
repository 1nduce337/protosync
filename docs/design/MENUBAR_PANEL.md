# Menu-bar panel (design direction B)

Status: **chosen direction**, replacing the Signal Foundry console look for everyday use.
Mockups: the "ProtoSync UI Directions" design canvas, row B (macOS panel and iPhone).

## Idea

ProtoSync is a utility you forget about until you need it. The main surface is a small dark panel
under the menu-bar icon, not a window. One glance shows who is online. One drag sends a file.
Anything that needs a decision appears in the panel, and nothing else asks for attention.

## Structure (macOS, 360 pt wide, height follows content)

1. **Header**: "ProtoSync", the "同步剪贴板" switch (pauses sending this Mac's clipboard; receiving continues), and a gear menu (设备与设置… / 打开收件箱 / 退出).
2. **Device avatars**: 52 pt circles, online first.
   - **Online:** a small lime dot.
   - **Offline:** dimmed.
   - **Click:** pick a file to send.
   - **Drag a file onto an avatar:** sends it to that device (a lime ring shows the drop target).
   - **Right-click:** send file, the 自动接收文件 toggle, remove device.
   - **Dashed "+" circle:** toggles the nearby-devices list for pairing.
3. **Decision cards**, only when needed:
   - **Pairing request** (on the device being asked): the 6-digit 配对码 in large monospaced digits, which both screens show identically, plus 接受 / 拒绝.
   - **"正在与「X」配对"** (on the device where you tapped 配对): the same 配对码 and "请在对方设备上确认", with no buttons.
   - **File request:** 接收 / 拒绝 / 总是.
4. **Transfers**: one line each with a 3 pt progress bar, or "等待对方确认" while the receiver decides.
5. **Clipboard history**: the last 6 items, in memory only and never written to disk.
   - Click an item to copy it again.
   - Each item shows its source device and time.
6. **Footer**: a hint ("拖文件到头像即可发送") and a link to open the inbox.

Right-clicking the menu-bar icon keeps the classic menu.

**Keeping the panel open while picking files:**
- By default the popover is `.applicationDefined`: clicking another app (e.g. Finder, to start a drag) doesn't close it. It closes on a second click on the menu-bar icon, on Esc, or when one of its own buttons opens a window.
- Settings › 菜单栏面板 › "点击其他地方时收起" (`panelClosesOnOutsideClick`, default off) switches back to `.transient`.
- Dragging a file onto the menu-bar icon opens the panel, so the drag can continue onto a device avatar.

## Main window (macOS)

The full version of the panel: everything the panel does, with more room. Opened from the panel footer ("打开窗口"), the gear menu and the right-click menu ("打开主窗口…"). It is a regular window, so it stays open while you pick files in Finder. Same visual rules as the panel and the settings window: always dark, `white 6%` fill groups with 10 pt corners, 11 pt section titles; Lime only for online dots, drop rings, progress, and the inbox link.

Top to bottom:
- **Header:** this Mac's circle, its name, "N 台设备在线 · 复制即同步", the 同步剪贴板 switch and a "设备与设置…" button.
- **Requests:** the same pairing / outgoing pairing / file request cards as the panel.
- **设备:** an adaptive grid of 150 pt tiles.
  - Each tile is a drop target for many files at once, with a Lime ring and "松开即发送" while hovering.
  - Click a tile for a multi-select picker; the right-click menu has send / 自动接收文件 / remove (confirmed).
  - The subtitle says "需对方确认" when auto-receive is off on the other side.
  - A dashed "配对新设备" tile opens the 附近的设备 list below the grid.
- **传输 | 剪贴板历史:** two columns on wide windows, stacked on narrow ones.
  - 传输: the last 30 file transfers, with progress, "等待对方确认" or the final status.
  - 剪贴板历史: the same click-to-copy rows as the panel.
- **收到的文件:** the 8 newest inbox files with icon, name and relative time. On hover there are 打开 / 显示 buttons, and a double-click opens the file.

## 设备与设置 window (macOS)

The same visual language as the panel, in a calmer, roomier layout:
- always dark;
- groups are `white 6%` fills with 10 pt corners;
- section titles are 11 pt secondary;
- rows are at least 44 pt tall with hairline dividers.

Lime is limited to switches that are on, online dots and primary buttons (配对).

Contents, top to bottom:
- **Header:** a 56 pt device circle for this Mac, the editable name, the short fingerprint with "复制完整指纹", the online count, and the address (click to copy).
- **Pending requests:** the same `PanelPairingCard` / `PanelOfferCard` the panel uses.
- **已配对设备:** 34 pt avatars, status and short fingerprint, the "自动接收" switch, and a ⋯ / right-click menu to remove (confirmed).
- **附近的设备**, with a quiet "重新查找" link.
- **菜单栏面板:** "点击其他地方时收起" (default off).
- **剪贴板:** three switches, each with a one-line explanation.
- **收到的文件:** the folder and the 5 most recent files.

## iOS

A single dark screen following the B-iPhone mockup:
- device avatars (tap to send a file, long-press for options) and the "+" pairing tile;
- request cards;
- transfers;
- clipboard history (tap to copy);
- received files (QuickLook);
- a pinned "发送剪贴板" bar.

The gear opens a settings sheet with the fingerprint, per-device 自动接收文件 toggles (swipe to remove) and the log.

## Android

The same single dark screen as iOS, built in plain Java views (no Gradle):
- `PanelUi.java` holds the tokens and builders, mirroring `PanelStyle.swift`.
- Avatars are 76 dp: tap to send a file, long-press for 自动接收文件 / 移除.
- Pairing and file requests are inline cards, not dialogs.
- The gear opens a full-screen settings sheet: this device, auto-receive switches, manual connect, log.

## Not done yet

- Show the target device on the transfer line (transfer events don't carry the peer yet).
