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
                    // The same URL that .draggable hands to the receiver — exposed
                    // for UI tests because XCUITest can't reliably synthesize a
                    // drag from a SwiftUI List row that fires the drop handler.
                    .accessibilityValue(fileURL.path)
            }
        }
        .tag(document.path)
    }
}
