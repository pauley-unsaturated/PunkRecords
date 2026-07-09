import Foundation

/// Transport- and metadata-level signals ``URLIngestClassifier`` needs to
/// route a fetched URL, gathered by Infra (HTTP status/redirects come from
/// ``WebHTTPClient``; `ogType`/`htmlLangAttribute`/`bodyClassIdentityBlob`
/// come from parsing the raw HTML, mirroring how ``ReadabilityExtractor``
/// already pulls `og:title`/canonical/byline). Deliberately does NOT carry
/// the extracted article body itself — that's passed to
/// ``URLIngestClassifier/classify(signals:bodyText:headings:)`` separately,
/// since body text/headings are what ``WebContent`` already carries and some
/// routes (video, PDF) are decided before any article body exists at all.
public struct URLIngestSignals: Sendable, Equatable {
    /// The URL as originally requested.
    public var requestedURL: URL
    /// The URL the request ultimately resolved to (after any redirects).
    /// Equal to `requestedURL` when there was no redirect.
    public var finalURL: URL
    /// URLs visited before landing on `finalURL`, in order. Does NOT include
    /// `finalURL` itself. Empty when there was no redirect (the common case).
    public var redirectChain: [URL]
    /// The final response's HTTP status code, when known. `nil` for routes
    /// decided before any request was made (e.g. video detected from the URL
    /// alone) or when the transport doesn't expose it (e.g. a synthetic test
    /// fixture that only cares about other signals).
    public var httpStatus: Int?
    /// Normalized MIME type (lowercased, parameters like `; charset=` and
    /// `; boundary=` stripped) — e.g. `"application/pdf"`, `"text/html"`.
    /// `nil` when unknown.
    public var contentType: String?
    /// The raw `<meta property="og:type">` value, e.g. `"video.other"`,
    /// `"article"`. `nil` when absent.
    public var ogType: String?
    /// The raw `<html lang="...">` attribute value, e.g. `"fr"`, `"en-US"`.
    /// `nil` when the page has no `lang` attribute.
    public var htmlLangAttribute: String?
    /// A language code guessed by an on-device recognizer (Infra:
    /// `NLLanguageRecognizer`) run against the extracted body text, used as a
    /// fallback when `htmlLangAttribute` is absent or unhelpful (e.g. `"und"`
    /// or missing). `nil` when not computed.
    public var languageRecognizerHint: String?
    /// Lowercased concatenation of every `class`/`id` attribute value found on
    /// elements in the page body, space-separated. A cheap, single string a
    /// pure Core matcher (``PaywallDetector``) can substring-search against
    /// its known-marker list, without Core needing an HTML parser. Empty
    /// string when unavailable (e.g. a PDF response, or a synthetic fixture
    /// that doesn't care about paywall detection).
    public var bodyClassIdentityBlob: String

    public init(
        requestedURL: URL,
        finalURL: URL? = nil,
        redirectChain: [URL] = [],
        httpStatus: Int? = nil,
        contentType: String? = nil,
        ogType: String? = nil,
        htmlLangAttribute: String? = nil,
        languageRecognizerHint: String? = nil,
        bodyClassIdentityBlob: String = ""
    ) {
        self.requestedURL = requestedURL
        self.finalURL = finalURL ?? requestedURL
        self.redirectChain = redirectChain
        self.httpStatus = httpStatus
        self.contentType = contentType
        self.ogType = ogType
        self.htmlLangAttribute = htmlLangAttribute
        self.languageRecognizerHint = languageRecognizerHint
        self.bodyClassIdentityBlob = bodyClassIdentityBlob
    }
}
