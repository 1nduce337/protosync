#!/bin/bash
# 组装 ProtoSync.app(无需完整版 Xcode,SwiftPM 编译 + 手工 bundle)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="ProtoSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ProtoSyncApp" "$APP/Contents/MacOS/ProtoSync"

# SwiftPM 资源 bundle(logo 等):ProtoSync_PrototoSyncApp.bundle → Contents/Resources
for b in "$BIN"/*_ProtoSyncApp.bundle; do
    [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>ProtoSync</string>
    <key>CFBundleIdentifier</key>            <string>local.protosync.app</string>
    <key>CFBundleName</key>                  <string>ProtoSync</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSLocalNetworkUsageDescription</key>
        <string>ProtoSync 需要访问本地网络以发现并连接你的其他设备,同步剪贴板与文件。</string>
    <key>NSBonjourServices</key>
        <array>
            <string>_protosync._tcp</string>
        </array>
</dict>
</plist>
PLIST

# 清除 FinderInfo/扩展属性,否则 codesign --verify --strict 会报 resource fork 错误
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
echo "✅ 已生成 $APP(双击运行,菜单栏出现图标)"
