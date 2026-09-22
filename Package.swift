// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Transfer",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(name: "Transfer", targets: ["Transfer"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "TransferCore"),
        .target(
            name: "TransferIO",
            dependencies: ["TransferCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "TransferUI", dependencies: ["TransferCore"]),
        .executableTarget(
            name: "Transfer",
            dependencies: ["TransferUI", "TransferIO", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"]),
        .testTarget(name: "TransferIOTests", dependencies: ["TransferIO"]),
    ]
)
