import Foundation

/// Pure coordination logic for the editor's inline completion popover, shared
/// between the `[[` wikilink and `#` tag triggers. The AppKit-side
/// `EditorCompletionCoordinator` owns the `NSTextView` and the popover UI; this
/// type owns the *decisions*: which trigger is active at the caret (wikilinks
/// take precedence over tags), and what edit an accepted title produces.
///
/// Kept in Core (no AppKit) so the session state machine is unit-testable
/// without an `NSTextView`. Trigger detection and insertion strings are
/// delegated to the already-tested `WikilinkAutocomplete` / `TagAutocomplete`,
/// so this type only encodes the coordination seam between them.
public enum EditorCompletion {
    /// Which trigger opened the active session.
    public enum Kind: Sendable, Equatable {
        case wikilink
        case tag
    }

    /// An active completion session at the caret.
    public struct Session: Sendable, Equatable {
        public let kind: Kind
        /// The query typed after the trigger, fed to the suggestion provider.
        public let query: String
        /// The text range (UTF-16, including the trigger) an accepted
        /// completion replaces. Its lower bound also anchors the popover.
        public let replaceRange: Range<Int>

        public init(kind: Kind, query: String, replaceRange: Range<Int>) {
            self.kind = kind
            self.query = query
            self.replaceRange = replaceRange
        }
    }

    /// The concrete edit an accepted completion applies to the text storage.
    public struct Edit: Sendable, Equatable {
        /// Range (UTF-16) to replace — the session's `replaceRange`.
        public let replaceRange: Range<Int>
        /// Text to insert in its place (`[[title]]` or `#tag `).
        public let insertion: String
        /// Absolute UTF-16 caret location after the edit.
        public let caretLocation: Int

        public init(replaceRange: Range<Int>, insertion: String, caretLocation: Int) {
            self.replaceRange = replaceRange
            self.insertion = insertion
            self.caretLocation = caretLocation
        }
    }

    /// Resolve the active session at `caretLocation`, honoring which triggers
    /// are enabled. A `[[` wikilink session takes precedence over a `#` tag
    /// session — `[[` is the more specific trigger. Returns nil when neither
    /// trigger is active (the caller then hides the popover and clears state).
    public static func activeSession(
        in text: String,
        caretLocation: Int,
        wikilinkEnabled: Bool,
        tagEnabled: Bool
    ) -> Session? {
        if wikilinkEnabled,
           let session = WikilinkAutocomplete.activeSession(in: text, caretLocation: caretLocation) {
            return Session(kind: .wikilink, query: session.query, replaceRange: session.replaceRange)
        }
        if tagEnabled,
           let session = TagAutocomplete.activeSession(in: text, caretLocation: caretLocation) {
            return Session(kind: .tag, query: session.query, replaceRange: session.replaceRange)
        }
        return nil
    }

    /// The edit produced by accepting `title` for `session`: the
    /// trigger-appropriate syntax (`[[title]]` or `#tag `) replacing the
    /// session range, plus the resulting absolute caret location.
    public static func edit(accepting title: String, for session: Session) -> Edit {
        let insertion: String
        let caretOffset: Int
        switch session.kind {
        case .wikilink:
            insertion = WikilinkAutocomplete.insertion(for: title)
            caretOffset = WikilinkAutocomplete.caretOffset(for: title)
        case .tag:
            insertion = TagAutocomplete.insertion(for: title)
            caretOffset = TagAutocomplete.caretOffset(for: title)
        }
        return Edit(
            replaceRange: session.replaceRange,
            insertion: insertion,
            caretLocation: session.replaceRange.lowerBound + caretOffset
        )
    }
}
