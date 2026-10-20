// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "MacMonitorCore", targets: ["MacMonitorCore"]),
        .executable(name: "MacMonitor", targets: ["MacMonitor"])
    ],
    targets: [
        .target(
            name: "MacMonitorCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "MacMonitor",
            dependencies: ["MacMonitorCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "MacMonitorCoreTests",
            dependencies: ["MacMonitorCore"]
        )
    ]
)
