import Foundation

/// Detects a PDF response by ``URLIngestSignals/contentType`` or a `.pdf` URL
/// suffix, per PUNK-zup's failure mode #2. Pure string matching — no PDF
/// parsing (that's `PDFKitTextExtractor`, Infra, gated behind this route).
public enum PDFDetector {
    /// Whether `contentType`/`url` indicate a PDF response.
    /// - Parameters:
    ///   - contentType: normalized MIME type (see ``URLIngestSignals/contentType``).
    ///   - url: the response's final URL (redirects resolved).
    public static func isPDF(contentType: String?, url: URL) -> Bool {
        if let contentType, contentType.lowercased().contains("application/pdf") {
            return true
        }
        return url.path.lowercased().hasSuffix(".pdf")
    }
}
