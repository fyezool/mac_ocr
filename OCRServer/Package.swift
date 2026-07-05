// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRServer",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.106.0"),
    ],
    targets: [
        .executableTarget(
            name: "OCRServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)
