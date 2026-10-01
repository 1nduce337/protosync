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

### Round 3 (compiled on the Mac; not checked by hand): settings window polish from the user's screenshots

- **Paired-device rows:** the "自动接收" caption and switch now sit as one trailing column; removal moved into a "⋯" menu per row plus a right-click menu (still confirmed).
- **Fingerprint:** shows the short 8-character form, with "复制完整指纹"; the full value is in the hover tooltip.
- **Address:** uses monospaced digits at body size.
- **Section footers:** small, secondary colour, left-aligned (they rendered right-aligned at body size).
- **iOS:** the gear button no longer picks up the Lime tint.
- ✅ **Verified on the Mac (no fixes needed):** `swift build`, `swift run protosync-tests` 45/45, `./scripts/make-app.sh`, `xcodegen generate` + iOS simulator build (unsigned).
- ⚠️ **Still to do by hand:** take a quick look at the settings window.

### Round 4 (compiled on the Mac; not checked by hand): settings window in the panel style

The user found the native `Form` too bland, so `SettingsView.swift` was rewritten in the panel's language:
- dark window (`darkAqua` in `main.swift`), fill groups and avatars, Lime only for switches, online dots and 配对;
- header with this Mac's identity;
- request cards reuse `PanelPairingCard` / `PanelOfferCard`.

New small components (`SettingsSection`, `SettingsRow`, `SettingsDivider`, `PanelSmallAvatar`) live in the same file. See the spec for the full layout.

- ✅ **Verified on the Mac (no fixes needed):** `swift build`, `swift run protosync-tests` 45/45, `./scripts/make-app.sh`. iOS not rebuilt this round (no iOS files changed by the round).
- ⚠️ **Still to do by hand:** open 设备与设置 and look at it.

### Round 5 (APK builds on the Mac; not installed or checked on a device): Android in the panel style

- **Android UI rebuilt to match iOS:**
  - `MainActivity` rewritten; layout in `res/layout/activity_main.xml`;
  - new `PanelUi.java` (Java counterpart of `PanelStyle.swift`) and `SettingsDialog.java`;
  - dark single screen with 76 dp device avatars (tap to send a file, long-press for auto-receive / remove) and the "+" pairing tile;
  - inline pairing and file-request cards (the old pop-up dialogs are gone);
  - transfers with thin Lime bars, tap-to-copy clipboard history, recently received files (tap to open), and a pinned "发送剪贴板" bar.
- **Gear → full-screen settings sheet:**
  - this device (name, short fingerprint + "复制完整指纹", port);
  - paired devices with Lime auto-receive switches and remove (confirmed);
  - manual connect (moved here from the old diagnostics area);
  - the log.
- **`SyncCore`:** adds an in-memory clipboard history (last 6, received and sent) and a recent received-files list (last 5).
- **Removed:**
  - `TransferTrackView.java`;
  - the old `bg_panel` / `btn_*` drawables and `values-night/colors.xml`.
- **New resources:**
  - vector icons (`ic_phone`, `ic_tablet`, `ic_laptop`, `ic_desktop`, `ic_plus`, `ic_close`, `ic_settings`, `ic_file`);
  - a 5-colour panel palette in `values/colors.xml`.
- ✅ **Verified in the cloud:**
  - the whole Android app compiles against the Android 14 framework (Robolectric `android-all`);
  - every referenced resource exists;
  - the protocol harness (v2 handshake, version error, file-approval flow) passes 26/26 against the new build.
- ✅ **Verified on the Mac (no fixes needed):** `./android/build_apk.sh` ran all 7 steps (aapt2 compile and link, javac, d8, zipalign, apksigner) and produced `android/build/ProtoSync-android.apk`.
- ⚠️ **Not verified:**
  - `adb install`: no device was connected (`adb devices` empty);
  - how it looks and behaves on a device.
- **Next:** plug in the phone (USB debugging on), run `adb install -r android/build/ProtoSync-android.apk`, and check the main screen and settings sheet.

### Round 6 (builds on the Mac; not installed or tested on devices): pairing fixes from device testing

The user reported two bugs:
- each side showed the *other* device's fingerprint as the "code", so the two screens never matched;
- both sides asked for approval, so accepting on one side left a one-sided pairing.

**Fixes (Swift and Java):**
- **6-digit pairing code (SAS)** shown on both screens, derived from the shared transcript (`SecureChannel.sas` / `Crypto.sas`). It is local only, with no wire change. `PeerInfo.sas` carries it to the UI; on Android it travels through `SyncCore.Listener` and `SyncService.Ui` (`onPairingRequested(name, fp, sas)`).
- **The initiator auto-accepts:** tapping 配对 records an intent (2 min). That one handshake is granted without asking, and the UI shows "正在与「X」配对" with the code. Only the other side gets a request card.
- **Persistence:** the initiator saves the pairing **only when the connection is established**. If the handshake fails or is rejected, both sides are told (`pairingFailed` / `onPairingFailed`) and no one-sided entry is left.
- The receiving side is unchanged: accepting saves the pairing immediately.

**Verified in the cloud:**
- Android compiles;
- the harness passes 27/27, including both ends of a real handshake computing the same code;
- the Java code matches an independent Python version of the Swift formula on 3 random handshakes.

**Verified on the Mac (no fixes needed):** `swift build`, `swift run protosync-tests` 48/48 (3 new code tests), `./scripts/make-app.sh`, iOS simulator build (xcodegen + xcodebuild, unsigned), `./android/build_apk.sh` (all 7 steps).

**Not verified:**
- `adb install -r`: no device was connected (`adb devices` empty), so the new APK is not on the phone;
- pairing on real devices.

**Next on the Mac:**
1. Run `swift build` and `swift run protosync-tests` (3 new code tests), `./scripts/make-app.sh`, and `./android/build_apk.sh`.
2. On the devices, remove the existing pairing on **both** sides, then pair from one side. Check that:
   - both screens show the same code;
   - only the other side asks;
   - accepting makes both sides list each other;
   - rejecting leaves neither side paired.

### Round 7 (generated and built on the Mac; icon not checked by eye in Finder or the menu bar): macOS app icon and menu-bar icon from the logo

- **`scripts/make-app-icons.swift`** gains a macOS section:
  - `packaging/macos/AppIcon.iconset`: 10 PNGs, Big Sur grid (824/1024 rounded square, Carbon fill, white + Lime logo, soft shadow);
  - `Sources/ProtoSyncApp/Resources/MenuBarIcon.png` and `MenuBarIcon@2x.png`: a logo silhouette cropped to its bounds, 18 pt, used as a template image so macOS tints it for light or dark menu bars.
- **`scripts/make-app.sh`** runs `iconutil` to build `Contents/Resources/AppIcon.icns`, and `Info.plist` gains `CFBundleIconFile`.
- **`main.swift`** loads `MenuBarIcon` (1x + 2x reps, `isTemplate`) for the status item and for the reset after the ✓ flash; it falls back to the old SF Symbol if the PNGs are missing.
- The bare SwiftPM executable (`.build/.../ProtoSyncApp`) will always show the generic Unix-executable icon; only the `.app` bundle carries an icon.
- ✅ **Done on the Mac (no fixes needed):**
  - `swift scripts/make-app-icons.swift .` ran; the iOS and Android icons came out byte-identical (git showed no changes to them), so only the new files were committed: `packaging/macos/AppIcon.iconset/` and `MenuBarIcon.png` (18 px) / `MenuBarIcon@2x.png` (36 px, RGBA);
  - `swift build`, `swift run protosync-tests` 48/48, `./scripts/make-app.sh` (`Contents/Resources/AppIcon.icns` is in the bundle);
  - the 1024 px icon looks right (Carbon rounded square, white + Lime logo).
- ⚠️ **Not checked:**
  - the Finder / Dock icon and the menu-bar template icon on screen (screen capture was not permitted, so the agent could not look);
  - `killall Finder` was not run; do it (or `touch ProtoSync.app`) if Finder shows the old icon.

### Round 8 (cloud): README rewrite and the 0.0.1 release prep (macOS + Android)

- **README** rewritten for the new design:
  - download table and the macOS first-launch (Gatekeeper) note;
  - quick start with the 6-digit pairing flow;
  - updated feature table, security model, build/release commands and roadmap.
  - It references four screenshots that **don't exist yet**: `docs/img/macos-panel.png`, `docs/img/macos-settings.png`, `docs/img/android-main.png`, `docs/img/pairing.png`. The user will supply them.
- **Version 0.0.1:**
  - macOS `CFBundleShortVersionString` 0.0.1 / `CFBundleVersion` 2;
  - Android `versionName` 0.0.1 / `versionCode` **4** (it must exceed the installed 3, or the update won't install in place).
- **Release files:**
  - `CHANGELOG.md`;
  - `docs/releases/v0.0.1.md` (the GitHub release body, including install steps and caveats);
  - `scripts/package-release.sh` (checks versions, runs the tests, builds both apps, writes `dist/` with SHA-256);
  - `dist/` is gitignored.
- **CLAUDE.md** gains a "Releases" section.
- ⚠️ **Not run:** the packaging script (macOS-only tools). There is no GitHub release tool in the cloud session, so tagging and publishing happen on the Mac.
- **Next on the Mac:**
  1. Add the four screenshots. Before committing them, crop or blur IP addresses and personal device names (see "Privacy" in `CLAUDE.md`).
  2. Merge `feat/menubar-popover-ui` into `main`.
  3. On `main`, run `scripts/package-release.sh 0.0.1`.
  4. Tag `v0.0.1` and push the tag.
  5. Create the GitHub release "ProtoSync 0.0.1" from that tag, with `docs/releases/v0.0.1.md` as the body, attaching `dist/ProtoSync-0.0.1-macOS.zip`, `dist/ProtoSync-0.0.1-android.apk` and `dist/ProtoSync-0.0.1-SHA256.txt`. Mark it as a pre-release.

## Folder reorganisation (merged into `main`)

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
