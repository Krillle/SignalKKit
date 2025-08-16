// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "SignalKKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SignalKKit",
            targets: ["SignalKKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: "SignalKKit",
            dependencies: ["Starscream"]),
        .testTarget(
            name: "SignalKKitTests",
            dependencies: ["SignalKKit"]),
    ]
)
