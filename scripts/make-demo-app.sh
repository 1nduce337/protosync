#!/bin/bash
# 组装 ProtoSync UIDemo.app(UI 设计沙盒,纯模拟数据)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG" --target ProtoSyncUIDemo
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="ProtoSyncUIDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ProtoSyncUIDemo" "$APP/Contents/MacOS/ProtoSyncUIDemo"

# SwiftPM 资源 bundle(logo 等)
for b in "$BIN"/*_ProtoSyncUIDemo.bundle; do
    [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>ProtoSyncUIDemo</string>
    <key>CFBundleIdentifier</key>            <string>local.protosync.uidemo</string>
    <key>CFBundleName</key>                  <string>ProtoSync UI Demo</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHumanReadableCopyright</key>      <string>UI 设计沙盒:纯模拟数据,无真实传输</string>
</dict>
</plist>
PLIST

xattr -cr "$APP" 2>/dev/null || true
# 本目录位于 iCloud Drive 同步范围,fileproviderd 会反复给文件打 provenance 属性,
# 与 codesign 竞态 → 签名+校验重试(最多 4 次)
SIGN_OK=0
for i in 1 2 3 4; do
    xattr -cr "$APP" 2>/dev/null || true
    if codesign --force --deep -s - "$APP" 2>/dev/null \
       && codesign --verify --deep --strict "$APP" 2>/dev/null; then
        SIGN_OK=1
        break
    fi
    sleep 1
done
[ "$SIGN_OK" = "1" ] || { echo "⚠️ codesign 多次重试后仍失败(iCloud 同步竞态)"; exit 1; }
echo "✅ 已生成 $APP"
