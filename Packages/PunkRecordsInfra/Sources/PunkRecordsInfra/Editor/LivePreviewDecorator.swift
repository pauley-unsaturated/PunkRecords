import AppKit
import Foundation

/// Live Preview decoration pass: hides markdown marker characters (`**`, `` ` ``,
/// `# `, `[[`/`]]`, a link's `[…](url)` scaffolding, …) at zero width when the
/// caret is outside their element, reveals them when the caret is inside, and
/// styles markdown link labels (link color + underline) so a folded
/// `[text](url)` reads as a clickable link. Grew out of the phase-0
/// `MarkerFoldDecorator` (PUNK-ef9); phase 1 (PUNK-zp1) added the full marker
/// inventory, link styling, and the on/off mode.
///
/// The fold decision is computed by the pure `MarkerFolding` functions. This
/// class owns the small amount of AppKit state folding needs — the previous
/// fold set — so it can diff pass-to-pass and invalidate ONLY the paragraphs
/// whose fold state changed. That scoping is load-bearing: folding changes
/// layout (a hidden `**` reflows its line), so an unscoped invalidation would
/// relayout the whole visible region on every caret move and visibly lag typing
/// in large notes.
///
/// It never calls `replaceCharacters` — folding is attribute + glyph only, so
/// `textView.string` stays byte-identical to the file and the undo stack is
/// untouched. Rendering happens in `WikilinkPillLayoutManager`'s glyph-generation
/// delegate hook, which turns `.punkFolded` characters into null glyphs.
///
/// Setting `isEnabled = false` (the "source mode" escape hatch, persisted as
/// the `editor.livePreview` default) makes the next pass compute an empty fold
/// set; the same diffing then unfolds everything and strips link styling, so
/// the editor returns to today's dim-only behavior.
@MainActor
public final class LivePreviewDecorator {
    public struct Style: @unchecked Sendable {
        /// Foreground applied to a markdown link's visible label.
        public var linkColor: NSColor

        public init(linkColor: NSColor = .linkColor) {
            self.linkColor = linkColor
        }

        public static let `default` = Style()
    }

    public let style: Style
    /// Live Preview on/off. When false the pass unfolds everything it folded
    /// and applies no styling — the editor behaves exactly as without folding.
    public var isEnabled = true

    /// The fold set applied on the previous pass, used to diff against the next.
    private var previousFolds: [NSRange] = []
    /// Link labels styled on the previous pass, so styling can be stripped from
    /// labels whose link was edited away (or when the mode is switched off).
    private var previousLinkLabels: [NSRange] = []

    public init(style: Style = .default) {
        self.style = style
    }

    /// Fold markers across the text view's visible scan range.
    public func decorate(textView: NSTextView) {
        decorate(textView: textView, in: EditorDecorationRange.scanRange(for: textView))
    }

    /// Fold markers within `scanRange` only — limits per-keystroke work to the
    /// visible region on large documents.
    public func decorate(textView: NSTextView, in scanRange: NSRange) {
        guard let textStorage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString

        let caret = textView.selectedRange().location
        let elements: [MarkerFolding.Element] =
            (isEnabled && text.length > 0 && scanRange.length > 0)
                ? MarkerFolding.elements(in: text, scanRange: scanRange)
                : []
        let newFolds = MarkerFolding.foldRanges(elements: elements, caret: caret)
        let linkLabels = elements.filter { $0.kind == .link }.map(\.content)

        // Only the paragraphs whose fold state actually changed need new glyphs.
        let changedParagraphs = MarkerFolding.invalidationRanges(
            old: previousFolds,
            new: newFolds,
            in: text
        )

        textStorage.beginEditing()
        styleLinkLabels(current: linkLabels, in: textStorage)
        // Rewrite the `.punkFolded` attribute only inside changed paragraphs, so
        // the attribute edit stays scoped too. Re-add EVERY new fold that
        // intersects a changed paragraph (not just the ones that changed) since
        // we clear the whole paragraph first.
        for paragraph in changedParagraphs {
            textStorage.removeAttribute(.punkFolded, range: paragraph)
            for fold in newFolds {
                let overlap = NSIntersectionRange(fold, paragraph)
                if overlap.length > 0 {
                    textStorage.addAttribute(.punkFolded, value: true, range: overlap)
                }
            }
        }
        textStorage.endEditing()

        // Force glyph regeneration + relayout for just those paragraphs so the
        // delegate re-runs and folded characters collapse (or reappear).
        for paragraph in changedParagraphs {
            layoutManager.invalidateGlyphs(
                forCharacterRange: paragraph,
                changeInLength: 0,
                actualCharacterRange: nil
            )
            layoutManager.invalidateLayout(
                forCharacterRange: paragraph,
                actualCharacterRange: nil
            )
        }

        previousFolds = newFolds
        previousLinkLabels = linkLabels
    }

    /// Color + underline the visible labels of markdown links, and strip that
    /// styling from labels whose link no longer exists (edited away, scrolled
    /// set changed, or Live Preview switched off). Color-only work — the
    /// storage edit notification handles display refresh; no layout changes.
    private func styleLinkLabels(current: [NSRange], in textStorage: NSTextStorage) {
        let length = textStorage.length
        for old in previousLinkLabels where !current.contains(where: { NSEqualRanges($0, old) }) {
            // Stale ranges may have shifted after edits; clamp and strip. Any
            // over-removal is repaired by the next decoration/highlight pass.
            guard old.location < length else { continue }
            let clamped = NSRange(location: old.location, length: min(old.length, length - old.location))
            guard clamped.length > 0 else { continue }
            textStorage.removeAttribute(.underlineStyle, range: clamped)
            textStorage.removeAttribute(.foregroundColor, range: clamped)
        }
        for label in current where label.location + label.length <= length {
            textStorage.addAttribute(.foregroundColor, value: style.linkColor, range: label)
            textStorage.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: label
            )
        }
    }
}
