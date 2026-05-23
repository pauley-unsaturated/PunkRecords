import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("Editor decoration performance")
struct EditorDecorationPerfTests {
    /// Builds a synthetic markdown document of roughly the requested byte size,
    /// dense with the constructs every decoration pass scans for.
    private func makeDocument(approxBytes: Int) -> String {
        let unit = "## Heading with **bold** *italic* `code` [[Note]] #tag and text.\n"
        let count = max(1, approxBytes / unit.utf8.count)
        return String(repeating: unit, count: count)
    }

    private func hostedTextView(_ text: String) -> NSTextView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = tv
        tv.string = text
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.setSelectedRange(NSRange(location: min(1000, (text as NSString).length), length: 0))
        return tv
    }

    @Test("Visible-range scan stays tiny on a ~10MB document")
    func scanRangeBounded() {
        let text = makeDocument(approxBytes: 10_000_000)
        let tv = hostedTextView(text)
        let scan = EditorDecorationRange.scanRange(for: tv)
        // The visible window + buffer must be a sliver of the whole document.
        #expect(scan.length < 100_000, "scan range \(scan.length) should be far smaller than the doc")
        #expect(scan.length < (text as NSString).length)
    }

    @Test("Full decoration pass on a ~10MB document beats the 50ms frame budget")
    func tenMegabyteUnderBudget() {
        let text = makeDocument(approxBytes: 10_000_000)
        let tv = hostedTextView(text)
        let hybrid = HybridUXDecorator()
        let wiki = WikilinkDecorator(isResolved: { _ in true })

        // Warm up layout so we measure decoration, not first-layout cost.
        _ = EditorDecorationRange.scanRange(for: tv)

        let start = ContinuousClock.now
        hybrid.decorate(textView: tv)
        wiki.decorate(textView: tv)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(50), "decoration took \(elapsed), expected < 50ms")
    }

    @Test("Off-screen text view (no layout) decorates the whole small document")
    func offscreenFallsBackToFull() {
        // An NSTextView with no bounded visibleRect should decorate everything,
        // so unit tests on small docs keep working.
        let tv = NSTextView()
        tv.string = "# A\n\n## B\n\nbody"
        let scan = EditorDecorationRange.scanRange(for: tv)
        #expect(scan.length == (tv.string as NSString).length)
    }
}
