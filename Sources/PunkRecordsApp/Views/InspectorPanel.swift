import SwiftUI
import PunkRecordsCore

/// ⌘I metadata inspector — a Reminders-style detail pane bound to the heading
/// under the caret (or the document root when the caret is above the first
/// heading). Editable fields: status, tags, scheduled/due dates (natural
/// language), and custom key/value rows.
///
/// This is a thin shell: every decision lives in unit-tested Core
/// (`PropsBlock`/`HeadingProps`/`NaturalDateParser`); the view loads a draft
/// from `AppState.currentProps()`, lets the user edit it, and commits the whole
/// draft with Save via `AppState.applyProps(_:)`. Layout/placement are validated
/// manually (pure-visual, poor automation ROI per CLAUDE.md).
struct InspectorPanel: View {
    @Environment(AppState.self) private var appState

    @State private var status: PropsStatus?
    @State private var tagsText = ""
    @State private var scheduledText = ""
    @State private var dueText = ""
    @State private var customRows: [PropsField] = []
    @State private var isDirty = false

    var body: some View {
        Group {
            if appState.selectedDocument == nil {
                ContentUnavailableView(
                    "No Note",
                    systemImage: "sidebar.right",
                    description: Text("Open a note to inspect its metadata.")
                )
            } else {
                editor
            }
        }
        .frame(minWidth: 240)
        .accessibilityIdentifier("inspectorPanel")
        .onAppear { reload() }
        .onChange(of: appState.inspectorTargetKey) { _, _ in reload() }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                statusSection
                Section("Tags") {
                    TextField("comma, separated, tags", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tagsText) { _, _ in isDirty = true }
                        .onSubmit(save)
                        .accessibilityIdentifier("inspectorTagsField")
                }
                dateSection("Scheduled", text: $scheduledText, identifier: "inspectorScheduledField")
                dateSection("Due", text: $dueText, identifier: "inspectorDueField")
                customSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.inspectorTargetIsRoot ? "doc.text" : "number")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.inspectorTargetTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(appState.inspectorTargetPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty)
                .accessibilityIdentifier("inspectorSaveButton")
        }
        .padding(12)
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            Picker("Status", selection: $status) {
                Text("None").tag(PropsStatus?.none)
                ForEach(PropsStatus.allCases, id: \.self) { value in
                    Text(value.displayName).tag(PropsStatus?.some(value))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: status) { _, _ in isDirty = true }
            .accessibilityIdentifier("inspectorStatusPicker")
        }
    }

    private func dateSection(_ title: String, text: Binding<String>, identifier: String) -> some View {
        Section(title) {
            TextField("e.g. next Monday, tomorrow at 3, +1w", text: text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { _, _ in isDirty = true }
                .onSubmit(save)
                .accessibilityIdentifier(identifier)
            if let hint = resolvedHint(text.wrappedValue) {
                Label(hint, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customSection: some View {
        Section("Custom Fields") {
            ForEach($customRows) { $row in
                HStack(spacing: 6) {
                    TextField("key", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: row.key) { _, _ in isDirty = true }
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: row.value) { _, _ in isDirty = true }
                    Button {
                        customRows.removeAll { $0.id == row.id }
                        isDirty = true
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                customRows.append(PropsField(key: "", value: ""))
                isDirty = true
            } label: {
                Label("Add Field", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Draft <-> Core

    /// Load the inspector's draft from the current target's stored props.
    private func reload() {
        let props = appState.currentProps()
        status = props.status
        tagsText = props.tags.joined(separator: ", ")
        scheduledText = props.scheduled ?? ""
        dueText = props.due ?? ""
        customRows = props.custom
        isDirty = false
    }

    /// Commit the whole draft to the target document.
    private func save() {
        Task {
            await appState.applyProps(makeBlock())
            isDirty = false
        }
    }

    /// Assemble a `PropsBlock` from the current field state, resolving the date
    /// fields through `NaturalDateParser`.
    private func makeBlock() -> PropsBlock {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return PropsBlock(
            tags: tags,
            status: status,
            scheduled: normalizedDate(scheduledText),
            due: normalizedDate(dueText),
            custom: customRows
        )
    }

    /// Resolve natural-language input to a canonical date string, or keep the
    /// raw text when it doesn't parse (so a literal `2026-07-10` still works and
    /// unparseable text isn't silently dropped).
    private func normalizedDate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = NaturalDateParser.parse(trimmed) { return parsed.canonicalString() }
        return trimmed
    }

    /// The resolved date to preview under a field, shown only when parsing
    /// changes the input (so `next Monday` reveals its concrete date).
    private func resolvedHint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = NaturalDateParser.parse(trimmed) else { return nil }
        let canonical = parsed.canonicalString()
        return canonical == trimmed ? nil : canonical
    }
}
