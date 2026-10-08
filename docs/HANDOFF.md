# Handoff

Shared status between Claude Code sessions (local Mac and cloud). Update before ending a session.
No private data here — see "Privacy" in `CLAUDE.md`.

_Last updated: 2026-10-08 (cloud session, `feat/send-window`)_

## In progress: send window + panel pinning (branch `feat/send-window`, cloud; Swift unverified)

- **Bug (user):** opening the menu-bar panel, then clicking a file in Finder to drag it, closed the panel (`NSPopover.behavior = .transient` closes on any outside click).
- **Fixes:**
  - **Pin button** in the panel header (`AppModel.panelPinned`): while on, `popover.behavior = .applicationDefined`, so it stays open. `popoverDidClose` resets it.
  - **Drag a file onto the menu-bar icon → the panel opens.** The status-bar button's window registers `.fileURL`, and `AppDelegate` (the window's delegate, `NSDraggingDestination`) shows the popover in `draggingEntered`. ⚠️ Relies on NSWindow forwarding drag messages to its delegate; if it doesn't fire, the pin button still covers the bug.
- **New "发送文件" window** (`Sources/ProtoSyncApp/SendWindow.swift`): one big drop tile per device (many files at once, click for a multi-select picker), request cards, and the last 30 file transfers. Opened from the gear menu, the panel footer ("发送窗口") and the right-click menu. Frame is autosaved.
- `AppModel.sendFile(to:)` now allows multiple selection. New `sendFiles(_:to:)` (skips folders) is shared by the panel avatars and the window tiles. Files are sent concurrently by the engine, as panel drops already were.
- ⚠️ **Unverified:** `swift build`, then by hand:
  1. pin the panel, click a file in Finder: the panel stays; unpinned, it closes as before;
  2. drag a file onto the menu-bar icon: the panel opens; drop it on an avatar;
  3. 发送文件 window: drop 3 files on a device tile; all three show in 传输 and arrive.

## Release 0.0.1 (now on `main`)

- `feat/menubar-popover-ui` (Rounds 2–11) and `chore/cleanup` are merged into `main`. The user chose to skip most of the manual checks.
- ✅ **Round 11 Swift changes compile.** `scripts/package-release.sh 0.0.1` ran on `main` (7df2201) with no fixes needed: tests 54/54, macOS and Android builds OK. Output in `dist/` (gitignored): `ProtoSync-0.0.1-macOS.zip`, `ProtoSync-0.0.1-android.apk`, `ProtoSync-0.0.1-SHA256.txt`.
- ✅ **Tag `v0.0.1` created and pushed** (points at 7df2201).
- ✅ **GitHub pre-release published:** https://github.com/1nduce337/protosync/releases/tag/v0.0.1 ("ProtoSync 0.0.1", pre-release, body from `docs/releases/v0.0.1.md`, the three `dist/` files attached; checksums matched before upload).
- ⚠️ The release build was not installed or tested on real devices.
- **Release steps (all done):**
  1. `git switch main && git pull`.
  2. `scripts/package-release.sh 0.0.1` → `dist/ProtoSync-0.0.1-macOS.zip`, `-android.apk`, `-SHA256.txt`.
  3. `git tag v0.0.1 && git push origin v0.0.1`.
  4. Publish the GitHub pre-release "ProtoSync 0.0.1" from that tag, with `docs/releases/v0.0.1.md` as the body and the three `dist/` files attached: `gh release create v0.0.1 --prerelease --title "ProtoSync 0.0.1" --notes-file docs/releases/v0.0.1.md dist/ProtoSync-0.0.1-*`, or the web UI.

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

### Round 8 (blocked on the Mac: screenshots missing, no gh): README rewrite and the 0.0.1 release prep (macOS + Android)

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
- 🛑 **Blocked on the Mac (nothing merged, packaged, tagged or released):**
  - `docs/img/` holds only the old `ios-simulator.png`; the four README screenshots (`macos-panel.png`, `macos-settings.png`, `android-main.png`, `pairing.png`) are not in the repo or in Desktop/Downloads, so there was nothing to privacy-check;
  - `gh` is not installed on this Mac, so the pre-release cannot be created from the command line (install it and run `gh auth login`, or create the release in the GitHub web UI).
- **Next on the Mac:**
  1. Add the four screenshots. Before committing them, crop or blur IP addresses and personal device names (see "Privacy" in `CLAUDE.md`).
  2. Merge `feat/menubar-popover-ui` into `main`.
  3. On `main`, run `scripts/package-release.sh 0.0.1`.
  4. Tag `v0.0.1` and push the tag.
  5. Create the GitHub release "ProtoSync 0.0.1" from that tag, with `docs/releases/v0.0.1.md` as the body, attaching `dist/ProtoSync-0.0.1-macOS.zip`, `dist/ProtoSync-0.0.1-android.apk` and `dist/ProtoSync-0.0.1-SHA256.txt`. Mark it as a pre-release.

### Round 9 (cloud): README screenshots, plus an Android spinner fix

- **The four README screenshots are in `docs/img/`:** `macos-panel.png`, `macos-settings.png`, `android-main.png`, `pairing.png` (a Mac + Android side-by-side with the same pairing code).
  - The user okayed the temporary device name and the home LAN IP shown in them.
  - Device fingerprints were blurred in the Mac settings screenshots (header, paired row, nearby row).
- **Android fix:** the spinner on the "正在与「X」配对" card rendered as a dot (default large style squeezed to 18 dp). It now uses `progressBarStyleSmall`. Compiles in the cloud.
- **Next on the Mac (the release):**
  1. Merge `feat/menubar-popover-ui` into `main`.
  2. On `main`, run `scripts/package-release.sh 0.0.1`.
  3. Tag `v0.0.1` and push the tag.
  4. Create the GitHub pre-release "ProtoSync 0.0.1" with `docs/releases/v0.0.1.md` as the body and the three `dist/` files attached.
  5. If `gh` isn't set up, the user creates the release on github.com (Releases → Draft a new release) and uploads the files from `dist/`.

### Round 11 (cloud; Android compiles + harness 34/34, Swift unverified): removing a device now removes it on both sides; notification icon

- **Bug (from device testing):** removing the Mac on Android left the Mac still "paired". The Mac kept auto-reconnecting, and Android showed a new pairing request every time.
- **Fix (Swift and Java, same branch; no version bump, older v2 peers ignore both additions):**
  - new sealed message `unpair`. `removePairedDevice` / `removePaired` send it to the online peer, then close. The receiver removes the pairing, disconnects and tells the UI ("「X」移除了与这台 Mac 的配对" / an Android toast).
  - new `hello.paired: true` (initiator only, on auto-reconnect to a stored pairing). A responder that no longer has the pairing does not prompt: it completes the handshake, sends `unpair` and closes (`unpairOnEstablish`). This covers the case where the peer was offline when it was removed.
  - `paired` is outside the transcript and unauthenticated. A forged flag can only suppress a pairing prompt; removal requires the sealed `unpair`.
  - Messages are now processed only from registered connections (Swift `handleMessage`, Java `handleEstablished`), so the short-lived `unpair` connection can't deliver clipboard data. Java also ignores a link after `retire()`.
  - Java sends `unpair`, half-closes the socket (`shutdownOutput`), then closes 1.5 s later, so the frame isn't lost to an RST. Swift closes once `nw.send` has handed the frame off.
  - New delegate/listener callbacks: Swift `peerUnpaired` (macOS + iOS implement it), Java `onPeerUnpaired` (SyncService → MainActivity).
- **Tests:** JVM harness +7 (paired flag over the wire, unpair after half-close, EOF closes the peer): 34/34. `protosync-tests` gained a "重连标记与 unpair" block (not run: cloud has no Swift).
- ✅ The user's screenshot shows the Round 10 "收到「X」的剪贴板" banner appearing on the Mac, so receive notifications work. The app icon in the banner was blank.
- **Notification icon was blank:** the iconset is fine. Notification Center caches the icon from when the app was first registered, which was before it had one. `make-app.sh` now runs `lsregister -f` on the built app. The Mac also needs a one-time cache reset (see the next steps).
- **Next on the Mac:**
  1. `swift build && swift run protosync-tests`, `./scripts/make-app.sh`, `./android/build_apk.sh`, install on the phone.
  2. Notification icon: quit ProtoSync, move `ProtoSync.app` to `/Applications` and open it from there, then run `killall usernoted NotificationCenter` (both restart by themselves). If the icon is still blank, remove ProtoSync from System Settings › Notifications and launch it again.
  3. Device test: pair, then remove on Android → the Mac drops it within a second, with no new pairing request. Then the reverse. Then remove on one side while the other is offline/quit → when it comes back, it drops the pairing with no prompt.
  4. Then the Round 10 checks, then the release (Round 9 steps).

### Round 10 (builds on the Mac; notifications and icon not checked by hand): macOS notifications fixed, "received" indicator in the menu bar

The user reported: the "同步时发送通知" switch is on but nothing appears; and receiving a clipboard from another device shows nothing in the menu bar. **The release is on hold until this is checked.**
- **Why notifications never showed:**
  - there was no `UNUserNotificationCenterDelegate`, so macOS silently dropped every notification while ProtoSync was the active app (always the case right after clicking the panel);
  - `add()` errors were ignored, so a denied permission failed silently;
  - the switch only covered *sending* the clipboard, never receiving.
- **Fix:** new `Sources/ProtoSyncApp/Notifier.swift` (one entry point):
  - sets the delegate, and `willPresent` returns `.banner, .list`;
  - logs authorization and `add()` errors via `PLog`;
  - skips everything when there is no bundle (`swift run`), since `UNUserNotificationCenter.current()` crashes there.
  - All existing notifications (pairing request, file request) now go through it.
- **The switch now covers:** clipboard sent, clipboard received, file received. Renamed to "同步时发送通知" in the settings window and the right-click menu (same `UserDefaults` key `syncSuccessNotification`).
- **Settings window:** when the switch is on but macOS blocks notifications, a row "系统设置里关闭了 ProtoSync 的通知" with an "打开通知设置" button appears. It re-checks when the app becomes active again. The right-click menu opens System Settings directly in that case.
- **Menu-bar indicator** (`main.swift`, `showPulse`):
  - *sent* (this Mac's copy synced): `arrow.up.circle.fill`, template (follows the menu-bar colour), 1.5 s. Replaces the old checkmark, which forced `darkAqua` and was white on a light menu bar;
  - *received* (clipboard or file from another device): `arrow.down.circle.fill` in palette colours, ink arrow on a Lime circle, visible on light and dark menu bars, 3 s; the tooltip names the sender (e.g. "已收到「X」的剪贴板").
  - `AppModel.onReceived` is the hook, called from the clipboard-received and file-saved callbacks.
- ✅ **Built on the Mac (no fixes needed):** `swift build`, `swift run protosync-tests` 48/48, `./scripts/make-app.sh`; the new ProtoSync.app was relaunched.
- ⚠️ **Not checked by hand yet** (the agent can't see banners or the menu bar):
  1. with the switch on, copying on the Mac shows a banner even while the panel is open;
  2. receiving a clipboard from the phone shows a banner and the Lime ↓ icon for 3 s;
  3. if the palette colours come out reversed (Lime arrow on a dark circle), swap `[ink, lime]` in `receivedImage`;
  4. turning notifications off for ProtoSync in System Settings makes the hint row appear.
- Note: the permission prompt is shown once by macOS. If the user dismissed it earlier, ProtoSync is listed in System Settings › Notifications and has to be enabled there (the new hint row links to it).
- **Next on the Mac:** build and check the above, then do the release steps from Round 9 (run `scripts/package-release.sh 0.0.1` again so the zip includes this fix).

## Cleanup (branch `chore/cleanup`, merged into `main`)

Branched from `main`; `feat/menubar-popover-ui` was not touched. Three separate commits. After each step: `swift build`, `swift run protosync-tests` (45/45 on this branch) and `./android/build_apk.sh` all passed.
- **Step 1:** the user backed up the Android debug keystore outside the repo before anything was deleted (it is gitignored and has no other copy).
- **Step 2:** removed `android/legacy-backup/` (3 old Java files, unreferenced by code). Also deleted ignored leftovers: the legacy-UI backup `.app`, the demo `.app.bak`, and the `*.bak-*` files under `ios/`. Kept the current `ProtoSync.app` / `ProtoSyncUIDemo.app` builds and the scaffold's build directories.
- **Step 2, skipped on purpose:** `DashboardView.swift` is still referenced on `main` (`main.swift` has the legacy-UI switch), so deleting it would change behaviour. The `feat/menubar-popover-ui` branch already removes it together with the switch; it goes away when that branch merges.
- **Step 3:** a clean build had two warnings, both fixed with no behaviour change: an explicit `[self]` capture in `SyncEngine.requestOfferDecision`, and `else if url != nil` in `AppModel`. A clean build now prints none.
- ⚠️ Not run: `./scripts/make-app.sh`, the iOS build (neither the iOS sources nor the app bundle script were changed).
- Merge note: `feat/menubar-popover-ui` rewrites `AppModel.swift`, so the one-line `url != nil` change may conflict there; keep whichever side compiles.

## Folder reorganisation (merged into `main`)

- Moved `ProtoSyncUIDemo/` and `android-compose-scaffold/` into `tools/`; moved `design/` into `docs/design/`.
- Updated every reference: `Package.swift`, `.gitignore`, both icon/logo scripts, README, CLAUDE.md, design doc, scaffold README.
- Removed the duplicate `ios/ProtoSync/SignalTheme.swift`; `ios/project.yml` now compiles `Sources/ProtoSyncApp/SignalTheme.swift` directly. The demo keeps its own theme copy on purpose (it's the design sandbox).
- ✅ Verified on the Mac: `swift build`, `swift run protosync-tests` (45/45), `swift build --target ProtoSyncUIDemo`, iOS simulator build (xcodegen + xcodebuild, unsigned).
- ⚠️ Not run: `./scripts/make-app.sh`, `./scripts/make-demo-app.sh`, the icon/logo scripts after the path change, the Android build (Android sources were not touched).
- Not done: deleting `android/legacy-backup/` and `DashboardView.swift`, cleaning untracked `.app` / `.bak` files.
- Merged together with the v2 hardening work (fast-forward); `main` now contains both.

## Active branch

`main`. Everything is merged: the v2 hardening branch, `chore/reorganize-folders`, `feat/menubar-popover-ui` and `chore/cleanup`. Start new work on a new branch.

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
