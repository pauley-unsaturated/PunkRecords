import Foundation

/// One PDF page's extracted plain text.
public struct PDFPageText: Sendable, Equatable, Codable {
    /// 1-based page number, matching the `#page=N` fragment convention Safari
    /// and Preview honor.
    public let pageNumber: Int
    public let text: String

    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}

/// The structured output of extracting text from a PDF: per-page text plus
/// whatever title PDFKit's document metadata offers. Kept separate from
/// ``WebContent`` (rather than trying to shoehorn page numbers into
/// `WebHeading`) so citation resolution can work at page granularity — see
/// ``PDFSummaryRenderer``.
public struct PDFExtractionResult: Sendable, Equatable, Codable {
    public let title: String?
    public let pages: [PDFPageText]

    public init(title: String?, pages: [PDFPageText]) {
        self.title = title
        self.pages = pages
    }

    /// Total extracted character count across every page — the "extracted
    /// content stats" signal used to decide whether extraction actually
    /// produced anything (an encrypted or scanned-image-only PDF yields no
    /// text).
    public var totalTextLength: Int { pages.reduce(0) { $0 + $1.text.count } }
}

/// Errors a ``PDFIngestExtracting`` implementation can throw.
public enum PDFIngestError: Error, Sendable, Equatable {
    /// The bytes were not a readable PDF (corrupt, or password-protected
    /// without an empty-password unlock).
    case unreadable(String)
    /// The PDF opened but no page yielded extractable text (e.g. a
    /// scanned-image-only PDF with no OCR layer).
    case noTextExtractable
}

/// Extracts per-page text from PDF bytes. The real implementation
/// (`PDFKitTextExtractor`, Infra) uses PDFKit — kept behind this Core
/// protocol so Core itself never imports PDFKit (see PUNK-zup's scoping
/// notes: this repo has one pre-existing exception, `PDFChatAttachmentHandler`,
/// which imports PDFKit directly in Core; new ingest code follows the
/// documented Core/Infra boundary instead of that precedent).
public protocol PDFIngestExtracting: Sendable {
    /// - Parameters:
    ///   - data: the raw PDF bytes (already fetched — this protocol does no
    ///     I/O of its own).
    ///   - sourceURL: the URL the bytes came from, for citation link building.
    func extract(data: Data, sourceURL: URL) throws -> PDFExtractionResult
}
