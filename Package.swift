// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarMijia",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "MijiaCore", targets: ["MijiaCore"]),
        .executable(name: "MenuBarMijiaApp", targets: ["MenuBarMijiaApp"])
    ],
    targets: [
        .target(
            name: "MijiaCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MenuBarMijiaApp",
            dependencies: ["MijiaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MijiaCoreTests",
            dependencies: ["MijiaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
