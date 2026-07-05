import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebFetchTool — AgentTool over a WebContentFetcher")
struct WebFetchToolTests {

    /// A fetcher stub that returns a canned result or throws a canned error, and
    /// records the URL it was asked to fetch.
    final class StubFetcher: WebContentFetcher, @unchecked Sendable {
        var result: WebContent?
        var error: WebFetchError?
        private(set) var requestedURLs: [URL] = []

        init(result: WebContent? = nil, error: WebFetchError? = nil) {
            self.result = result
            self.error = error
        }

        func fetch(url: URL) async throws -> WebContent {
            requestedURLs.append(url)
            if let error { throw error }
            if let result { return result }
            throw WebFetchError.noReadableContent
        }
    }

    private func sampleContent(url: URL) -> WebContent {
        WebContent(
            title: "Sample Article",
            byline: "Jane Doe",
            contentMarkdown: "# Sample Article\n\nBody text here.",
            headings: [WebHeading(level: 1, text: "Sample Article", anchorID: "sample-article")],
            extractedAt: Date(timeIntervalSince1970: 0),
            tier: .readability,
            sourceURL: url,
            canonicalURL: nil
        )
    }

    @Test("Exposes the web_fetch tool with a url parameter")
    func schema() {
        let tool = WebFetchTool(fetcher: StubFetcher())
        #expect(tool.name == "web_fetch")
        #expect(tool.parameterSchema.required == ["url"])
        #expect(tool.parameterSchema.properties["url"] != nil)
    }

    @Test("Fetches the URL and formats title, byline, source, and body")
    func happyPath() async throws {
        let url = URL(string: "https://example.com/post")!
        let fetcher = StubFetcher(result: sampleContent(url: url))
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: ["url": "https://example.com/post"])
        #expect(!result.isError)
        #expect(fetcher.requestedURLs == [url])
        #expect(result.content.contains("# Sample Article"))
        #expect(result.content.contains("By Jane Doe"))
        #expect(result.content.contains("Source: https://example.com/post"))
        #expect(result.content.contains("Body text here."))
    }

    @Test("Rejects a missing url argument without calling the fetcher")
    func missingURL() async throws {
        let fetcher = StubFetcher()
        let tool = WebFetchTool(fetcher: fetcher)
        let result = try await tool.execute(arguments: [:])
        #expect(result.isError)
        #expect(fetcher.requestedURLs.isEmpty)
    }

    @Test("Rejects a non-http(s) URL without calling the fetcher")
    func rejectsNonHTTP() async throws {
        let fetcher = StubFetcher()
        let tool = WebFetchTool(fetcher: fetcher)
        let result = try await tool.execute(arguments: ["url": "file:///etc/passwd"])
        #expect(result.isError)
        #expect(fetcher.requestedURLs.isEmpty)
    }

    @Test("Surfaces a consent-required error as an actionable message")
    func consentError() async throws {
        let fetcher = StubFetcher(error: .jinaConsentRequired(domain: "example.com"))
        let tool = WebFetchTool(fetcher: fetcher)
        let result = try await tool.execute(arguments: ["url": "https://example.com/x"])
        #expect(result.isError)
        #expect(result.content.contains("example.com"))
        #expect(result.content.lowercased().contains("consent"))
    }

    @Test("Truncates very long content and notes the cached remainder")
    func truncation() {
        let url = URL(string: "https://example.com/long")!
        let long = String(repeating: "x", count: 500)
        let content = WebContent(
            title: "Long", byline: nil, contentMarkdown: long, headings: [],
            extractedAt: Date(timeIntervalSince1970: 0), tier: .readability,
            sourceURL: url, canonicalURL: nil
        )
        let formatted = WebFetchTool.format(content, maxContentCharacters: 100)
        #expect(formatted.contains("truncated"))
        #expect(formatted.count < 400)
    }
}
