#!/bin/bash
# 无 Gradle 构建 ProtoSync Android APK:javac + d8 + aapt2 + zipalign + apksigner
set -euo pipefail
cd "$(dirname "$0")"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
BT="$ANDROID_HOME/build-tools/35.0.0"
PLATFORM="$ANDROID_HOME/platforms/android-34/android.jar"

BUILD="build"
rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$BUILD/dex" "$BUILD/gen"

echo "[1/7] aapt2 compile(res → res.zip)"
if [ -d res ]; then
    "$BT/aapt2" compile --dir res -o "$BUILD/res.zip"
    RES_ARGS=(-R "$BUILD/res.zip" --auto-add-overlay)
else
    RES_ARGS=()
fi

echo "[2/7] aapt2 link(资源+清单 → 基础 APK + R.java)"
"$BT/aapt2" link -o "$BUILD/base.apk" -I "$PLATFORM" \
    --manifest AndroidManifest.xml --java "$BUILD/gen" --min-sdk-version 28 --target-sdk-version 34 \
    "${RES_ARGS[@]}"

echo "[3/7] javac"
"$JAVA_HOME/bin/javac" -source 8 -target 8 -nowarn -classpath "$PLATFORM" \
    -d "$BUILD/classes" $(find src "$BUILD/gen" -name "*.java")

echo "[4/7] d8(转 dex)"
"$JAVA_HOME/bin/jar" cf "$BUILD/classes.jar" -C "$BUILD/classes" .
"$BT/d8" --release --lib "$PLATFORM" --output "$BUILD/dex" "$BUILD/classes.jar"

echo "[5/7] 打包 dex 进 APK"
cd "$BUILD/dex" && zip -q -j ../base.apk classes.dex && cd ../..

echo "[6/7] zipalign"
"$BT/zipalign" -f 4 "$BUILD/base.apk" "$BUILD/aligned.apk"

echo "[7/7] 签名"
# keystore 必须持久化,否则每次构建签名变化导致手机无法覆盖安装
KEYSTORE="$PWD/debug.keystore"  # 脚本已 cd 到 android/
if [ ! -f "$KEYSTORE" ]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEYSTORE" -alias protosync \
        -storepass protosync -keypass protosync -dname "CN=ProtoSync Debug" \
        -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:protosync \
    --out "$BUILD/ProtoSync-android.apk" "$BUILD/aligned.apk"

"$BT/apksigner" verify "$BUILD/ProtoSync-android.apk" && echo "✅ $BUILD/ProtoSync-android.apk"
