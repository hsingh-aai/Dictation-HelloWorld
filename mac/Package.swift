// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationHello",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationEngine", targets: ["DictationEngine"]),
        .executable(name: "DictationHello", targets: ["DictationHello"]),
    ],
    targets: [
        // Dependency-free: the whole pipeline, and everything decidable as pure value types.
        .target(name: "DictationEngine", path: "Sources/DictationEngine"),
        // AppKit + SwiftUI shell composing the engine.
        .executableTarget(
            name: "DictationHello",
            dependencies: ["DictationEngine"],
            path: "App/DictationHello"
        ),
        .testTarget(
            name: "DictationEngineTests",
            dependencies: ["DictationEngine"],
            path: "Tests/DictationEngineTests"
        ),
    ]
)
