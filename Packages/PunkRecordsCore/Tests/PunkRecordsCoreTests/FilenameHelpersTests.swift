import Testing
@testable import PunkRecordsCore

@Suite("Filename Helpers Tests")
struct FilenameHelpersTests {

    // MARK: - sanitizeFilename

    @Test("Replaces forward slashes with dashes")
    func sanitizeSlashes() {
        #expect(FilenameHelpers.sanitizeFilename("foo/bar") == "foo-bar")
        #expect(FilenameHelpers.sanitizeFilename("a/b/c") == "a-b-c")
    }

    @Test("Strips path-unsafe characters across the set")
    func sanitizeUnsafeCharacters() {
        #expect(FilenameHelpers.sanitizeFilename("a\\b") == "a-b")
        #expect(FilenameHelpers.sanitizeFilename("hello:world") == "hello-world")
        #expect(FilenameHelpers.sanitizeFilename("a*b?c") == "a-b-c")
        #expect(FilenameHelpers.sanitizeFilename(#"a"b"#) == "a-b")
        #expect(FilenameHelpers.sanitizeFilename("a<b>c") == "a-b-c")
        #expect(FilenameHelpers.sanitizeFilename("a|b") == "a-b")
    }

    @Test("Leaves safe names unchanged")
    func sanitizeSafe() {
        #expect(FilenameHelpers.sanitizeFilename("Mark's Backlog") == "Mark's Backlog")
        #expect(FilenameHelpers.sanitizeFilename("2026-05-16 Digest") == "2026-05-16 Digest")
    }

    // MARK: - replaceFirstH1

    @Test("Replaces existing H1 in the body")
    func replaceExistingH1() {
        let content = """
        ---
        id: 1
        ---

        # Untitled

        Some body text.
        """
        let result = FilenameHelpers.replaceFirstH1(in: content, with: "Mark's Backlog")
        #expect(result.contains("# Mark's Backlog"))
        #expect(!result.contains("# Untitled"))
        #expect(result.contains("Some body text."))
        // Frontmatter preserved
        #expect(result.contains("id: 1"))
    }

    @Test("Does not touch H1-looking lines inside frontmatter")
    func ignoresH1InsideFrontmatter() {
        // The `# foo` inside frontmatter is a YAML comment, not a heading.
        let content = """
        ---
        id: 1
        # foo
        ---

        # Real Heading

        Body.
        """
        let result = FilenameHelpers.replaceFirstH1(in: content, with: "New Title")
        #expect(result.contains("# foo"))
        #expect(result.contains("# New Title"))
        #expect(!result.contains("# Real Heading"))
    }

    @Test("Inserts H1 when none exists in body")
    func insertWhenMissing() {
        let content = """
        ---
        id: 1
        ---

        Just a paragraph with no heading.
        """
        let result = FilenameHelpers.replaceFirstH1(in: content, with: "Fresh Title")
        #expect(result.contains("# Fresh Title"))
        #expect(result.contains("Just a paragraph with no heading."))
    }

    @Test("Inserts H1 in content without frontmatter")
    func insertWithoutFrontmatter() {
        let content = "Just some text.\nAnother line."
        let result = FilenameHelpers.replaceFirstH1(in: content, with: "Title")
        #expect(result.contains("# Title"))
        #expect(result.contains("Just some text."))
    }

    @Test("Replaces only the first H1, leaves later headings alone")
    func replacesFirstOnly() {
        let content = """
        # First

        # Second

        ## Subheading
        """
        let result = FilenameHelpers.replaceFirstH1(in: content, with: "Replaced")
        #expect(result.contains("# Replaced"))
        #expect(result.contains("# Second"))
        #expect(result.contains("## Subheading"))
    }

    @Test("Ignores H2 and deeper headings when looking for the first H1")
    func ignoresDeeperHeadings() {
        let content = """
        ## Subheading first

        # Actual H1
        """
        let result = FilenameHelpers.replaceFirstH1(in: content, with: "Replaced")
        #expect(result.contains("## Subheading first"))
        #expect(result.contains("# Replaced"))
        #expect(!result.contains("# Actual H1"))
    }

    // MARK: - uniqueNotePath

    @Test("Returns base name when path is free")
    func uniqueBase() async {
        let result = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { _ in false }
        #expect(result == "Untitled.md")
    }

    @Test("Bumps to ' 2' when base is taken")
    func uniqueSecond() async {
        let taken: Set<String> = ["Untitled.md"]
        let result = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { taken.contains($0) }
        #expect(result == "Untitled 2.md")
    }

    @Test("Continues bumping past consecutive collisions")
    func uniqueFifth() async {
        let taken: Set<String> = [
            "Untitled.md",
            "Untitled 2.md",
            "Untitled 3.md",
            "Untitled 4.md",
        ]
        let result = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { taken.contains($0) }
        #expect(result == "Untitled 5.md")
    }
}
