# Handoff

Shared status between Claude Code sessions (local Mac and cloud). Update before ending a session.
No private data here — see "Privacy" in `CLAUDE.md`.

_Last updated: 2026-10-01 (local Mac session)_

## In progress: menu-bar panel UI (branch `feat/menubar-popover-ui`)

Design direction B was chosen (spec: `docs/design/MENUBAR_PANEL.md`).
- **Done (macOS):**
  - left-clicking the menu-bar icon opens a new dark panel (`Sources/ProtoSyncApp/MenuBarPanel.swift`) with device avatars (drag files onto them), pairing, file requests, transfers and the last 6 clipboard items;
  - right-clicking keeps the classic menu;
  - the main window is now "设备与设置" and no longer opens at launch;
  - new "同步剪贴板" switch (pauses sending; persisted in `UserDefaults` key `clipboardSyncEnabled`);
  - clipboard history is in memory only.
- **Engine API change:** `didReceiveClipboardText/Image` now pass `from peer: PeerConnection.PeerInfo`. The Mac app, iOS app and CLI peer are updated.
- ✅ **Compiled on the Mac (no fixes needed):** `swift build` (warnings only, pre-existing style), `swift run protosync-tests` 45/45, `./scripts/make-app.sh`, iOS simulator build (xcodegen + xcodebuild, unsigned). The app launches and stays running.
- ⚠️ **Not checked by hand yet** (needs a person at the Mac; the agent can't click the menu bar or drag files):
  1. left-click opens the panel, right-click opens the classic menu;
  2. dragging a file onto a device avatar sends it;
  3. clicking a history item copies it again;
  4. the "同步剪贴板" switch stops sending;
  5. pairing and file-request cards show up in the panel.
- ✅ The user checked the panel by hand; it renders as designed.

### Round 2 (compiled on the Mac; not checked by hand)

- **Panel polish:**
  - Android devices get a modern phone icon (`smartphone`, falls back to `iphone` before macOS 14) instead of the keypad phone;
  - panel copy uses full-width punctuation.
- **New 设备与设置 window** (`SettingsView.swift`): native grouped `Form`; see the spec. The old `SignalFoundryView.swift` and `DashboardView.swift` are deleted, along with the "切换到旧版界面" menu item.
- **Shared code:**
  - shared helpers moved to `SharedUI.swift` (macOS only) and `PanelStyle.swift` (macOS + iOS, added to `ios/project.yml`);
  - renames: `SignalDeviceRow` → `DeviceRow`, `signalFPText` → `shortFPText`.
- **Background reading:** the settings window flips it through `@AppStorage`; `AppDelegate` now watches `UserDefaults` and `updateNapActivity()` became idempotent.
- **iOS redesigned** (`ios/ProtoSync/App.swift`, model additions in `Model.swift`): see the spec.
  - "发送剪贴板" now also sends images.
- ✅ **Verified on the Mac (no fixes needed):** `swift build`, `swift run protosync-tests` 45/45, `./scripts/make-app.sh`, `xcodegen generate` + iOS simulator build (unsigned).
- ⚠️ **Still to do by hand:** check the settings window and the iOS screen (agent can't click or run the UI).
- **Then:** Android migration to the same design.

### Round 3 (cloud, not compiled yet): settings window polish from the user's screenshots

- **Paired-device rows:** the "自动接收" caption and switch now sit as one trailing column; removal moved into a "⋯" menu per row plus a right-click menu (still confirmed).
- **Fingerprint:** shows the short 8-character form, with "复制完整指纹"; the full value is in the hover tooltip.
- **Address:** uses monospaced digits at body size.
- **Section footers:** small, secondary colour, left-aligned (they rendered right-aligned at body size).
- **iOS:** the gear button no longer picks up the Lime tint.
- **Next on the Mac:** run `swift build`, `swift run protosync-tests` and `./scripts/make-app.sh`, rebuild iOS, then take a quick look at the settings window.

 (merged into `main`)

- Moved `ProtoSyncUIDemo/` and `android-compose-scaffold/` into `tools/`; moved `design/` into `docs/design/`.
- Updated every reference: `Package.swift`, `.gitignore`, both icon/logo scripts, README, CLAUDE.md, design doc, scaffold README.
- Removed the duplicate `ios/ProtoSync/SignalTheme.swift`; `ios/project.yml` now compiles `Sources/ProtoSyncApp/SignalTheme.swift` directly. The demo keeps its own theme copy on purpose (it's the design sandbox).
- ✅ Verified on the Mac: `swift build`, `swift run protosync-tests` (45/45), `swift build --target ProtoSyncUIDemo`, iOS simulator build (xcodegen + xcodebuild, unsigned).
- ⚠️ Not run: `./scripts/make-app.sh`, `./scripts/make-demo-app.sh`, the icon/logo scripts after the path change, the Android build (Android sources were not touched).
- Not done: deleting `android/legacy-backup/` and `DashboardView.swift`, cleaning untracked `.app` / `.bak` files.
- Merged together with the v2 hardening work (fast-forward); `main` now contains both.

## Active branch

`main`. The v2 hardening branch (`claude/affectionate-shannon-ry7gf9`) and `chore/reorganize-folders` are both merged; start new work on a new branch.

## Done on this branch

- **Protocol v2 handshake hardening** (Swift and Java):
  - device names are bound into the transcript;
  - auth signatures carry a role label;
  - `hello` carries a version, and a mismatch returns a readable error.
- **Per-device "auto-receive files" setting:**
  - applies on macOS (both UIs), iOS and Android;
  - untrusted senders get a `pending` ack, and the receiver shows accept once / always / decline;
  - an unanswered prompt auto-declines after 120 s or when the sender disconnects.
- **macOS clipboard monitor** skips content that password managers mark as concealed or transient.
- **Clipboard hash** is recomputed on receipt; mismatches are dropped.
- **Bug fix:** the Swift receiver now re-acks the sender's own retried offer instead of rejecting it.
- `CLAUDE.md` and this file were added.

## Verified vs unverified

- ✅ **Android:** the whole app compiles against Android 14 framework classes. A JVM harness passed 25/25, covering a real v2 handshake over loopback, the version-mismatch error and the whole file-approval flow.
- ✅ **Swift/Java wire match:** the Java transcript and signatures match an independent reimplementation of the Swift layout.
- ✅ **Swift (macOS + iOS):** compiled and tested on the Mac after merge (45/45, see above).

## Next steps (local Mac session)

1. Pull the branch, then run `swift build` and `swift run protosync-tests`. Fix anything that fails.
2. Build the iOS app (`cd ios && xcodegen generate`, then a simulator build).
3. Build the Android APK with `./android/build_apk.sh`.
4. Update **all** devices together, since v2 can't talk to v1. Test pairing, then check each of these:
   - a file sent from a device with auto-receive off shows the prompt;
   - "always" turns auto-receive on for that device;
   - copying a password from a password manager on the Mac does not sync.
5. Real-device checks from step 4 are still pending (merge happened after the Mac build and tests, not after device testing).

## Backlog (ideas, not started)

- 6-digit SAS pairing code derived from the transcript (on the README roadmap)
- Store identity keys in Keychain / Android Keystore instead of plain files
- Resume interrupted file transfers
- Binary chunk frames (base64-in-JSON costs about 33%); needs a protocol version bump
- Multi-file / folder transfer
- Clipboard history panel
- iOS Share Extension, plus an Android share target / Quick Settings tile
- Pause sync / per-app exclusions on macOS
- CI (GitHub Actions: `swift build` + tests on macOS, plus the Android build)
- Shared Swift/Java protocol test vectors checked in, so both test suites verify compatibility
- Cleanup:
  - delete `android/legacy-backup/`
  - decide the long-term fate of `tools/android-compose-scaffold/`
- Android clipboard images, Windows client, HarmonyOS NEXT client, Bluetooth discovery (roadmap)
