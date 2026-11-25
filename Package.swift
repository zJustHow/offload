// swift-tools-version: 6.0
import PackageDescription

// Offload: "on-device understanding -> readable knowledge base -> assistants that use it",
// with a hybrid retrieval layer (BM25 + trigram + vector, fused with weighted RRF) on top of
// the summaries.
let package = Package(
    name: "Offload",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "OffloadCore", targets: ["OffloadCore"]),
        .library(name: "OffloadUI", targets: ["OffloadUI"]),
        .executable(name: "offload-previews", targets: ["OffloadPreviews"]),
        .executable(name: "offload", targets: ["offload"]),
        .executable(name: "OffloadApp", targets: ["OffloadApp"]),
    ],
    targets: [
        .target(
            name: "OffloadCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "offload",
            dependencies: ["OffloadCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SwiftUI/AppKit components (the notch assistant, Apple-Intelligence-style glow). It does not
        // depend on OffloadCore, so every view can be rendered to an image and inspected on its own.
        .target(
            name: "OffloadUI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OffloadPreviews",
            dependencies: ["OffloadUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OffloadApp",
            dependencies: ["OffloadCore", "OffloadUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OffloadUITests",
            dependencies: ["OffloadUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OffloadCoreTests",
            dependencies: ["OffloadCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
