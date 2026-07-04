import Foundation
import Testing
@testable import PunkRecordsCore

struct TextChatAttachmentHandlerTests {
    @Test func textSwiftAndYAMLFilesRenderAsPromptBlocks() throws {
        let root = try makeTemporaryDirectory()
        let text = try write("notes.txt", contents: "hello notes", in: root)
        let swift = try write("Sources/App.swift", contents: "let answer = 42", in: root)
        let yaml = try write("config.yaml", contents: "name: punk\n", in: root)

        let prompt = try TextChatAttachmentHandler.prompt(
            userText: "Summarize these",
            attachments: [
                input(for: text),
                input(for: swift),
                input(for: yaml),
            ],
            homeDirectory: root
        )

        #expect(prompt.contains("Summarize these"))
        #expect(prompt.contains("### notes.txt (~/notes.txt)"))
        #expect(prompt.contains("```text\nhello notes\n```"))
        #expect(prompt.contains("### App.swift (~/Sources/App.swift)"))
        #expect(prompt.contains("```swift\nlet answer = 42\n```"))
        #expect(prompt.contains("### config.yaml (~/config.yaml)"))
        #expect(prompt.contains("```yaml\nname: punk\n\n```"))
    }

    @Test func estimatedTokensComeFromDecodedContent() throws {
        let root = try makeTemporaryDirectory()
        let url = try write("long.md", contents: String(repeating: "a", count: 400), in: root)

        let payload = try TextChatAttachmentHandler.payload(for: input(for: url), homeDirectory: root)

        #expect(payload.metadata.estimatedTokens == TokenEstimator.estimateTokens(in: payload.content))
        #expect(ChatAttachmentPolicy.estimatedTokens(for: payload.metadata) == 100)
    }

    @Test func binaryContentIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("object.txt")
        try Data([0x7f, 0x45, 0x4c, 0x46, 0x00]).write(to: url)

        #expect(throws: TextChatAttachmentError.binaryContent("object.txt")) {
            try TextChatAttachmentHandler.payload(for: input(for: url), homeDirectory: root)
        }
    }

    @Test func latin1ContentIsRejectedAsUnsupportedEncoding() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xe9]).write(to: url)

        #expect(throws: TextChatAttachmentError.encodingNotSupported("latin1.txt")) {
            try TextChatAttachmentHandler.payload(for: input(for: url), homeDirectory: root)
        }
    }

    @Test func largeFilesWarnAndOversizedFilesAreRejected() throws {
        let root = try makeTemporaryDirectory()
        let warningURL = try write(
            "warning.log",
            contents: String(repeating: "a", count: Int(TextChatAttachmentHandler.warningByteThreshold)),
            in: root
        )
        let warningPayload = try TextChatAttachmentHandler.payload(
            for: input(for: warningURL),
            homeDirectory: root
        )
        #expect(warningPayload.warning?.contains("warning.log") == true)

        let tooLarge = root.appendingPathComponent("too-large.txt")
        try Data(repeating: 0x61, count: Int(TextChatAttachmentHandler.maximumByteCount + 1))
            .write(to: tooLarge)

        #expect(throws: TextChatAttachmentError.fileTooLarge(
            byteCount: TextChatAttachmentHandler.maximumByteCount + 1,
            limit: TextChatAttachmentHandler.maximumByteCount
        )) {
            try TextChatAttachmentHandler.payload(for: input(for: tooLarge), homeDirectory: root)
        }
    }

    private func input(for url: URL) throws -> TextChatAttachmentInput {
        let byteCount = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return TextChatAttachmentInput(
            url: url,
            metadata: ChatAttachmentMetadata(
                bookmarkBase64: "bookmark",
                filename: url.lastPathComponent,
                byteCount: byteCount?.int64Value ?? 0,
                type: .text
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ path: String, contents: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
