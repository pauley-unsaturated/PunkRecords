import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("HeadingProps Tests")
struct HeadingPropsTests {
    private func heading(_ title: String, in text: String) -> HeadingNode {
        HeadingOutline.parse(text).first { $0.title == title }!
    }

    // MARK: - Caret → target

    @Test("Caret inside a section resolves to that heading; deepest wins")
    func caretResolvesHeading() {
        let text = "# A\nbody\n## B\nmore\n# C\ntail"
        let nodes = HeadingOutline.parse(text)
        let bStart = (text as NSString).range(of: "## B").location
        #expect(HeadingProps.target(forCaret: bStart + 1, in: nodes) == .heading(nodes[1]))
        // A caret in A's own body (before B) resolves to A.
        #expect(HeadingProps.target(forCaret: 2, in: nodes) == .heading(nodes[0]))
    }

    @Test("Caret above the first heading resolves to the document root")
    func caretResolvesRoot() {
        let text = "---\nid: 1\n---\n\nintro\n\n# A\nbody"
        let nodes = HeadingOutline.parse(text)
        #expect(HeadingProps.target(forCaret: 0, in: nodes) == .documentRoot)
        #expect(HeadingProps.target(forCaret: 5, in: nodes) == .documentRoot)
    }

    @Test("Caret at end of document resolves to the last heading")
    func caretAtEOF() {
        let text = "# A\n## B\ntail"
        let nodes = HeadingOutline.parse(text)
        #expect(HeadingProps.target(forCaret: (text as NSString).length, in: nodes) == .heading(nodes[1]))
    }

    // MARK: - Insert under a heading

    @Test("Insert places the callout directly under the heading, blank line before body")
    func insertUnderHeading() {
        let doc = "# Title\n\nIntro\n\n## Task\n\nbody\n"
        let block = PropsBlock(status: .doing)
        let out = HeadingProps.apply(block, to: doc, heading: heading("Task", in: doc))
        #expect(out == "# Title\n\nIntro\n\n## Task\n> [!props]\n> status:: doing\n\nbody\n")
        // Reading it back reproduces the block.
        #expect(HeadingProps.read(from: out, heading: heading("Task", in: out)) == block)
    }

    @Test("Insert keeps the body from being absorbed by the blockquote")
    func insertSeparatesBody() {
        let doc = "## Task\nimmediate body"
        let out = HeadingProps.apply(PropsBlock(status: .todo), to: doc, heading: heading("Task", in: doc))
        // Exactly one blank line separates the callout from the following paragraph.
        #expect(out.contains("> status:: todo\n\nimmediate body"))
    }

    @Test("Applying the same block twice replaces, never duplicates")
    func idempotentApply() {
        let doc = "# Title\n\n## Task\n\nbody\n"
        let block = PropsBlock(tags: ["x"], status: .doing)
        let once = HeadingProps.apply(block, to: doc, heading: heading("Task", in: doc))
        let twice = HeadingProps.apply(block, to: once, heading: heading("Task", in: once))
        #expect(once == twice)
        // Only one callout header in the result.
        #expect(once.components(separatedBy: "> [!props]").count == 2)
    }

    @Test("Replacing an existing block updates values in place")
    func replaceExisting() {
        let doc = "## Task\n> [!props]\n> status:: doing\n\nbody\n"
        let out = HeadingProps.apply(PropsBlock(status: .done), to: doc, heading: heading("Task", in: doc))
        #expect(out == "## Task\n> [!props]\n> status:: done\n\nbody\n")
    }

    @Test("Emptying a block removes the callout and restores the original text")
    func removeRestoresOriginal() {
        let original = "# Title\n\nIntro\n\n## Task\n\nbody\n"
        let withBlock = HeadingProps.apply(PropsBlock(status: .doing), to: original, heading: heading("Task", in: original))
        let cleared = HeadingProps.apply(PropsBlock(), to: withBlock, heading: heading("Task", in: withBlock))
        #expect(cleared == original)
    }

    // MARK: - Newline / EOF edge cases

    @Test("Heading at EOF with no trailing newline")
    func headingAtEOFNoNewline() {
        let doc = "# A\n## B"
        let out = HeadingProps.apply(PropsBlock(status: .todo), to: doc, heading: heading("B", in: doc))
        #expect(out == "# A\n## B\n> [!props]\n> status:: todo")
        #expect(!out.hasSuffix("\n"))   // no trailing-newline drift
        #expect(HeadingProps.read(from: out, heading: heading("B", in: out)) == PropsBlock(status: .todo))
    }

    @Test("Heading followed only by a trailing newline keeps that newline")
    func headingTrailingNewlineOnly() {
        let doc = "## H\n"
        let out = HeadingProps.apply(PropsBlock(status: .doing), to: doc, heading: heading("H", in: doc))
        #expect(out == "## H\n> [!props]\n> status:: doing\n")
        #expect(out.hasSuffix("\n"))
    }

    @Test("Insert in the middle does not disturb the document tail")
    func noTailDrift() {
        let doc = "# A\n\n## B\nbody\n\n# C\ntail\n"
        let out = HeadingProps.apply(PropsBlock(status: .doing), to: doc, heading: heading("B", in: doc))
        #expect(out.hasSuffix("# C\ntail\n"))
        #expect(out.contains("## B\n> [!props]\n> status:: doing\n\nbody"))
    }

    // MARK: - Emoji / CJK bodies

    @Test("Emoji and CJK content survive insertion and read-back")
    func unicodeContent() {
        let doc = "# 見出し 🎯\n\n本文の内容 with an emoji 😀\n"
        let block = PropsBlock(tags: ["日本語"], status: .doing)
        let out = HeadingProps.apply(block, to: doc, heading: heading("見出し 🎯", in: doc))
        #expect(out.contains("本文の内容 with an emoji 😀"))
        #expect(HeadingProps.read(from: out, heading: heading("見出し 🎯", in: out)) == block)
    }

    // MARK: - Frontmatter (document root)

    @Test("Reads managed + custom keys from frontmatter, hides system keys")
    func readFrontmatter() {
        let doc = """
        ---
        id: ABC
        created: 2026-01-01
        tags: [old, done]
        status: doing
        owner: Mark
        ---

        # Body
        """
        let block = HeadingProps.readFrontmatter(from: doc)
        #expect(block.tags == ["old", "done"])
        #expect(block.status == .doing)
        #expect(block.custom.map(\.key) == ["owner"])
        #expect(block.custom.first?.value == "Mark")
    }

    @Test("Writing frontmatter preserves system keys and replaces managed keys")
    func applyFrontmatter() {
        let doc = "---\nid: ABC\ncreated: 2026-01-01\ntags: [old]\n---\n\n# Body\n"
        let block = PropsBlock(
            tags: ["new"],
            status: .todo,
            scheduled: "2026-07-10",
            custom: [PropsField(key: "owner", value: "Mark")]
        )
        let out = HeadingProps.apply(block, to: doc, target: .documentRoot)
        #expect(out == """
        ---
        id: ABC
        created: 2026-01-01
        tags: [new]
        status: todo
        scheduled: 2026-07-10
        owner: Mark
        ---

        # Body

        """)
    }

    @Test("Frontmatter apply round-trips and is idempotent")
    func frontmatterRoundTrip() {
        let doc = "---\nid: ABC\ncreated: 2026-01-01\n---\n\n# Body\n"
        let block = PropsBlock(tags: ["a"], status: .done, due: "2026-07-20")
        let once = HeadingProps.apply(block, to: doc, target: .documentRoot)
        let twice = HeadingProps.apply(block, to: once, target: .documentRoot)
        #expect(once == twice)
        #expect(HeadingProps.readFrontmatter(from: once) == block)
    }

    @Test("Applying to a document without frontmatter creates one")
    func createsFrontmatter() {
        let doc = "# Just a heading\n\nbody\n"
        let out = HeadingProps.apply(PropsBlock(status: .todo), to: doc, target: .documentRoot)
        #expect(out == "---\nstatus: todo\n---\n\n# Just a heading\n\nbody\n")
    }

    @Test("Clearing frontmatter props leaves system keys intact")
    func clearFrontmatterKeepsSystem() {
        let doc = "---\nid: ABC\ntags: [x]\nstatus: doing\n---\n\n# Body\n"
        let out = HeadingProps.apply(PropsBlock(), to: doc, target: .documentRoot)
        #expect(out == "---\nid: ABC\n---\n\n# Body\n")
    }
}
