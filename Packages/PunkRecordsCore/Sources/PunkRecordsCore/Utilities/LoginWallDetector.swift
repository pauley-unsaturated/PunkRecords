import Foundation

/// Detects a login wall, per PUNK-zup's failure mode #4: an HTTP 401/403, or a
/// redirect through a login-ish URL (own site's `/login` page, or a known SSO
/// host). Pure URL/status inspection — no network, no HTML parsing.
public enum LoginWallDetector {
    /// HTTP status codes that unambiguously mean "you must authenticate."
    public static let blockingStatusCodes: Set<Int> = [401, 403]

    /// Substrings checked (case-insensitively) against each candidate URL's
    /// path. A response that redirected through one of these is treated as
    /// requiring sign-in.
    public static let loginPathMarkers: [String] = [
        "/login", "/signin", "/sign-in", "/log-in", "authwall", "/sso", "/accounts/login",
    ]

    /// Known SSO/identity-provider hosts — landing on one of these via
    /// redirect is a login wall regardless of path.
    public static let ssoHosts: Set<String> = [
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "login.live.com",
    ]

    static let userFacingMessage =
        "This page requires signing in — open it in your browser, sign in, then re-trigger the summary from there."

    /// Whether `signals` indicate a login wall. Checked BEFORE
    /// ``PaywallDetector`` in ``URLIngestClassifier`` — an explicit HTTP
    /// status or redirect is a harder signal than the paywall heuristic's
    /// short-body-plus-marker inference.
    public static func detect(signals: URLIngestSignals) -> BlockReason? {
        if let status = signals.httpStatus, blockingStatusCodes.contains(status) {
            return BlockReason(
                userFacingMessage: userFacingMessage,
                diagnostic: "HTTP \(status) for \(signals.finalURL.absoluteString)"
            )
        }
        for url in signals.redirectChain + [signals.finalURL] {
            if let host = url.host?.lowercased(), ssoHosts.contains(host) {
                return BlockReason(userFacingMessage: userFacingMessage, diagnostic: "redirected to SSO host \(host)")
            }
            let path = url.path.lowercased()
            if loginPathMarkers.contains(where: { path.contains($0) }) {
                return BlockReason(
                    userFacingMessage: userFacingMessage,
                    diagnostic: "redirected to login-ish URL \(url.absoluteString)"
                )
            }
        }
        return nil
    }
}
