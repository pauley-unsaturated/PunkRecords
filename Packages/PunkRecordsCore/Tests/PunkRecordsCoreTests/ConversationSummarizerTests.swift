import Testing
import Foundation
@testable import PunkRecordsCore

/// Unit tests for ``ConversationSummarizer``'s pure decisions — prompt
/// construction, default-title derivation, destination-path derivation, and the
/// "is there anything to summarize?" gate — lifted out of the App controller so
/// they're testable without the LLM, the actor, or the filesystem.
@Suite("ConversationSummarizer pure logic")
struct ConversationSummarizerTests {

    // MARK: - hasSummarizableContent

    @Test("Empty transcript is not summarizable")
    func emptyIsNotSummarizable() {
        #expect(!ConversationSummarizer.hasSummarizableContent([]))
    }

    @Test("A user + assistant exchange is summarizable")
    func exchangeIsSummarizable() {
        let messages = [
            ChatMessage(role: .user, content: "How do actors work?"),
            ChatMessage(role: .assistant, content: "They serialize access to state."),
        ]
        #expect(ConversationSummarizer.hasSummarizableContent(messages))
    }

    @Test("Tool-only or blank messages are not summarizable")
    func toolOnlyIsNotSummarizable() {
        let toolOnly = [
            ChatMessage(role: .tool, content: "[tool]"),
            ChatMessage(role: .assistant, content: "   \n  "),
        ]
        #expect(!ConversationSummarizer.hasSummarizableContent(toolOnly))
    }

    @Test("A single non-empty user message is enough")
    func singleUserMessageIsSummarizable() {
        #expect(ConversationSummarizer.hasSummarizableContent([
            ChatMessage(role: .user, content: "Just one line."),
        ]))
    }

    // MARK: - summarizationPrompt

    @Test("Prompt embeds the transcript, the title, and the faithfulness guardrails")
    func promptShape() {
        let transcript = "# My Chat\nUser: hi\nAssistant: hello"
        let prompt = ConversationSummarizer.summarizationPrompt(
            transcript: transcript,
            threadTitle: "My Chat"
        )
        #expect(prompt.contains(transcript))
        #expect(prompt.contains("Conversation title: My Chat"))
        #expect(prompt.contains("## Topic"))
        #expect(prompt.contains("## Key Points"))
        #expect(prompt.contains("## Decisions & Outcomes"))
        #expect(prompt.contains("## Open Questions"))
        #expect(prompt.contains("Do NOT invent"))
        // The App wraps the body under its own H1 / frontmatter, so the model
        // must not emit either.
        #expect(prompt.contains("Do NOT include a top-level"))
    }

    @Test("A blank thread title omits the title line but still prompts")
    func promptWithoutTitle() {
        let prompt = ConversationSummarizer.summarizationPrompt(
            transcript: "User: hi",
            threadTitle: "   "
        )
        #expect(!prompt.contains("Conversation title:"))
        #expect(prompt.contains("User: hi"))
    }

    // MARK: - defaultNoteTitle

    @Test("Default title prefixes the thread title with 'Summary — '")
    func defaultTitleFromThread() {
        #expect(
            ConversationSummarizer.defaultNoteTitle(forThreadTitle: "Actor reentrancy")
                == "Summary — Actor reentrancy"
        )
    }

    @Test("Default title collapses a placeholder/empty thread title to bare 'Summary'")
    func defaultTitleFallback() {
        #expect(ConversationSummarizer.defaultNoteTitle(forThreadTitle: "") == "Summary")
        #expect(ConversationSummarizer.defaultNoteTitle(forThreadTitle: "   ") == "Summary")
        #expect(
            ConversationSummarizer.defaultNoteTitle(forThreadTitle: ChatThreadHelpers.defaultTitle)
                == "Summary"
        )
    }

    // MARK: - destinationPath

    @Test("Destination path at the vault root is just the sanitized filename")
    func destinationAtRoot() {
        #expect(
            ConversationSummarizer.destinationPath(inFolder: "", title: "Summary — Chat")
                == "Summary — Chat.md"
        )
    }

    @Test("Destination path inside a folder keeps the folder prefix")
    func destinationInFolder() {
        #expect(
            ConversationSummarizer.destinationPath(inFolder: "Notes", title: "Summary — Chat")
                == "Notes/Summary — Chat.md"
        )
    }

    @Test("Destination path sanitizes filename-hostile characters in the title")
    func destinationSanitizes() {
        #expect(
            ConversationSummarizer.destinationPath(inFolder: "", title: "A/B: C?")
                == "A-B- C-.md"
        )
    }

    @Test("A blank title falls back to a stable 'Summary' filename")
    func destinationBlankTitle() {
        #expect(ConversationSummarizer.destinationPath(inFolder: "", title: "   ") == "Summary.md")
    }

    @Test("Trailing/leading slashes on the folder are normalized away")
    func destinationNormalizesFolder() {
        #expect(
            ConversationSummarizer.destinationPath(inFolder: "/Notes/", title: "X")
                == "Notes/X.md"
        )
    }
}
