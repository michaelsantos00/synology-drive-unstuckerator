// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DriveMonitorCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DriveMonitorCore", targets: ["DriveMonitorCore"]),
        .library(name: "DriveMonitorUI", targets: ["DriveMonitorUI"]),
        .executable(name: "Unstuckerator", targets: ["Unstuckerator"])
    ],
    targets: [
        .target(
            name: "DriveMonitorCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "DriveMonitorUI",
            dependencies: ["DriveMonitorCore"],
            path: "App",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Unstuckerator",
            dependencies: ["DriveMonitorUI"],
            path: "AppLauncher",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DriveMonitorCoreTests",
            dependencies: ["DriveMonitorCore"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
