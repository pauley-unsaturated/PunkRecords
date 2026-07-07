import Foundation

/// Builds the one-shot prompt that turns fetched ``WebContent`` (the
/// ``WebFetchTool`` output) into a structured JSON payload — see
/// ``WebSummaryPayload`` — which ``WebSummaryPostProcessor`` then renders into
/// the 4-section markdown summary body with inline citation links.
///
/// Rides the same one-shot ``TextCompleter`` seam as ``ConversationSummarizer``
/// and ``NoteCompiler``: no tools, no session state, provider-agnostic (the
/// Infra session path backs `TextCompleter` for Anthropic, OpenAI, and Apple
/// Foundation Models alike). `TextCompleter` has no structured-output hook, so
/// this uses prompt-enforced JSON — an explicit schema plus "output ONLY JSON"
/// instructions — rather than a provider-specific structured-output API. That
/// also keeps the contract identical across providers, which matters for the
/// determinism requirement below.
public enum WebSummaryPrompt {
    /// Bumped whenever the schema or instructions change in a way that could
    /// alter output shape or citation behavior. Callers (PUNK-ddq) store this
    /// in note frontmatter so a later prompt change is never silently
    /// conflated with summaries produced under an older prompt.
    public static let promptVersion = "web-summary-v1"

    /// Key Points bullet count bounds (inclusive), shared with ``WebSummaryValidator``.
    public static let minKeyPoints = 5
    public static let maxKeyPoints = 9
    /// Notable Quotes count bounds (inclusive), shared with ``WebSummaryValidator``.
    public static let minQuotes = 2
    public static let maxQuotes = 4
    /// Quotes longer than this are truncated by ``WebSummaryPostProcessor`` —
    /// see its doc comment for the truncation policy.
    public static let maxQuoteWords = 30

    /// Build the full prompt for `content`. Includes the article's title,
    /// byline, source URL, heading outline (so the model can cite a real
    /// anchor id), and body markdown, followed by the exact JSON schema and
    /// hard requirements the response must satisfy.
    public static func build(content: WebContent) -> String {
        let bylineLine = content.byline.map { "By \($0)\n" } ?? ""
        let headingLines = content.headings.isEmpty
            ? "(none)"
            : content.headings.map { "- \($0.anchorID): \($0.text)" }.joined(separator: "\n")

        return """
        You are producing a cliffs-notes summary of a fetched web article for a personal \
        knowledge base. Read the ARTICLE text below and output ONE JSON object — no markdown, \
        no ```json code fences, no preamble, no explanation, nothing before or after it — \
        matching EXACTLY this schema:

        {
          "tldr": string,                    // 1-3 sentences distilling the article
          "key_points": [                    // \(minKeyPoints)-\(maxKeyPoints) items, each a single faithful point
            {
              "text": string,                // the key point, in your own words
              "citation": {
                "citation_index": integer,    // 1-based, unique across every citation in this response
                "supporting_text": string,    // a VERBATIM substring copied exactly from ARTICLE below
                "nearest_heading_anchor": string | null   // an anchor id from "Headings" below, or null
              }
            }
          ],
          "quotes": [                        // \(minQuotes)-\(maxQuotes) items — notable, quotable excerpts
            {
              "citation": {
                "citation_index": integer,
                "supporting_text": string,    // the VERBATIM quote itself, copied exactly — max \(maxQuoteWords) words
                "nearest_heading_anchor": string | null
              }
            }
          ],
          "why_it_matters": [string] | null  // optional: short bullets on why this matters or open
                                              // questions; omit the key or use null if there are none
        }

        Hard requirements:
        - "supporting_text" MUST be an exact, verbatim substring of the ARTICLE text below — copy \
        characters exactly; do not paraphrase, summarize, or fix typos/punctuation inside it. It is \
        used to build a citation link, so an inexact quote silently breaks that link.
        - Every key point and every quote must be grounded by its citation — never invent a point \
        the ARTICLE text doesn't support.
        - "nearest_heading_anchor" must be one of the anchor ids listed under "Headings" below, or null.
        - Output ONLY the JSON object described above. No surrounding text, no code fences.

        Article title: \(content.title)
        \(bylineLine)Source: \(content.sourceURL.absoluteString)

        Headings:
        \(headingLines)

        ARTICLE:
        \(content.contentMarkdown)
        """
    }
}
