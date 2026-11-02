// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Parley",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ParleyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Parley",
            dependencies: ["ParleyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParleyCoreTests",
            dependencies: ["ParleyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
