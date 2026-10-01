# ProtoSync — notes for Claude Code

Local-first, end-to-end encrypted clipboard and file sync between macOS, iOS and Android over the LAN.
No server: devices discover each other with Bonjour/mDNS and talk over a custom encrypted TCP protocol.

This file is committed and read by every Claude Code session (local and cloud). **Keep it free of
private data** — see "Privacy" below.

## Start and end of every session

- **Start:** read `docs/HANDOFF.md` for current status, the active branch and next steps. Pull that branch first.
- **End:** update `docs/HANDOFF.md` (done / in progress / unverified / next), then commit and push.
- When editing `docs/HANDOFF.md`, keep every existing heading: insert new sections *before* the next heading instead of replacing it, then compare the heading list before and after (`grep '^#' docs/HANDOFF.md`).
- Only one agent works on a given branch at a time. If a branch is mid-task in another session, use a new branch.

## Layout

| Path | What |
|---|---|
| `Sources/Core/` | Swift protocol stack, platform-independent (used by macOS and iOS) |
| `Sources/ProtoSyncApp/` | macOS menu-bar app (SwiftUI). `MenuBarPanel` = the popover (main UI); `SettingsView` = the 设备与设置 window; `PanelStyle` = shared tokens (also compiled by iOS) |
| `Sources/protosync-peer/` | CLI test peer |
| `Sources/protosync-tests/` | Test runner (plain executable — no XCTest in a Command Line Tools setup) |
| `ios/` | iOS app (xcodegen project + SwiftUI), reuses `Core` |
| `android/src/com/protosync/core/` | Java protocol stack — a second, independent implementation of the same wire protocol |
| `android/src/com/protosync/app/` | Android UI and foreground service (plain Java, no Gradle) |
| `tools/ProtoSyncUIDemo/` | UI sandbox with mock data (SwiftPM target; build with `scripts/make-demo-app.sh`). Has its own theme copy on purpose |
| `tools/android-compose-scaffold/` | Toolchain smoke test for a future Compose migration; not part of the real build |
| `docs/design/` | Design specs (`MENUBAR_PANEL.md` is current; Signal Foundry is legacy) and logo assets |

## Build and test

```bash
# macOS (SwiftPM, Command Line Tools are enough)
swift build
swift run protosync-tests        # must end with all tests passing
./scripts/make-app.sh            # builds ProtoSync.app

# iOS (xcodegen + Xcode 15+)
cd ios && xcodegen generate && open ProtoSync.xcodeproj

# Android (no Gradle: javac + d8 + aapt2 + apksigner; needs JAVA_HOME and ANDROID_HOME with build-tools 35)
./android/build_apk.sh
adb install -r android/build/ProtoSync-android.apk
```

## Protocol rules (most important)

Swift (`Sources/Core`) and Java (`android/src/com/protosync/core`) implement the **same wire protocol byte for byte**.

- **Any wire change must be made on both sides in the same branch.** That covers message fields, handshake, key derivation, framing and ack semantics.
- A change that breaks compatibility must bump `ProtocolVersion.current` (Swift) **and** `Protocol.VERSION` (Java). The version travels in `hello`; a mismatch closes the connection with a readable `error` frame.
- Current version: **v2**. Handshake transcript = `SHA256("ProtoSync-v2" ‖ initSign ‖ initDh ‖ initEph ‖ len32(initName) ‖ initName ‖ respSign ‖ respDh ‖ respEph ‖ len32(respName) ‖ respName)`. Auth signature covers `"protosync-auth-initiator"|"protosync-auth-responder" ‖ transcript`. See `SecureChannel.swift` and `Crypto.java`.
- Constants that must match on both sides:

| Constant | Value |
|---|---|
| Max frame | 64 MB |
| Chunk size | 192 KB |
| Window | 16 chunks |
| Max file size | 4 GiB |
| File offer decision timeout | 120 s |

- Listen ports: macOS/iOS use 52525; Android uses 52526. Both fall back to a random port.
- File ack states:
  - `accept:true, done:false`: go / next window
  - `done:true`: final result
  - `accept:false, done:true`: rejected
  - `pending:true`: the receiver is asking the user; the sender stops re-offering and waits
- **Everything from the wire is untrusted.** Validate through `FileTransferGuard` (Swift) / `Transfers.isValid*` (Java). Temp files use local UUIDs, never remote names. The receiver recomputes clipboard hashes and drops mismatches.
- Clipboard hash = SHA-256 of the UTF-8 text, or of the PNG bytes.

## Behaviour worth knowing

- Pairing = TOFU plus a 6-digit pairing code (SAS) that both screens show. It is derived from the handshake transcript: `SHA256("ProtoSync-SAS" ‖ transcript)`, first 4 bytes big-endian, mod 1,000,000. It is computed locally, never sent, and must match between `SecureChannel.sas` and `Crypto.sas`.
- The device where the user tapped 配对 auto-accepts that one handshake; only the other side asks. The initiator persists the pairing only once the connection is established, so a rejected request leaves no one-sided pairing. Paired devices reconnect automatically.
- Per-device `trustFiles` flag (default on). When off, incoming files prompt the user (accept once / always / decline).
- The macOS clipboard monitor skips content marked `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` (password managers).
- iOS and Android can only *send* the clipboard manually (OS limits); receiving is automatic.

## Environment notes

- **Cloud sessions** have no Swift toolchain, Xcode or Android SDK. Swift changes made in the cloud are unverified until `swift build && swift run protosync-tests` runs on the Mac. Say so in `docs/HANDOFF.md`.
- In the cloud, Android code can still be compiled against Robolectric's `org.robolectric:android-all` jar from Maven Central (dl.google.com is blocked). Stub `R.java` from the `R.<type>.<name>` references.
- **The local Mac session** owns anything that needs Swift, Xcode, a simulator, real devices or `adb`.

## Conventions

- Code comments and UI strings are in Chinese. Match the surrounding style and comment density.
- UI follows the panel design (`docs/design/MENUBAR_PANEL.md`):
  - one Lime accent;
  - fills instead of outlines;
  - system font;
  - Chinese-only copy with full-width punctuation;
  - no console-style English tags.
- The macOS settings window uses native `Form` controls instead, and no Lime.
- Android follows the same panel design: tokens and builders live in `android/src/com/protosync/app/PanelUi.java` (the Java mirror of `PanelStyle.swift`); keep the two in sync.
- `Sources/ProtoSyncApp/PanelStyle.swift` and `SignalTheme.swift` are shared by macOS **and** iOS (`ios/project.yml` compiles them directly). Don't copy them into `ios/`.
- Android stays plain Java with no Gradle (Java 8 source level).

## Privacy

`docs/dev/` is gitignored and holds private local notes. Never copy anything from it into committed files, and never commit any of the following:

- device UDIDs or serial numbers
- email addresses or Apple ID
- Apple Developer Team ID or signing identities
- LAN / public IP addresses or MAC addresses
- real device fingerprints
- personal device names
- API keys, keystores or provisioning profiles

Use placeholders (`<UDID>`, `<TEAM_ID>`, `192.168.x.x`) in docs.
