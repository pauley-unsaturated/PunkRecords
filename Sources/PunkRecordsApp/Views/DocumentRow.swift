import SwiftUI
import PunkRecordsCore

struct DocumentRow: View {
    let document: Document
    let isRenaming: Bool
    @Binding var renameText: String
    let fileURL: URL
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onShowInFinder: () -> Void
    let onRequestDelete: () -> Void

    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .onAppear { renameFieldFocused = true }
                    .accessibilityIdentifier("renameField")
            } else {
                Label(document.title, systemImage: "doc.text")
                    .draggable(fileURL)
                    .contextMenu {
                        Button("Rename", action: onBeginRename)
                        Button("Show in Finder", action: onShowInFinder)
                        Divider()
                        Button("Move to Trash", role: .destructive, action: onRequestDelete)
                            .keyboardShortcut(.delete, modifiers: .command)
                    }
            }
        }
        .tag(document.path)
    }
}
