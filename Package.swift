// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "ClaudeMonitor", targets: ["ClaudeMonitor"])
    ],
    targets: [
        .target(
            name: "CStorageScanner",
            path: "Sources/CStorageScanner",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ClaudeMonitor",
            dependencies: ["CStorageScanner"],
            path: "Sources/ClaudeMonitor",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
