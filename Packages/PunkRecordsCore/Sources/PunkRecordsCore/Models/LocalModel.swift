import Foundation

/// A model advertised by a local inference server, ready to be selected for use.
public struct LocalModel: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// The identifier sent in the request body's `model` field.
    public let id: String
    /// Human-facing label (defaults to `id`).
    public let displayName: String
    /// On-disk size in bytes, when the server reports it (Ollama does).
    public let sizeBytes: Int64?

    public init(id: String, displayName: String? = nil, sizeBytes: Int64? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.sizeBytes = sizeBytes
    }
}

/// Pure JSON → `[LocalModel]` decoders for the two local-server list endpoints.
/// Kept separate from the network actors so they're unit-testable against
/// fixture payloads with no I/O.
public enum LocalModelListParser {
    /// Parse Ollama's `GET /api/tags` payload:
    /// `{ "models": [ { "name": "llama3:8b", "model": "...", "size": 4661224676 } ] }`
    public static func parseOllamaTags(_ data: Data) -> [LocalModel] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return [] }

        let parsed: [LocalModel] = models.compactMap { entry in
            guard let name = entry["name"] as? String ?? entry["model"] as? String,
                  !name.isEmpty else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value
            return LocalModel(id: name, sizeBytes: size)
        }
        return sortedByID(parsed)
    }

    /// Parse an OpenAI-compatible `GET /v1/models` payload:
    /// `{ "data": [ { "id": "model-name", "object": "model" } ] }`
    public static func parseOpenAIModels(_ data: Data) -> [LocalModel] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = json["data"] as? [[String: Any]]
        else { return [] }

        let parsed: [LocalModel] = entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return LocalModel(id: id)
        }
        return sortedByID(parsed)
    }

    private static func sortedByID(_ models: [LocalModel]) -> [LocalModel] {
        models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
