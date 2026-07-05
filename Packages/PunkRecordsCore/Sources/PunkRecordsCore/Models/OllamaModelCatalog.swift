import Foundation

/// Stateless helpers for listing the models installed on a local Ollama
/// server, so the Settings UI can offer a picker instead of requiring the
/// user to hand-type finicky model names (`qwen3:latest`, …).
///
/// Ollama exposes `GET {baseURL}/api/tags`, which returns the locally pulled
/// models. Following the ``ProviderRegistry`` / `JinaReader` idiom, this type
/// owns the pure parts — endpoint construction, response parsing, and picker
/// option assembly — while the actual GET lives in Infra
/// (`OllamaModelListClient`) so this stays Core-legal and unit-testable
/// without network.
public enum OllamaModelCatalog {

    /// The `GET` endpoint listing installed models on the server at `baseURL`.
    /// Tolerates a trailing slash on the stored base URL.
    public static func tagsEndpoint(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api/tags")
    }

    /// Errors from ``models(fromTagsResponse:)``.
    public enum ParseError: Error, Equatable {
        /// The body was not the expected `{"models": [...]}` JSON shape.
        case malformedResponse
    }

    /// Parse an `/api/tags` response body into installed model names, deduped
    /// and sorted case-insensitively. Names are kept verbatim (including tag
    /// suffixes like `:latest`) — Ollama accepts them exactly as listed, which
    /// is the whole point of not retyping them.
    public static func models(fromTagsResponse data: Data) throws -> [String] {
        guard let response = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            throw ParseError.malformedResponse
        }
        let names = response.models.compactMap { $0.name ?? $0.model }
        var seen = Set<String>()
        return names
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Options for the Settings model picker: the installed models plus the
    /// currently stored selection injected if absent (server down mid-session,
    /// or a model the user pulled elsewhere / not yet pulled), so the picker
    /// never silently loses the persisted value. Blank stored values are
    /// ignored. Result keeps the installed sort order with an injected stored
    /// value merged into place.
    public static func pickerOptions(installed: [String], stored: String) -> [String] {
        guard !stored.isEmpty, !installed.contains(stored) else { return installed }
        return (installed + [stored])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Wire format

    /// `/api/tags` body: `{"models":[{"name":"qwen3:latest","model":...},…]}`.
    /// `name` is the canonical field; older servers populate `model` only.
    private struct TagsResponse: Decodable {
        let models: [Entry]

        struct Entry: Decodable {
            let name: String?
            let model: String?
        }
    }
}
