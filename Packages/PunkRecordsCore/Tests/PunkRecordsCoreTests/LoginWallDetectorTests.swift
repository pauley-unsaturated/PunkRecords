import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("LoginWallDetector — HTTP 401/403 or login-ish redirect")
struct LoginWallDetectorTests {

    @Test("HTTP 401 is a login wall")
    func status401() {
        let s = URLIngestSignals(requestedURL: URL(string: "https://example.com/members/post")!, httpStatus: 401)
        #expect(LoginWallDetector.detect(signals: s) != nil)
    }

    @Test("HTTP 403 is a login wall")
    func status403() {
        let s = URLIngestSignals(requestedURL: URL(string: "https://example.com/members/post")!, httpStatus: 403)
        #expect(LoginWallDetector.detect(signals: s) != nil)
    }

    @Test("A redirect to a /login path is a login wall")
    func redirectToLoginPath() {
        let s = URLIngestSignals(
            requestedURL: URL(string: "https://example.com/members/post")!,
            finalURL: URL(string: "https://example.com/login?next=/members/post")!
        )
        let reason = LoginWallDetector.detect(signals: s)
        #expect(reason != nil)
        #expect(reason?.userFacingMessage.lowercased().contains("sign") == true)
    }

    @Test("A redirect chain through a login-ish URL before landing elsewhere is still detected")
    func redirectChainThroughLogin() {
        let s = URLIngestSignals(
            requestedURL: URL(string: "https://example.com/members/post")!,
            finalURL: URL(string: "https://example.com/")!,
            redirectChain: [URL(string: "https://example.com/accounts/login?next=/members/post")!]
        )
        #expect(LoginWallDetector.detect(signals: s) != nil)
    }

    @Test("A redirect to a known SSO host is a login wall")
    func redirectToSSOHost() {
        let s = URLIngestSignals(
            requestedURL: URL(string: "https://example.com/members/post")!,
            finalURL: URL(string: "https://accounts.google.com/o/oauth2/auth?redirect=x")!
        )
        #expect(LoginWallDetector.detect(signals: s) != nil)
    }

    @Test("A normal 200 response with no login redirect is NOT a login wall")
    func normalResponseNotDetected() {
        let s = URLIngestSignals(
            requestedURL: URL(string: "https://example.com/blog/post")!,
            httpStatus: 200
        )
        #expect(LoginWallDetector.detect(signals: s) == nil)
    }

    @Test("A 404 is not treated as a login wall")
    func notFoundIsNotLoginWall() {
        let s = URLIngestSignals(requestedURL: URL(string: "https://example.com/gone")!, httpStatus: 404)
        #expect(LoginWallDetector.detect(signals: s) == nil)
    }
}
