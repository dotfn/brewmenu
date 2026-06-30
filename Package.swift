// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "BrewMenu",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BrewMenu",
            path: "Sources",
            exclude: ["Info.plist"]
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
