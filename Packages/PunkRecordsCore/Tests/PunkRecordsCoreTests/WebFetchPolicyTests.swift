import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebFetchTierPolicy — tier escalation")
struct WebFetchTierPolicyTests {

    @Test("Sparse Tier 1 output escalates to the browser")
    func sparseEscalates() {
        #expect(WebFetchTierPolicy.shouldEscalateToBrowser(tier1CharacterCount: 40, isProbablyReaderable: true))
        #expect(WebFetchTierPolicy.shouldEscalateToBrowser(tier1CharacterCount: 0, isProbablyReaderable: true))
    }

    @Test("Rich Tier 1 output stays on Tier 1")
    func richStays() {
        #expect(!WebFetchTierPolicy.shouldEscalateToBrowser(tier1CharacterCount: 5_000, isProbablyReaderable: true))
    }

    @Test("A failing readerable check escalates even with enough text")
    func notReaderableEscalates() {
        #expect(WebFetchTierPolicy.shouldEscalateToBrowser(tier1CharacterCount: 5_000, isProbablyReaderable: false))
    }

    @Test("Threshold boundary is exclusive-below")
    func boundary() {
        let n = WebFetchTierPolicy.minReadableContentLength
        #expect(WebFetchTierPolicy.shouldEscalateToBrowser(tier1CharacterCount: n - 1, isProbablyReaderable: true))
        #expect(!WebFetchTierPolicy.shouldEscalateToBrowser(tier1CharacterCount: n, isProbablyReaderable: true))
    }

    @Test("Jina is only considered when Tier 2 is still sparse")
    func considerJina() {
        #expect(WebFetchTierPolicy.shouldConsiderJina(tier2CharacterCount: 10))
        #expect(!WebFetchTierPolicy.shouldConsiderJina(tier2CharacterCount: 5_000))
    }
}

@Suite("WebFetchConsentPolicy — Jina opt-in gating")
struct WebFetchConsentPolicyTests {

    @Test("Normalizes host: lowercased, www stripped")
    func consentDomain() {
        #expect(WebFetchConsentPolicy.consentDomain(for: URL(string: "https://WWW.Example.com/x")!) == "example.com")
        #expect(WebFetchConsentPolicy.consentDomain(for: URL(string: "http://blog.example.com/")!) == "blog.example.com")
    }

    @Test("Non-http(s) URLs have no consent domain")
    func nonHTTP() {
        #expect(WebFetchConsentPolicy.consentDomain(for: URL(string: "file:///tmp/x.html")!) == nil)
        #expect(WebFetchConsentPolicy.consentDomain(for: URL(string: "ftp://example.com/x")!) == nil)
    }

    @Test("Stored consent for the domain allows the fetch")
    func allowed() {
        let url = URL(string: "https://example.com/article")!
        #expect(WebFetchConsentPolicy.decision(forURL: url, consentedDomains: ["example.com"]) == .allowed)
    }

    @Test("A www variant of the URL is covered by the bare-domain consent")
    func wwwCoveredByBare() {
        let url = URL(string: "https://www.example.com/article")!
        #expect(WebFetchConsentPolicy.decision(forURL: url, consentedDomains: ["example.com"]) == .allowed)
    }

    @Test("No stored consent needs a prompt")
    func needsPrompt() {
        let url = URL(string: "https://example.com/article")!
        #expect(WebFetchConsentPolicy.decision(forURL: url, consentedDomains: []) == .needsPrompt(domain: "example.com"))
        #expect(WebFetchConsentPolicy.decision(forURL: url, consentedDomains: ["other.com"]) == .needsPrompt(domain: "example.com"))
    }

    @Test("Consent for one domain does not leak to another")
    func noCrossDomainLeak() {
        let url = URL(string: "https://evil.com/x")!
        #expect(WebFetchConsentPolicy.decision(forURL: url, consentedDomains: ["example.com"]) == .needsPrompt(domain: "evil.com"))
    }

    @Test("Invalid URL cannot use Jina")
    func invalid() {
        let url = URL(string: "file:///tmp/x")!
        #expect(WebFetchConsentPolicy.decision(forURL: url, consentedDomains: ["example.com"]) == .invalidURL)
    }
}
