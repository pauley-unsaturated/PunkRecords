import SwiftUI
import PunkRecordsCore

/// ⌘⇧M refile picker — fuzzy-matches the query against every `File ▸ Heading`
/// destination and moves the heading (with its subtree) on Enter. When the move
/// would change `[[Note#Heading]]` links, a dialog offers to update them.
struct RefileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var pendingTarget: RefileTarget?
    @State private var pendingLinkCount = 0
    @State private var showLinkDialog = false
    @FocusState private var fieldFocused: Bool

    private var targets: [RefileTarget] { appState.refileTargets() }

    private var matches: [RefileTarget] {
        let scored: [(target: RefileTarget, score: Int)] = targets.compactMap { target in
            guard let score = QuickOpenMatcher.fuzzyScore(candidate: target.displayPath, query: query) else { return nil }
            return (target, score)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.target.displayPath.localizedStandardCompare(rhs.target.displayPath) == .orderedAscending
            }
            .prefix(50)
            .map(\.target)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: 560, height: 420)
        .onAppear { fieldFocused = true }
        .confirmationDialog(
            "\(pendingLinkCount) link\(pendingLinkCount == 1 ? "" : "s") point to “\(appState.refileSource?.headingTitle ?? "")”",
            isPresented: $showLinkDialog,
            titleVisibility: .visible
        ) {
            Button("Update Links & Move") { commit(updateLinks: true) }
            Button("Move Without Updating") { commit(updateLinks: false) }
            Button("Cancel", role: .cancel) { pendingTarget = nil }
        } message: {
            Text("Moving this heading to another note would change those links.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source = appState.refileSource {
                Text("Refile “\(source.headingTitle)”")
                    .font(.headline)
            }
            HStack {
                Image(systemName: "arrow.right.doc.on.clipboard")
                    .foregroundStyle(.secondary)
                TextField("Move to… (File ▸ Heading)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .accessibilityIdentifier("refileField")
            }
            .onChange(of: query) { _, _ in selectedIndex = 0 }
        }
        .padding()
    }

    @ViewBuilder
    private var list: some View {
        if matches.isEmpty {
            ContentUnavailableView(
                "No destinations",
                systemImage: "arrow.right.doc.on.clipboard",
                description: Text("Try a different file or heading name.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(Array(matches.enumerated()), id: \.offset, selection: $selectedIndex) { idx, target in
                    HStack(spacing: 6) {
                        Image(systemName: target.headingPath == nil ? "doc" : "number")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        Text(target.displayPath).lineLimit(1)
                    }
                    .tag(idx)
                    .id(idx)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedIndex = idx; submit() }
                }
                .listStyle(.plain)
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), matches.count - 1)
    }

    private func submit() {
        guard matches.indices.contains(selectedIndex) else { return }
        let target = matches[selectedIndex]
        let impact = appState.refileLinkImpact(to: target)
        if impact > 0 {
            pendingTarget = target
            pendingLinkCount = impact
            showLinkDialog = true
        } else {
            pendingTarget = target
            commit(updateLinks: false)
        }
    }

    private func commit(updateLinks: Bool) {
        guard let target = pendingTarget else { return }
        Task {
            await appState.performRefile(to: target, updateLinks: updateLinks)
            appState.selectedDocumentPath = target.documentPath
            dismiss()
        }
    }
}
