// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Spacebar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpacebarCore", targets: ["SpacebarCore"]),
        .executable(name: "spacebar", targets: ["spacebar"]),
        .executable(name: "spacebar-gui", targets: ["spacebar-gui"]),
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
        .target(
            name: "SpacebarGUILib",
            dependencies: ["SpacebarCore"],
            path: "Sources/SpacebarGUILib"
        ),
        .executableTarget(
            name: "spacebar",
            dependencies: [
                "SpacebarCore",
                "SpacebarGUILib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Spacebar"
        ),
        .executableTarget(
            name: "spacebar-gui",
            dependencies: ["SpacebarCore", "SpacebarGUILib"],
            path: "Sources/SpacebarGUI"
        ),
        .testTarget(
            name: "SpacebarCoreTests",
            dependencies: ["SpacebarCore"]
        ),
        .testTarget(
            name: "SpacebarGUITests",
            dependencies: ["SpacebarGUILib"]
        ),
    ]
)
