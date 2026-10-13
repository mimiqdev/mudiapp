// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GhosttyTerminalHarness",
    platforms: [.iOS(.v17)],
    products: [
        .executable(name: "GhosttyTerminalHarness", targets: ["GhosttyTerminalHarness"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/libghostty-spm.git",
            revision: "d403978c66870baa422709d1dde385730a4bdaef"
        ),
    ],
    targets: [
        .executableTarget(
            name: "GhosttyTerminalHarness",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
    ]
)
