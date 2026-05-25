import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("PreviewLinkRewriter Tests")
struct PreviewLinkRewriterTests {
    @Test("Plain wikilink becomes a note link")
    func plainWikilink() {
        let out = PreviewLinkRewriter.rewrite("See [[Foo Bar]] today")
        #expect(out == "See [Foo Bar](punk://note/Foo%20Bar) today")
    }

    @Test("Aliased wikilink uses the alias as display text, target in the URL")
    func aliasedWikilink() {
        let out = PreviewLinkRewriter.rewrite("[[Target Note|the alias]]")
        #expect(out == "[the alias](punk://note/Target%20Note)")
    }

    @Test("Tag becomes a tag link")
    func tag() {
        let out = PreviewLinkRewriter.rewrite("tagged #swift here")
        #expect(out == "tagged [#swift](punk://tag/swift) here")
    }

    @Test("Hierarchical tag keeps its slash in the path")
    func hierarchicalTag() {
        // '/' is path-legal and round-trips via URL.path, so it stays unescaped.
        let out = PreviewLinkRewriter.rewrite("#area/work")
        #expect(out == "[#area/work](punk://tag/area/work)")
    }

    @Test("Fenced code blocks are left untouched (no #include rewrite)")
    func fencedCodeUntouched() {
        let md = """
        before #tag
        ```cpp
        #include <cmath>
        auto x = [[notlink]];
        ```
        after #tag
        """
        let out = PreviewLinkRewriter.rewrite(md)
        #expect(out.contains("#include <cmath>"))
        #expect(out.contains("[[notlink]]"))
        // Tags outside the fence still convert.
        #expect(out.contains("before [#tag](punk://tag/tag)"))
        #expect(out.contains("after [#tag](punk://tag/tag)"))
    }

    @Test("Inline code spans are left untouched")
    func inlineCodeUntouched() {
        let out = PreviewLinkRewriter.rewrite("use `#define` not #macro")
        #expect(out.contains("`#define`"))
        #expect(out.contains("[#macro](punk://tag/macro)"))
    }

    @Test("Standard markdown links and URL fragments are not mangled")
    func standardLinksUntouched() {
        let md = "[docs](https://example.com/page#section)"
        let out = PreviewLinkRewriter.rewrite(md)
        #expect(out == md, "existing links and #fragments after word chars stay intact")
    }

    @Test("A # mid-word is not a tag")
    func hashMidWord() {
        let out = PreviewLinkRewriter.rewrite("C# is a language")
        #expect(out == "C# is a language")
    }

    @Test("Multiple wikilinks and tags on one line all convert")
    func multiplePerLine() {
        let out = PreviewLinkRewriter.rewrite("[[A]] and [[B]] with #x and #y")
        #expect(out == "[A](punk://note/A) and [B](punk://note/B) with [#x](punk://tag/x) and [#y](punk://tag/y)")
    }
}
