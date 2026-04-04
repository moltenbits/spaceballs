// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Spaceballs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaceballsCore", targets: ["SpaceballsCore"]),
        .executable(name: "spaceballs", targets: ["spaceballs"]),
        .executable(name: "spaceballs-gui", targets: ["spaceballs-gui"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SpaceballsCore",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .target(
            name: "SpaceballsGUILib",
            dependencies: ["SpaceballsCore"],
            path: "Sources/SpaceballsGUILib"
        ),
        .executableTarget(
            name: "spaceballs",
            dependencies: [
                "SpaceballsCore",
                "SpaceballsGUILib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Spaceballs"
        ),
        .executableTarget(
            name: "spaceballs-gui",
            dependencies: ["SpaceballsCore", "SpaceballsGUILib"],
            path: "Sources/SpaceballsGUI"
        ),
        .testTarget(
            name: "SpaceballsCoreTests",
            dependencies: ["SpaceballsCore"]
        ),
        .testTarget(
            name: "SpaceballsGUITests",
            dependencies: ["SpaceballsGUILib"]
        ),
    ]
)
