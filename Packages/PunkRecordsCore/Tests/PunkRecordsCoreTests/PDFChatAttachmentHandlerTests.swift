import AppKit
import Foundation
import Testing
@testable import PunkRecordsCore

struct PDFChatAttachmentHandlerTests {
    @Test func pdfTextExtractsIntoPromptBlockWithPageMetadata() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("paper.pdf")
        try writePDF(url, pages: ["First page heading", "Second page notes"])

        let payload = try PDFChatAttachmentHandler.payload(for: input(for: url), homeDirectory: root)

        #expect(payload.metadata.pageCount == 2)
        #expect(payload.metadata.processingNote == "text extracted, 2 pages")
        #expect(payload.metadata.estimatedTokens == TokenEstimator.estimateTokens(in: payload.extractedText))
        #expect(payload.promptBlock.contains("### paper.pdf (~/paper.pdf)"))
        #expect(payload.promptBlock.contains("Pages: 2"))
        #expect(payload.promptBlock.contains("--- Page 1 ---"))
        #expect(payload.promptBlock.contains("First page heading"))
        #expect(payload.promptBlock.contains("--- Page 2 ---"))
        #expect(payload.promptBlock.contains("Second page notes"))
    }

    @Test func promptAppendsPDFExtractsAfterUserText() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("brief.pdf")
        try writePDF(url, pages: ["Briefing text"])

        let prompt = try PDFChatAttachmentHandler.prompt(
            userText: "Summarize",
            attachments: [input(for: url)],
            homeDirectory: root
        )

        #expect(prompt.hasPrefix("Summarize"))
        #expect(prompt.contains("Attached PDF text extracts:"))
        #expect(prompt.contains("Briefing text"))
    }

    @Test func scannedPDFWithoutTextIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("scan.pdf")
        try writePDF(url, pages: [""])

        #expect(throws: PDFChatAttachmentError.noTextExtractable("scan.pdf")) {
            try PDFChatAttachmentHandler.payload(for: input(for: url), homeDirectory: root)
        }
    }

    @Test func largePageCountWarnsAndOversizedFileIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("long.pdf")
        try writePDF(url, pages: (1...101).map { "Page \($0)" })

        let payload = try PDFChatAttachmentHandler.payload(for: input(for: url), homeDirectory: root)
        #expect(payload.metadata.pageCount == 101)
        #expect(payload.warning?.contains("101 pages") == true)

        let oversized = PDFChatAttachmentInput(
            url: url,
            metadata: ChatAttachmentMetadata(
                bookmarkBase64: "bookmark",
                filename: "too-large.pdf",
                byteCount: PDFChatAttachmentHandler.maximumByteCount + 1,
                type: .pdf
            )
        )
        #expect(throws: PDFChatAttachmentError.fileTooLarge(
            byteCount: PDFChatAttachmentHandler.maximumByteCount + 1,
            limit: PDFChatAttachmentHandler.maximumByteCount
        )) {
            try PDFChatAttachmentHandler.payload(for: oversized, homeDirectory: root)
        }
    }

    private func input(for url: URL) throws -> PDFChatAttachmentInput {
        let byteCount = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return PDFChatAttachmentInput(
            url: url,
            metadata: ChatAttachmentMetadata(
                bookmarkBase64: "bookmark",
                filename: url.lastPathComponent,
                byteCount: byteCount?.int64Value ?? 0,
                type: .pdf
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePDF(_ url: URL, pages: [String]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                (text as NSString).draw(
                    in: CGRect(x: 72, y: 700, width: 468, height: 40),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
                )
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        try data.write(to: url, options: .atomic)
    }
}
