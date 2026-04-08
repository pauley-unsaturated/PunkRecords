import SwiftUI
import PunkRecordsCore

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search vault...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { Task { await performSearch() } }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            if results.isEmpty && !query.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
            } else {
                List(results, id: \.documentID) { result in
                    Button {
                        appState.selectedDocumentID = result.documentID
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                                .font(.headline)
                            Text(result.excerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onChange(of: query) {
            Task { await performSearch() }
        }
    }

    private func performSearch() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        guard let index = appState.searchIndex else { return }
        do {
            results = try await index.search(query: query)
        } catch {
            results = []
        }
    }
}

#Preview("Search View") {
    SearchView()
        .environment(PreviewData.makePreviewAppState())
}
