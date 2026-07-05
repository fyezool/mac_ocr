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
            dependencies: []
        ),
    ]
)
