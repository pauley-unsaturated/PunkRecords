import SwiftUI
import PunkRecordsCore

struct BacklinksPanel: View {
    let documentID: DocumentID
    @Environment(AppState.self) private var appState
    @State private var backlinks: [Document] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Backlinks", systemImage: "link")
                .font(.headline)
                .padding(.horizontal)

            if backlinks.isEmpty {
                Text("No notes link to this document")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal)
            } else {
                List(backlinks) { doc in
                    Button {
                        appState.selectedDocumentID = doc.id
                    } label: {
                        Label(doc.title, systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .task(id: documentID) {
            await loadBacklinks()
        }
    }

}

#Preview("Backlinks — Empty") {
    BacklinksPanel(documentID: PreviewData.sampleDocumentID)
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 300, height: 200)
}

private extension BacklinksPanel {
    func loadBacklinks() async {
        guard let index = appState.searchIndex,
              let repo = appState.repository else { return }
        do {
            let ids = try await index.backlinks(for: documentID)
            var docs: [Document] = []
            for id in ids {
                if let doc = try await repo.document(withID: id) {
                    docs.append(doc)
                }
            }
            backlinks = docs
        } catch {
            backlinks = []
        }
    }
}
