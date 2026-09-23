import CoreGraphics
import CoreML
import Foundation
import Vision

/// A model that maps images and text into the same vector space.
protocol EmbeddingModel: Sendable {
    /// Also the name of this model's vector in Qdrant. Changing the set of
    /// models triggers a full re-index.
    var id: String { get }
    var dimensions: Int { get }
    func embed(image: CGImage) throws -> [Float]
    func embed(text: String) throws -> [Float]
}

/// Describes a CLIP-style Core ML model pair: an image encoder and a text
/// encoder that both output an embedding, plus the CLIP BPE tokenizer.
struct ModelSpec: Codable, Sendable {
    var id: String
    /// `.mlpackage` names, looked up in the app's bundled models and in
    /// ~/Library/Application Support/PhotoSearch/Models.
    var imageModel: String
    var textModel: String
    var dimensions: Int?
    var imageInput: String?
    var textInput: String?
    var output: String?

    /// Apple MobileCLIP variants from huggingface.co/apple/coreml-mobileclip.
    /// Only S2 ships with the app; the others can be dropped into the Models
    /// folder (scripts/fetch_deps.sh --extra-models fetches B (LT)).
    static let builtIn: [ModelSpec] = [
        .mobileCLIP("mobileclip-s0", "mobileclip_s0"),
        .mobileCLIP("mobileclip-s1", "mobileclip_s1"),
        .mobileCLIP("mobileclip-s2", "mobileclip_s2"),
        .mobileCLIP("mobileclip-blt", "mobileclip_blt"),
    ]
    static let defaultID = "mobileclip-s2"

    private static func mobileCLIP(_ id: String, _ file: String) -> ModelSpec {
        ModelSpec(id: id, imageModel: "\(file)_image.mlpackage", textModel: "\(file)_text.mlpackage")
    }
}

/// Runs a `ModelSpec` on-device with Core ML (Neural Engine when available).
/// Packages are compiled on first use, then cached in Application Support.
final class CoreMLCLIP: EmbeddingModel, @unchecked Sendable {
    enum Failure: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            if case .missing(let name) = self {
                return "Model file \(name) not found (looked in the app and in \(AppPaths.userModels.path))."
            }
            return nil
        }
    }

    let id: String
    let dimensions: Int

    private let imageModel: MLModel
    private let textModel: MLModel
    private let imageInput: String
    private let textInput: String
    private let output: String
    private let imageConstraint: MLImageConstraint
    private let tokenizer: CLIPTokenizer
    /// Core ML doesn't promise concurrent predictions on one model are safe.
    private let imageLock = NSLock()
    private let textLock = NSLock()

    init(_ spec: ModelSpec) throws {
        id = spec.id
        dimensions = spec.dimensions ?? 512
        imageInput = spec.imageInput ?? "image"
        textInput = spec.textInput ?? "text"
        output = spec.output ?? "final_emb_1"

        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageModel = try MLModel(contentsOf: Self.compiled(spec.imageModel), configuration: config)
        textModel = try MLModel(contentsOf: Self.compiled(spec.textModel), configuration: config)
        guard let constraint = imageModel.modelDescription.inputDescriptionsByName[imageInput]?.imageConstraint else {
            throw Failure.missing("\(spec.imageModel) input \"\(imageInput)\"")
        }
        imageConstraint = constraint
        tokenizer = try CLIPTokenizer(
            vocabURL: AppPaths.models.appendingPathComponent("clip-vocab.json"),
            mergesURL: AppPaths.models.appendingPathComponent("clip-merges.txt")
        )
    }

    func embed(image: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(
            cgImage: image,
            constraint: imageConstraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        )
        let out = try imageLock.withLock { try imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [imageInput: value])) }
        return Self.normalized(out.featureValue(for: output)!.multiArrayValue!)
    }

    func embed(text: String) throws -> [Float] {
        let ids = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
        let out = try textLock.withLock { try textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [textInput: array])) }
        return Self.normalized(out.featureValue(for: output)!.multiArrayValue!)
    }

    private static func normalized(_ array: MLMultiArray) -> [Float] {
        var v = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }

    /// Compiles `<name>.mlpackage` once and reuses the result. Recompiles if
    /// the package is newer than the cached compile (app update).
    private static func compiled(_ package: String) throws -> URL {
        let fm = FileManager.default
        guard let source = [AppPaths.models, AppPaths.userModels]
            .map({ $0.appendingPathComponent(package) })
            .first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw Failure.missing(package)
        }
        let cacheDir = AppPaths.support.appendingPathComponent("CompiledModels")
        let target = cacheDir.appendingPathComponent((package as NSString).deletingPathExtension + ".mlmodelc")
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

/// Optional power-user settings in
/// ~/Library/Application Support/PhotoSearch/config.json, e.g.
///
///     { "searchModel": "mobileclip-s2", "compareModels": ["mobileclip-blt"] }
///
/// `models` can describe extra Core ML models beyond the built-in ones.
struct AppConfig: Codable {
    var searchModel: String?
    var compareModels: [String]?
    var models: [ModelSpec]?

    static var url: URL { AppPaths.support.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            NSLog("PhotoSearch: ignoring unreadable config.json: \(error)")
            return AppConfig()
        }
    }

    /// The search model first, then any comparison models, without duplicates.
    func modelSpecs() -> [ModelSpec] {
        let known = Dictionary((ModelSpec.builtIn + (models ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { _, custom in custom })
        var ids = [searchModel ?? ModelSpec.defaultID] + (compareModels ?? [])
        ids = ids.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return ids.compactMap { id in
            if known[id] == nil { NSLog("PhotoSearch: unknown model \"\(id)\" in config.json") }
            return known[id]
        }
    }
}
