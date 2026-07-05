import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("OllamaModelCatalog — /api/tags parsing + picker options")
struct OllamaModelCatalogTests {

    // MARK: - Endpoint

    @Test("tags endpoint appends api/tags to the base URL")
    func tagsEndpoint() {
        let url = OllamaModelCatalog.tagsEndpoint(baseURL: URL(string: "http://localhost:11434")!)
        #expect(url.absoluteString == "http://localhost:11434/api/tags")
    }

    @Test("tags endpoint tolerates a trailing slash on the base URL")
    func tagsEndpointTrailingSlash() {
        let url = OllamaModelCatalog.tagsEndpoint(baseURL: URL(string: "http://192.168.1.5:11434/")!)
        #expect(url.absoluteString == "http://192.168.1.5:11434/api/tags")
    }

    // MARK: - Parsing

    private let realShapeBody = Data("""
    {"models":[
      {"name":"qwen3:latest","model":"qwen3:latest","modified_at":"2026-06-01T10:00:00Z",
       "size":5200000000,"digest":"abc","details":{"family":"qwen3","parameter_size":"8B"}},
      {"name":"gemma4:27b","model":"gemma4:27b","size":16000000000},
      {"name":"Llama3.2:latest","model":"Llama3.2:latest","size":2000000000}
    ]}
    """.utf8)

    @Test("parses model names verbatim from a real-shaped response, sorted case-insensitively")
    func parsesRealShape() throws {
        let models = try OllamaModelCatalog.models(fromTagsResponse: realShapeBody)
        #expect(models == ["gemma4:27b", "Llama3.2:latest", "qwen3:latest"])
    }

    @Test("falls back to the model field when name is missing")
    func modelFieldFallback() throws {
        let body = Data(#"{"models":[{"model":"qwen3:latest"}]}"#.utf8)
        #expect(try OllamaModelCatalog.models(fromTagsResponse: body) == ["qwen3:latest"])
    }

    @Test("dedupes repeated names and drops empties")
    func dedupesAndDropsEmpties() throws {
        let body = Data(#"{"models":[{"name":"a"},{"name":"a"},{"name":""},{"name":"b"}]}"#.utf8)
        #expect(try OllamaModelCatalog.models(fromTagsResponse: body) == ["a", "b"])
    }

    @Test("empty models array parses to an empty list")
    func emptyList() throws {
        let body = Data(#"{"models":[]}"#.utf8)
        #expect(try OllamaModelCatalog.models(fromTagsResponse: body) == [])
    }

    @Test("malformed JSON throws malformedResponse")
    func malformedJSON() {
        let body = Data("ollama is not running".utf8)
        #expect(throws: OllamaModelCatalog.ParseError.malformedResponse) {
            try OllamaModelCatalog.models(fromTagsResponse: body)
        }
    }

    @Test("valid JSON of the wrong shape throws malformedResponse")
    func wrongShape() {
        let body = Data(#"{"tags":["qwen3"]}"#.utf8)
        #expect(throws: OllamaModelCatalog.ParseError.malformedResponse) {
            try OllamaModelCatalog.models(fromTagsResponse: body)
        }
    }

    // MARK: - Picker options

    @Test("picker options pass installed through when the stored model is present")
    func optionsStoredPresent() {
        let options = OllamaModelCatalog.pickerOptions(installed: ["a", "b"], stored: "b")
        #expect(options == ["a", "b"])
    }

    @Test("picker options inject a stored model the server doesn't list, keeping sort order")
    func optionsInjectStored() {
        let options = OllamaModelCatalog.pickerOptions(installed: ["alpha", "gamma"], stored: "Beta")
        #expect(options == ["alpha", "Beta", "gamma"])
    }

    @Test("picker options ignore a blank stored value")
    func optionsBlankStored() {
        let options = OllamaModelCatalog.pickerOptions(installed: ["a"], stored: "")
        #expect(options == ["a"])
    }
}
