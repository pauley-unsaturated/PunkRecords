import Foundation

/// Which video hosting provider a ``VideoTarget`` was detected on. Determines
/// which ``VideoTranscriptProviding`` implementation Infra should use.
public enum VideoProvider: String, Sendable, Equatable, Codable, CaseIterable {
    case youTube
    case vimeo
}

/// A detected video: which provider, and the provider-specific video id
/// extracted from the URL (e.g. the `v` query param for a YouTube watch URL,
/// or the numeric path component for Vimeo).
public struct VideoTarget: Sendable, Equatable, Codable {
    public let provider: VideoProvider
    public let videoID: String
    /// The URL the video was detected from (used as the base for `&t=Ns`
    /// deep links — see ``VideoSummaryRenderer``).
    public let sourceURL: URL

    public init(provider: VideoProvider, videoID: String, sourceURL: URL) {
        self.provider = provider
        self.videoID = videoID
        self.sourceURL = sourceURL
    }
}

/// A block a caller should surface verbatim instead of attempting a summary —
/// the outcome for ``IngestRoute/paywalled(_:)`` and ``IngestRoute/loginWalled(_:)``.
/// Deliberately typed data rather than a free-form string so callers (and
/// tests) can distinguish "nothing to summarize, tell the user why" from an
/// actual transport failure.
public struct BlockReason: Sendable, Equatable {
    /// Short, user-facing explanation — safe to show verbatim in chat/UI.
    public let userFacingMessage: String
    /// Internal diagnostic (which signal fired), useful in logs/tests but not
    /// meant for the end user.
    public let diagnostic: String

    public init(userFacingMessage: String, diagnostic: String) {
        self.userFacingMessage = userFacingMessage
        self.diagnostic = diagnostic
    }
}

/// One chunk of a long document, as planned by ``LongFormChunkPlanner``.
public struct DocumentChunk: Sendable, Equatable {
    /// 0-based position in the plan.
    public let index: Int
    /// The nearest enclosing H2 section title, when the plan split on
    /// headings (``ChunkPlan/Strategy/perH2Section``). `nil` for
    /// ``ChunkPlan/Strategy/sizeBased`` chunks, or for a size-based chunk
    /// after the plan is done.
    public let heading: String?
    /// This chunk's markdown slice.
    public let markdown: String
    /// ``TokenEstimator`` estimate for `markdown`.
    public let estimatedTokens: Int

    public init(index: Int, heading: String?, markdown: String, estimatedTokens: Int) {
        self.index = index
        self.heading = heading
        self.markdown = markdown
        self.estimatedTokens = estimatedTokens
    }
}

/// A deterministic plan for summarizing a document too long to fit in one
/// prompt: the document split into per-``DocumentChunk`` pieces plus the
/// strategy used to split it. See ``LongFormChunkPlanner`` for how the plan is
/// built and its doc comment for what's intentionally NOT implemented here
/// (the multi-call LLM orchestration that would actually run a summary over
/// each chunk and a meta-summary over the results).
public struct ChunkPlan: Sendable, Equatable {
    /// How the document was split.
    public enum Strategy: String, Sendable, Equatable {
        /// Split at `##` (H2) boundaries — used when the document has enough
        /// H2 headings to produce reasonably-sized sections.
        case perH2Section
        /// Split by accumulating paragraphs up to a token budget — the
        /// fallback when there are too few (or no) H2 headings to split on.
        case sizeBased
    }

    public let strategy: Strategy
    public let chunks: [DocumentChunk]
    public let totalEstimatedTokens: Int

    public init(strategy: Strategy, chunks: [DocumentChunk], totalEstimatedTokens: Int) {
        self.strategy = strategy
        self.chunks = chunks
        self.totalEstimatedTokens = totalEstimatedTokens
    }
}

/// Which language-handling behavior to apply when ``ForeignLanguageDetector``
/// flags a page as non-English. Exposed as a parameter (with a default)
/// rather than hardcoded, per PUNK-zup — a Settings toggle to let the user
/// choose is left as future App-layer work.
public enum ForeignLanguagePolicy: String, Sendable, Equatable, Codable, CaseIterable {
    /// Write the summary prose (tldr / key points / why-it-matters) in the
    /// SAME language as the source article.
    case summarizeInSourceLanguage
    /// Translate the summary prose into English while writing it.
    case translateThenSummarize

    /// The default policy. Chosen as the lower-risk option: it's what the
    /// summarizer already does today (nothing currently detects language, so
    /// the model summarizes in whatever language it naturally responds in —
    /// typically the source language for an instruction-tuned model reading
    /// non-English text). Making that behavior explicit, rather than
    /// defaulting to `.translateThenSummarize`, avoids silently changing
    /// existing summaries the first time this ships.
    public static let `default`: ForeignLanguagePolicy = .summarizeInSourceLanguage
}

/// Attached to an ``IngestDecision`` when the source content is not in the
/// target language (see ``ForeignLanguageDetector``). Orthogonal to
/// ``IngestRoute`` — any route whose content is actually summarized (article,
/// longForm, conversationTranscript) can carry a language hint, e.g. a long
/// French article is `IngestDecision(route: .longForm(plan), languageHint:
/// .init(languageCode: "fr", ...))`. Composing via a separate field, rather
/// than adding foreign-language cases to `IngestRoute` itself, is the
/// documented precedence decision — see ``URLIngestClassifier``.
public struct LanguageHint: Sendable, Equatable {
    /// BCP-47-ish primary language subtag, lowercased (e.g. `"fr"`, `"ja"`).
    public let languageCode: String
    public let policy: ForeignLanguagePolicy

    public init(languageCode: String, policy: ForeignLanguagePolicy = .default) {
        self.languageCode = languageCode
        self.policy = policy
    }
}

/// The routing outcome for a fetched (or about-to-be-fetched) URL. Cases are
/// mutually exclusive by construction — ``URLIngestClassifier`` picks exactly
/// one, in a documented precedence order. Orthogonal concerns (language)
/// travel alongside a route on ``IngestDecision`` rather than as cases here.
public enum IngestRoute: Sendable, Equatable {
    /// A normal, readable page — summarize it via the standard prompt.
    case article
    /// A YouTube/Vimeo video — summarize its transcript, not page HTML.
    case video(VideoTarget)
    /// A PDF — extract text via PDFKit (Infra), cite by page number.
    case pdf
    /// Extracted body is short AND a known paywall marker (classname/id or
    /// domain) was found — surface `reason` instead of summarizing garbage.
    case paywalled(BlockReason)
    /// The response required authentication (401/403, or redirected to a
    /// login-ish URL) — surface `reason` instead of summarizing garbage.
    case loginWalled(BlockReason)
    /// Extracted body exceeds the long-form token threshold — `plan`
    /// describes how to chunk it (see ``ChunkPlan``).
    case longForm(ChunkPlan)
    /// Extracted body looks like a transcript/comment-thread (high
    /// speaker-name line density) — use the transcript prompt variant
    /// (``WebSummaryPrompt/Variant/transcript``) instead of the standard one.
    case conversationTranscript
}

/// The full classifier verdict: a primary ``route`` plus an orthogonal,
/// optional ``languageHint``.
public struct IngestDecision: Sendable, Equatable {
    public let route: IngestRoute
    public let languageHint: LanguageHint?

    public init(route: IngestRoute, languageHint: LanguageHint?) {
        self.route = route
        self.languageHint = languageHint
    }
}
