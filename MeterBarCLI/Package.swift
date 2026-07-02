// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeterBarCLI",
    // Matches the app's deployment target: the CLI ships inside MeterBar.app
    // (Contents/Helpers/meterbar), so it only ever runs where the app runs.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "meterbar", targets: ["MeterBarCLI"])
    ],
    dependencies: [
        // The app's library: models, formatting, quota bands, and the shared
        // cache stores. Replaces the CLI's hand-maintained copies of these
        // types, which had already drifted (an Int-vs-Double mismatch once
        // silently emptied all CLI output).
        .package(name: "MeterBar", path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "MeterBarCLI",
            dependencies: [
                .product(name: "MeterBar", package: "MeterBar"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources",
            // Same language mode as the app library.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
