import Foundation

/// Pure consent policy for the opt-in Jina Reader tier (Tier 3), which sends
/// the target URL to a third-party service. The *decision* — given a URL and
/// the set of domains the user has already consented to, is a fetch allowed or
/// must we prompt? — lives here in Core so it is deterministic and unit-tested.
/// Persistence (UserDefaults) and the actual dialog are thin Infra/App shells.
public enum WebFetchConsentPolicy {

    /// The outcome of evaluating consent for a Jina fetch.
    public enum Decision: Sendable, Equatable {
        /// The domain has stored consent — proceed without prompting.
        case allowed
        /// No stored consent for this domain — the App must prompt the user,
        /// noting that `domain` will leave the device, before proceeding.
        case needsPrompt(domain: String)
        /// The URL isn't a fetchable http(s) URL; Jina can't be used at all.
        case invalidURL
    }

    /// Normalize a URL to the consent key used for storage and lookup: the
    /// lowercased host with a leading `www.` stripped, so consent granted for
    /// `www.example.com` also covers `example.com` and its paths. Returns `nil`
    /// for non-http(s) URLs or URLs without a host.
    public static func consentDomain(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Decide whether a Jina fetch for `url` is allowed given the domains the
    /// user has already consented to. `consentedDomains` must be normalized via
    /// ``consentDomain(for:)`` (the store guarantees this).
    public static func decision(
        forURL url: URL,
        consentedDomains: Set<String>
    ) -> Decision {
        guard let domain = consentDomain(for: url) else { return .invalidURL }
        return consentedDomains.contains(domain) ? .allowed : .needsPrompt(domain: domain)
    }
}
