import Foundation
import PunkRecordsCore

/// Persists per-domain consent for the opt-in Jina Reader tier (Tier 3), which
/// sends the target URL off-device. Backed by `UserDefaults`; the *decision*
/// logic lives in Core's ``WebFetchConsentPolicy`` so it stays pure and tested —
/// this shell only reads/writes the consented-domain set and delegates the
/// verdict. `@unchecked Sendable`: `UserDefaults` is documented thread-safe (same
/// rationale as `KeychainService`).
public final class WebFetchConsentStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "webfetch.jina.consentedDomains") {
        self.defaults = defaults
        self.key = key
    }

    /// The normalized domains the user has consented to (see
    /// ``WebFetchConsentPolicy/consentDomain(for:)``).
    public func consentedDomains() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// Evaluate whether a Jina fetch for `url` is currently allowed.
    public func decision(forURL url: URL) -> WebFetchConsentPolicy.Decision {
        WebFetchConsentPolicy.decision(forURL: url, consentedDomains: consentedDomains())
    }

    /// Record consent for the domain of `url`. No-op for non-http(s) URLs.
    public func grantConsent(forURL url: URL) {
        guard let domain = WebFetchConsentPolicy.consentDomain(for: url) else { return }
        grantConsent(forDomain: domain)
    }

    /// Record consent for an already-normalized `domain`.
    public func grantConsent(forDomain domain: String) {
        var current = consentedDomains()
        current.insert(domain)
        defaults.set(Array(current).sorted(), forKey: key)
    }

    /// Withdraw consent for `domain`.
    public func revokeConsent(forDomain domain: String) {
        var current = consentedDomains()
        current.remove(domain)
        defaults.set(Array(current).sorted(), forKey: key)
    }
}
