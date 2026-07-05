import SwiftUI
import AppKit
import PunkRecordsCore

/// ⌘O Quick Open palette — fuzzy-matches the query against vault titles,
/// keyboard-driven, opens the selected note in the active editor pane.
struct QuickOpenView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open quickly…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(openSelection)
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .accessibilityIdentifier("quickOpenField")

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            .padding()

            Divider()

            if matches.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Try a different filename or substring.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(matches.enumerated()), id: \.offset, selection: $selectedIndex) { idx, match in
                        QuickOpenRow(match: match)
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
        .frame(minWidth: 540, minHeight: 360, idealHeight: 420)
        .onAppear {
            fieldFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
    }

    private var matches: [QuickOpenMatcher.Match] {
        QuickOpenMatcher.match(documents: appState.documents, query: query, limit: 50)
    }

    private func moveSelection(by delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        let next = max(0, min(count - 1, selectedIndex + delta))
        selectedIndex = next
    }

    private func openSelection() {
        guard !matches.isEmpty else { return }
        let idx = max(0, min(matches.count - 1, selectedIndex))
        let chosen = matches[idx].document
        appState.selectedDocumentPath = chosen.path
        dismiss()
    }
}

/// Single row: title with matched characters bolded, dim folder path.
private struct QuickOpenRow: View {
    let match: QuickOpenMatcher.Match

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            highlightedTitle
                .font(.headline)
                .lineLimit(1)
            Text(folderPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var folderPath: String {
        let folder = (match.document.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "/" : folder
    }

    private var highlightedTitle: Text {
        let title = match.document.title
        let chars = Array(title)
        let hits = Set(match.matchedIndices)
        var result = Text("")
        for (i, c) in chars.enumerated() {
            let piece = Text(String(c))
            // SwiftUI.Text has no += overload, only `+`, so this can't be shortened.
            // swiftlint:disable:next shorthand_operator
            result = result + (hits.contains(i) ? piece.bold().foregroundColor(.accentColor) : piece)
        }
        return result
    }
}

#Preview("Quick Open") {
    QuickOpenView()
        .environment(PreviewData.makePreviewAppState())
}
