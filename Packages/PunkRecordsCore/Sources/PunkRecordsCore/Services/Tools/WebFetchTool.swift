import Foundation

/// Fetches a web page and returns cleaned, reader-mode markdown for the agent
/// to summarize or quote. A thin ``AgentTool`` shell over a
/// ``WebContentFetcher`` (the three-tier ladder lives in Infra), mirroring how
/// ``VaultSearchTool`` / ``ReadDocumentTool`` wrap their services. Keeping the
/// fetcher a separate injected service lets a future web-search feature reuse
/// it (PUNK-e5u) without duplicating the extraction pipeline.
public struct WebFetchTool: AgentTool, Sendable {
    public let name = "web_fetch"
    public let description = """
        Fetch a web page by URL and return its main article as clean markdown, \
        with title, byline, and a heading outline. Use this to read or summarize \
        an online page the user links to. Prefers a fast offline reader; \
        JS-heavy pages fall back to a headless browser automatically.
        """

    private let fetcher: any WebContentFetcher

    /// Cap on how much article markdown to return to the model in one call, so a
    /// long page can't blow the context budget. The full text is still cached to
    /// disk; the agent can note the truncation and fetch specific anchors later.
    private let maxContentCharacters: Int

    public var parameterSchema: ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "url": ToolProperty(type: "string", description: "The absolute http(s) URL of the page to fetch")
            ],
            required: ["url"]
        )
    }

    public init(fetcher: any WebContentFetcher, maxContentCharacters: Int = 12_000) {
        self.fetcher = fetcher
        self.maxContentCharacters = maxContentCharacters
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let raw = arguments["url"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(
                content: "Missing required 'url' parameter. Pass {\"url\": \"https://example.com/page\"}.",
                isError: true
            )
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ToolResult(
                content: "'\(trimmed)' is not a valid http(s) URL. Pass an absolute URL like https://example.com/page.",
                isError: true
            )
        }

        do {
            let content = try await fetcher.fetch(url: url)
            return ToolResult(content: Self.format(content, maxContentCharacters: maxContentCharacters))
        } catch let error as WebFetchError {
            return ToolResult(content: Self.describe(error, url: url), isError: true)
        } catch {
            return ToolResult(
                content: "Failed to fetch \(url.absoluteString): \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Formatting (pure, testable)

    /// Render a ``WebContent`` into the tool's text payload: a header block with
    /// title/byline/source and the (possibly truncated) article markdown.
    public static func format(_ content: WebContent, maxContentCharacters: Int) -> String {
        var lines: [String] = []
        lines.append("# \(content.title)")
        if let byline = content.byline, !byline.isEmpty {
            lines.append("By \(byline)")
        }
        lines.append("Source: \(content.sourceURL.absoluteString)")
        if let canonical = content.canonicalURL, canonical != content.sourceURL {
            lines.append("Canonical: \(canonical.absoluteString)")
        }
        lines.append("Extracted via: \(content.tier.displayName)")
        lines.append("")

        let body: String
        if content.contentMarkdown.count > maxContentCharacters {
            body = String(content.contentMarkdown.prefix(maxContentCharacters))
                + "\n\n[... truncated; \(content.contentMarkdown.count - maxContentCharacters) more characters cached on disk ...]"
        } else {
            body = content.contentMarkdown
        }
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private static func describe(_ error: WebFetchError, url: URL) -> String {
        switch error {
        case .invalidURL(let s):
            return "'\(s)' is not a valid http(s) URL."
        case .transport(let message):
            return "Could not fetch \(url.absoluteString): \(message)"
        case .noReadableContent:
            return "Fetched \(url.absoluteString) but found no readable article content."
        case .jinaConsentRequired(let domain):
            return """
                Reading \(url.absoluteString) needs the remote Jina reader, which sends the URL off-device. \
                The user has not consented for '\(domain)'. Ask the user to allow it, then retry.
                """
        }
    }
}
