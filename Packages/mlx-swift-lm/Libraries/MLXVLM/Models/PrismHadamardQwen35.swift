//
//  PrismHadamardQwen35.swift
//  mlx-swift-lm
//
//  Loads PrismML's Hadamard-packed Qwen 3.5 checkpoints (Ternary Bonsai 2). Port of the
//  pack's own `runtime/vision_artifact.py` loader.
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

#if canImport(os)
    import os
#endif

/// `config.json` of a `prism_hadamard_qwen35` pack: a stock Qwen 3.5 configuration plus the
/// list of language-model modules stored packed.
public struct PrismHadamardQwen35Configuration: Decodable, Sendable {
    /// One packed module. `block` is the Hadamard block size, or 0 for no transform.
    public struct PackedModule: Decodable, Sendable {
        public let path: String
        public let block: Int
        public let embedding: Bool
        public let dtype: String
    }

    public struct Quantization: Decodable, Sendable {
        public let bits: Int
        public let groupSize: Int

        enum CodingKeys: String, CodingKey {
            case bits
            case groupSize = "group_size"
        }
    }

    public let base: Qwen35Configuration
    public let modules: [PackedModule]
    public let quantization: Quantization
    public let baseModelType: String

    enum CodingKeys: String, CodingKey {
        case modules
        case quantization
        case baseModelType = "base_model_type"
    }

    public init(from decoder: Decoder) throws {
        base = try Qwen35Configuration(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modules = try container.decode([PackedModule].self, forKey: .modules)
        quantization = try container.decode(Quantization.self, forKey: .quantization)
        baseModelType = try container.decode(String.self, forKey: .baseModelType)
    }
}

extension PrismHadamardQwen35Configuration: ModelConfigurationValidating {
    public func validateModelConfiguration() throws {
        guard baseModelType == "qwen3_5" else {
            throw PrismHadamardQwen35Error.unsupported("base model type \(baseModelType)")
        }
        for module in modules {
            guard module.dtype == "float16" else {
                throw PrismHadamardQwen35Error.unsupported("activation dtype \(module.dtype)")
            }
            guard module.block == 0 || [512, 1024, 2048, 4096].contains(module.block) else {
                throw PrismHadamardQwen35Error.unsupported("Hadamard block size \(module.block)")
            }
        }
    }
}

public enum PrismHadamardQwen35Error: LocalizedError {
    case unsupported(String)
    case missingTensor(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): "Unsupported Prism Hadamard pack: \(what)"
        case .missingTensor(let key): "Prism Hadamard pack is missing \(key)"
        }
    }
}

/// Qwen 3.5 whose language model projections are affine low-bit weights folded into a signed
/// Hadamard basis. Each packed module is replaced by a layer that applies the matching input
/// transform (or the inverse, after lookup, for the embedding). The vision tower is stock FP16.
public final class PrismHadamardQwen35: Qwen35 {
    private let packedModules: [PrismHadamardQwen35Configuration.PackedModule]
    private let quantization: PrismHadamardQwen35Configuration.Quantization

    public init(_ configuration: PrismHadamardQwen35Configuration) {
        packedModules = configuration.modules
        quantization = configuration.quantization
        super.init(configuration.base)
    }

    public override func sanitize(weights: [String: MLXArray], metadata: [String: String])
        -> [String: MLXArray]
    {
        var weights = super.sanitize(weights: weights, metadata: metadata)
        do {
            try installPackedModules(from: &weights)
        } catch {
            // `sanitize` can't throw. The `.signs` tensors stay in place, so the strict weight
            // update that follows fails the load instead of running untransformed weights.
            #if canImport(os)
                Logger(subsystem: "mlx-swift-lm", category: "prism-hadamard")
                    .error("Failed to install packed modules: \(String(describing: error))")
            #endif
        }
        return weights
    }

    /// Replaces every packed module with its Hadamard layer and takes its `.signs` out of
    /// `weights` (they live in the transform, not the parameter tree).
    private func installPackedModules(from weights: inout [String: MLXArray]) throws {
        var transforms: [Int: [SignedBlockHadamard]] = [:]
        var updates: [(String, Module)] = []
        var consumedSigns: [String] = []

        for record in packedModules {
            let key = "language_model." + record.path
            func tensor(_ suffix: String) throws -> MLXArray {
                guard let value = weights["\(key).\(suffix)"] else {
                    throw PrismHadamardQwen35Error.missingTensor("\(key).\(suffix)")
                }
                return value
            }
            let weight = try tensor("weight")
            let scales = try tensor("scales")
            let biases = try tensor("biases")

            var transform: SignedBlockHadamard?
            if record.block > 0 {
                let signs = try tensor("signs").asType(.float32).asArray(Float.self)
                // Layers of one width share one sign vector; reuse its transform so they
                // share one buffer too.
                if let shared = transforms[signs.count]?.first(where: { $0.matches(signs: signs) }) {
                    transform = shared
                } else {
                    let made = try SignedBlockHadamard(blockSize: record.block, signs: signs)
                    transforms[signs.count, default: []].append(made)
                    transform = made
                }
                consumedSigns.append("\(key).signs")
            } else if weights["\(key).signs"] != nil {
                throw PrismHadamardQwen35Error.unsupported("signs on untransformed \(record.path)")
            }

            let module: Module
            switch (record.embedding, transform) {
            case (true, let transform?):
                module = try HadamardQuantizedEmbedding(
                    weight: weight, scales: scales, biases: biases,
                    groupSize: quantization.groupSize, bits: quantization.bits,
                    transform: transform, outputDType: .float16)
            case (false, let transform?):
                module = try HadamardQuantizedLinear(
                    weight: weight, scales: scales, biases: biases,
                    groupSize: quantization.groupSize, bits: quantization.bits,
                    transform: transform)
            case (false, nil):
                module = QuantizedLinear(
                    weight: weight, bias: nil, scales: scales, biases: biases,
                    groupSize: quantization.groupSize, bits: quantization.bits)
            case (true, nil):
                throw PrismHadamardQwen35Error.unsupported("untransformed packed embedding")
            }
            updates.append((key, module))
        }

        try update(modules: ModuleChildren.unflattened(updates), verify: [.noUnusedKeys])
        for key in consumedSigns {
            weights[key] = nil
        }
    }

    public override func prepare() throws {
        try super.prepare()
        // FP32 activations (the pack keeps its norms in FP32) would otherwise widen the FP16
        // scales and offsets on every call.
        for case let (_, linear as HadamardQuantizedLinear) in leafModules().flattened() {
            linear.prepareWideConstants()
        }
    }
}
