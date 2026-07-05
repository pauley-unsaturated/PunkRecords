import SwiftUI
import PunkRecordsCore

/// Destination picker shown once a conversation summary is ready: an editable
/// title (prefilled `Summary — <thread title>`) plus a folder picker over the
/// vault's existing folders. Confirm writes the note and opens it; Cancel drops
/// to the controller's Copy / Retry fallback so the summary is never lost.
///
/// A thin shell: all decisions (title default, path derivation, folder list,
/// save-through-repository) live in ``ConversationSummarizer`` /
/// ``ChatSessionController``. Visual layout is validated manually.
struct SummarySaveSheet: View {
    @Bindable var controller: ChatSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Summary as Note")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Note title", text: $controller.summaryTitle)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("summaryTitleField")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Folder", selection: $controller.summaryFolder) {
                    ForEach(controller.summaryFolderOptions, id: \.self) { folder in
                        Text(folder.isEmpty ? "Vault Root" : folder).tag(folder)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("summaryFolderPicker")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    controller.cancelSaveSummary()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("summaryCancelButton")

                Button("Save") {
                    controller.confirmSaveSummary()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTitleEmpty)
                .accessibilityIdentifier("summarySaveButton")
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private var isTitleEmpty: Bool {
        controller.summaryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
