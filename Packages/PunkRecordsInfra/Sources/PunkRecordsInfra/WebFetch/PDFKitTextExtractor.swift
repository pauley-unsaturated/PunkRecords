import Foundation
import PDFKit
import PunkRecordsCore

/// PDFKit-backed ``PDFIngestExtracting``: extracts per-page plain text from
/// PDF bytes. Fully offline/local — no network, so unlike
/// ``YouTubeTranscriptProvider`` this IS exercised by the default (non-live)
/// test suite, using a small PDF generated at test time via Core Graphics.
///
/// Mirrors `PDFChatAttachmentHandler` (Core's pre-existing chat-attachment
/// PDF handler)'s page-by-page extraction approach, but returns STRUCTURED
/// per-page text rather than one joined string, since PUNK-zup's
/// page-anchored citations (``PDFSummaryRenderer``) need to know which page a
/// quote came from. Lives in Infra, behind the Core ``PDFIngestExtracting``
/// protocol, per PUNK-zup's scoping notes on keeping new ingest code off the
/// `PDFChatAttachmentHandler` precedent of importing PDFKit directly in Core.
public struct PDFKitTextExtractor: PDFIngestExtracting {
    public init() {}

    public func extract(data: Data, sourceURL: URL) throws -> PDFExtractionResult {
        guard let document = PDFDocument(data: data) else {
            throw PDFIngestError.unreadable(sourceURL.absoluteString)
        }
        if document.isEncrypted, !document.unlock(withPassword: "") {
            throw PDFIngestError.unreadable(sourceURL.absoluteString)
        }

        var pages: [PDFPageText] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            pages.append(PDFPageText(pageNumber: index + 1, text: text))
        }
        guard !pages.isEmpty else { throw PDFIngestError.noTextExtractable }

        let rawTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let trimmedTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PDFExtractionResult(title: (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil, pages: pages)
    }
}
