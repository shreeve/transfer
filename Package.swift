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
            dependencies: ["TransferUI", "TransferIO"]
        ),
        .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"]),
        .testTarget(name: "TransferIOTests", dependencies: ["TransferIO"]),
    ]
)
