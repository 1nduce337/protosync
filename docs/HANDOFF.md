# Handoff

Shared status between Claude Code sessions (local Mac and cloud). Update before ending a session.
No private data here — see "Privacy" in `CLAUDE.md`.

_Last updated: 2026-10-01 (local Mac session)_

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
- ⚠️ **Swift (macOS + iOS) has not been compiled or run yet.** The cloud has no Swift toolchain.

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
