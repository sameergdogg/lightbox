// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// The CLI embeds an Info.plist in its binary. Without a usage description, macOS has no
/// text to show in the Photos permission prompt and refuses access outright.
let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Support/lightbox-Info.plist").path

let package = Package(
    name: "lightbox",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LightboxKit", targets: ["LightboxKit"]),
        .library(name: "LightboxModels", targets: ["LightboxModels"]),
        .executable(name: "lightbox", targets: ["lightbox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.19.2"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "LightboxKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Model runtimes (ONNX Runtime, Hugging Face tokenizers) and the providers built on them.
        // Kept out of LightboxKit so an app that links only the core (Dedupe for the App Store)
        // ships no model runtime and none of the providers whose weights are non-commercial.
        .target(
            name: "LightboxModels",
            dependencies: [
                "LightboxKit",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "lightbox",
            dependencies: [
                "LightboxKit",
                "LightboxModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist]),
            ]
        ),
        .testTarget(name: "LightboxKitTests", dependencies: ["LightboxKit"]),
        .testTarget(name: "LightboxModelsTests", dependencies: ["LightboxModels"]),
    ]
)
