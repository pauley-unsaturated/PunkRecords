import Foundation
import PDFKit

public struct PDFChatAttachmentInput {
    public let url: URL
    public let metadata: ChatAttachmentMetadata

    public init(url: URL, metadata: ChatAttachmentMetadata) {
        self.url = url
        self.metadata = metadata
    }
}

public struct PDFChatAttachmentPayload: Equatable, Sendable {
    public let metadata: ChatAttachmentMetadata
    public let promptBlock: String
    public let extractedText: String
    public let warning: String?
}

public enum PDFChatAttachmentHandler {
    public static let maximumByteCount: Int64 = 32 * 1_024 * 1_024
    public static let warningPageThreshold = 100

    public static func prompt(
        userText: String,
        attachments: [PDFChatAttachmentInput],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let pdfAttachments = attachments.filter { $0.metadata.type == .pdf }
        guard !pdfAttachments.isEmpty else { return userText }

        let blocks = try pdfAttachments.map {
            try payload(for: $0, homeDirectory: homeDirectory).promptBlock
        }
        var parts: [String] = []
        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUserText.isEmpty {
            parts.append(trimmedUserText)
        }
        parts.append("Attached PDF text extracts:\n\n" + blocks.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    public static func payload(
        for input: PDFChatAttachmentInput,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> PDFChatAttachmentPayload {
        guard input.metadata.type == .pdf else {
            throw PDFChatAttachmentError.unsupportedType(input.metadata.filename)
        }
        guard input.metadata.byteCount <= maximumByteCount else {
            throw PDFChatAttachmentError.fileTooLarge(
                byteCount: input.metadata.byteCount,
                limit: maximumByteCount
            )
        }

        let didAccess = input.url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                input.url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: input.url) else {
            throw PDFChatAttachmentError.unreadable(input.metadata.filename)
        }
        if document.isEncrypted && !document.unlock(withPassword: "") {
            throw PDFChatAttachmentError.passwordRequired(input.metadata.filename)
        }

        let pages = document.pageCount
        let extractedText = extractText(from: document)
        guard !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PDFChatAttachmentError.noTextExtractable(input.metadata.filename)
        }

        let metadata = ChatAttachmentMetadata(
            id: input.metadata.id,
            bookmarkBase64: input.metadata.bookmarkBase64,
            filename: input.metadata.filename,
            byteCount: input.metadata.byteCount,
            type: .pdf,
            estimatedTokens: TokenEstimator.estimateTokens(in: extractedText),
            pageCount: pages,
            processingNote: "text extracted, \(pages) \(pages == 1 ? "page" : "pages")"
        )
        return PDFChatAttachmentPayload(
            metadata: metadata,
            promptBlock: promptBlock(
                filename: metadata.filename,
                path: displayPath(for: input.url, homeDirectory: homeDirectory),
                pageCount: pages,
                text: extractedText
            ),
            extractedText: extractedText,
            warning: warning(for: metadata)
        )
    }

    private static func extractText(from document: PDFDocument) -> String {
        (0..<document.pageCount)
            .compactMap { pageIndex -> String? in
                guard let text = document.page(at: pageIndex)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return "--- Page \(pageIndex + 1) ---\n\(text)"
            }
            .joined(separator: "\n\n")
    }

    private static func promptBlock(filename: String, path: String, pageCount: Int, text: String) -> String {
        """
        ### \(filename) (\(path))
        Pages: \(pageCount)
        Extraction: PDFKit text extracted

        ```text
        \(text)
        ```
        """
    }

    private static func displayPath(for url: URL, homeDirectory: URL) -> String {
        let homePath = homeDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath == homePath {
            return "~"
        }
        if filePath.hasPrefix(homePath + "/") {
            return "~/" + String(filePath.dropFirst(homePath.count + 1))
        }
        return filePath
    }

    private static func warning(for metadata: ChatAttachmentMetadata) -> String? {
        guard let pageCount = metadata.pageCount, pageCount > warningPageThreshold else { return nil }
        return "\(metadata.filename) has \(pageCount) pages. Large PDFs can make chat responses slower."
    }
}

public enum PDFChatAttachmentError: LocalizedError, Equatable {
    case unsupportedType(String)
    case unreadable(String)
    case passwordRequired(String)
    case noTextExtractable(String)
    case fileTooLarge(byteCount: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let filename):
            return "\(filename) is not a PDF attachment."
        case .unreadable(let filename):
            return "\(filename) could not be opened as a PDF."
        case .passwordRequired(let filename):
            return "\(filename) is password-protected. Password-protected PDFs are not supported yet."
        case .noTextExtractable(let filename):
            return "\(filename) appears to be scanned; no text extractable. Image OCR is not yet supported."
        case .fileTooLarge(let byteCount, let limit):
            let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "PDF attachment is \(size), which exceeds the \(limit) limit."
        }
    }
}
