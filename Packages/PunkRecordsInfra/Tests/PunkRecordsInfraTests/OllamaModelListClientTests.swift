import Foundation
import Testing
@testable import PunkRecordsInfra
import PunkRecordsCore

@Suite("OllamaModelListClient — transport seam")
struct OllamaModelListClientTests {

    @Test("requests {base}/api/tags and returns parsed, sorted names")
    func requestsTagsEndpoint() async throws {
        let requested = Mutex<[URL]>([])
        let client = OllamaModelListClient { url in
            requested.withLock { $0.append(url) }
            return Data(#"{"models":[{"name":"qwen3:latest"},{"name":"gemma4:27b"}]}"#.utf8)
        }

        let models = try await client.installedModels(baseURL: URL(string: "http://localhost:11434")!)

        #expect(models == ["gemma4:27b", "qwen3:latest"])
        #expect(requested.withLock { $0 } == [URL(string: "http://localhost:11434/api/tags")!])
    }

    @Test("transport errors propagate (server down → caller falls back to manual entry)")
    func transportErrorPropagates() async {
        let client = OllamaModelListClient { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: URLError.self) {
            try await client.installedModels(baseURL: URL(string: "http://localhost:11434")!)
        }
    }

    @Test("malformed body surfaces the catalog parse error")
    func malformedBodyThrows() async {
        let client = OllamaModelListClient { _ in Data("<html>proxy error</html>".utf8) }
        await #expect(throws: OllamaModelCatalog.ParseError.malformedResponse) {
            try await client.installedModels(baseURL: URL(string: "http://localhost:11434")!)
        }
    }
}

/// Tiny lock box so the transport closure (@Sendable) can record requests.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
