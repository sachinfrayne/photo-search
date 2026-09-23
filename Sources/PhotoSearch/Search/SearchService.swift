import Foundation

struct Photo: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let taken: Date?
    let country: String?
    let city: String?
    var score: Double = 0

    init(id: String, payload: JSON, score: Double = 0) {
        self.id = id
        url = URL(fileURLWithPath: payload["path"] as? String ?? "")
        taken = (payload["taken"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        country = payload["country"] as? String
        city = payload["city"] as? String
        self.score = score
    }

    var thumbnailURL: URL { Indexer.thumbnailURL(id) }
}

/// Turns what the user typed into a Qdrant query.
///
/// - Place names ("in italy"), dates ("august", "2025") and times of day
///   ("sunrise", "night") become filters on the photo's metadata, because
///   metadata beats guessing from pixels: a sunrise and a sunset look alike,
///   but the camera clock knows which is which.
/// - The whole phrase is embedded with the CLIP text encoder for visual
///   similarity.
/// - Words that match Apple Vision's scene labels nudge those photos up.
/// - Raw CLIP similarities aren't comparable between queries (a true
///   "church" match can score lower than the best wrong match for "dog"),
///   so each query is calibrated against a random sample of the library:
///   only photos that stand out for *this* query are kept.
final class SearchService: @unchecked Sendable {
    /// Keep photos at least this many standard deviations above the
    /// library's typical similarity for the query...
    static let minZScore = 1.8
    /// ...and within this distance of the best match.
    static let relativeMargin = 0.06
    static let labelBoost = 0.03
    static let sampleSize = 512

    /// Per model: vectors of a random sample of the library, for calibration.
    private var sample: [String: [[Float]]] = [:]
    /// How strongly the best result of the last search stood out (debug aid).
    private(set) var lastTopZ = 0.0

    private let client: QdrantClient
    /// Models by id; `searchModel` answers searches in the app, the others
    /// are only used by `--compare`.
    private let models: [String: EmbeddingModel]
    let searchModel: String
    private var places: [(name: String, field: String, value: String)] = []
    private let lock = NSLock()

    private static let aliases: [String: String] = [
        "italia": "italy", "españa": "spain", "espana": "spain", "deutschland": "germany",
        "england": "united kingdom", "uk": "united kingdom", "britain": "united kingdom",
        "usa": "united states", "america": "united states", "holland": "netherlands",
        "schweiz": "switzerland", "suisse": "switzerland", "österreich": "austria",
    ]
    private static let months = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]
    /// Times of day as wall-clock hour ranges (inclusive; may wrap midnight).
    private static let timesOfDay: [String: (from: Int, to: Int)] = [
        "sunrise": (4, 10), "dawn": (4, 9), "morning": (5, 11),
        "noon": (11, 14), "midday": (11, 14), "afternoon": (12, 18),
        "sunset": (16, 23), "dusk": (17, 23), "evening": (17, 23),
        "night": (20, 4), "nighttime": (20, 4),
    ]

    private static let stopwords: Set<String> = [
        "a", "an", "the", "in", "on", "at", "of", "and", "or", "with", "from", "to", "by", "for",
        "photo", "photos", "picture", "pictures", "image", "images", "some", "my", "me", "is",
        "are", "front", "standing", "sitting", "near", "next", "inside", "outside",
    ]

    init(client: QdrantClient, models: [EmbeddingModel]) {
        self.client = client
        self.models = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        searchModel = models[0].id
    }

    /// Refreshes the known place names (call after indexing).
    func refreshPlaces() async {
        var found: [(String, String, String)] = []
        for field in ["country", "city"] {
            for value in (try? await client.facet(Indexer.collection, key: field)) ?? [] {
                found.append((value.lowercased(), field, value))
            }
        }
        // Longest first so "united kingdom" wins over a hypothetical "kingdom".
        found.sort { $0.0.count > $1.0.count }

        let points = (try? await client.query(Indexer.collection, body: [
            "query": ["sample": "random"], "limit": Self.sampleSize, "with_vector": true,
        ])) ?? []
        var sampled: [String: [[Float]]] = [:]
        for id in models.keys { sampled[id] = points.compactMap { $0.vectors[id] } }
        lock.withLock {
            places = found
            sample = sampled
        }
    }

    func allPhotos() async throws -> [Photo] {
        try await client.scrollAll(Indexer.collection)
            .map { Photo(id: $0.id, payload: $0.payload) }
            .sorted { ($0.taken ?? .distantPast) > ($1.taken ?? .distantPast) }
    }

    /// Searches with the app's search model, or with `modelID` (for comparing).
    func search(_ text: String, using modelID: String? = nil) async throws -> [Photo] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await allPhotos() }

        let using = modelID ?? searchModel
        guard let model = models[using] else { return [] }
        let parsed = parse(query)
        let vector = try model.embed(text: "a photo of \(query)")

        // A filter that matches nothing ("sunrise 2026" in a 2025 library)
        // means nothing matches; don't quietly widen the search. Unknown
        // places never become filters, so "church in italy" still works.
        let results = try await run(vector: vector, using: using, filter: parsed.filter, labels: parsed.labelWords)
        guard let top = results.first?.score else { return [] }
        let (mean, std) = baseline(for: vector, model: using)
        lastTopZ = std > 0 ? (top - mean) / std : 0
        let cutoff = max(top - Self.relativeMargin, mean + Self.minZScore * std)
        // Nothing standing out means nothing matches: an empty grid with a
        // "no photos match" message is more honest than a random best guess.
        return results.filter { $0.score >= cutoff }
    }

    /// Mean and spread of this query's similarity across the library sample.
    private func baseline(for vector: [Float], model: String) -> (Double, Double) {
        let sample = lock.withLock { self.sample[model] ?? [] }
        guard sample.count >= 8 else { return (0, 0) }
        let sims = sample.map { v in Double(zip(v, vector).reduce(0) { $0 + $1.0 * $1.1 }) }
        let mean = sims.reduce(0, +) / Double(sims.count)
        let variance = sims.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sims.count)
        return (mean, variance.squareRoot())
    }

    // MARK: - Query building

    struct Parsed {
        var filter: JSON?
        var labelWords: [String]
    }

    func parse(_ query: String) -> Parsed {
        var lowered = " " + query.lowercased() + " "
        for (alias, canonical) in Self.aliases {
            lowered = lowered.replacingOccurrences(of: " \(alias) ", with: " \(canonical) ")
        }

        var must: [JSON] = []
        for place in lock.withLock({ places }) where lowered.contains(" \(place.name) ") {
            must.append(["key": place.field, "match": ["value": place.value]])
            lowered = lowered.replacingOccurrences(of: " \(place.name) ", with: " ")
        }

        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var labelWords: [String] = []
        for word in words {
            if let m = Self.months.firstIndex(of: word) {
                must.append(["key": "month", "match": ["value": m + 1]])
            } else if let range = Self.timesOfDay[word] {
                must.append(Self.hourCondition(range))
            } else if word.count == 4, let year = Int(word), (1900...2100).contains(year) {
                must.append(["key": "year", "match": ["value": year]])
            } else if word.count > 2, !Self.stopwords.contains(word) {
                labelWords.append(word)
                // Crude singular so "paintings" matches the "painting" label.
                if word.hasSuffix("s") && !word.hasSuffix("ss") { labelWords.append(String(word.dropLast())) }
            }
        }
        return Parsed(filter: must.isEmpty ? nil : ["must": must], labelWords: labelWords)
    }

    private static func hourCondition(_ r: (from: Int, to: Int)) -> JSON {
        if r.from <= r.to {
            return ["key": "hour", "range": ["gte": r.from, "lte": r.to]]
        }
        // Wraps midnight, e.g. night = 20:00–04:59.
        return ["should": [
            ["key": "hour", "range": ["gte": r.from]],
            ["key": "hour", "range": ["lte": r.to]],
        ]]
    }

    private func run(vector: [Float], using: String, filter: JSON?, labels: [String]) async throws -> [Photo] {
        var prefetch: JSON = ["query": vector, "using": using, "limit": 500]
        if let filter { prefetch["filter"] = filter }

        let body: JSON
        if labels.isEmpty {
            body = prefetch.merging(["with_payload": true]) { a, _ in a }
        } else {
            body = [
                "prefetch": prefetch,
                "query": ["formula": ["sum": [
                    "$score",
                    ["mult": [Self.labelBoost, ["key": "labels", "match": ["any": labels]]]],
                ]]],
                "limit": 500,
                "with_payload": true,
            ]
        }
        return try await client.query(Indexer.collection, body: body)
            .map { Photo(id: $0.id, payload: $0.payload, score: $0.score) }
    }
}
