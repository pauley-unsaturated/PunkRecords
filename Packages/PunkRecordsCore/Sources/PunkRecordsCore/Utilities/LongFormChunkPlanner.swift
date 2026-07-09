import Foundation

/// Plans how to split a too-long document into per-``DocumentChunk`` pieces,
/// per PUNK-zup's failure mode #6. Pure, deterministic — splits at `##` (H2)
/// boundaries when there are enough of them to produce reasonably-sized
/// sections, else falls back to greedily accumulating paragraphs up to a
/// token budget.
///
/// **Scope note (documented TODO seam):** this type only produces the
/// ``ChunkPlan`` — the boundaries and per-chunk token estimates. It does NOT
/// perform the two-stage LLM orchestration the plan is FOR (summarize each
/// chunk, then meta-summarize the per-chunk summaries). That orchestration
/// needs the session/LLM-calling plumbing (`SessionAgentRunner` or a
/// `TextCompleter` loop) which lives in Infra/App, not Core, and multiple
/// live calls per long document — left as a follow-up (see PUNK-zup's
/// validation notes) rather than implemented here, per the issue's explicit
/// scope allowance. A caller with access to a `TextCompleter` can walk
/// `plan.chunks`, summarize each with ``WebSummaryPrompt`` against a
/// synthetic per-chunk `WebContent`, then feed the concatenated per-chunk
/// TL;DRs back through the same prompt as a meta-summarization pass.
public enum LongFormChunkPlanner {
    /// ``TokenEstimator`` threshold above which a document is "long-form."
    public static let longFormTokenThreshold = 50_000
    /// Target size for a single chunk once split.
    public static let targetChunkTokens = 8_000
    /// Hard cap before a single H2 section (or a size-based run) is further
    /// split — keeps any one chunk from blowing a per-call context budget
    /// even when a document has very unevenly sized sections.
    public static let maxChunkTokens = targetChunkTokens * 2

    /// Whether `bodyText` exceeds ``longFormTokenThreshold``.
    public static func isLongForm(bodyText: String) -> Bool {
        TokenEstimator.estimateTokens(in: bodyText) > longFormTokenThreshold
    }

    /// Build a deterministic chunk plan for `bodyText`.
    public static func plan(bodyText: String) -> ChunkPlan {
        let h2Sections = splitByH2(bodyText)
        if h2Sections.count > 1 {
            let chunks = expand(h2Sections)
            return ChunkPlan(
                strategy: .perH2Section,
                chunks: chunks,
                totalEstimatedTokens: chunks.reduce(0) { $0 + $1.estimatedTokens }
            )
        }
        let chunks = sizeBasedChunks(of: bodyText)
        return ChunkPlan(
            strategy: .sizeBased,
            chunks: chunks,
            totalEstimatedTokens: chunks.reduce(0) { $0 + $1.estimatedTokens }
        )
    }

    // MARK: - H2 splitting

    struct RawSection: Equatable {
        let heading: String?
        let text: String
    }

    /// Split `text` at lines that are EXACTLY an H2 heading (`## Title`, not
    /// `### Title`). Text before the first H2 becomes a `heading: nil`
    /// preamble section (dropped if empty). Falls back to a single
    /// `heading: nil` section covering the whole text when there are no H2s.
    static func splitByH2(_ text: String) -> [RawSection] {
        let pattern = "^## (?!#)(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return [RawSection(heading: nil, text: text)]
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [RawSection(heading: nil, text: text)] }

        var sections: [RawSection] = []
        let firstStart = matches[0].range.location
        if firstStart > 0 {
            let preamble = nsText.substring(to: firstStart).trimmingCharacters(in: .whitespacesAndNewlines)
            if !preamble.isEmpty { sections.append(RawSection(heading: nil, text: preamble)) }
        }
        for (index, match) in matches.enumerated() {
            let heading = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsText.length
            let sectionText = nsText.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(RawSection(heading: heading, text: sectionText))
        }
        return sections
    }

    /// Turn raw H2 sections into ``DocumentChunk``s, further size-splitting
    /// any section that alone exceeds ``maxChunkTokens`` (sub-chunks of an
    /// oversized section keep that section's heading).
    static func expand(_ sections: [RawSection]) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        for section in sections {
            let tokens = TokenEstimator.estimateTokens(in: section.text)
            if tokens <= maxChunkTokens {
                chunks.append(DocumentChunk(index: chunks.count, heading: section.heading, markdown: section.text, estimatedTokens: tokens))
                continue
            }
            for piece in paragraphChunks(of: section.text, targetTokens: targetChunkTokens) {
                let pieceTokens = TokenEstimator.estimateTokens(in: piece)
                chunks.append(DocumentChunk(index: chunks.count, heading: section.heading, markdown: piece, estimatedTokens: pieceTokens))
            }
        }
        return chunks
    }

    // MARK: - Size-based fallback

    static func sizeBasedChunks(of text: String) -> [DocumentChunk] {
        paragraphChunks(of: text, targetTokens: targetChunkTokens).enumerated().map { index, chunkText in
            DocumentChunk(
                index: index,
                heading: nil,
                markdown: chunkText,
                estimatedTokens: TokenEstimator.estimateTokens(in: chunkText)
            )
        }
    }

    /// Greedily accumulate blank-line-separated paragraphs into chunks no
    /// larger than `targetTokens`. A single paragraph that alone exceeds the
    /// budget becomes its own oversized chunk rather than being split
    /// mid-sentence — sentence-safety wins over strict budget adherence.
    static func paragraphChunks(of text: String, targetTokens: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0
        for paragraph in paragraphs {
            let paragraphTokens = TokenEstimator.estimateTokens(in: paragraph)
            if !current.isEmpty, currentTokens + paragraphTokens > targetTokens {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                currentTokens = 0
            }
            current.append(paragraph)
            currentTokens += paragraphTokens
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }
}
