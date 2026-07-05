import Foundation
import PunkRecordsCore
import WebKit

/// Tier 2 of the web-fetch ladder: render a page in an invisible `WKWebView`
/// (so the page's own JavaScript runs) then inject Mozilla's Readability.js and
/// evaluate `new Readability(document).parse()`. Used when Tier 1's offline
/// extraction comes back too sparse (see ``WebFetchTierPolicy``). `@MainActor`
/// because `WKWebView` is main-thread-only.
@MainActor
final class WebKitReadabilityExtractor: BrowserContentExtracting {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    func extract(url: URL) async throws -> ReadabilityResult {
        let readabilitySource = try Self.readabilityScript()

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: configuration
        )
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter

        // Race navigation against a timeout so a hung page can't wedge the loop.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            waiter.fail(WebFetchError.transport("Tier 2 navigation timed out after \(Int(timeout))s"))
        }
        defer {
            timeoutTask.cancel()
            webView.navigationDelegate = nil
            webView.stopLoading()
        }

        try await waiter.load(webView, URLRequest(url: url, timeoutInterval: timeout))
        timeoutTask.cancel()

        return try await evaluate(readabilitySource, in: webView)
    }

    // MARK: - JavaScript evaluation

    private func evaluate(_ readabilitySource: String, in webView: WKWebView) async throws -> ReadabilityResult {
        let script = Self.parseScript(readabilitySource: readabilitySource)
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(script)
        } catch {
            throw WebFetchError.transport("Readability.js evaluation failed: \(error.localizedDescription)")
        }

        guard let json = raw as? String, !json.isEmpty else {
            throw WebFetchError.noReadableContent
        }
        if json.hasPrefix("ERROR:") {
            throw WebFetchError.transport(String(json.dropFirst("ERROR:".count)))
        }
        return try Self.decode(json)
    }

    /// Parse the JSON string produced by the injected script into a
    /// ``ReadabilityResult``. Pure; unit-testable without a browser.
    nonisolated static func decode(_ json: String) throws -> ReadabilityResult {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebFetchError.transport("Readability.js returned malformed JSON")
        }
        return ReadabilityResult(
            title: object["title"] as? String,
            byline: object["byline"] as? String,
            contentHTML: object["content"] as? String ?? "",
            textContent: object["textContent"] as? String ?? ""
        )
    }

    /// The self-contained script injected into the rendered page: it defines
    /// `Readability` from the vendored source, runs it against a clone of the
    /// live document, and returns a JSON string (or an `ERROR:`/`null` sentinel).
    nonisolated static func parseScript(readabilitySource: String) -> String {
        """
        (function() {
          try {
            \(readabilitySource)
            var documentClone = document.cloneNode(true);
            var article = new Readability(documentClone).parse();
            if (!article) { return null; }
            return JSON.stringify({
              title: article.title || "",
              byline: article.byline || "",
              content: article.content || "",
              textContent: article.textContent || ""
            });
          } catch (e) {
            return "ERROR:" + (e && e.message ? e.message : String(e));
          }
        })();
        """
    }

    nonisolated static func readabilityScript() throws -> String {
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw WebFetchError.transport("Readability.js resource missing from bundle")
        }
        return source
    }
}

/// Bridges `WKNavigationDelegate` callbacks to an `async` load. Guarantees the
/// continuation resumes exactly once (first of didFinish / didFail / timeout).
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ webView: WKWebView, _ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            webView.load(request)
        }
    }

    func fail(_ error: Error) { finish(.failure(error)) }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }
}
