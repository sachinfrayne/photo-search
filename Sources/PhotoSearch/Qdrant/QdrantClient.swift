import Foundation

typealias JSON = [String: Any]

/// Thin REST client for the handful of Qdrant endpoints PhotoSearch uses.
/// Requests and responses are plain JSON dictionaries, which keeps the
/// query-building code close to Qdrant's documented request bodies.
final class QdrantClient: @unchecked Sendable {
    struct APIError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "Qdrant returned \(status): \(body)" }
    }

    struct Point {
        let id: String
        let score: Double
        let payload: JSON
        /// Named vectors, when requested with `with_vector`.
        var vectors: [String: [Float]] = [:]
    }

    private let process: QdrantProcess
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    init(process: QdrantProcess) {
        self.process = process
    }

    // MARK: - Collections

    func collectionExists(_ name: String) async throws -> Bool {
        let r = try await call("GET", "/collections/\(name)/exists")
        return (r["result"] as? JSON)?["exists"] as? Bool ?? false
    }

    /// One named cosine vector per entry, e.g. ["mobileclip-s2": 512].
    func createCollection(_ name: String, vectors: [String: Int]) async throws {
        _ = try await call("PUT", "/collections/\(name)", [
            "vectors": vectors.mapValues { ["size": $0, "distance": "Cosine"] },
        ])
    }

    func deleteCollection(_ name: String) async throws {
        _ = try await call("DELETE", "/collections/\(name)")
    }

    func createIndex(_ collection: String, field: String, schema: String) async throws {
        _ = try await call("PUT", "/collections/\(collection)/index?wait=true", [
            "field_name": field, "field_schema": schema,
        ])
    }

    func count(_ collection: String) async throws -> Int {
        let r = try await call("POST", "/collections/\(collection)/points/count", ["exact": true])
        return (r["result"] as? JSON)?["count"] as? Int ?? 0
    }

    // MARK: - Points

    func upsert(_ collection: String, points: [JSON]) async throws {
        guard !points.isEmpty else { return }
        _ = try await call("PUT", "/collections/\(collection)/points?wait=true", ["points": points])
    }

    func setPayload(_ collection: String, id: String, payload: JSON) async throws {
        _ = try await call("POST", "/collections/\(collection)/points/payload?wait=true", [
            "payload": payload, "points": [id],
        ])
    }

    func delete(_ collection: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await call("POST", "/collections/\(collection)/points/delete?wait=true", ["points": ids])
    }

    /// Every point's payload (no vectors), paging through the whole collection.
    func scrollAll(_ collection: String, fields: [String]? = nil) async throws -> [Point] {
        var out: [Point] = []
        var offset: Any? = nil
        repeat {
            var body: JSON = ["limit": 1000, "with_vector": false]
            body["with_payload"] = fields.map { $0 as Any } ?? true
            if let offset { body["offset"] = offset }
            let r = try await call("POST", "/collections/\(collection)/points/scroll", body)
            let result = r["result"] as? JSON ?? [:]
            out += Self.points(result["points"])
            offset = result["next_page_offset"].flatMap { $0 is NSNull ? nil : $0 }
        } while offset != nil
        return out
    }

    /// Universal Query API (`/points/query`).
    func query(_ collection: String, body: JSON) async throws -> [Point] {
        let r = try await call("POST", "/collections/\(collection)/points/query", body)
        return Self.points((r["result"] as? JSON)?["points"])
    }

    /// Distinct values of a keyword field.
    func facet(_ collection: String, key: String, limit: Int = 500) async throws -> [String] {
        let r = try await call("POST", "/collections/\(collection)/facet", ["key": key, "limit": limit])
        let hits = (r["result"] as? JSON)?["hits"] as? [JSON] ?? []
        return hits.compactMap { $0["value"] as? String }
    }

    // MARK: - Plumbing

    private static func points(_ raw: Any?) -> [Point] {
        (raw as? [JSON] ?? []).map {
            Point(
                id: String(describing: $0["id"] ?? ""),
                score: ($0["score"] as? Double) ?? 0,
                payload: $0["payload"] as? JSON ?? [:],
                vectors: (($0["vector"] as? [String: Any]) ?? [:]).compactMapValues {
                    ($0 as? [NSNumber])?.map(\.floatValue)
                }
            )
        }
    }

    private func call(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: URL(string: process.baseURL.absoluteString + path)!)
        request.httpMethod = method
        request.setValue(process.apiKey, forHTTPHeaderField: "api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
    }
}
