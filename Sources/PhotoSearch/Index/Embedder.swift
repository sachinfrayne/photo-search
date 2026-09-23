import CoreGraphics
import CoreML
import Foundation
import Vision

/// A model that maps images and text into the same vector space.
protocol EmbeddingModel: Sendable {
    /// Stored alongside the index; changing it triggers a full re-index.
    var id: String { get }
    var dimensions: Int { get }
    func embed(image: CGImage) throws -> [Float]
    func embed(text: String) throws -> [Float]
}

/// Apple's MobileCLIP-S2, run on-device with Core ML (Neural Engine when
/// available). The .mlpackage files ship inside the app and are compiled on
/// first launch, then cached in Application Support.
final class MobileCLIP: EmbeddingModel, @unchecked Sendable {
    let id = "mobileclip-s2"
    let dimensions = 512

    private let imageModel: MLModel
    private let textModel: MLModel
    private let imageConstraint: MLImageConstraint
    private let tokenizer: CLIPTokenizer
    /// Core ML doesn't promise concurrent predictions on one model are safe.
    private let imageLock = NSLock()
    private let textLock = NSLock()

    init() throws {
        let dir = AppPaths.models
        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageModel = try MLModel(contentsOf: Self.compiled("mobileclip_s2_image", in: dir), configuration: config)
        textModel = try MLModel(contentsOf: Self.compiled("mobileclip_s2_text", in: dir), configuration: config)
        imageConstraint = imageModel.modelDescription.inputDescriptionsByName["image"]!.imageConstraint!
        tokenizer = try CLIPTokenizer(
            vocabURL: dir.appendingPathComponent("clip-vocab.json"),
            mergesURL: dir.appendingPathComponent("clip-merges.txt")
        )
    }

    func embed(image: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(
            cgImage: image,
            constraint: imageConstraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        )
        let out = try imageLock.withLock { try imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value])) }
        return Self.normalized(out.featureValue(for: "final_emb_1")!.multiArrayValue!)
    }

    func embed(text: String) throws -> [Float] {
        let ids = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
        let out = try textLock.withLock { try textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": array])) }
        return Self.normalized(out.featureValue(for: "final_emb_1")!.multiArrayValue!)
    }

    private static func normalized(_ array: MLMultiArray) -> [Float] {
        var v = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }

    /// Compiles `<name>.mlpackage` once and reuses the result. Recompiles if
    /// the bundled package is newer than the cached compile (app update).
    private static func compiled(_ name: String, in dir: URL) throws -> URL {
        let fm = FileManager.default
        let source = dir.appendingPathComponent("\(name).mlpackage")
        let cacheDir = AppPaths.support.appendingPathComponent("CompiledModels")
        let target = cacheDir.appendingPathComponent("\(name).mlmodelc")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        func modified(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.appendingPathComponent("Manifest.json").path))?[.modificationDate] as? Date
                ?? (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        if fm.fileExists(atPath: target.path),
           let built = (try? fm.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date,
           let src = modified(source), built >= src {
            return target
        }

        let temp = try MLModel.compileModel(at: source)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: temp, to: target)
        return target
    }
}
