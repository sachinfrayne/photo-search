import Foundation
import PhotoSorterCore

/// Everything behind the window: the Qdrant process, the embedding model,
/// the indexer and search. Shared by the app UI and the hidden CLI.
final class Engine: @unchecked Sendable {
    let qdrant = QdrantProcess()
    let geocoder = GeocodeCache()
    private(set) var client: QdrantClient!
    /// Search model first, then any comparison models from config.json.
    private(set) var models: [EmbeddingModel] = []
    private(set) var indexer: Indexer!
    private(set) var search: SearchService!

    func start() async throws {
        // Model loading (first launch compiles them) overlaps with Qdrant startup.
        async let loadedModels = Task.detached(priority: .userInitiated) { try Self.loadModels() }.value
        try await qdrant.start()
        client = QdrantClient(process: qdrant)
        models = try await loadedModels
        indexer = Indexer(client: client, models: models, geocoder: geocoder)
        search = SearchService(client: client, models: models)
        try await indexer.prepare()
        await search.refreshPlaces()
    }

    func stop() {
        qdrant.stop()
    }

    /// Models from config.json. A comparison model that can't be loaded is
    /// skipped; if the search model can't be, fall back to the bundled one.
    private static func loadModels() throws -> [EmbeddingModel] {
        let specs = AppConfig.load().modelSpecs()
        var loaded: [EmbeddingModel] = []
        for spec in specs {
            do {
                loaded.append(try CoreMLCLIP(spec))
            } catch {
                NSLog("PhotoSearch: skipping model \(spec.id): \(error.localizedDescription)")
            }
        }
        if loaded.isEmpty || loaded.first?.id != specs.first?.id {
            let fallback = ModelSpec.builtIn.first { $0.id == ModelSpec.defaultID }!
            loaded.removeAll { $0.id == fallback.id }
            loaded.insert(try CoreMLCLIP(fallback), at: 0)
        }
        return loaded
    }

    /// Qdrant's web dashboard, for power users.
    var dashboardURL: URL { qdrant.baseURL.appendingPathComponent("dashboard") }
    var apiKey: String { qdrant.apiKey }
}

/// `PhotoSearch --index <folder>` and `PhotoSearch --search "<query>"`, for
/// testing without the UI. Uses the same data directory as the app unless
/// PHOTOSEARCH_DATA is set.
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        let engine = Engine()
        defer { engine.stop() }
        do {
            try await engine.start()
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--index":
                    i += 1
                    let root = URL(fileURLWithPath: args[i]).standardizedFileURL
                    let start = Date()
                    try await engine.indexer.sync(root: root) { done, total in
                        if total > 0 && (done == total || done % 10 == 0) { print("indexed \(done)/\(total)") }
                    }
                    await engine.search.refreshPlaces()
                    print("index holds \(await engine.indexer.count()) photos (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
                case "--search":
                    i += 1
                    let start = Date()
                    let results = try await engine.search.search(args[i])
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("\n\"\(args[i])\" → \(results.count) results (\(ms) ms), topZ \(String(format: "%.2f", engine.search.lastTopZ)), filter: \(engine.search.parse(args[i]).filter.map { "\($0)" } ?? "none")")
                    for r in results.prefix(12) {
                        print(String(format: "  %.3f  %@  %@", r.score, r.country ?? "-", r.url.lastPathComponent))
                    }
                case "--import":
                    // --import <library> <file-or-folder>: same path as dropping onto the window.
                    let root = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
                    let item = URL(fileURLWithPath: args[i + 2])
                    i += 2
                    let library = Library(root: root, sorter: Sorter(geocodeCache: engine.geocoder))
                    let indexer = engine.indexer!
                    print("imported \(await library.importItems([item]) { await indexer.contains(contentOf: $0) }) file(s)")
                    try await engine.indexer.sync(root: root) { _, _ in }
                    print("index holds \(await engine.indexer.count()) photos")
                case "--compare":
                    // --compare "<query>": the same search with every configured model.
                    i += 1
                    print("\n\"\(args[i])\"")
                    for model in engine.models {
                        let start = Date()
                        let results = try await engine.search.search(args[i], using: model.id)
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        let tag = model.id == engine.search.searchModel ? " (search model)" : ""
                        print("  \(model.id)\(tag): \(results.count) results, \(ms) ms")
                        for r in results.prefix(8) {
                            print(String(format: "    %.3f  %@", r.score, r.url.lastPathComponent))
                        }
                    }
                case "--labels":
                    for p in try await engine.client.scrollAll(Indexer.collection, fields: ["path", "labels"]) {
                        let name = URL(fileURLWithPath: p.payload["path"] as? String ?? "").lastPathComponent
                        print(name, (p.payload["labels"] as? [String] ?? []).joined(separator: ", "))
                    }
                default:
                    print("unknown argument \(args[i])")
                }
                i += 1
            }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}
