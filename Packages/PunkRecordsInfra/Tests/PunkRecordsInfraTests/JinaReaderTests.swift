import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

@Suite("JinaReader — Tier 3 endpoint + response parsing")
struct JinaReaderTests {

    private let sourceURL = URL(string: "https://example.com/page?x=1")!

    @Test("Endpoint appends the full target URL after r.jina.ai")
    func endpoint() {
        #expect(JinaReader.endpoint(for: sourceURL).absoluteString
            == "https://r.jina.ai/https://example.com/page?x=1")
    }

    @Test("Parses Jina's header block into title + markdown body")
    func parseWithHeader() {
        let body = """
        Title: Example Page
        URL Source: https://example.com/page
        Markdown Content:
        # Example Page

        First paragraph.

        ## Section

        Second paragraph.
        """
        let article = JinaReader.parse(body, sourceURL: sourceURL)
        #expect(article.title == "Example Page")
        #expect(article.contentMarkdown.hasPrefix("# Example Page"))
        #expect(!article.contentMarkdown.contains("URL Source:"))
        #expect(article.rawHeadings.map(\.text) == ["Example Page", "Section"])
    }

    @Test("Without a header block, the whole response is the markdown body")
    func parseWithoutHeader() {
        let body = "# Bare Markdown\n\nJust content, no Jina header."
        let article = JinaReader.parse(body, sourceURL: sourceURL)
        #expect(article.contentMarkdown == body)
        #expect(article.title == "Bare Markdown")
    }

    @Test("Falls back to the host when there is no title or heading")
    func titleFallsBackToHost() {
        let article = JinaReader.parse("Just a line of prose with no heading.", sourceURL: sourceURL)
        #expect(article.title == "example.com")
    }
}

@Suite("WebKitReadabilityExtractor — pure JS-bridge helpers")
struct WebKitReadabilityExtractorHelperTests {

    @Test("Decodes the JSON the injected script returns")
    func decode() throws {
        let json = #"{"title":"T","byline":"B","content":"<p>Hi</p>","textContent":"Hi"}"#
        let result = try WebKitReadabilityExtractor.decode(json)
        #expect(result == ReadabilityResult(title: "T", byline: "B", contentHTML: "<p>Hi</p>", textContent: "Hi"))
    }

    @Test("Missing optional fields decode to empty/nil")
    func decodePartial() throws {
        let result = try WebKitReadabilityExtractor.decode(#"{"content":"<p>x</p>"}"#)
        #expect(result.title == nil)
        #expect(result.contentHTML == "<p>x</p>")
        #expect(result.textContent == "")
    }

    @Test("Malformed JSON throws a transport error")
    func decodeMalformed() {
        #expect(throws: WebFetchError.self) {
            _ = try WebKitReadabilityExtractor.decode("not json")
        }
    }

    @Test("Injected script embeds the vendored source and calls Readability")
    func parseScript() {
        let script = WebKitReadabilityExtractor.parseScript(readabilitySource: "/*READABILITY_SOURCE*/")
        #expect(script.contains("/*READABILITY_SOURCE*/"))
        #expect(script.contains("new Readability"))
        #expect(script.contains("JSON.stringify"))
    }

    @Test("The vendored Readability.js resource is present in the bundle")
    func resourcePresent() throws {
        let source = try WebKitReadabilityExtractor.readabilityScript()
        #expect(source.contains("function Readability"))
        #expect(source.contains("Apache License"))
    }
}
