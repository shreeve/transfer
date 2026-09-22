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
        .executableTarget(name: "Transfer")
    ]
)
