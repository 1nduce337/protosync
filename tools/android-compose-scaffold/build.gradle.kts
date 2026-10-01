plugins {
    // AGP 8.13 依赖的 Gradle 内部 API 在 Gradle 9.6 被移除,本机 Gradle 9.7.1 必须配 AGP 9.x
    // AGP 9 内置 Kotlin 支持(不再需要 org.jetbrains.kotlin.android);
    // Compose 编译器插件仍由 org.jetbrains.kotlin.plugin.compose 提供
    id("com.android.application") version "9.0.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.0" apply false
}
