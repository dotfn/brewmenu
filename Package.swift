// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BrewMenu",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BrewMenu",
            path: "Sources",
            exclude: ["Info.plist"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "BrewMenuTests",
            dependencies: ["BrewMenu"],
            path: "Tests/BrewMenuTests"
        ),
        .testTarget(
            name: "BrewMenuIntegrationTests",
            dependencies: ["BrewMenu"],
            path: "Tests/BrewMenuIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
