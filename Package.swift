// swift-tools-version:5.10
import PackageDescription

// 注:本机只有 Command Line Tools(无完整 Xcode),XCTest 不可用,
// 因此测试以独立可执行 runner 的形式放在 protosync-tests,`swift run protosync-tests` 运行。
let package = Package(
    name: "ProtoSync",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // 供 iOS 工程等外部引用协议与传输层
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        .target(name: "Core"),
        .executableTarget(
            name: "ProtoSyncApp",
            dependencies: ["Core"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "protosync-peer",
            dependencies: ["Core"]
        ),
        .executableTarget(
            name: "protosync-tests",
            dependencies: ["Core"]
        ),
        // UI 设计沙盒:纯模拟数据,无传输层;验证过的设计再移植回 ProtoSyncApp
        .executableTarget(
            name: "ProtoSyncUIDemo",
            path: "ProtoSyncUIDemo",
            resources: [.copy("Resources")]
        ),
    ]
)
