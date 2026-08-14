// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRBenchmark",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "OCRBenchmark",
            dependencies: ["OCRCore"]
        ),
        .target(
            name: "OCRCore",
            dependencies: [],
            // Swift 5 language mode matches the app target's SWIFT_VERSION so the
            // shared files (including the socket server) compile identically in
            // both the package and the Xcode app without a strict-concurrency
            // refactor of the server right now.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OCRCoreTests",
            dependencies: ["OCRCore"]
        ),
    ]
)
