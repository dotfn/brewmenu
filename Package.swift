// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BrewMenu",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        // Domain models, error types and localisation helpers. No UI and no process or network code,
        // so the app's logic depends on a small, separately compiled layer.
        .target(
            name: "BrewCore",
            path: "Sources/BrewCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BrewMenu",
            dependencies: ["BrewCore"],
            path: "Sources",
            exclude: ["Info.plist", "BrewCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "BrewMenuTests",
            dependencies: ["BrewMenu", "BrewCore"],
            path: "Tests/BrewMenuTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
