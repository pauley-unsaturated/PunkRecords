import Foundation
import Testing
@testable import PunkRecordsCore

struct ChatAttachmentPolicyTests {
    @Test func estimatedTokensIncludesPromptAndAttachments() {
        let attachment = ChatAttachmentMetadata(
            bookmarkBase64: "bookmark",
            filename: "notes.md",
            byteCount: 4_000,
            type: .text
        )

        let tokens = ChatAttachmentPolicy.estimatedTokens(
            prompt: String(repeating: "a", count: 400),
            attachments: [attachment]
        )

        #expect(tokens == 1_100)
    }

    @Test func confirmationTriggersForLargeTotalEstimate() {
        let attachment = ChatAttachmentMetadata(
            bookmarkBase64: "bookmark",
            filename: "large.md",
            byteCount: 210_000,
            type: .text
        )

        #expect(ChatAttachmentPolicy.needsConfirmation(prompt: "Summarize", attachments: [attachment]))
    }

    @Test func confirmationTriggersForSingleLargeAttachment() {
        let attachment = ChatAttachmentMetadata(
            bookmarkBase64: "bookmark",
            filename: "scan.pdf",
            byteCount: 21 * 1_024 * 1_024,
            type: .pdf
        )

        #expect(ChatAttachmentPolicy.needsConfirmation(prompt: "Read this", attachments: [attachment]))
    }

    @Test func transcriptCommentRoundTripsAttachmentMetadata() throws {
        let attachment = ChatAttachmentMetadata(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            bookmarkBase64: "Ym9va21hcms=",
            filename: "paper.pdf",
            byteCount: 42,
            type: .pdf
        )

        let comment = try ChatAttachmentPolicy.transcriptComments(for: [attachment])
        #expect(comment.hasPrefix("<!-- attachment: "))
        #expect(comment.hasSuffix(" -->"))

        let jsonStart = comment.index(comment.startIndex, offsetBy: "<!-- attachment: ".count)
        let jsonEnd = comment.index(comment.endIndex, offsetBy: -" -->".count)
        let json = String(comment[jsonStart..<jsonEnd])
        let decoded = try JSONDecoder().decode(ChatAttachmentMetadata.self, from: Data(json.utf8))

        #expect(decoded == attachment)
    }
}
