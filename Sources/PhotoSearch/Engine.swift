import Foundation
import PhotoSorterCore

/// Everything behind the window: the Qdrant process, the embedding model,
/// the indexer and search. Shared by the app UI and the hidden CLI.
final class Engine: @unchecked Sendable {
    let qdrant = QdrantProcess()
    let geocoder = GeocodeCache()
    private(set) var client: QdrantClient!
    private(set) var model: EmbeddingModel!
    private(set) var indexer: Indexer!
    private(set) var search: SearchService!

    func start() async throws {
        // Model loading (first launch compiles it) overlaps with Qdrant startup.
        async let loadedModel = Task.detached(priority: .userInitiated) { try MobileCLIP() }.value
        try await qdrant.start()
        client = QdrantClient(process: qdrant)
        model = try await loadedModel
        indexer = Indexer(client: client, model: model, geocoder: geocoder)
        search = SearchService(client: client, model: model)
        try await indexer.prepare()
        await search.refreshPlaces()
    }

    func stop() {
        qdrant.stop()
    }
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
