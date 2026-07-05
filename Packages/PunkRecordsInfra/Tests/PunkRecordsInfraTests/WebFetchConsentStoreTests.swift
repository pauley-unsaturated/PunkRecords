import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

@Suite("WebFetchConsentStore — per-domain Jina consent persistence")
struct WebFetchConsentStoreTests {

    private func makeStore() -> (WebFetchConsentStore, UserDefaults, String) {
        let suite = "webfetch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (WebFetchConsentStore(defaults: defaults, key: "consented"), defaults, suite)
    }

    @Test("A fresh domain needs a prompt")
    func freshNeedsPrompt() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://example.com/x")!
        #expect(store.decision(forURL: url) == .needsPrompt(domain: "example.com"))
    }

    @Test("Granting consent persists and later allows the domain")
    func grantThenAllow() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://www.example.com/article")!
        store.grantConsent(forURL: url)
        #expect(store.consentedDomains().contains("example.com"))
        #expect(store.decision(forURL: url) == .allowed)
        // A different path on the same domain is also allowed.
        #expect(store.decision(forURL: URL(string: "https://example.com/other")!) == .allowed)
    }

    @Test("Consent survives being read through a new store on the same defaults")
    func persistsAcrossInstances() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.grantConsent(forDomain: "example.com")
        let reopened = WebFetchConsentStore(defaults: defaults, key: "consented")
        #expect(reopened.decision(forURL: URL(string: "https://example.com/x")!) == .allowed)
    }

    @Test("Revoking consent returns the domain to needs-prompt")
    func revoke() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.grantConsent(forDomain: "example.com")
        store.revokeConsent(forDomain: "example.com")
        #expect(store.decision(forURL: URL(string: "https://example.com/x")!) == .needsPrompt(domain: "example.com"))
    }

    @Test("Granting for one domain does not consent another")
    func isolated() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.grantConsent(forDomain: "example.com")
        #expect(store.decision(forURL: URL(string: "https://evil.com/x")!) == .needsPrompt(domain: "evil.com"))
    }
}
