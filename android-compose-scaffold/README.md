# ProtoSync Compose Scaffold(工具链冒烟工程)

用途:证明本机可以构建 Jetpack Compose 工程,供将来 Android 端迁移 UI 时使用。
不参与 `android/build_apk.sh` 的纯 Java 构建链。

## 可用的版本组合(2026-09-22 实测通过)

| 组件 | 版本 | 说明 |
|---|---|---|
| Gradle | 9.7.1(brew) | 本机系统 Gradle |
| AGP | **9.0.0** | AGP 8.13 依赖的 Gradle 内部 API 在 Gradle 9.6 被移除,必须用 AGP 9.x |
| Kotlin | AGP 9 **内置 Kotlin** | 不再需要 `org.jetbrains.kotlin.android` 插件(加了会报错) |
| Compose 插件 | org.jetbrains.kotlin.plugin.compose **2.3.0** | Compose 编译器仍需单独声明 |
| JDK | 17(`/opt/homebrew/opt/openjdk@17`) | 在 `gradle.properties` 里 `org.gradle.java.home` 固定 |
| SDK | compileSdk/targetSdk 34,minSdk 28 | `$ANDROID_HOME=/opt/homebrew/share/android-commandlinetools` |

## 构建

```bash
cd android-compose-scaffold
gradle :app:assembleDebug --no-daemon
# → app/build/outputs/apk/debug/app-debug.apk
```

## 已知坑

- `services.gradle.org` 在本机网络不通,Gradle wrapper 无法下载其他版本 → 直接用系统 Gradle + AGP 9 组合,不要走 wrapper。
- AGP 9 报「'org.jetbrains.kotlin.android' plugin is no longer required」就是还没删该插件。
- 迁移真实 UI 时:把 ProtoSync 的 Signal Foundry token(colorPalette)做成 Compose MaterialTheme,
  协议层 `com.protosync.core` 零改动可直接复用(它只依赖 android.* 平台 API,不含任何 View)。
