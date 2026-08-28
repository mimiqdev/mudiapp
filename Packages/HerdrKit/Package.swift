// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HerdrKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
    ],
    targets: [
        .target(name: "HerdrKit"),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"]),
    ]
)
