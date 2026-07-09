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
    /// Which instruction set ``build(content:variant:languageHint:)`` emits.
    /// Both variants decode to the SAME ``WebSummaryPayload`` shape (so
    /// ``WebSummaryPostProcessor``/``WebSummaryValidator`` need no variant
    /// awareness) — only the wording of the instructions differs, per
    /// PUNK-zup's failure mode #7: a page whose body is mostly speaker turns
    /// (``TranscriptHeuristic``) is asked to extract participants, decisions,
    /// and disagreements as its "key points" instead of generic article
    /// takeaways.
    public enum Variant: String, Sendable, Equatable, CaseIterable {
        case standard
        case transcript

        /// Bumped whenever THIS variant's schema or instructions change in a
        /// way that could alter output shape or citation behavior. Callers
        /// (PUNK-ddq) store this in note frontmatter so a later prompt change
        /// is never silently conflated with summaries produced under an
        /// older prompt. Each variant carries its own suffix so the
        /// transcript variant's instructions can change independently of the
        /// standard one's.
        public var promptVersion: String {
            switch self {
            case .standard: return "web-summary-v1"
            case .transcript: return "web-summary-v1-transcript"
            }
        }
    }

    /// The standard variant's version. Kept as a top-level constant (rather
    /// than requiring existing call sites to spell out
    /// `Variant.standard.promptVersion`) since it predates the transcript
    /// variant.
    public static let promptVersion = Variant.standard.promptVersion

    /// Key Points bullet count bounds (inclusive), shared with ``WebSummaryValidator``.
    public static let minKeyPoints = 5
    public static let maxKeyPoints = 9
    /// Notable Quotes count bounds (inclusive), shared with ``WebSummaryValidator``.
    public static let minQuotes = 2
    public static let maxQuotes = 4
    /// Quotes longer than this are truncated by ``WebSummaryPostProcessor`` —
    /// see its doc comment for the truncation policy.
    public static let maxQuoteWords = 30

    /// Build the full prompt for `content`. Includes the article's (or
    /// transcript's) title, byline, source URL, heading outline (so the model
    /// can cite a real anchor id), and body markdown, followed by the exact
    /// JSON schema and hard requirements the response must satisfy.
    /// - Parameters:
    ///   - variant: which instruction set to emit — see ``Variant``.
    ///   - languageHint: when non-nil (``ForeignLanguageDetector`` flagged the
    ///     source as non-English), appends a directive telling the model
    ///     whether to write the summary prose in the source language or
    ///     translate it, per `languageHint.policy`. Quotes (`supporting_text`)
    ///     always stay verbatim in the source language regardless — that's a
    ///     hard requirement, not something the policy can override, since a
    ///     translated quote would no longer match the source page and break
    ///     citation resolution.
    public static func build(
        content: WebContent,
        variant: Variant = .standard,
        languageHint: LanguageHint? = nil
    ) -> String {
        let bylineLine = content.byline.map { "By \($0)\n" } ?? ""
        let headingLines = content.headings.isEmpty
            ? "(none)"
            : content.headings.map { "- \($0.anchorID): \($0.text)" }.joined(separator: "\n")
        let sourceLabel = variant == .transcript ? "TRANSCRIPT" : "ARTICLE"
        let subject = variant == .transcript ? "conversation transcript (an interview, chat log, or comment thread)" : "web article"
        let keyPointsInstruction = variant == .transcript
            ? "extract PARTICIPANTS, DECISIONS, and DISAGREEMENTS, not generic takeaways"
            : "each a single faithful point"

        return """
        You are producing a cliffs-notes summary of a fetched \(subject) for a personal \
        knowledge base. Read the \(sourceLabel) text below and output ONE JSON object — no \
        markdown, no ```json code fences, no preamble, no explanation, nothing before or after \
        it — matching EXACTLY this schema:

        {
          "tldr": string,                    // 1-3 sentences distilling the \(variant == .transcript ? "conversation" : "article")
          "key_points": [                    // \(minKeyPoints)-\(maxKeyPoints) items — \(keyPointsInstruction)
            {
              "text": string,                // the point, in your own words
              "citation": {
                "citation_index": integer,    // 1-based, unique across every citation in this response
                "supporting_text": string,    // a VERBATIM substring copied exactly from \(sourceLabel) below
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
        - "supporting_text" MUST be an exact, verbatim substring of the \(sourceLabel) text below — copy \
        characters exactly; do not paraphrase, summarize, or fix typos/punctuation inside it. It is \
        used to build a citation link, so an inexact quote silently breaks that link.
        - Every key point and every quote must be grounded by its citation — never invent a point \
        the \(sourceLabel) text doesn't support.
        - "nearest_heading_anchor" must be one of the anchor ids listed under "Headings" below, or null.
        - Output ONLY the JSON object described above. No surrounding text, no code fences.
        \(languageDirective(for: languageHint))
        \(variant == .transcript ? "Transcript" : "Article") title: \(content.title)
        \(bylineLine)Source: \(content.sourceURL.absoluteString)

        Headings:
        \(headingLines)

        \(sourceLabel):
        \(content.contentMarkdown)
        """
    }

    /// The language directive appended to the hard requirements when
    /// `hint` is non-nil, or `""` (no-op) when it's `nil`. See `build`'s
    /// `languageHint` parameter doc for the verbatim-quote carve-out.
    private static func languageDirective(for hint: LanguageHint?) -> String {
        guard let hint else { return "" }
        switch hint.policy {
        case .summarizeInSourceLanguage:
            return """
            - Language: the source is not in English (detected: \(hint.languageCode)). Write "tldr", \
            each key point's "text", and "why_it_matters" in the SAME language as the source. \
            "supporting_text" stays verbatim in the source's original language regardless.
            """
        case .translateThenSummarize:
            return """
            - Language: the source is not in English (detected: \(hint.languageCode)). Translate as \
            you write "tldr", each key point's "text", and "why_it_matters" into English. \
            "supporting_text" stays verbatim in the source's ORIGINAL language regardless — never \
            translate a quote used as supporting_text, since it must match the source text exactly.
            """
        }
    }
}
