import CryptoKit
import Foundation
import ImageIO
import PhotoSorterCore
import UniformTypeIdentifiers
import Vision

/// Keeps the Qdrant collection in step with the photos on disk: embeds new
/// photos, follows files that were moved or renamed (by content hash, so no
/// re-embedding), and forgets files that were deleted.
actor Indexer {
    static let collection = "photos"
    /// Bump when the payload layout changes in a way that needs a rebuild.
    private static let schemaVersion = 4
    static let imageExts: Set<String> = Sorter.mediaExts.subtracting(MetadataReader.videoExts)

    private let client: QdrantClient
    /// Every photo gets one named vector per model (search model first).
    private let models: [EmbeddingModel]
    private let geocoder: GeocodeCache
    private var knownByPath: [String: (id: String, mtime: Int, size: Int)] = [:]
    private var knownIDs: Set<String> = []

    init(client: QdrantClient, models: [EmbeddingModel], geocoder: GeocodeCache) {
        self.client = client
        self.models = models
        self.geocoder = geocoder
    }

    // MARK: - Collection setup

    /// Creates the collection on first run, and rebuilds it if the set of
    /// embedding models or the payload layout changed since it was built.
    func prepare() async throws {
        let metaURL = AppPaths.support.appendingPathComponent("index.json")
        let wanted: [String: AnyHashable] = ["models": models.map(\.id).sorted(), "schema": Self.schemaVersion]
        let current = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: AnyHashable]
        let exists = try await client.collectionExists(Self.collection)

        if exists && current != wanted {
            try await client.deleteCollection(Self.collection)
        }
        if !exists || current != wanted {
            try await client.createCollection(
                Self.collection,
                vectors: Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.dimensions) })
            )
            for field in ["country", "city", "labels", "path"] {
                try await client.createIndex(Self.collection, field: field, schema: "keyword")
            }
            for field in ["taken", "year", "month", "hour"] {
                try await client.createIndex(Self.collection, field: field, schema: "integer")
            }
            try JSONSerialization.data(withJSONObject: wanted).write(to: metaURL)
        }
        try await loadKnown()
    }

    private func loadKnown() async throws {
        let points = try await client.scrollAll(Self.collection, fields: ["path", "mtime", "size"])
        knownByPath = [:]
        knownIDs = []
        for p in points {
            knownIDs.insert(p.id)
            if let path = p.payload["path"] as? String {
                knownByPath[path] = (p.id, p.payload["mtime"] as? Int ?? 0, p.payload["size"] as? Int ?? 0)
            }
        }
    }

    // MARK: - Sync

    /// Full reconciliation of `root` against the index.
    func sync(root: URL, progress: @escaping @MainActor (Int, Int) -> Void) async throws {
        let files = Sorter().scanFiles(under: root).media.filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
        let onDisk = Set(files.map { $0.standardizedFileURL.path })
        try await index(files, root: root, progress: progress)
        // Moved photos were re-pointed during indexing, so whatever path is
        // left over and missing from disk has really been deleted.
        try await forget(paths: knownByPath.keys.filter { !onDisk.contains($0) })
    }

    /// Indexes (or re-indexes) specific files. Unchanged files are skipped.
    func index(_ files: [URL], root: URL, progress: (@MainActor (Int, Int) -> Void)? = nil) async throws {
        var todo: [(url: URL, mtime: Int, size: Int)] = []
        for url in files {
            let path = url.standardizedFileURL.path
            guard let (mtime, size) = Self.fileStamp(url) else { continue }
            if let known = knownByPath[path], known.mtime == mtime, known.size == size { continue }
            todo.append((url, mtime, size))
        }
        let total = todo.count
        if total == 0 { await progress?(0, 0); return }
        await progress?(0, total)

        let models = models, geocoder = geocoder
        var done = 0
        var batch: [JSON] = []

        try await withThrowingTaskGroup(of: Prepared?.self) { group in
            var iterator = todo.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                let isKnown: @Sendable (String) -> Bool = { [knownIDs] id in knownIDs.contains(id) }
                group.addTask {
                    try? await Self.prepare(item.url, mtime: item.mtime, size: item.size, root: root,
                                            models: models, geocoder: geocoder, isKnown: isKnown)
                }
            }
            for _ in 0..<4 { addNext() }

            while let result = try await group.next() {
                addNext()
                done += 1
                if let p = result {
                    let replaced = knownByPath[p.path]?.id
                    knownByPath[p.path] = (p.id, p.mtime, p.size)
                    // Edited in place: the old content's point is now orphaned.
                    if let old = replaced, old != p.id, !knownByPath.values.contains(where: { $0.id == old }) {
                        try await remove(ids: [old])
                    }
                    knownIDs.insert(p.id)
                    if let vectors = p.vectors {
                        batch.append(["id": p.id, "vector": vectors, "payload": p.payload])
                    } else {
                        // Same photo, new place (moved/renamed): just update where it lives.
                        try await client.setPayload(Self.collection, id: p.id, payload: p.payload)
                    }
                }
                if batch.count >= 16 {
                    try await client.upsert(Self.collection, points: batch)
                    batch.removeAll()
                }
                await progress?(done, total)
            }
        }
        try await client.upsert(Self.collection, points: batch)
    }

    /// Forgets files that no longer exist at these paths.
    func forget(paths: [String]) async throws {
        var ids: [String] = []
        for path in paths {
            guard let known = knownByPath.removeValue(forKey: path) else { continue }
            if let other = knownByPath.first(where: { $0.value.id == known.id }) {
                // An identical copy lives elsewhere: point the photo at it.
                try await client.setPayload(Self.collection, id: known.id, payload: ["path": other.key])
            } else {
                ids.append(known.id)
            }
        }
        try await remove(ids: ids)
    }

    /// Whether a photo with exactly this content is already in the library.
    func contains(contentOf url: URL) -> Bool {
        guard let id = try? Self.contentID(url) else { return false }
        return knownIDs.contains(id)
    }

    private func remove(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await client.delete(Self.collection, ids: ids)
        for id in ids {
            knownIDs.remove(id)
            try? FileManager.default.removeItem(at: Self.thumbnailURL(id))
        }
    }

    func count() async -> Int { knownIDs.count }

    // MARK: - Per-photo work (runs concurrently, off the actor)

    private struct Prepared: @unchecked Sendable {
        let id: String
        let path: String
        let mtime: Int
        let size: Int
        let vectors: [String: [Float]]?
        let payload: JSON
    }

    private static func prepare(
        _ url: URL, mtime: Int, size: Int, root: URL,
        models: [EmbeddingModel], geocoder: GeocodeCache,
        isKnown: @Sendable (String) -> Bool
    ) async throws -> Prepared? {
        let id = try contentID(url)
        let path = url.standardizedFileURL.path

        var payload: JSON = ["path": path, "mtime": mtime, "size": size]
        let meta = await MetadataReader.read(url)
        if let date = meta.date {
            let cal = Calendar(identifier: .gregorian)
            payload["taken"] = Int(date.timeIntervalSince1970)
            payload["year"] = cal.component(.year, from: date)
            payload["month"] = cal.component(.month, from: date)
            // Wall-clock hour the photo was taken, for "sunrise", "night", etc.
            payload["hour"] = Calendar.current.component(.hour, from: date)
        }
        var place = Place()
        if let lat = meta.latitude, let lon = meta.longitude {
            place = await geocoder.place(for: lat, lon) ?? Place()
        }
        if place.country == nil { place.country = countryFromFolder(url, root: root) }
        if let country = place.country { payload["country"] = country }
        if let city = place.city { payload["city"] = city }

        // Already embedded under another path: only the payload changes.
        if isKnown(id) {
            if !FileManager.default.fileExists(atPath: thumbnailURL(id).path),
               let thumb = thumbnail(url) {
                saveThumbnail(thumb, id: id)
            }
            return Prepared(id: id, path: path, mtime: mtime, size: size, vectors: nil, payload: payload)
        }

        guard let thumb = thumbnail(url) else { return nil }
        saveThumbnail(thumb, id: id)
        payload["width"] = thumb.width
        payload["height"] = thumb.height
        payload["labels"] = sceneLabels(thumb)
        var vectors: [String: [Float]] = [:]
        for model in models { vectors[model.id] = try model.embed(image: thumb) }
        return Prepared(id: id, path: path, mtime: mtime, size: size, vectors: vectors, payload: payload)
    }

    /// Photos that PhotoSorter placed under `<year>/<MM - Month>/<Country>/`
    /// keep their country in the folder name even when the file itself has
    /// no GPS, so use that as a fallback.
    static func countryFromFolder(_ url: URL, root: URL) -> String? {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= rootParts.count + 4, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        let rel = Array(parts.dropFirst(rootParts.count))
        let isYear = rel[0].count == 4 && Int(rel[0]) != nil
        let isMonth = rel[1].range(of: #"^\d{2} - "#, options: .regularExpression) != nil
        let country = rel[2]
        guard isYear, isMonth, country != Sorter.unknownLocation else { return nil }
        return country
    }

    /// SHA-256 of the file contents, shaped as a UUID for Qdrant.
    static func contentID(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // mark as a name-based (v5-style) UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = NSUUID(uuidBytes: bytes)
        return uuid.uuidString.lowercased()
    }

    static func thumbnailURL(_ id: String) -> URL {
        AppPaths.thumbnails.appendingPathComponent("\(id).jpg")
    }

    /// Orientation-corrected, 512px-max thumbnail.
    static func thumbnail(_ url: URL, maxPixels: Int = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func saveThumbnail(_ image: CGImage, id: String) {
        let url = thumbnailURL(id)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// On-device scene labels from Apple's Vision classifier (e.g. "art",
    /// "painting", "stained glass"). Vision's confidences run low, so a modest
    /// threshold keeps useful labels without much noise; they only nudge
    /// ranking, never decide it.
    private static func sceneLabels(_ image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence >= 0.25 }
            .prefix(12)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() }
    }

    private static func fileStamp(_ url: URL) -> (Int, Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return (Int(mtime.timeIntervalSince1970), size)
    }
}
