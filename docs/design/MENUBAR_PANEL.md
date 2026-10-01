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
3. **Decision cards**, only when needed: a pairing request (fingerprint shown in monospace digits) and a file request (接收 / 拒绝 / 总是).
4. **Transfers**: one line each with a 3 pt progress bar, or "等待对方确认" while the receiver decides.
5. **Clipboard history**: the last 6 items, in memory only and never written to disk.
   - Click an item to copy it again.
   - Each item shows its source device and time.
6. **Footer**: a hint ("拖文件到头像即可发送") and a link to open the inbox.

Right-clicking the menu-bar icon keeps the classic menu. The full window is now "设备与设置", opened from the gear menu or the right-click menu, and no longer opens at launch.

## Visual rules

- The panel is always dark (`darkAqua`) and sits on the system popover material. There are no custom panel backgrounds or borders.
- **One accent: Lime `#E7FF16`.** Use it only for:
  - primary buttons (ink `#15181B` text on lime);
  - online dots;
  - drop-target rings;
  - progress fills;
  - the inbox link.
- Grouping uses fills (`white 6%` / `11%`), not outlines: no 1 px borders around every section.
- Type: the system font only. 13 pt for the title, 12 pt for body, 11 pt for secondary, 10 pt for metadata. Use monospaced digits only for fingerprints and percentages.
- Copy is Chinese only, with no English tags. Drop "SCAN", "ONLINE", "IDLE", zero-padded counts, dot grids and cut corners.
- Status is never shown by color alone: offline devices are also dimmed and say "离线" in the tooltip and accessibility label.

## 设备与设置 window (macOS)

A native grouped `Form` that follows the system's light/dark mode, with no Lime. It has these sections:
- pending pairing / file requests;
- 本机 (name, full fingerprint, address);
- 已配对设备 (online state, 自动接收文件, remove with confirmation);
- 附近的设备;
- 剪贴板 (sync, background reading, notifications);
- 收到的文件.

## iOS

A single dark screen following the B-iPhone mockup:
- device avatars (tap to send a file, long-press for options) and the "+" pairing tile;
- request cards;
- transfers;
- clipboard history (tap to copy);
- received files (QuickLook);
- a pinned "发送剪贴板" bar.

The gear opens a settings sheet with the fingerprint, per-device 自动接收文件 toggles (swipe to remove) and the log.

## Not done yet

- Android: the same layout in the existing plain-Java views.
- Show the target device on the transfer line (transfer events don't carry the peer yet).
