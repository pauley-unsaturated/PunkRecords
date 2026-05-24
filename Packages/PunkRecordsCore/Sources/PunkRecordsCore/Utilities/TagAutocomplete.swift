import Foundation

/// Pure trigger-detection for the editor's `#tag` autocomplete.
///
/// Kept in Core (no AppKit) so the session logic is unit-testable without an
/// NSTextView. The popover UI consumes `activeSession` and feeds the query to
/// `suggestions(matching:in:)` against the vault's known tags.
///
/// Mirrors `WikilinkAutocomplete`, but the trigger and stop rules differ:
/// a `#` opens a session only when it is not preceded by a word character or
/// `/` (matching `WikilinkDecorator.tagRegex`), the first body character must
/// be a letter, and any non-tag character (including whitespace) ends it.
public enum TagAutocomplete {
    /// The minimum query length before the popover appears — i.e. the user has
    /// typed `#` plus two characters (the third character overall).
    public static let minQueryLength = 2

    /// An active autocomplete session: the partial tag typed after `#` and the
    /// range (including the `#`) that an accepted completion replaces.
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
    /// Returns nil until at least `minQueryLength` body characters have been
    /// typed, so single-character `#a` does not pop the menu prematurely.
    public static func activeSession(in text: String, caretLocation: Int) -> Session? {
        let chars = Array(text.utf16)
        guard caretLocation >= 1, caretLocation <= chars.count else { return nil }

        // Walk back over tag-body characters collecting the query.
        var i = caretLocation - 1
        while i >= 0 {
            let c = chars[i]
            if c == 0x23 { break }          // '#' — opener found
            guard isTagBody(c) else { return nil }
            i -= 1
        }
        guard i >= 0, chars[i] == 0x23 else { return nil }

        let hashIndex = i
        let queryStart = hashIndex + 1
        // The character immediately before '#' must not be a word char or '/'.
        if hashIndex > 0, isHashBlocker(chars[hashIndex - 1]) { return nil }
        // The first body character must be a letter (matches the tag grammar).
        guard queryStart < caretLocation, isTagStart(chars[queryStart]) else { return nil }

        let query = String(
            utf16CodeUnits: Array(chars[queryStart..<caretLocation]),
            count: caretLocation - queryStart
        )
        guard query.count >= minQueryLength else { return nil }
        return Session(query: query, replaceRange: hashIndex..<caretLocation)
    }

    /// Case-insensitive suggestions for `query` drawn from `tags`, best-first.
    /// Prefix matches rank ahead of mid-string matches; ties break
    /// alphabetically. `tags` is expected to be the vault's distinct tag set.
    public static func suggestions(matching query: String, in tags: [String], limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else {
            return Array(tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(limit))
        }
        let scored = tags.compactMap { tag -> (tag: String, prefix: Bool)? in
            let lower = tag.lowercased()
            if lower.hasPrefix(q) { return (tag, true) }
            if lower.contains(q) { return (tag, false) }
            return nil
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.prefix != rhs.prefix { return lhs.prefix }
                return lhs.tag.localizedStandardCompare(rhs.tag) == .orderedAscending
            }
            .prefix(limit)
            .map(\.tag)
    }

    /// The text to insert when a completion is accepted, including the `#` and a
    /// trailing space so the caret lands on a fresh word and the session ends.
    public static func insertion(for tag: String) -> String {
        "#\(tag) "
    }

    /// Where the caret should land after inserting `insertion(for:)` relative to
    /// the start of the replaced range — just past the trailing space.
    public static func caretOffset(for tag: String) -> Int {
        insertion(for: tag).utf16.count
    }

    // MARK: - Character classes

    private static func isTagStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) // A-Z a-z
    }

    private static func isTagBody(_ c: UInt16) -> Bool {
        isTagStart(c)
            || (c >= 0x30 && c <= 0x39) // 0-9
            || c == 0x5F                // _
            || c == 0x2D                // -
            || c == 0x2F                // /
    }

    /// A `#` preceded by one of these is not a tag opener (e.g. `a#b`, `/#`).
    private static func isHashBlocker(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || (c >= 0x30 && c <= 0x39) || c == 0x5F // \w
            || c == 0x2F                              // /
    }
}
