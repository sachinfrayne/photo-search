import CoreGraphics
import CoreML
import Foundation
import Tokenizers
import Vision

/// A model that maps images and text into the same vector space.
protocol EmbeddingModel: Sendable {
    /// Also the name of this model's vector in Qdrant. Changing the set of
    /// models triggers a full re-index.
    var id: String { get }
    var name: String { get }
    var dimensions: Int { get }
    func embed(image: CGImage) throws -> [Float]
    /// Embeds a search phrase; the model's own prompt ("a photo of …") is applied.
    func embed(query: String) throws -> [Float]
}

// MARK: - Model folders

/// A model is a folder with a `model.json` describing its Core ML image and
/// text encoders and tokenizer, e.g. Models/siglip2-base-256/model.json:
///
///     { "id": "siglip2-base-256", "name": "SigLIP 2 base", "dimensions": 768,
///       "image": { "model": "image.mlpackage", "input": "image", "resize": "squash" },
///       "text": { "model": "text.mlpackage", "input": "input_ids", "tokenizer": "huggingface",
///                 "contextLength": 64, "lowercase": true, "prompt": "a photo of {}" },
///       "output": "embedding", "computeUnits": "cpuAndNeuralEngine" }
///
/// `tokenizer` is "huggingface" (tokenizer.json in the folder) or "clip"
/// (clip-vocab.json + clip-merges.txt). `resize` is "squash" or "centerCrop".
struct ModelManifest: Codable, Sendable {
    struct Image: Codable, Sendable {
        var model: String
        var input: String?
        var resize: String?
    }

    struct Text: Codable, Sendable {
        var model: String
        var input: String?
        var tokenizer: String?
        var contextLength: Int?
        var lowercase: Bool?
        var prompt: String?
    }

    var id: String
    var name: String?
    var source: String?
    var license: String?
    var dimensions: Int
    var image: Image
    var text: Text
    var output: String?
    var computeUnits: String?

    /// Filled in on discovery, not part of model.json.
    var folder: URL?

    private enum CodingKeys: String, CodingKey {
        case id, name, source, license, dimensions, image, text, output, computeUnits
    }

    /// The model the app ships with and uses unless config.json says otherwise.
    static let defaultID = "siglip2-base-256"

    /// Model folders bundled with the app plus any in the user's Models folder
    /// (a user folder with the same id wins).
    static func discover() -> [ModelManifest] {
        var byID: [String: ModelManifest] = [:]
        for dir in [AppPaths.models, AppPaths.userModels] {
            let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let file = folder.appendingPathComponent("model.json")
                guard let data = try? Data(contentsOf: file) else { continue }
                do {
                    var manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
                    manifest.folder = folder
                    byID[manifest.id] = manifest
                } catch {
                    NSLog("PhotoSearch: ignoring \(file.path): \(error)")
                }
            }
        }
        return byID.values.sorted { $0.displayName < $1.displayName }
    }

    var displayName: String { name ?? id }
}

// MARK: - Core ML runner

protocol TextTokenizer: Sendable {
    /// Token ids padded to the model's context length.
    func encode(_ text: String) -> [Int32]
}

extension CLIPTokenizer: TextTokenizer {}

/// Wraps a Hugging Face tokenizer.json (SigLIP 2's Gemma tokenizer and
/// others). Pads to a fixed length the way the models were trained.
final class HuggingFaceTokenizer: TextTokenizer, @unchecked Sendable {
    private let tokenizer: Tokenizer
    private let contextLength: Int
    private let padID: Int

    init(folder: URL, contextLength: Int) async throws {
        tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        self.contextLength = contextLength
        padID = tokenizer.convertTokenToId("<pad>") ?? 0
    }

    func encode(_ text: String) -> [Int32] {
        var ids = tokenizer.encode(text: text)
        if ids.count > contextLength { ids = Array(ids.prefix(contextLength)) }
        ids += Array(repeating: padID, count: contextLength - ids.count)
        return ids.map(Int32.init)
    }
}

/// Runs a `ModelManifest` on-device with Core ML. Packages are compiled on
/// first use, then cached in Application Support.
final class CoreMLEmbedder: EmbeddingModel, @unchecked Sendable {
    enum Failure: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            if case .missing(let what) = self { return "Model is incomplete: \(what) not found." }
            return nil
        }
    }

    let id: String
    let name: String
    let dimensions: Int

    private let manifest: ModelManifest
    private let imageModel: MLModel
    private let textModel: MLModel
    private let imageInput: String
    private let textInput: String
    private let output: String
    private let imageConstraint: MLImageConstraint
    private let crop: VNImageCropAndScaleOption
    private let tokenizer: TextTokenizer
    /// Core ML doesn't promise concurrent predictions on one model are safe.
    private let imageLock = NSLock()
    private let textLock = NSLock()

    static func load(_ manifest: ModelManifest) async throws -> CoreMLEmbedder {
        guard let folder = manifest.folder else { throw Failure.missing("model folder") }
        let context = manifest.text.contextLength ?? 77
        let tokenizer: TextTokenizer
        switch manifest.text.tokenizer ?? "clip" {
        case "huggingface":
            tokenizer = try await HuggingFaceTokenizer(folder: folder, contextLength: context)
        default:
            tokenizer = try CLIPTokenizer(
                vocabURL: folder.appendingPathComponent("clip-vocab.json"),
                mergesURL: folder.appendingPathComponent("clip-merges.txt"),
                contextLength: context
            )
        }
        return try CoreMLEmbedder(manifest, folder: folder, tokenizer: tokenizer)
    }

    private init(_ manifest: ModelManifest, folder: URL, tokenizer: TextTokenizer) throws {
        self.manifest = manifest
        self.tokenizer = tokenizer
        id = manifest.id
        name = manifest.displayName
        dimensions = manifest.dimensions
        imageInput = manifest.image.input ?? "image"
        textInput = manifest.text.input ?? "text"
        output = manifest.output ?? "embedding"
        crop = manifest.image.resize == "squash" ? .scaleFill : .centerCrop

        let config = MLModelConfiguration()
        config.computeUnits = Self.computeUnits(manifest.computeUnits)
        imageModel = try MLModel(contentsOf: Self.compiled(folder, manifest.image.model, id: id), configuration: config)
        textModel = try MLModel(contentsOf: Self.compiled(folder, manifest.text.model, id: id), configuration: config)
        guard let constraint = imageModel.modelDescription.inputDescriptionsByName[imageInput]?.imageConstraint else {
            throw Failure.missing("image input \"\(imageInput)\" in \(manifest.image.model)")
        }
        imageConstraint = constraint
    }

    func embed(image: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(cgImage: image, constraint: imageConstraint, options: [.cropAndScale: crop.rawValue])
        let out = try imageLock.withLock { try imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [imageInput: value])) }
        return try vector(out)
    }

    func embed(query: String) throws -> [Float] {
        var text = (manifest.text.prompt ?? "{}").replacingOccurrences(of: "{}", with: query)
        if manifest.text.lowercase ?? false { text = text.lowercased() }
        let ids = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
        let out = try textLock.withLock { try textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [textInput: array])) }
        return try vector(out)
    }

    /// Token ids for a phrase, for checking the tokenizer against Python.
    func tokenIDs(_ text: String) -> [Int32] { tokenizer.encode(text) }

    private func vector(_ out: MLFeatureProvider) throws -> [Float] {
        guard let array = out.featureValue(for: output)?.multiArrayValue else { throw Failure.missing("output \"\(output)\"") }
        var v = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }

    private static func computeUnits(_ name: String?) -> MLComputeUnits {
        switch name {
        case "cpuOnly": return .cpuOnly
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        default: return .all
        }
    }

    /// Compiles a `.mlpackage` once and reuses the result. Recompiles if the
    /// package is newer than the cached compile (app or model update).
    private static func compiled(_ folder: URL, _ package: String, id: String) throws -> URL {
        let fm = FileManager.default
        let source = folder.appendingPathComponent(package)
        guard fm.fileExists(atPath: source.path) else { throw Failure.missing(package) }
        let cacheDir = AppPaths.support.appendingPathComponent("CompiledModels").appendingPathComponent(id)
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

// MARK: - Settings

/// Optional settings in ~/Library/Application Support/PhotoSearch/config.json:
///
///     { "searchModel": "siglip2-base-256", "compareModels": ["mobileclip-s2"] }
///
/// The Settings window writes `searchModel`; `compareModels` is for power
/// users comparing models with `--compare`.
struct AppConfig: Codable {
    var searchModel: String?
    var compareModels: [String]?

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

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url)
    }

    /// Wanted model ids: the search model first, then comparison models.
    var modelIDs: [String] {
        ([searchModel ?? ModelManifest.defaultID] + (compareModels ?? []))
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}
