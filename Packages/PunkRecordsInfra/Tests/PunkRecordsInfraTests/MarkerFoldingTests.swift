import Foundation
import Testing
@testable import PunkRecordsInfra

@Suite("MarkerFolding fold computation")
struct MarkerFoldingTests {
    /// Convenience: fold over the whole string with the given caret.
    private func folds(_ string: String, caret: Int) -> [NSRange] {
        let text = string as NSString
        return MarkerFolding.foldRanges(
            in: text,
            scanRange: NSRange(location: 0, length: text.length),
            caret: caret
        )
    }

    /// True if `folds` contains exactly a range at `location` of `length`.
    private func contains(_ folds: [NSRange], location: Int, length: Int) -> Bool {
        folds.contains { $0.location == location && $0.length == length }
    }

    // MARK: - Delimiter pairing (caret far away)

    @Test("Bold **…** folds both double-asterisk delimiters")
    func boldPairing() {
        // "x **bold** y" — bold whole = [2, 8]; open [2,2], close [8,2].
        let result = folds("x **bold** y", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 2))
        #expect(contains(result, location: 8, length: 2))
    }

    @Test("Bold __…__ folds both double-underscore delimiters")
    func boldUnderscorePairing() {
        // "x __bold__ y" — open [2,2], close [8,2].
        let result = folds("x __bold__ y", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 2))
        #expect(contains(result, location: 8, length: 2))
    }

    @Test("Italic *…* folds both single-asterisk delimiters")
    func italicPairing() {
        // "x *it* y" — open [2,1], close [5,1].
        let result = folds("x *it* y", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 1))
        #expect(contains(result, location: 5, length: 1))
    }

    @Test("Italic _…_ folds both single-underscore delimiters")
    func italicUnderscorePairing() {
        // "x _it_ y" — open [2,1], close [5,1].
        let result = folds("x _it_ y", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 1))
        #expect(contains(result, location: 5, length: 1))
    }

    @Test("Inline code `…` folds both backtick delimiters")
    func inlineCodePairing() {
        // "x `code` y" — open [2,1], close [7,1].
        let result = folds("x `code` y", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 1))
        #expect(contains(result, location: 7, length: 1))
    }

    // MARK: - Caret inside / outside / at boundaries

    @Test("Caret inside the element reveals (no folds)")
    func caretInsideReveals() {
        // "x **bold** y" — content 'bold' spans 4...7; caret at 5 is inside.
        #expect(folds("x **bold** y", caret: 5).isEmpty)
    }

    @Test("Caret on the opening delimiter reveals")
    func caretOnOpenDelimiterReveals() {
        // Caret at 3 sits between the two opening asterisks.
        #expect(folds("x **bold** y", caret: 3).isEmpty)
    }

    @Test("Caret exactly at the element start boundary reveals")
    func caretAtStartBoundaryReveals() {
        // whole.location == 2; caret at 2 is the inclusive start boundary.
        #expect(folds("x **bold** y", caret: 2).isEmpty)
    }

    @Test("Caret exactly at the element end boundary reveals")
    func caretAtEndBoundaryReveals() {
        // whole end == 2 + 8 == 10; caret at 10 is the inclusive end boundary.
        #expect(folds("x **bold** y", caret: 10).isEmpty)
    }

    @Test("Caret just past the element folds")
    func caretJustPastFolds() {
        // whole end == 10; caret at 11 is outside → folds.
        #expect(folds("x **bold** y", caret: 11).count == 2)
    }

    @Test("Caret just before the element folds")
    func caretJustBeforeFolds() {
        // whole.location == 2; caret at 1 is outside → folds.
        #expect(folds("x **bold** y", caret: 1).count == 2)
    }

    @Test("With multiple elements, only the caret's element reveals")
    func multipleElementsSelectiveReveal() {
        // "**a** **b**" — first whole [0,5], second whole [6,5].
        // Caret at 2 is inside the first element only.
        let result = folds("**a** **b**", caret: 2)
        // First element revealed; second element's two delimiters remain folded.
        #expect(result.count == 2)
        #expect(contains(result, location: 6, length: 2))
        #expect(contains(result, location: 9, length: 2))
    }

    // MARK: - Unbalanced / unterminated markers

    @Test("Unterminated bold does not fold")
    func unterminatedBold() {
        #expect(folds("x **bold and no close", caret: 0).isEmpty)
    }

    @Test("Lone double-asterisk does not fold")
    func loneDoubleAsterisk() {
        #expect(folds("a ** b", caret: 0).isEmpty)
    }

    @Test("Lone single asterisk does not fold")
    func loneSingleAsterisk() {
        #expect(folds("2 * 3 = 6", caret: 0).isEmpty)
    }

    @Test("Unterminated inline code does not fold")
    func unterminatedCode() {
        #expect(folds("x `unclosed code", caret: 0).isEmpty)
    }

    @Test("Empty markers with no content do not fold")
    func emptyMarkers() {
        // "****" has no content between the pairs — no element.
        #expect(folds("a **** b", caret: 0).isEmpty)
    }

    // MARK: - Precedence

    @Test("Bold is not mis-read as two italics")
    func boldNotItalic() {
        // Exactly the two `**` pairs fold — the inner single `*`s never fire.
        let result = folds("x **bold** y", caret: 0)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.length == 2 })
    }

    @Test("An asterisk inside inline code is not emphasis")
    func asteriskInsideCode() {
        // "x `a*b` y" — only the two backticks fold; the `*` is inside code.
        let result = folds("x `a*b` y", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 1)) // open backtick
        #expect(contains(result, location: 6, length: 1)) // close backtick
    }

    // MARK: - UTF-16 offsets (emoji / CJK)

    @Test("Emoji prefix keeps UTF-16 delimiter offsets correct")
    func emojiUTF16Offsets() {
        // "😀 **bold**" — 😀 is 2 UTF-16 units, then a space at index 2.
        // Bold whole = [3, 8]; open [3,2], close [9,2].
        let string = "😀 **bold**"
        let text = string as NSString
        #expect(text.length == 11) // 2 (emoji) + 1 (space) + 8 (**bold**)
        // Caret at 0 is outside the bold element → folds.
        let result = MarkerFolding.foldRanges(
            in: text,
            scanRange: NSRange(location: 0, length: text.length),
            caret: 0
        )
        #expect(result.count == 2)
        #expect(contains(result, location: 3, length: 2))
        #expect(contains(result, location: 9, length: 2))
    }

    @Test("CJK content keeps UTF-16 delimiter offsets correct")
    func cjkUTF16Offsets() {
        // "中文 *x*" — CJK chars are single UTF-16 units (BMP).
        // 中=0, 文=1, space=2, *=3, x=4, *=5.
        let string = "中文 *x*"
        let text = string as NSString
        let result = MarkerFolding.foldRanges(
            in: text,
            scanRange: NSRange(location: 0, length: text.length),
            caret: 0
        )
        #expect(result.count == 2)
        #expect(contains(result, location: 3, length: 1))
        #expect(contains(result, location: 5, length: 1))
    }

    @Test("Emoji inside the content is spanned, not split")
    func emojiInsideContent() {
        // "**a😀b**" — emoji sits in the content; only the `**` pairs fold.
        // open [0,2]; content 'a😀b' = a(2) + 😀(2 units) + b = indices 2..5;
        // close [6,2].
        let string = "**a😀b**"
        let text = string as NSString
        #expect(text.length == 8)
        let result = MarkerFolding.foldRanges(
            in: text,
            scanRange: NSRange(location: 0, length: text.length),
            caret: text.length // caret past end reveals; use a clearly-outside caret instead
        )
        // Caret == length is the inclusive end boundary → revealed. Re-check with
        // a padded string so we can place the caret strictly outside.
        #expect(result.isEmpty)
        let padded = "\(string) z" as NSString
        let outside = MarkerFolding.foldRanges(
            in: padded,
            scanRange: NSRange(location: 0, length: padded.length),
            caret: padded.length - 1
        )
        #expect(outside.count == 2)
        #expect(contains(outside, location: 0, length: 2))
        #expect(contains(outside, location: 6, length: 2))
    }

    // MARK: - Scan range scoping

    @Test("Elements outside the scan range are not folded")
    func scanRangeExcludesOutOfRange() {
        // Bold sits at the tail; a scan range covering only the head finds nothing.
        let string = "head text here and **bold** at the tail"
        let text = string as NSString
        let headOnly = NSRange(location: 0, length: 10)
        let result = MarkerFolding.foldRanges(in: text, scanRange: headOnly, caret: 0)
        #expect(result.isEmpty)
    }
}

@Suite("MarkerFolding phase-1 elements (strikethrough, headings, wikilinks, links)")
struct MarkerFoldingPhase1Tests {
    private func folds(_ string: String, caret: Int) -> [NSRange] {
        let text = string as NSString
        return MarkerFolding.foldRanges(
            in: text,
            scanRange: NSRange(location: 0, length: text.length),
            caret: caret
        )
    }

    private func contains(_ folds: [NSRange], location: Int, length: Int) -> Bool {
        folds.contains { $0.location == location && $0.length == length }
    }

    // MARK: - Strikethrough

    @Test("Strikethrough ~~…~~ folds both tilde pairs")
    func strikethroughPairing() {
        // "a ~~x~~ b" — open [2,2], close [5,2].
        let result = folds("a ~~x~~ b", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 2, length: 2))
        #expect(contains(result, location: 5, length: 2))
    }

    @Test("Caret inside strikethrough reveals")
    func strikethroughCaretInside() {
        #expect(folds("a ~~x~~ b", caret: 4).isEmpty)
    }

    @Test("Unterminated strikethrough does not fold")
    func strikethroughUnterminated() {
        #expect(folds("a ~~gone forever", caret: 0).isEmpty)
    }

    // MARK: - ATX headings

    @Test("Heading folds hashes plus exactly one trailing space")
    func headingMarkerFold() {
        // "# Title\nbody" — marker [0,2] ("# "), caret on body line.
        let result = folds("# Title\nbody", caret: 9)
        #expect(result.count == 1)
        #expect(contains(result, location: 0, length: 2))
    }

    @Test("Deeper heading levels fold all hashes plus one space")
    func headingLevelThree() {
        // "### Three\nx" — marker [0,4] ("### ").
        let result = folds("### Three\nx", caret: 10)
        #expect(result.count == 1)
        #expect(contains(result, location: 0, length: 4))
    }

    @Test("Indented heading folds only the hash marker, not the indent")
    func headingIndented() {
        // "  ## Hi\nx" — marker [2,3] ("## "); the two leading spaces stay.
        let result = folds("  ## Hi\nx", caret: 8)
        #expect(result.count == 1)
        #expect(contains(result, location: 2, length: 3))
    }

    @Test("Caret anywhere on the heading line reveals its marker")
    func headingCaretOnLine() {
        // Caret mid-title, at line start, and at line end (before \n) all reveal.
        #expect(folds("# Title\nbody", caret: 4).isEmpty)
        #expect(folds("# Title\nbody", caret: 0).isEmpty)
        #expect(folds("# Title\nbody", caret: 7).isEmpty)
    }

    @Test("Caret at the start of the next line folds the heading")
    func headingCaretNextLine() {
        // Index 8 is the first char of "body" — outside the heading element.
        #expect(folds("# Title\nbody", caret: 8).count == 1)
    }

    @Test("A #tag at line start is not a heading (no space after hashes)")
    func hashTagNotHeading() {
        #expect(folds("#tag and text", caret: 13).isEmpty)
    }

    @Test("A heading with only whitespace after the marker does not fold")
    func emptyHeadingNotFolded() {
        #expect(folds("#   \nbody", caret: 6).isEmpty)
    }

    @Test("Heading marker and inline bold on the same line fold independently")
    func headingWithInlineBold() {
        // "# Head **b** x\nnext" — heading marker [0,2]; bold ** at [7,2]/[10,2].
        let all = folds("# Head **b** x\nnext", caret: 16)
        #expect(all.count == 3)
        #expect(contains(all, location: 0, length: 2))
        #expect(contains(all, location: 7, length: 2))
        #expect(contains(all, location: 10, length: 2))

        // Caret inside the heading title reveals the heading but NOT the bold
        // (per-element semantics).
        let inTitle = folds("# Head **b** x\nnext", caret: 4)
        #expect(inTitle.count == 2)
        #expect(contains(inTitle, location: 7, length: 2))
        #expect(contains(inTitle, location: 10, length: 2))
    }

    // MARK: - Wikilink brackets

    @Test("Wikilink folds both bracket pairs")
    func wikilinkPairing() {
        // "see [[Note]] end" — [[ at [4,2], ]] at [10,2].
        let result = folds("see [[Note]] end", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 4, length: 2))
        #expect(contains(result, location: 10, length: 2))
    }

    @Test("Caret inside or at the boundary of a wikilink reveals")
    func wikilinkCaretInside() {
        #expect(folds("see [[Note]] end", caret: 7).isEmpty)
        #expect(folds("see [[Note]] end", caret: 4).isEmpty)  // start boundary
        #expect(folds("see [[Note]] end", caret: 12).isEmpty) // end boundary
    }

    @Test("Unterminated wikilink does not fold")
    func wikilinkUnterminated() {
        #expect(folds("see [[Note and nothing", caret: 0).isEmpty)
    }

    // MARK: - Markdown links

    @Test("Link folds the open bracket and the whole ](url) tail")
    func linkFolding() {
        // "see [text](http://x.co) end" — [ at [4,1], "](http://x.co)" at [9,14].
        let result = folds("see [text](http://x.co) end", caret: 26)
        #expect(result.count == 2)
        #expect(contains(result, location: 4, length: 1))
        #expect(contains(result, location: 9, length: 14))
    }

    @Test("Caret inside a link (label or url) reveals the whole link")
    func linkCaretInside() {
        #expect(folds("see [text](http://x.co) end", caret: 7).isEmpty)  // in label
        #expect(folds("see [text](http://x.co) end", caret: 15).isEmpty) // in url
    }

    @Test("Image references are never folded")
    func imageNotFolded() {
        #expect(folds("shot: ![alt](img.png) done", caret: 0).isEmpty)
    }

    @Test("A link inside an inline code span is not folded as a link")
    func linkInsideCodeSpan() {
        // "`[a](b)` and text" — only the two backticks fold.
        let result = folds("`[a](b)` and text", caret: 12)
        #expect(result.count == 2)
        #expect(contains(result, location: 0, length: 1))
        #expect(contains(result, location: 7, length: 1))
    }

    @Test("A wikilink is not mis-read as a markdown link")
    func wikilinkNotLink() {
        // Only the wikilink brackets fold — no 1-char "[" fold anywhere.
        let result = folds("see [[Note]] end", caret: 0)
        #expect(result.allSatisfy { $0.length == 2 })
    }

    // MARK: - Fenced code blocks

    @Test("Nothing folds inside a backtick fence")
    func fenceExcludesInline() {
        #expect(folds("```\n**bold** and `code`\n```\nafter", caret: 30).isEmpty)
    }

    @Test("A heading-looking line inside a fence does not fold; one outside does")
    func fenceExcludesHeading() {
        // "```\n# not a heading\n```\n# real\n" — only "# real" folds.
        let result = folds("```\n# not a heading\n```\n# real\nx", caret: 31)
        #expect(result.count == 1)
        #expect(contains(result, location: 24, length: 2))
    }

    @Test("Nothing folds inside a tilde fence")
    func tildeFenceExcludes() {
        #expect(folds("~~~\n**bold** ~~x~~\n~~~\nafter", caret: 25).isEmpty)
    }

    @Test("A tilde fence line inside a backtick fence does not close it")
    func mixedFenceChars() {
        // The ~~~ line is content of the ``` fence; **bold** stays excluded,
        // while **b2** after the real close folds.
        let result = folds("```\n~~~\n**bold**\n```\nafter **b2**", caret: 22)
        #expect(result.count == 2)
        #expect(contains(result, location: 27, length: 2))
        #expect(contains(result, location: 31, length: 2))
    }

    @Test("An unterminated fence excludes everything after it")
    func unterminatedFence() {
        // "**a**" before the fence folds; "**inside**" after the open fence doesn't.
        let result = folds("before **a**\n```\n**inside**", caret: 0)
        #expect(result.count == 2)
        #expect(contains(result, location: 7, length: 2))
        #expect(contains(result, location: 10, length: 2))
    }
}

@Suite("MarkerFolding link hit testing")
struct MarkerFoldingLinkTargetTests {
    @Test("Index on the link label resolves to its URL")
    func labelHit() {
        let text = "see [text](http://x.co) end"
        #expect(MarkerFolding.linkTarget(at: 5, in: text) == "http://x.co")
        #expect(MarkerFolding.linkTarget(at: 8, in: text) == "http://x.co") // last label char
    }

    @Test("Indexes outside the label are not hits")
    func nonLabelMisses() {
        let text = "see [text](http://x.co) end"
        #expect(MarkerFolding.linkTarget(at: 0, in: text) == nil)   // body text
        #expect(MarkerFolding.linkTarget(at: 4, in: text) == nil)   // the [
        #expect(MarkerFolding.linkTarget(at: 9, in: text) == nil)   // the ]
        #expect(MarkerFolding.linkTarget(at: 15, in: text) == nil)  // inside the url
        #expect(MarkerFolding.linkTarget(at: 25, in: text) == nil)  // after the link
    }

    @Test("Image references are not link hits")
    func imageMiss() {
        let text = "shot: ![alt](img.png) done"
        #expect(MarkerFolding.linkTarget(at: 9, in: text) == nil)
    }

    @Test("Links inside inline code spans are not hits")
    func codeSpanMiss() {
        let text = "`[a](b)` and text"
        #expect(MarkerFolding.linkTarget(at: 2, in: text) == nil)
    }

    @Test("Links inside fenced code blocks are not hits")
    func fenceMiss() {
        let text = "```\n[a](http://b.c)\n```"
        #expect(MarkerFolding.linkTarget(at: 5, in: text) == nil)
    }

    @Test("Wikilinks are not link hits")
    func wikilinkMiss() {
        let text = "see [[Note]] end"
        #expect(MarkerFolding.linkTarget(at: 7, in: text) == nil)
    }

    @Test("URL whitespace is trimmed; an empty url is not a hit")
    func urlTrimmingAndEmpty() {
        #expect(MarkerFolding.linkTarget(at: 1, in: "[t]( http://x.co )") == "http://x.co")
        #expect(MarkerFolding.linkTarget(at: 1, in: "[t]()") == nil)
    }

    @Test("Emoji before the link keeps UTF-16 label offsets correct")
    func emojiOffsets() {
        // "😀 [go](http://x.co)" — 😀 is 2 UTF-16 units, so [ is at 3 and the
        // label "go" spans [4,2].
        let text = "😀 [go](http://x.co)"
        #expect(MarkerFolding.linkTarget(at: 4, in: text) == "http://x.co")
        #expect(MarkerFolding.linkTarget(at: 3, in: text) == nil) // the [
        #expect(MarkerFolding.linkTarget(at: 6, in: text) == nil) // the ]
    }
}

@Suite("MarkerFolding scoped invalidation")
struct MarkerFoldingInvalidationTests {
    private func range(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    private func equalRanges(_ lhs: [NSRange], _ rhs: [NSRange]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { NSEqualRanges($0, $1) }
    }

    // MARK: - invalidationRanges

    @Test("Identical fold sets invalidate nothing")
    func noChangeInvalidatesNothing() {
        let text = "aaaa\nbbbb" as NSString
        let same = [range(0, 2), range(5, 2)]
        #expect(MarkerFolding.invalidationRanges(old: same, new: same, in: text).isEmpty)
    }

    @Test("A newly folded range invalidates only its paragraph")
    func newFoldInvalidatesItsParagraph() {
        // "aaaa\nbbbb" — paragraph 1 = [0,5] (includes the newline).
        let text = "aaaa\nbbbb" as NSString
        let result = MarkerFolding.invalidationRanges(
            old: [],
            new: [range(1, 2)],
            in: text
        )
        #expect(equalRanges(result, [range(0, 5)]))
    }

    @Test("A removed fold invalidates only its paragraph")
    func removedFoldInvalidatesItsParagraph() {
        let text = "aaaa\nbbbb" as NSString
        let result = MarkerFolding.invalidationRanges(
            old: [range(6, 1)],
            new: [],
            in: text
        )
        // Paragraph 2 = [5,4] (last line, no trailing newline).
        #expect(equalRanges(result, [range(5, 4)]))
    }

    @Test("A caret move never invalidates an unchanged middle paragraph")
    func caretMoveKeepsMiddleParagraphUntouched() {
        // Three paragraphs: [0,5], [5,5], [10,4]. Change the first and last only.
        let text = "aaaa\nbbbb\ncccc" as NSString
        let old = [range(1, 1), range(6, 1), range(11, 1)] // all three folded
        let new = [range(6, 1)] // first & last revealed (caret moved into them)
        let result = MarkerFolding.invalidationRanges(old: old, new: new, in: text)
        // Only paragraphs 1 and 3 change; the unchanged middle [5,5] is absent,
        // and the whole document is never returned as one range.
        #expect(result.count == 2)
        #expect(result.contains { NSEqualRanges($0, range(0, 5)) })
        #expect(result.contains { NSEqualRanges($0, range(10, 4)) })
        #expect(!result.contains { NSEqualRanges($0, range(0, 14)) })
        #expect(!result.contains { $0.location <= 5 && $0.location + $0.length >= 10 })
    }

    @Test("Two changed folds in one paragraph collapse to a single invalidation")
    func twoFoldsSameParagraphMerge() {
        // "**a** more **b**" is one paragraph; two folds change → one range.
        let text = "**a** more **b**" as NSString
        let result = MarkerFolding.invalidationRanges(
            old: [],
            new: [range(0, 2), range(11, 2)],
            in: text
        )
        #expect(result.count == 1)
        #expect(NSEqualRanges(result[0], text.paragraphRange(for: range(0, 0))))
    }

    @Test("Stale offsets past end are clamped, not crashed")
    func staleOffsetClamped() {
        // After a deletion an old fold may point past the end; must not crash.
        let text = "short" as NSString
        let result = MarkerFolding.invalidationRanges(
            old: [range(999, 2)],
            new: [],
            in: text
        )
        #expect(result.count == 1)
        #expect(result[0].location + result[0].length <= text.length)
    }

    // MARK: - mergeRanges

    @Test("Overlapping ranges merge")
    func mergeOverlapping() {
        let merged = MarkerFolding.mergeRanges([range(0, 6), range(4, 4)])
        #expect(equalRanges(merged, [range(0, 8)]))
    }

    @Test("Touching ranges merge")
    func mergeTouching() {
        let merged = MarkerFolding.mergeRanges([range(0, 5), range(5, 4)])
        #expect(equalRanges(merged, [range(0, 9)]))
    }

    @Test("Disjoint ranges stay separate and sorted")
    func mergeDisjoint() {
        let merged = MarkerFolding.mergeRanges([range(5, 2), range(0, 3)])
        #expect(equalRanges(merged, [range(0, 3), range(5, 2)]))
    }

    @Test("Empty input yields empty output")
    func mergeEmpty() {
        #expect(MarkerFolding.mergeRanges([]).isEmpty)
    }
}
