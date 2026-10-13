// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TerminiIOSHarness",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .executable(name: "TerminiIOSHarness", targets: ["TerminiIOSHarness"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/arach/Termini.git",
            revision: "140238ec0d03ce0ad794765a6ceebcf2445f0894"
        ),
    ],
    targets: [
        .executableTarget(
            name: "TerminiIOSHarness",
            dependencies: [
                .product(name: "Termini", package: "Termini"),
            ]
        ),
    ]
)
