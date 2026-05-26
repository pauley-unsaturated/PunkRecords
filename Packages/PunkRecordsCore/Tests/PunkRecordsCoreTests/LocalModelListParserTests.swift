import XCTest
@testable import PunkRecordsCore

final class LocalModelListParserTests: XCTestCase {
    // MARK: - Ollama /api/tags

    func testParseOllamaTags() {
        let json = """
        {
          "models": [
            { "name": "llama3:8b", "model": "llama3:8b", "size": 4661224676 },
            { "name": "qwen2.5-coder:7b", "model": "qwen2.5-coder:7b", "size": 4683073184 }
          ]
        }
        """.data(using: .utf8)!

        let models = LocalModelListParser.parseOllamaTags(json)
        XCTAssertEqual(models.count, 2)
        // Sorted by id with natural ordering.
        XCTAssertEqual(models[0].id, "llama3:8b")
        XCTAssertEqual(models[0].sizeBytes, 4_661_224_676)
        XCTAssertEqual(models[1].id, "qwen2.5-coder:7b")
        XCTAssertEqual(models[0].displayName, "llama3:8b")
    }

    func testParseOllamaTagsEmptyOrMalformed() {
        XCTAssertTrue(LocalModelListParser.parseOllamaTags(Data()).isEmpty)
        XCTAssertTrue(LocalModelListParser.parseOllamaTags("{}".data(using: .utf8)!).isEmpty)
        XCTAssertTrue(LocalModelListParser.parseOllamaTags("not json".data(using: .utf8)!).isEmpty)
    }

    func testParseOllamaTagsSkipsNamelessEntries() {
        let json = """
        { "models": [ { "size": 123 }, { "name": "good:latest" } ] }
        """.data(using: .utf8)!
        let models = LocalModelListParser.parseOllamaTags(json)
        XCTAssertEqual(models.map(\.id), ["good:latest"])
    }

    // MARK: - OpenAI-compatible /v1/models

    func testParseOpenAIModels() {
        let json = """
        {
          "object": "list",
          "data": [
            { "id": "qwen2.5-7b-instruct", "object": "model" },
            { "id": "phi-4", "object": "model" }
          ]
        }
        """.data(using: .utf8)!

        let models = LocalModelListParser.parseOpenAIModels(json)
        XCTAssertEqual(models.map(\.id), ["phi-4", "qwen2.5-7b-instruct"]) // sorted
        XCTAssertNil(models[0].sizeBytes) // OpenAI list has no size
    }

    func testParseOpenAIModelsMalformed() {
        XCTAssertTrue(LocalModelListParser.parseOpenAIModels(Data()).isEmpty)
        XCTAssertTrue(LocalModelListParser.parseOpenAIModels("{}".data(using: .utf8)!).isEmpty)
    }
}
