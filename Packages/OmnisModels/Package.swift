// swift-tools-version: 6.2

import PackageDescription

/// Omnis's on-device model runtime: MLX (with PrismML's 1-bit kernels, via the vendored
/// mlx-swift-lm), a tokenizer, and a loader that turns a downloaded model folder into a
/// FoundationModels `LanguageModel`.
let package = Package(
    name: "OmnisModels",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OmnisModels", targets: ["OmnisModels"])
    ],
    dependencies: [
        .package(path: "../mlx-swift-lm"),
        // Minor releases have been API-breaking; bump deliberately.
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", .upToNextMinor(from: "0.7.1")),
    ],
    targets: [
        .target(
            name: "OmnisModels",
            dependencies: [
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
            ],
            exclude: ["TokenizerBridge-LICENSE.txt"]
        )
    ]
)
