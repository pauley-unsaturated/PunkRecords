import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("VaultPaths — image attachment convention")
struct VaultPathsTests {

    @Test("Image directory mirrors the note's hierarchy under attachments/")
    func imageDirectoryMirrorsNotePath() {
        #expect(VaultPaths.imageDirectory(forNoteAt: "Hello.md") == "attachments/Hello")
        #expect(VaultPaths.imageDirectory(forNoteAt: "Daily/2026-05-18.md")
                == "attachments/Daily/2026-05-18")
        #expect(VaultPaths.imageDirectory(forNoteAt: "deep/nested/Note.md")
                == "attachments/deep/nested/Note")
    }

    @Test("First-attempt image path uses the sanitized filename verbatim")
    func firstAttemptKeepsFilename() async {
        let path = await VaultPaths.imagePath(
            forNoteAt: "Notes/Foo.md",
            originalFilename: "diagram.png",
            exists: { _ in false }
        )
        #expect(path == "attachments/Notes/Foo/diagram.png")
    }

    @Test("Whitespace and invalid chars in filename are sanitized")
    func filenameSanitization() async {
        let path = await VaultPaths.imagePath(
            forNoteAt: "X.md",
            originalFilename: "Screenshot 2026-05-18 at 09.42.31.png",
            exists: { _ in false }
        )
        #expect(path == "attachments/X/Screenshot-2026-05-18-at-09.42.31.png")
    }

    @Test("Filename with path separators is flattened — no escape from attachments/")
    func filenameCannotEscapeDirectory() async {
        let path = await VaultPaths.imagePath(
            forNoteAt: "X.md",
            originalFilename: "../../etc/passwd",
            exists: { _ in false }
        )
        // The note's image directory remains the prefix; '..' separators
        // get sanitized to '-' so the file can't climb out.
        #expect(path.hasPrefix("attachments/X/"))
        #expect(!path.contains(".."))
        #expect(!path.contains("/etc/"))
    }

    @Test("Collision gets a uuid suffix on the stem, extension preserved")
    func collisionGetsUuidSuffix() async {
        let path = await VaultPaths.imagePath(
            forNoteAt: "X.md",
            originalFilename: "foo.png",
            exists: { candidate in candidate == "attachments/X/foo.png" }
        )
        #expect(path != "attachments/X/foo.png")
        #expect(path.hasPrefix("attachments/X/foo-"))
        #expect(path.hasSuffix(".png"))
        // Stem includes the original plus a dash and an 8-char hex-ish suffix.
        let middle = path
            .replacingOccurrences(of: "attachments/X/foo-", with: "")
            .replacingOccurrences(of: ".png", with: "")
        #expect(middle.count == 8, "Expected 8-char suffix, got '\(middle)'")
    }

    @Test("Filename without extension keeps the no-extension form on collision")
    func collisionWithNoExtension() async {
        let path = await VaultPaths.imagePath(
            forNoteAt: "X.md",
            originalFilename: "README",
            exists: { candidate in candidate == "attachments/X/README" }
        )
        #expect(path.hasPrefix("attachments/X/README-"))
        #expect(!path.contains("."))
    }

    @Test("Markdown image reference uses vault-relative path, no leading slash")
    func markdownReferenceFormat() {
        let ref = VaultPaths.markdownImageReference(
            alt: "A diagram",
            imagePath: "attachments/Notes/Foo/diagram.png"
        )
        #expect(ref == "![A diagram](attachments/Notes/Foo/diagram.png)")
        #expect(!ref.contains("file://"))
        #expect(!ref.contains("](/"))
    }

    @Test("Spaces in image path are percent-encoded so markdown parses cleanly")
    func spacesPercentEncoded() {
        let ref = VaultPaths.markdownImageReference(
            alt: "alt",
            imagePath: "attachments/Note With Space/img.png"
        )
        #expect(ref.contains("Note%20With%20Space"))
    }

    @Test("Brackets in alt text are escaped")
    func altTextEscaped() {
        let ref = VaultPaths.markdownImageReference(
            alt: "alt [with] brackets",
            imagePath: "x.png"
        )
        #expect(ref.contains("alt \\[with\\] brackets"))
    }

    @Test("Empty alt text is permitted")
    func emptyAltAllowed() {
        let ref = VaultPaths.markdownImageReference(alt: "", imagePath: "x.png")
        #expect(ref == "![](x.png)")
    }
}
