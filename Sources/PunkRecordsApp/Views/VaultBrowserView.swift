import SwiftUI
import PunkRecordsCore

struct VaultBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var documents: [Document] = []
    @State private var expandedFolders: Set<String> = []

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedDocumentID) {
            if let vault = appState.currentVault {
                Section(vault.name) {
                    ForEach(groupedByFolder, id: \.folder) { group in
                        if group.folder.isEmpty {
                            ForEach(group.documents) { doc in
                                documentRow(doc)
                            }
                        } else {
                            DisclosureGroup(group.folder) {
                                ForEach(group.documents) { doc in
                                    documentRow(doc)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "plus") {
                    appState.createNewNote()
                }
            }
        }
        .task {
            await loadDocuments()
        }
        .refreshable {
            await loadDocuments()
        }
    }

    private func documentRow(_ doc: Document) -> some View {
        Label(doc.title, systemImage: "doc.text")
            .tag(doc.id)
    }

    private var groupedByFolder: [FolderGroup] {
        var groups: [String: [Document]] = [:]
        for doc in documents {
            let folder = (doc.path as NSString).deletingLastPathComponent
            groups[folder, default: []].append(doc)
        }
        return groups.map { FolderGroup(folder: $0.key, documents: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.folder < $1.folder }
    }

    private func loadDocuments() async {
        guard let repo = appState.repository else { return }
        do {
            documents = try await repo.allDocuments()
        } catch {
            appState.errorMessage = "Failed to load documents: \(error.localizedDescription)"
        }
    }
}

#Preview("Vault Browser") {
    VaultBrowserView()
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 250, height: 400)
}

private struct FolderGroup: Identifiable {
    let folder: String
    let documents: [Document]
    var id: String { folder }
}
