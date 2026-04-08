import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

@MainActor
@Observable
final class DocumentEditorViewModel {
    var document: Document
    var isDirty = false
    var selectionRange: NSRange?
    var isSaving = false

    private let repository: FileSystemDocumentRepository
    private let searchIndex: SQLiteSearchIndex?

    init(
        document: Document,
        repository: FileSystemDocumentRepository,
        searchIndex: SQLiteSearchIndex?
    ) {
        self.document = document
        self.repository = repository
        self.searchIndex = searchIndex
    }

    func updateContent(_ newContent: String) {
        guard newContent != document.content else { return }
        document = Document(
            id: document.id,
            title: document.title,
            content: newContent,
            path: document.path,
            tags: document.tags,
            created: document.created,
            modified: Date(),
            frontmatter: document.frontmatter,
            linkedDocumentIDs: document.linkedDocumentIDs
        )
        isDirty = true
    }

    func save() async throws {
        guard isDirty else { return }
        isSaving = true
        defer { isSaving = false }

        try await repository.save(document)

        if let index = searchIndex {
            try await index.index(document: document)
        }

        isDirty = false
    }
}
