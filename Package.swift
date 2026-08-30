// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "diskmap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DiskMapCore", swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .executableTarget(name: "DiskMapApp", dependencies: ["DiskMapCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "dmbench", dependencies: ["DiskMapCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DiskMapCoreTests", dependencies: ["DiskMapCore", "DiskMapApp"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
