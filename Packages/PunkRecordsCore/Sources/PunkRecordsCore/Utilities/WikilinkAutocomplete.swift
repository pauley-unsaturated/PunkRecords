import Foundation

/// Pure trigger-detection for the editor's `[[` wikilink autocomplete.
///
/// Kept in Core (no AppKit) so the session logic is unit-testable without an
/// NSTextView. The popover UI consumes `activeSession` and feeds the query to
/// `QuickOpenMatcher` against vault titles.
public enum WikilinkAutocomplete {
    /// An active autocomplete session: the query typed after `[[` and the
    /// range (including the `[[`) that an accepted completion replaces.
    public struct Session: Sendable, Equatable {
        public let query: String
        public let replaceRange: Range<Int>

        public init(query: String, replaceRange: Range<Int>) {
            self.query = query
            self.replaceRange = replaceRange
        }
    }

    /// Detect an active session given the full text and caret (UTF-16) offset.
    ///
    /// A session is active when an unclosed `[[` precedes the caret on the same
    /// line with no intervening `]`. Unlike slash commands, the query may
    /// contain spaces (note titles do), so whitespace does not end it — only a
    /// newline, a `]`, or a `|` (alias separator) does.
    public static func activeSession(in text: String, caretLocation: Int) -> Session? {
        let chars = Array(text.utf16)
        guard caretLocation >= 2, caretLocation <= chars.count else { return nil }

        var i = caretLocation - 1
        while i >= 1 {
            let c = chars[i]
            if c == 0x0A { return nil }            // newline — no session
            if c == 0x5D { return nil }            // ']' — caret is past a link
            if c == 0x7C { return nil }            // '|' — past the target half
            if c == 0x5B && chars[i - 1] == 0x5B { // '[' preceded by '[' → "[[" opener
                let start = i - 1
                let queryStart = i + 1
                guard queryStart <= caretLocation else { return nil }
                let query = String(
                    utf16CodeUnits: Array(chars[queryStart..<caretLocation]),
                    count: caretLocation - queryStart
                )
                return Session(query: query, replaceRange: start..<caretLocation)
            }
            i -= 1
        }
        return nil
    }

    /// The text to insert when a completion is accepted, including closing
    /// brackets. Replaces the session's `replaceRange`.
    public static func insertion(for title: String) -> String {
        "[[\(title)]]"
    }

    /// Where the caret should land after inserting `insertion(for:)` relative to
    /// the start of the replaced range — just past the closing `]]`.
    public static func caretOffset(for title: String) -> Int {
        insertion(for: title).utf16.count
    }
}
