// swift-tools-version: 6.0
import PackageDescription

// Arrows point at what a target may depend on. The scan depends on nothing;
// everything else depends on the scan and, where it must, on the actions.
// `diskmap` links the scan and the reports only, which is what makes "nothing
// on the command line deletes anything" a fact about the build rather than a
// promise in the documentation.
let fast: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
]
let plain: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "diskmap",
    platforms: [.macOS(.v14)],
    targets: [
        // The tree itself: walking a disk, holding it, watching it, and the
        // questions that are answered from the index alone.
        .target(name: "DiskMapScan", swiftSettings: fast),

        // What a file says about itself once Spotlight has read it.
        .target(name: "DiskMapMeta", dependencies: ["DiskMapScan"], swiftSettings: fast),

        // Everything that changes the disk. Nothing else may.
        .target(name: "DiskMapActions", dependencies: ["DiskMapScan"], swiftSettings: fast),

        // Two folders, and what to do about the difference.
        .target(name: "DiskMapCompare",
                dependencies: ["DiskMapScan", "DiskMapActions"], swiftSettings: fast),

        // Copies, easy space, and the document another program reads.
        .target(name: "DiskMapReports", dependencies: ["DiskMapScan"], swiftSettings: fast),

        // A facade over the five, for callers that legitimately use all of them.
        .target(name: "DiskMapCore",
                dependencies: ["DiskMapScan", "DiskMapMeta", "DiskMapActions",
                               "DiskMapCompare", "DiskMapReports"],
                swiftSettings: plain),

        .executableTarget(name: "DiskMapApp", dependencies: ["DiskMapCore"], swiftSettings: plain),
        .executableTarget(name: "diskmap",
                          dependencies: ["DiskMapScan", "DiskMapReports"], swiftSettings: plain),
        .executableTarget(name: "dmbench", dependencies: ["DiskMapCore"], swiftSettings: plain),

        // The Finder extension. An app extension is a bundle whose executable
        // starts at NSExtensionMain rather than at main, which is what the
        // linker flag says; the bundle around it is assembled by the build
        // script, because a Swift package cannot produce an .appex itself.
        .executableTarget(name: "DiskMapFinder", swiftSettings: plain,
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e",
                                                         "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "DiskMapCoreTests",
                    dependencies: ["DiskMapCore", "DiskMapApp", "DiskMapScan", "DiskMapMeta",
                                   "DiskMapActions", "DiskMapCompare", "DiskMapReports"],
                    swiftSettings: plain),
    ]
)
