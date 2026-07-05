import Foundation
import PunkRecordsCore

/// Minimal HTTP GET seam so the web-fetch tiers can be tested without live
/// network. Tier 1 uses it to download raw HTML; Tier 3 uses it to call the
/// Jina Reader endpoint. Tests inject a mock and assert on the URLs requested
/// (or that none were, for consent gating).
public protocol WebHTTPClient: Sendable {
    /// Perform a GET. Returns the response body and the resolved final URL
    /// (after redirects) so callers can record a canonical location.
    /// - Throws: ``WebFetchError/transport(_:)`` on transport/non-2xx failures.
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> WebHTTPResponse
}

/// The bytes and metadata of a successful HTTP GET.
public struct WebHTTPResponse: Sendable {
    public let body: Data
    public let finalURL: URL
    public let mimeType: String?
    public let textEncodingName: String?

    public init(body: Data, finalURL: URL, mimeType: String?, textEncodingName: String?) {
        self.body = body
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
    }

    /// Best-effort decode of the body as text, honoring the response's declared
    /// encoding and falling back to UTF-8 then Latin-1 (which never fails).
    public func text() -> String {
        if let name = textEncodingName {
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEnc != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
                if let s = String(data: body, encoding: String.Encoding(rawValue: nsEnc)) {
                    return s
                }
            }
        }
        return String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .isoLatin1)
            ?? ""
    }
}

/// `URLSession`-backed ``WebHTTPClient``. The default transport for real fetches.
public struct URLSessionWebHTTPClient: WebHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> WebHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WebFetchError.transport("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            return WebHTTPResponse(
                body: data,
                finalURL: response.url ?? url,
                mimeType: response.mimeType,
                textEncodingName: response.textEncodingName
            )
        } catch let error as WebFetchError {
            throw error
        } catch {
            throw WebFetchError.transport(error.localizedDescription)
        }
    }
}
