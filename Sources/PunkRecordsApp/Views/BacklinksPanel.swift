import SwiftUI
import PunkRecordsCore

struct BacklinksPanel: View {
    let documentID: DocumentID
    @Environment(AppState.self) private var appState
    @State private var backlinks: [Document] = []

    /// Combines the displayed doc with AppState's change tick so the panel
    /// re-queries whenever *any* document mutates — picking up new links
    /// to this doc, removed links, and deletions of linking docs without
    /// requiring the user to navigate away and back.
    private struct RefreshKey: Hashable {
        let documentID: DocumentID
        let tick: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Backlinks", systemImage: "link")
                    .font(.headline)
                Spacer()
                if !backlinks.isEmpty {
                    Text("\(backlinks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("backlinksCount")
                }
            }
            .padding(.horizontal)

            if backlinks.isEmpty {
                Text("No notes link to this document")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal)
            } else {
                List(backlinks) { doc in
                    Button {
                        appState.selectedDocumentPath = doc.path
                    } label: {
                        Label(doc.title, systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .task(id: RefreshKey(documentID: documentID, tick: appState.vaultChangeTick)) {
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
