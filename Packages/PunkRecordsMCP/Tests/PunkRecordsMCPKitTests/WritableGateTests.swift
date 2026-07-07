import Testing
@testable import PunkRecordsMCPKit

@Suite("WritableGate — create_note read-only gating")
struct WritableGateTests {
    private let allToolNames = ["vault_search", "read_document", "list_documents", "create_note"]

    @Test("read-only mode hides create_note from the visible tool list")
    func hidesCreateNoteWhenReadOnly() {
        let visible = WritableGate.visibleToolNames(from: allToolNames, writable: false)
        #expect(!visible.contains("create_note"))
        #expect(visible.sorted() == ["list_documents", "read_document", "vault_search"])
    }

    @Test("writable mode shows all tools including create_note")
    func showsAllToolsWhenWritable() {
        let visible = WritableGate.visibleToolNames(from: allToolNames, writable: true)
        #expect(Set(visible) == Set(allToolNames))
    }

    @Test("read-only mode rejects a create_note call with an error ToolResult")
    func rejectsCreateNoteCallWhenReadOnly() {
        let rejection = WritableGate.rejection(forToolNamed: "create_note", writable: false)
        #expect(rejection != nil)
        #expect(rejection?.isError == true)
        #expect(rejection?.content.contains("--writable") == true)
    }

    @Test("writable mode does not reject a create_note call")
    func allowsCreateNoteCallWhenWritable() {
        #expect(WritableGate.rejection(forToolNamed: "create_note", writable: true) == nil)
    }

    @Test("read-only tools are never rejected regardless of writable")
    func readOnlyToolsNeverRejected() {
        for name in ["vault_search", "read_document", "list_documents"] {
            #expect(WritableGate.rejection(forToolNamed: name, writable: false) == nil)
            #expect(WritableGate.rejection(forToolNamed: name, writable: true) == nil)
        }
    }
}
