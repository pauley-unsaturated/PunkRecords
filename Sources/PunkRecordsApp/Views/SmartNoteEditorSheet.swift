import SwiftUI
import AppKit
import PunkRecordsCore

/// The "New Smart Note…" / edit sheet: a name field over `NSPredicateEditor`
/// (the Finder/Mail rule-builder). The editor edits an `NSPredicate`; Save
/// bridges it to a Core ``SmartNoteQuery`` via ``SmartNotePredicateBridge`` and
/// writes `Smart Notes/{name}.md`.
///
/// Only the literal `NSPredicateEditorRowTemplate`s live here (they need
/// AppKit); the AST, evaluation, and predicate conversion are all pure Core.
/// Appearance and rule-builder interaction are validated by hand (poor
/// automation ROI per CLAUDE.md).
struct SmartNoteEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// The smart note being edited, or `nil` for a brand-new one.
    let existing: SmartNote?

    @State private var name: String
    @State private var predicate: NSPredicate
    @State private var conversionError: String?

    init(existing: SmartNote?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        if let existing {
            _predicate = State(initialValue: SmartNotePredicateBridge.makePredicate(existing.query))
        } else {
            _predicate = State(initialValue: SmartNoteRowTemplates.defaultPredicate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Smart Note" : "Edit Smart Note")
                .font(.title3.weight(.semibold))

            HStack {
                Text("Name")
                TextField("e.g. Reading Queue", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("smartNoteNameField")
            }

            Divider()

            PredicateEditorView(predicate: $predicate)
                .frame(minWidth: 480, minHeight: 200)
                .accessibilityIdentifier("smartNotePredicateEditor")

            if let conversionError {
                Label(conversionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("smartNoteSaveButton")
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 320)
    }

    private func save() {
        let query: SmartNoteQuery
        do {
            query = try SmartNotePredicateBridge.makeQuery(from: predicate)
        } catch {
            conversionError = "This rule can't be saved yet — add at least one condition."
            return
        }
        let targetName = name
        let previous = existing
        Task {
            await appState.saveSmartNote(name: targetName, query: query, replacing: previous)
            dismiss()
        }
    }
}

// MARK: - NSPredicateEditor host

/// Thin `NSViewRepresentable` around `NSPredicateEditor`, reporting the edited
/// predicate back through the binding on every change.
private struct PredicateEditorView: NSViewRepresentable {
    @Binding var predicate: NSPredicate

    func makeCoordinator() -> Coordinator { Coordinator(predicate: $predicate) }

    func makeNSView(context: Context) -> NSPredicateEditor {
        let editor = NSPredicateEditor()
        editor.rowTemplates = SmartNoteRowTemplates.all()
        editor.canRemoveAllRows = false
        editor.target = context.coordinator
        editor.action = #selector(Coordinator.predicateChanged(_:))
        editor.objectValue = predicate
        return editor
    }

    func updateNSView(_ nsView: NSPredicateEditor, context: Context) {
        // The editor is the source of truth once shown; avoid clobbering
        // in-progress edits by only pushing an externally-changed predicate.
        if let current = nsView.objectValue as? NSPredicate, current != predicate {
            nsView.objectValue = predicate
        }
    }

    final class Coordinator: NSObject {
        private let predicate: Binding<NSPredicate>

        init(predicate: Binding<NSPredicate>) {
            self.predicate = predicate
        }

        @objc func predicateChanged(_ sender: NSPredicateEditor) {
            if let updated = sender.objectValue as? NSPredicate {
                predicate.wrappedValue = updated
            }
        }
    }
}

// MARK: - Row templates

/// Builds the `NSPredicateEditorRowTemplate`s exposed by the rule-builder. Kept
/// to the fields the stock editor can present cleanly (text, tag, status enum,
/// dates); the frontmatter-key and existence/relative-date forms are supported
/// by the Core bridge/evaluator but not surfaced as editor rows.
enum SmartNoteRowTemplates {

    /// The predicate a fresh sheet opens on: "all of the following" with one tag
    /// condition, so the editor shows a usable starting row.
    static var defaultPredicate: NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSComparisonPredicate(
                leftExpression: NSExpression(forKeyPath: "tag"),
                rightExpression: NSExpression(forConstantValue: ""),
                modifier: .direct,
                type: .contains,
                options: [.caseInsensitive]
            )
        ])
    }

    static func all() -> [NSPredicateEditorRowTemplate] {
        [compound, tag, status] + textFields + dateFields
    }

    private static var compound: NSPredicateEditorRowTemplate {
        NSPredicateEditorRowTemplate(compoundTypes: [
            NSNumber(value: NSCompoundPredicate.LogicalType.and.rawValue),
            NSNumber(value: NSCompoundPredicate.LogicalType.or.rawValue),
            NSNumber(value: NSCompoundPredicate.LogicalType.not.rawValue)
        ])
    }

    private static var tag: NSPredicateEditorRowTemplate {
        stringTemplate(keyPath: "tag", operators: [.contains, .equalTo, .notEqualTo, .beginsWith])
    }

    private static var status: NSPredicateEditorRowTemplate {
        NSPredicateEditorRowTemplate(
            leftExpressions: [NSExpression(forKeyPath: "status")],
            rightExpressions: PropsStatus.allCases.map { NSExpression(forConstantValue: $0.rawValue) },
            modifier: .direct,
            operators: [
                NSNumber(value: NSComparisonPredicate.Operator.equalTo.rawValue),
                NSNumber(value: NSComparisonPredicate.Operator.notEqualTo.rawValue)
            ],
            options: 0
        )
    }

    private static var textFields: [NSPredicateEditorRowTemplate] {
        [
            stringTemplate(keyPath: "title", operators: [.contains, .beginsWith, .equalTo]),
            stringTemplate(keyPath: "path", operators: [.beginsWith, .contains, .equalTo]),
            stringTemplate(keyPath: "text", operators: [.contains])
        ]
    }

    private static var dateFields: [NSPredicateEditorRowTemplate] {
        ["scheduled", "due", "created", "modified"].map { keyPath in
            NSPredicateEditorRowTemplate(
                leftExpressions: [NSExpression(forKeyPath: keyPath)],
                rightExpressionAttributeType: .dateAttributeType,
                modifier: .direct,
                operators: [
                    NSNumber(value: NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue),
                    NSNumber(value: NSComparisonPredicate.Operator.lessThan.rawValue),
                    NSNumber(value: NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue),
                    NSNumber(value: NSComparisonPredicate.Operator.greaterThan.rawValue),
                    NSNumber(value: NSComparisonPredicate.Operator.equalTo.rawValue)
                ],
                options: 0
            )
        }
    }

    private static func stringTemplate(
        keyPath: String,
        operators: [NSComparisonPredicate.Operator]
    ) -> NSPredicateEditorRowTemplate {
        NSPredicateEditorRowTemplate(
            leftExpressions: [NSExpression(forKeyPath: keyPath)],
            rightExpressionAttributeType: .stringAttributeType,
            modifier: .direct,
            operators: operators.map { NSNumber(value: $0.rawValue) },
            options: Int(NSComparisonPredicate.Options.caseInsensitive.rawValue |
                         NSComparisonPredicate.Options.diacriticInsensitive.rawValue)
        )
    }
}
