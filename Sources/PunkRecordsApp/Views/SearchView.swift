import SwiftUI
import PunkRecordsCore

/// ⌘⇧F vault-wide search — full-text search over the SAME `SearchService` the
/// agent's `vault_search` tool uses, so the query syntax (free text, `tag:`,
/// `title:`, and combinations) is identical. As-you-type with a short debounce,
/// keyboard-driven, opens the selected note in the active editor pane.
///
/// All non-trivial logic (snippet highlighting, display mapping, list
/// navigation) lives in the pure, unit-tested `VaultSearchDisplay` / `SearchSnippet`
/// in Core; this view is a thin shell. Visual polish is validated manually.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var items: [SearchResultDisplayItem] = []
    @State private var selectedIndex = 0
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// As-you-type debounce. Long enough to coalesce fast typing into one query,
    /// short enough to feel live.
    private static let debounce = Duration.milliseconds(275)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 440, idealHeight: 480)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Header

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search vault…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit(openSelection)
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .accessibilityIdentifier("vaultSearchField")

            if isSearching {
                ProgressView().controlSize(.small)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .padding()
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            emptyState
        } else if items.isEmpty && !isSearching {
            noResultsState
        } else {
            resultsList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Search your vault", systemImage: "magnifyingglass")
        } description: {
            Text("Full-text search across every note. Filter with tag:swift or title:guide.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No results", systemImage: "magnifyingglass")
        } description: {
            Text("No notes match “\(trimmedQuery)”. Try broader terms, or filter with tag: or title:.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("^[\(items.count) result](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                List(Array(items.enumerated()), id: \.offset, selection: $selectedIndex) { idx, item in
                    SearchResultRow(item: item)
                        .tag(idx)
                        .id(idx)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = idx
                            openSelection()
                        }
                }
                .listStyle(.plain)
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Search

    /// Cancel any in-flight search and schedule a fresh one after the debounce.
    /// An empty query clears results immediately.
    private func scheduleSearch() {
        searchTask?.cancel()
        selectedIndex = 0

        guard !trimmedQuery.isEmpty else {
            items = []
            isSearching = false
            return
        }

        isSearching = true
        let pending = query
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            await runSearch(pending)
        }
    }

    private func runSearch(_ pending: String) async {
        guard let index = appState.searchIndex else {
            items = []
            isSearching = false
            return
        }
        let results = (try? await index.search(query: pending)) ?? []
        // Drop a stale response: the user typed on while this was in flight.
        guard !Task.isCancelled, pending == query else { return }
        items = VaultSearchDisplay.items(from: results)
        selectedIndex = VaultSearchDisplay.clampIndex(selectedIndex, count: items.count)
        isSearching = false
    }

    // MARK: - Navigation

    private func moveSelection(by delta: Int) {
        selectedIndex = VaultSearchDisplay.move(selection: selectedIndex, by: delta, count: items.count)
    }

    /// Open the selected note in the active editor pane. Navigates by path (the
    /// stable key), matching Quick Open. Scroll-to-first-match is not wired: the
    /// editor exposes no AppState-driven reveal hook, so this opens the note only.
    private func openSelection() {
        guard !items.isEmpty else { return }
        let idx = VaultSearchDisplay.clampIndex(selectedIndex, count: items.count)
        appState.selectedDocumentPath = items[idx].path
        dismiss()
    }
}

/// One result row: note title, dim folder path, and the FTS snippet with the
/// matched terms bolded. Segmentation/highlighting comes from the tested
/// `SearchResultDisplayItem.snippetSegments`.
private struct SearchResultRow: View {
    let item: SearchResultDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(item.folder)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if item.hasSnippet {
                snippetText
                    .font(.callout)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var snippetText: Text {
        var text = Text("")
        for segment in item.snippetSegments {
            let piece = Text(segment.text)
            // SwiftUI.Text supports only `+`, not `+=`.
            // swiftlint:disable:next shorthand_operator
            text = text + (segment.isHighlighted
                ? piece.bold().foregroundColor(.primary)
                : piece.foregroundColor(.secondary))
        }
        return text
    }
}

#Preview("Search View") {
    SearchView()
        .environment(PreviewData.makePreviewAppState())
}
