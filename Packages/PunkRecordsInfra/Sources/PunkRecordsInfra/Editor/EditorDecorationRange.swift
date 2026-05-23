import AppKit
import Foundation

/// Computes which character range a per-keystroke decoration pass should touch.
///
/// Decorating the whole document on every edit is O(document size) and becomes
/// unusable on large notes (a 10MB file takes minutes). Since off-screen text
/// isn't drawn, we only decorate the visible range — expanded to whole lines
/// (so line-anchored regexes and headings aren't clipped) plus a buffer of
/// extra lines above and below to cover small scrolls before the next pass.
enum EditorDecorationRange {
    /// Number of extra lines to decorate above and below the visible range.
    static let bufferLines = 40

    static func scanRange(for textView: NSTextView) -> NSRange {
        let text = textView.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard text.length > 0 else { return full }

        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return full
        }

        let visible = textView.visibleRect
        // No real layout yet (e.g. an off-screen text view in a unit test):
        // decorate everything. Callers in that situation use small documents.
        guard visible.width > 0, visible.height > 0 else { return full }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0, charRange.length < text.length else { return full }

        // Expand to whole lines.
        var expanded = text.lineRange(for: charRange)

        // Add a line buffer above and below.
        for _ in 0..<bufferLines {
            guard expanded.location > 0 else { break }
            let prevLine = text.lineRange(for: NSRange(location: expanded.location - 1, length: 0))
            expanded = NSRange(
                location: prevLine.location,
                length: expanded.length + (expanded.location - prevLine.location)
            )
        }
        for _ in 0..<bufferLines {
            let end = expanded.location + expanded.length
            guard end < text.length else { break }
            let nextLine = text.lineRange(for: NSRange(location: end, length: 0))
            expanded = NSRange(
                location: expanded.location,
                length: (nextLine.location + nextLine.length) - expanded.location
            )
        }

        return expanded
    }
}
