// 顶层构建脚本。
//
// 版本选择说明（不是随手写的）：
//   · AGP 8.1.4 + Gradle 8.7 + JDK 17 —— 这三个版本经实测解析成功
//     （`gradle dependencies --configuration compileClasspath` → BUILD SUCCESSFUL）。
//   · Kotlin 用 1.9.22：Gradle 8.7 内置的 Kotlin 就是 1.9.22，且本地
//     GRADLE_USER_HOME 缓存里已有 1.9.24 全套，两者都在可用范围内，取 1.9.22 与
//     Gradle 自带版本一致，避免多拉一份编译器。
//   · compileSdk 34：本机 SDK 只装了 android-34 与 build-tools 34.0.0，别无选择。
plugins {
    id("com.android.application") version "8.1.4" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
}