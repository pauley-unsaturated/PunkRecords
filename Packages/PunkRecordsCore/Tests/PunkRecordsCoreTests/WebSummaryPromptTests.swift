import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebSummaryPrompt — builds the structured-JSON summarization prompt")
struct WebSummaryPromptTests {

    private func sampleContent() -> WebContent {
        WebContent(
            title: "The Article Title",
            byline: "Jane Doe",
            contentMarkdown: "Body paragraph one. Body paragraph two.",
            headings: [
                WebHeading(level: 1, text: "Intro", anchorID: "intro"),
                WebHeading(level: 2, text: "Details", anchorID: "details")
            ],
            extractedAt: Date(timeIntervalSince1970: 0),
            tier: .readability,
            sourceURL: URL(string: "https://example.com/article")!,
            canonicalURL: nil
        )
    }

    @Test("promptVersion is a stable, non-empty identifier")
    func promptVersionIsStable() {
        #expect(WebSummaryPrompt.promptVersion == "web-summary-v1")
    }

    @Test("Includes the article title, byline, source URL, and body")
    func includesArticleMetadata() {
        let prompt = WebSummaryPrompt.build(content: sampleContent())
        #expect(prompt.contains("The Article Title"))
        #expect(prompt.contains("Jane Doe"))
        #expect(prompt.contains("https://example.com/article"))
        #expect(prompt.contains("Body paragraph one. Body paragraph two."))
    }

    @Test("Lists heading anchor ids so the model can cite a real anchor")
    func listsHeadingAnchors() {
        let prompt = WebSummaryPrompt.build(content: sampleContent())
        #expect(prompt.contains("intro: Intro"))
        #expect(prompt.contains("details: Details"))
    }

    @Test("States the key_points and quotes count bounds and JSON schema keys")
    func statesSchemaAndBounds() {
        let prompt = WebSummaryPrompt.build(content: sampleContent())
        #expect(prompt.contains("\"tldr\""))
        #expect(prompt.contains("\"key_points\""))
        #expect(prompt.contains("\"citation_index\""))
        #expect(prompt.contains("\"supporting_text\""))
        #expect(prompt.contains("\"nearest_heading_anchor\""))
        #expect(prompt.contains("\"quotes\""))
        #expect(prompt.contains("\"why_it_matters\""))
        #expect(prompt.contains("5-9"))
        #expect(prompt.contains("2-4"))
        #expect(prompt.contains("max 30 words"))
    }

    @Test("Instructs the model to output only JSON with no surrounding text or fences")
    func instructsRawJSONOnly() {
        let prompt = WebSummaryPrompt.build(content: sampleContent())
        #expect(prompt.lowercased().contains("output only the json"))
        #expect(prompt.lowercased().contains("no code fences"))
    }

    @Test("Renders an empty page with no headings without crashing and notes 'none'")
    func handlesNoHeadings() {
        let content = WebContent(
            title: "No Headings",
            byline: nil,
            contentMarkdown: "Just text.",
            headings: [],
            extractedAt: Date(timeIntervalSince1970: 0),
            tier: .readability,
            sourceURL: URL(string: "https://example.com/plain")!,
            canonicalURL: nil
        )
        let prompt = WebSummaryPrompt.build(content: content)
        #expect(prompt.contains("(none)"))
        #expect(!prompt.contains("By ")) // no byline line when byline is nil
    }
}
