// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            // Info.plist and the entitlements belong to Parrot.app; see
            // scripts/build-macos-app.
            exclude: ["Info.plist", "Parrot.entitlements"]
        ),
        .testTarget(
            name: "ParrotTests",
            dependencies: ["parrot"]
        ),
    ]
)
