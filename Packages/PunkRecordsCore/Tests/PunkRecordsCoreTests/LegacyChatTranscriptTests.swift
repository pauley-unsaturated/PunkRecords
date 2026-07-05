import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("Legacy chat transcript parse/render")
struct LegacyChatTranscriptTests {

    @Test("Render then parse preserves user/assistant rows and content")
    func renderParseRoundTrip() throws {
        let messages = [
            ChatMessage(role: .user, content: "What's in my vault?"),
            ChatMessage(role: .assistant, content: "Several notes about DSP."),
        ]
        let text = try LegacyChatTranscript.render(messages)
        #expect(text.contains(LegacyChatTranscript.marker))

        let parsed = try LegacyChatTranscript.parse(text)
        #expect(parsed.count == 2)
        #expect(parsed[0].role == .user)
        #expect(parsed[0].content == "What's in my vault?")
        #expect(parsed[1].role == .assistant)
        #expect(parsed[1].content == "Several notes about DSP.")
    }

    @Test("Tool rows are not part of the legacy format and are dropped on render")
    func toolRowsDropped() throws {
        let messages = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .tool, content: "", toolCall: ToolCallInfo(name: "vault_search", arguments: "{}")),
            ChatMessage(role: .assistant, content: "hello"),
        ]
        let parsed = try LegacyChatTranscript.parse(LegacyChatTranscript.render(messages))
        #expect(parsed.map(\.role) == [.user, .assistant])
    }

    @Test("Empty text parses to no messages")
    func emptyParses() throws {
        #expect(try LegacyChatTranscript.parse("").isEmpty)
        #expect(try LegacyChatTranscript.parse(LegacyChatTranscript.marker + "\n").isEmpty)
    }
}
