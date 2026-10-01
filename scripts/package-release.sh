#!/bin/bash
# 打包发布产物:macOS ProtoSync.app(zip)+ Android APK → dist/,并输出 SHA-256。
# 用法:scripts/package-release.sh 0.0.1
# 前提:与 make-app.sh / build_apk.sh 相同(Command Line Tools、JAVA_HOME、ANDROID_HOME);
#       APK 用 android/debug.keystore 签名——以后每个版本都必须用同一个 keystore,否则手机无法覆盖安装。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: scripts/package-release.sh <版本号,如 0.0.1>}"

# 版本号必须与两端工程一致,避免发出去的包自报版本不对
grep -q "<string>$VERSION</string>" scripts/make-app.sh \
    || { echo "❌ scripts/make-app.sh 的 CFBundleShortVersionString 不是 $VERSION"; exit 1; }
grep -q "android:versionName=\"$VERSION\"" android/AndroidManifest.xml \
    || { echo "❌ android/AndroidManifest.xml 的 versionName 不是 $VERSION"; exit 1; }
[ -d packaging/macos/AppIcon.iconset ] \
    || { echo "❌ 缺少 packaging/macos/AppIcon.iconset(先运行 swift scripts/make-app-icons.swift .)"; exit 1; }

echo "== 测试 =="
swift run protosync-tests

echo "== macOS =="
./scripts/make-app.sh

echo "== Android =="
./android/build_apk.sh

echo "== 打包 =="
mkdir -p dist
rm -f dist/ProtoSync-"$VERSION"-*
# ditto 保留 bundle 结构与签名(zip 会破坏符号链接/扩展属性)
ditto -c -k --sequesterRsrc --keepParent ProtoSync.app "dist/ProtoSync-$VERSION-macOS.zip"
cp android/build/ProtoSync-android.apk "dist/ProtoSync-$VERSION-android.apk"
(cd dist && shasum -a 256 ProtoSync-"$VERSION"-macOS.zip ProtoSync-"$VERSION"-android.apk \
    | tee "ProtoSync-$VERSION-SHA256.txt")

echo "✅ 发布产物在 dist/:"
ls -lh dist/ProtoSync-"$VERSION"-*
