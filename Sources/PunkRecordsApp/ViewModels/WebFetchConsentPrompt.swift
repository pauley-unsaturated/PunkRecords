import AppKit
import Foundation
import PunkRecordsCore
import PunkRecordsInfra

/// Thin App-side glue for the opt-in Jina (Tier 3) consent gate. The *decision*
/// (allowed vs needs-prompt) is the Core ``WebFetchConsentPolicy`` and the
/// per-domain persistence is Infra's ``WebFetchConsentStore``; this only owns
/// the actual dialog. Produces the `@Sendable (URL) async -> Bool` closure the
/// ``ThreeTierWebContentFetcher`` calls before any request leaves the device.
@MainActor
enum WebFetchConsentPrompt {

    /// Build the consent closure. When a domain is already consented it returns
    /// `true` immediately; otherwise it shows a modal alert naming the URL that
    /// would leave the device, persisting the grant on approval.
    static func makeConsentClosure(store: WebFetchConsentStore) -> @Sendable (URL) async -> Bool {
        return { url in
            await MainActor.run {
                switch store.decision(forURL: url) {
                case .allowed:
                    return true
                case .invalidURL:
                    return false
                case .needsPrompt(let domain):
                    let granted = presentAlert(url: url, domain: domain)
                    if granted { store.grantConsent(forDomain: domain) }
                    return granted
                }
            }
        }
    }

    private static func presentAlert(url: URL, domain: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send this URL to the Jina reader?"
        alert.informativeText = """
            PunkRecords couldn't read \(url.absoluteString) on-device. It can use the \
            remote Jina reader (r.jina.ai) instead, which means this URL leaves your \
            device. Allow this for “\(domain)” from now on?
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}
