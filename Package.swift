// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Spacebar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpacebarCore", targets: ["SpacebarCore"]),
        .executable(name: "spacebar", targets: ["spacebar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SpacebarCore",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .executableTarget(
            name: "spacebar",
            dependencies: [
                "SpacebarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Spacebar"
        ),
        .testTarget(
            name: "SpacebarCoreTests",
            dependencies: ["SpacebarCore"]
        ),
    ]
)
