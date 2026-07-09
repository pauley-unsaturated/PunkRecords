import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("PDFDetector — content-type / .pdf suffix detection")
struct PDFDetectorTests {

    @Test("Detects via normalized application/pdf content type")
    func detectsByContentType() {
        let url = URL(string: "https://example.com/reports/quarterly-report")!
        #expect(PDFDetector.isPDF(contentType: "application/pdf", url: url))
        #expect(PDFDetector.isPDF(contentType: "application/pdf; charset=binary", url: url))
    }

    @Test("Detects via .pdf URL suffix when content type is absent")
    func detectsBySuffix() {
        let url = URL(string: "https://example.com/reports/quarterly-report.pdf")!
        #expect(PDFDetector.isPDF(contentType: nil, url: url))
    }

    @Test(".pdf suffix match is case-insensitive")
    func suffixCaseInsensitive() {
        let url = URL(string: "https://example.com/reports/quarterly-report.PDF")!
        #expect(PDFDetector.isPDF(contentType: nil, url: url))
    }

    @Test("A normal HTML article is not detected as a PDF")
    func normalArticleNotDetected() {
        let url = URL(string: "https://example.com/blog/great-article")!
        #expect(!PDFDetector.isPDF(contentType: "text/html; charset=utf-8", url: url))
    }

    @Test("A .pdf-looking query string alone does not trigger a false positive")
    func queryStringDoesNotFalsePositive() {
        let url = URL(string: "https://example.com/download?file=report.pdf")!
        #expect(!PDFDetector.isPDF(contentType: "text/html", url: url))
    }
}
