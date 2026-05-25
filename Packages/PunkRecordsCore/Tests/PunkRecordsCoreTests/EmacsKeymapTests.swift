import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("EmacsKeymap Tests")
struct EmacsKeymapTests {
    private func chord(_ key: String, control: Bool = false, meta: Bool = false) -> EmacsKeyChord {
        EmacsKeyChord(key: key, control: control, meta: meta)
    }

    @Test("Meta word motions map")
    func metaWordMotions() {
        #expect(EmacsKeymap.command(for: chord("f", meta: true)) == .forwardWord)
        #expect(EmacsKeymap.command(for: chord("b", meta: true)) == .backwardWord)
    }

    @Test("Meta kill/case/transpose map")
    func metaEditing() {
        #expect(EmacsKeymap.command(for: chord("d", meta: true)) == .killWord)
        #expect(EmacsKeymap.command(for: chord("\u{7f}", meta: true)) == .backwardKillWord)
        #expect(EmacsKeymap.command(for: chord("w", meta: true)) == .copyRegion)
        #expect(EmacsKeymap.command(for: chord("c", meta: true)) == .capitalizeWord)
        #expect(EmacsKeymap.command(for: chord("u", meta: true)) == .upcaseWord)
        #expect(EmacsKeymap.command(for: chord("l", meta: true)) == .downcaseWord)
        #expect(EmacsKeymap.command(for: chord("t", meta: true)) == .transposeWords)
        #expect(EmacsKeymap.command(for: chord("y", meta: true)) == .yankPop)
    }

    @Test("Meta buffer/paragraph motions map")
    func metaBufferMotions() {
        #expect(EmacsKeymap.command(for: chord("<", meta: true)) == .beginningOfBuffer)
        #expect(EmacsKeymap.command(for: chord(">", meta: true)) == .endOfBuffer)
        #expect(EmacsKeymap.command(for: chord("{", meta: true)) == .backwardParagraph)
        #expect(EmacsKeymap.command(for: chord("}", meta: true)) == .forwardParagraph)
    }

    @Test("Control mark/kill/quit/yank/undo map")
    func controlChords() {
        #expect(EmacsKeymap.command(for: chord(" ", control: true)) == .setMark)
        #expect(EmacsKeymap.command(for: chord("g", control: true)) == .keyboardQuit)
        #expect(EmacsKeymap.command(for: chord("w", control: true)) == .killRegion)
        #expect(EmacsKeymap.command(for: chord("y", control: true)) == .yank)
        #expect(EmacsKeymap.command(for: chord("/", control: true)) == .undo)
        #expect(EmacsKeymap.command(for: chord("_", control: true)) == .undo)
    }

    @Test("Plain keys and unmapped chords return nil")
    func unmappedReturnNil() {
        #expect(EmacsKeymap.command(for: chord("f")) == nil)               // no modifier
        #expect(EmacsKeymap.command(for: chord("z", meta: true)) == nil)   // unmapped meta
        #expect(EmacsKeymap.command(for: chord("q", control: true)) == nil) // unmapped control
    }

    @Test("Control+Meta combos are not mapped (reserved)")
    func controlMetaUnmapped() {
        #expect(EmacsKeymap.command(for: chord("f", control: true, meta: true)) == nil)
    }
}
