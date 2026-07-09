import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("SmartNoteFile")
struct SmartNoteFileTests {

    @Test("serialize → parse reproduces the identical smart note")
    func fileRoundTrip() throws {
        let note = SmartNote(
            name: "My Backlog",
            query: SmartNoteQuery(root: .and([
                .comparison(.init(.scheduled, .lessThanOrEqualTo, .date(.today))),
                .not(.comparison(.init(.status, .equalTo, .status(.done)))),
                .comparison(.init(.tag, .contains, .text("project")))
            ]))
        )
        let file = try SmartNoteFile.serialize(note)
        let parsed = try SmartNoteFile.parse(file)
        #expect(parsed == note)
    }

    @Test("Serialized file carries a human-readable body description")
    func fileHasDescription() throws {
        let note = SmartNote(
            name: "Today",
            query: SmartNoteBuiltins.today.query
        )
        let file = try SmartNoteFile.serialize(note)
        #expect(file.contains("smartnote: 1"))
        #expect(file.contains("name: Today"))
        #expect(file.contains("scheduled is on or before today"))
        #expect(file.contains("status is not done"))
    }

    @Test("parse rejects a file with an unsupported version")
    func rejectsUnsupportedVersion() {
        let content = """
        ---
        smartnote: 999
        name: Future
        query: {"root":{"comparison":{"field":"tag","op":"exists","value":{"kind":"empty"}},"type":"comparison"},"version":999}
        ---

        future
        """
        #expect(throws: SmartNoteFileError.unsupportedVersion(999)) {
            _ = try SmartNoteFile.parse(content)
        }
    }

    @Test("parse rejects a non-smart-note markdown file")
    func rejectsPlainNote() {
        let content = "---\nid: 1\ntitle: Regular\n---\n\n# Regular note"
        #expect(throws: SmartNoteFileError.notASmartNote) {
            _ = try SmartNoteFile.parse(content)
        }
    }

    @Test("isSmartNotePath recognizes the Smart Notes directory")
    func smartNotePath() {
        #expect(SmartNoteFile.isSmartNotePath("Smart Notes/Today.md"))
        #expect(SmartNoteFile.isSmartNotePath("Daily/2026-07-07.md") == false)
        #expect(VaultPaths.smartNotePath(forName: "Today") == "Smart Notes/Today.md")
    }

    @Test("Description renders AND / OR / NOT phrasing")
    func descriptionRendering() {
        let query = SmartNoteQuery(root: .or([
            .comparison(.init(.path, .beginsWith, .text("Web/"))),
            .comparison(.init(.tag, .contains, .text("web")))
        ]))
        #expect(SmartNoteDescription.describe(query) == "path begins with “Web/” or tag contains “web”")

        let negated = SmartNoteQuery(root: .not(.comparison(.init(.status, .equalTo, .status(.done)))))
        #expect(SmartNoteDescription.describe(negated) == "not (status is done)")
    }
}
