import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("PropsBlock Tests")
struct PropsBlockTests {
    @Test("Serializes fields in stable order with the [!props] header")
    func serializesStableOrder() {
        let block = PropsBlock(
            tags: ["alpha", "beta"],
            status: .doing,
            scheduled: "2026-07-10",
            due: "2026-07-15",
            custom: [PropsField(key: "owner", value: "Mark")]
        )
        #expect(block.calloutText() == """
        > [!props]
        > tags:: alpha, beta
        > status:: doing
        > scheduled:: 2026-07-10
        > due:: 2026-07-15
        > owner:: Mark
        """)
    }

    @Test("Empty block serializes to nil")
    func emptyIsNil() {
        #expect(PropsBlock().calloutText() == nil)
        #expect(PropsBlock().isEmpty)
        #expect(PropsBlock(tags: ["", "   "], scheduled: "  ").isEmpty)
    }

    @Test("Round-trips through serialize → parse")
    func roundTrip() {
        let block = PropsBlock(
            tags: ["work", "urgent"],
            status: .done,
            scheduled: "2026-07-10 15:00",
            due: "2026-07-20",
            custom: [PropsField(key: "owner", value: "Mark"), PropsField(key: "estimate", value: "2h")]
        )
        let text = block.calloutText()!
        #expect(PropsBlock.parseCallout(text) == block)
    }

    @Test("Parse → serialize is idempotent")
    func idempotent() {
        let text = """
        > [!props]
        > tags:: a, b
        > status:: todo
        > owner:: Mark
        """
        let once = PropsBlock.parseCallout(text)
        let twice = PropsBlock.parseCallout(once.calloutText()!)
        #expect(once == twice)
        #expect(once.calloutText() == twice.calloutText())
    }

    @Test("All three statuses parse and serialize")
    func statuses() {
        for status in PropsStatus.allCases {
            let block = PropsBlock(status: status)
            let parsed = PropsBlock.parseCallout(block.calloutText()!)
            #expect(parsed.status == status)
        }
        // An unknown status word is dropped (no crash, nil status).
        #expect(PropsBlock.parseCallout("> [!props]\n> status:: blocked").status == nil)
    }

    @Test("Tags are comma-split, trimmed, lowercased, de-duplicated")
    func tagNormalization() {
        let parsed = PropsBlock.parseCallout("> [!props]\n> tags:: Alpha,  BETA , alpha")
        #expect(parsed.tags == ["alpha", "beta", "alpha"])   // parse keeps raw order/dupes
        // Serialization is where de-duplication + normalization is enforced.
        #expect(PropsBlock(tags: ["Alpha", "BETA", "alpha"]).calloutText()
            == "> [!props]\n> tags:: alpha, beta")
    }

    @Test("Parsing ignores the header line and lines without ::")
    func ignoresNoise() {
        let text = """
        > [!props]
        > this line has no separator
        > status:: doing
        plain text outside the quote
        """
        let parsed = PropsBlock.parseCallout(text)
        #expect(parsed.status == .doing)
        #expect(parsed.custom.isEmpty)
    }

    @Test("A custom key colliding with a reserved key is dropped on serialize")
    func reservedCollision() {
        let block = PropsBlock(status: .todo, custom: [PropsField(key: "status", value: "sneaky")])
        // Only the real status field survives; the shadow custom row is filtered.
        #expect(block.calloutText() == "> [!props]\n> status:: todo")
    }

    @Test("Values keep single colons, URLs, emoji, and CJK")
    func richValues() {
        let block = PropsBlock(
            scheduled: "2026-07-10 15:00",
            custom: [
                PropsField(key: "link", value: "https://example.com/x"),
                PropsField(key: "note", value: "会議 📅 at 3:00")
            ]
        )
        let parsed = PropsBlock.parseCallout(block.calloutText()!)
        #expect(parsed.scheduled == "2026-07-10 15:00")
        #expect(parsed.custom.first { $0.key == "link" }?.value == "https://example.com/x")
        #expect(parsed.custom.first { $0.key == "note" }?.value == "会議 📅 at 3:00")
    }

    @Test("Empty-value custom rows are dropped")
    func dropsEmptyCustom() {
        let block = PropsBlock(status: .doing, custom: [PropsField(key: "empty", value: "  ")])
        #expect(block.calloutText() == "> [!props]\n> status:: doing")
    }
}
