import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

/// Unit tests for AnyLanguageModelProvider's pure prompt-assembly logic.
/// Network/model calls (the Ollama-backed `LanguageModelSession`) are out of
/// scope — these exercise the static `buildPrompt` folding only.
@Suite("AnyLanguageModelProvider prompt assembly")
struct AnyLanguageModelProviderTests {

    @Test("Bare user prompt passes through unchanged")
    func userPromptOnly() {
        let request = LLMRequest(userPrompt: "What is a wikilink?")
        #expect(AnyLanguageModelProvider.buildPrompt(request) == "What is a wikilink?")
    }

    @Test("System prompt is prepended, separated by a blank line")
    func systemThenUser() {
        let request = LLMRequest(userPrompt: "Summarize.", systemPrompt: "You are terse.")
        #expect(AnyLanguageModelProvider.buildPrompt(request) == "You are terse.\n\nSummarize.")
    }

    @Test("Selected text is surfaced between system and user prompt")
    func systemSelectedUser() {
        let request = LLMRequest(
            userPrompt: "Rewrite it.",
            systemPrompt: "You are terse.",
            selectedText: "the quick brown fox"
        )
        #expect(AnyLanguageModelProvider.buildPrompt(request)
            == "You are terse.\n\nSelected text: the quick brown fox\n\nRewrite it.")
    }

    @Test("Empty system prompt is dropped rather than adding blank separators")
    func emptySystemDropped() {
        let request = LLMRequest(userPrompt: "Hello", systemPrompt: "")
        #expect(AnyLanguageModelProvider.buildPrompt(request) == "Hello")
    }

    @Test("Empty selected text is dropped")
    func emptySelectedDropped() {
        let request = LLMRequest(userPrompt: "Hello", selectedText: "")
        #expect(AnyLanguageModelProvider.buildPrompt(request) == "Hello")
    }
}
