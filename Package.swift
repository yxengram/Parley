// swift-tools-version:6.0
import Foundation
import PackageDescription

// Toolchain workaround: with the Command Line Tools toolchain (no Xcode), SwiftPM does not pass
// the TestingMacros plugin to the test target's emit-module job, so every `@Test`/`@Suite` fails
// with "plugin for module 'TestingMacros' not found". Point the compiler at the CLT plugin dir,
// but only when CLT is the active developer directory, so an Xcode toolchain never gets CLT's macros.
let cltRoot = "/Library/Developer/CommandLineTools"
let cltTestingPlugins = cltRoot + "/usr/lib/swift/host/plugins/testing"
let activeDeveloperDir: String? = {
    if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty { return dir }
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
}()
let usingCommandLineTools = activeDeveloperDir.map { $0.hasPrefix(cltRoot) } ?? true
var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
if usingCommandLineTools && FileManager.default.fileExists(atPath: cltTestingPlugins) {
    testSwiftSettings.append(.unsafeFlags(["-plugin-path", cltTestingPlugins]))
}

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
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "ParleyAppTests",
            dependencies: ["Parley", "ParleyCore"],
            swiftSettings: testSwiftSettings
        ),
    ]
)
