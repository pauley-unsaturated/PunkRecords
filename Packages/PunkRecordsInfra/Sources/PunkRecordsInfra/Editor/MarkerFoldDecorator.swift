import AppKit
import Foundation

/// Applies marker folding to an `NSTextView`: hides markdown delimiter
/// characters (`**`, `` ` ``, …) at zero width when the caret is outside their
/// element, and reveals them when the caret is inside.
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
@MainActor
public final class MarkerFoldDecorator {
    /// The fold set applied on the previous pass, used to diff against the next.
    private var previousFolds: [NSRange] = []

    public init() {}

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
        let newFolds = MarkerFolding.foldRanges(in: text, scanRange: scanRange, caret: caret)

        // Only the paragraphs whose fold state actually changed need new glyphs.
        let changedParagraphs = MarkerFolding.invalidationRanges(
            old: previousFolds,
            new: newFolds,
            in: text
        )
        guard !changedParagraphs.isEmpty else { return }

        // Rewrite the `.punkFolded` attribute only inside changed paragraphs, so
        // the attribute edit stays scoped too. Re-add EVERY new fold that
        // intersects a changed paragraph (not just the ones that changed) since
        // we clear the whole paragraph first.
        textStorage.beginEditing()
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
    }
}
