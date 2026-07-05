import Foundation
import PunkRecordsCore

/// Fetches the models installed on a local Ollama server via
/// `GET {baseURL}/api/tags`, for the Settings model picker.
///
/// The transport is injectable so tests can assert the requested URL and feed
/// fixture bodies without network (same seam idea as `WebHTTPClient`). The
/// default transport uses a short timeout: the server is local, so anything
/// slower than a couple of seconds means "not running" and Settings should
/// fall back to manual entry promptly rather than hang.
public struct OllamaModelListClient: Sendable {

    public typealias Transport = @Sendable (URL) async throws -> Data

    private let transport: Transport

    public init(transport: @escaping Transport = OllamaModelListClient.urlSessionTransport) {
        self.transport = transport
    }

    /// Installed model names on the server at `baseURL`, deduped and sorted
    /// (see ``OllamaModelCatalog/models(fromTagsResponse:)``).
    public func installedModels(baseURL: URL) async throws -> [String] {
        let data = try await transport(OllamaModelCatalog.tagsEndpoint(baseURL: baseURL))
        return try OllamaModelCatalog.models(fromTagsResponse: data)
    }

    /// Default transport: plain GET with a 3s timeout, throwing on non-2xx.
    @Sendable public static func urlSessionTransport(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
