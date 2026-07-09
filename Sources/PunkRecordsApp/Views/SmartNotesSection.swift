import SwiftUI
import PunkRecordsCore

/// The sidebar "Smart Notes" section (PUNK-ic6): the shipped built-ins above the
/// user's saved smart notes, each an expandable row whose children are the
/// matching notes. Selecting a match drives the normal document selection (it
/// reuses `DocumentRow` via the injected `rowForDocument` closure, exactly like
/// the folder tree), so opening a matched note works unchanged.
///
/// Query evaluation is the pure, tested ``SmartNoteEvaluator`` reached through
/// `AppState.smartNoteMatches(_:)`; this view is a thin shell.
struct SmartNotesSection<RowContent: View>: View {
    @Environment(AppState.self) private var appState

    @ViewBuilder let rowForDocument: (Document) -> RowContent
    let onNewSmartNote: () -> Void
    let onEditSmartNote: (SmartNote) -> Void

    @State private var expanded = true

    var body: some View {
        Section(isExpanded: $expanded) {
            Button(action: onNewSmartNote) {
                Label("New Smart Note…", systemImage: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Create a saved search")
            .accessibilityIdentifier("newSmartNoteButton")

            ForEach(SmartNoteBuiltins.all) { builtin in
                SmartNoteRow(
                    name: builtin.name,
                    systemImage: builtin.systemImage,
                    query: builtin.query,
                    rowForDocument: rowForDocument
                )
            }

            ForEach(appState.smartNotes) { note in
                SmartNoteRow(
                    name: note.name,
                    systemImage: "line.3.horizontal.decrease.circle",
                    query: note.query,
                    rowForDocument: rowForDocument
                )
                .contextMenu {
                    Button("Edit…") { onEditSmartNote(note) }
                    Button("Delete", role: .destructive) {
                        Task { await appState.deleteSmartNote(note) }
                    }
                }
            }
        } header: {
            Text("Smart Notes")
        }
        .accessibilityIdentifier("smartNotesSection")
    }
}

/// One smart note in the sidebar: an expandable row whose children are the
/// matching notes (evaluated lazily on expand). A per-heading match (e.g. Today)
/// shows the matched heading titles beneath the note.
private struct SmartNoteRow<RowContent: View>: View {
    @Environment(AppState.self) private var appState

    let name: String
    let systemImage: String
    let query: SmartNoteQuery
    @ViewBuilder let rowForDocument: (Document) -> RowContent

    var body: some View {
        DisclosureGroup {
            let matches = appState.smartNoteMatches(query)
            if matches.isEmpty {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches, id: \.document.path) { match in
                    rowForDocument(match.document)
                    if !match.matchedHeadings.isEmpty {
                        Text(match.matchedHeadings.map(\.title).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 24)
                    }
                }
            }
        } label: {
            Label(name, systemImage: systemImage)
                .accessibilityIdentifier("smartNoteRow")
        }
    }
}
