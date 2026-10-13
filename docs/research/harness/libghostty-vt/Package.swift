// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibghosttyVTHarness",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .executable(name: "LibghosttyVTHarness", targets: ["LibghosttyVTHarness"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/caelyreth/libghostty-vt-spm.git",
            revision: "1f5446ec78f38546f1aee8f73067b9a4f7703262"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LibghosttyVTHarness",
            dependencies: [
                .product(name: "GhosttyVt", package: "libghostty-vt-spm"),
            ]
        ),
    ]
)
