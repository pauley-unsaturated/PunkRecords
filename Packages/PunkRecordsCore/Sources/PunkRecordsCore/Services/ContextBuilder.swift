import Foundation

/// Assembles LLM context from KB documents, scaling automatically based on provider context size.
public actor ContextBuilder {
    private let searchService: any SearchService
    private let repository: any DocumentRepository

    public init(searchService: any SearchService, repository: any DocumentRepository) {
        self.searchService = searchService
        self.repository = repository
    }

    public enum ContextTier {
        case small   // < 4k tokens: current document only
        case medium  // 4k–32k: current doc + top FTS hits
        case large   // 32k+: full algorithm with graph neighbors + recency

        public init(maxTokens: Int) {
            switch maxTokens {
            case ..<4_000: self = .small
            case 4_000..<32_000: self = .medium
            default: self = .large
            }
        }
    }

    /// Builds context for an LLM request, scaling to fit the provider's context window.
    public func buildContext(
        prompt: String,
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        maxTokens: Int,
        vaultName: String
    ) async throws -> (systemPrompt: String, excerpts: [DocumentExcerpt]) {
        let tier = ContextTier(maxTokens: maxTokens)
        let responseBudget = Int(Double(maxTokens) * 0.3)
        let contextBudget = maxTokens - responseBudget - TokenEstimator.estimateTokens(in: prompt)

        guard contextBudget > 0 else {
            return (buildSystemPrompt(vaultName: vaultName, excerpts: []), [])
        }

        var excerpts: [DocumentExcerpt] = []

        switch tier {
        case .small:
            excerpts = try await buildSmallContext(
                currentDocumentID: currentDocumentID,
                budget: contextBudget
            )
        case .medium:
            excerpts = try await buildMediumContext(
                prompt: prompt,
                scope: scope,
                currentDocumentID: currentDocumentID,
                budget: contextBudget
            )
        case .large:
            excerpts = try await buildLargeContext(
                prompt: prompt,
                scope: scope,
                currentDocumentID: currentDocumentID,
                budget: contextBudget
            )
        }

        let systemPrompt = buildSystemPrompt(vaultName: vaultName, excerpts: excerpts)
        return (systemPrompt, excerpts)
    }

    // MARK: - Small Context (< 4k)

    private func buildSmallContext(
        currentDocumentID: DocumentID?,
        budget: Int
    ) async throws -> [DocumentExcerpt] {
        guard let docID = currentDocumentID,
              let doc = try await repository.document(withID: docID) else {
            return []
        }
        let truncated = TokenEstimator.truncateToTokenBudget(doc.content, budget: budget)
        return [DocumentExcerpt(
            documentID: doc.id,
            title: doc.title,
            excerpt: truncated,
            relevanceScore: 1.0
        )]
    }

    // MARK: - Medium Context (4k–32k)

    private func buildMediumContext(
        prompt: String,
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        budget: Int
    ) async throws -> [DocumentExcerpt] {
        var excerpts: [DocumentExcerpt] = []
        var usedTokens = 0

        // Add current document first
        if let docID = currentDocumentID,
           let doc = try await repository.document(withID: docID) {
            let docTokens = min(budget / 2, TokenEstimator.estimateTokens(in: doc.content))
            let truncated = TokenEstimator.truncateToTokenBudget(doc.content, budget: docTokens)
            excerpts.append(DocumentExcerpt(
                documentID: doc.id,
                title: doc.title,
                excerpt: truncated,
                relevanceScore: 1.0
            ))
            usedTokens += TokenEstimator.estimateTokens(in: truncated)
        }

        // Add FTS results
        let searchResults = try await searchService.search(query: prompt)
        for result in searchResults {
            guard usedTokens < budget else { break }
            if excerpts.contains(where: { $0.documentID == result.documentID }) { continue }

            let remaining = budget - usedTokens
            let truncated = TokenEstimator.truncateToTokenBudget(result.excerpt, budget: remaining)
            excerpts.append(DocumentExcerpt(
                documentID: result.documentID,
                title: result.title,
                excerpt: truncated,
                relevanceScore: result.score
            ))
            usedTokens += TokenEstimator.estimateTokens(in: truncated)
        }

        return excerpts
    }

    // MARK: - Large Context (32k+)

    private func buildLargeContext(
        prompt: String,
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        budget: Int
    ) async throws -> [DocumentExcerpt] {
        var candidates: [ScoredCandidate] = []

        // 1. FTS search
        let searchResults = try await searchService.search(query: prompt)
        for result in searchResults {
            candidates.append(ScoredCandidate(
                documentID: result.documentID,
                title: result.title,
                content: result.excerpt,
                score: result.score
            ))
        }

        // 2. Graph neighbors of current document
        if let docID = currentDocumentID,
           let doc = try await repository.document(withID: docID) {
            // Add current doc with highest score
            candidates.append(ScoredCandidate(
                documentID: doc.id,
                title: doc.title,
                content: doc.content,
                score: 10.0  // Highest priority
            ))

            // Add linked documents
            for linkedID in doc.linkedDocumentIDs {
                if let linked = try await repository.document(withID: linkedID) {
                    let existing = candidates.first(where: { $0.documentID == linkedID })
                    let graphBonus: Float = 2.0
                    candidates.append(ScoredCandidate(
                        documentID: linked.id,
                        title: linked.title,
                        content: linked.content,
                        score: (existing?.score ?? 0) + graphBonus
                    ))
                }
            }

            // Add backlinks
            let backlinkIDs = try await searchService.backlinks(for: docID)
            for blID in backlinkIDs {
                if let bl = try await repository.document(withID: blID) {
                    let existing = candidates.first(where: { $0.documentID == blID })
                    candidates.append(ScoredCandidate(
                        documentID: bl.id,
                        title: bl.title,
                        content: bl.content,
                        score: (existing?.score ?? 0) + 1.5
                    ))
                }
            }
        }

        // Deduplicate: keep highest score per document
        var bestByID: [DocumentID: ScoredCandidate] = [:]
        for candidate in candidates {
            if let existing = bestByID[candidate.documentID] {
                if candidate.score > existing.score {
                    bestByID[candidate.documentID] = candidate
                }
            } else {
                bestByID[candidate.documentID] = candidate
            }
        }

        // Sort by score descending
        let sorted = bestByID.values.sorted { $0.score > $1.score }

        // Greedily fill budget
        var excerpts: [DocumentExcerpt] = []
        var usedTokens = 0

        for candidate in sorted {
            guard usedTokens < budget else { break }
            let remaining = budget - usedTokens
            let truncated = TokenEstimator.truncateToTokenBudget(candidate.content, budget: remaining)
            guard !truncated.isEmpty else { continue }

            excerpts.append(DocumentExcerpt(
                documentID: candidate.documentID,
                title: candidate.title,
                excerpt: truncated,
                relevanceScore: candidate.score
            ))
            usedTokens += TokenEstimator.estimateTokens(in: truncated)
        }

        return excerpts
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(vaultName: String, excerpts: [DocumentExcerpt]) -> String {
        var prompt = """
        You are a personal research assistant for a knowledge base called "\(vaultName)".
        The user's notes are provided below as context. Your job is to:
        - Answer questions by cross-referencing the provided notes.
        - Cite specific notes when drawing on them (use the format [[Note Title]]).
        - Point out contradictions or gaps in the user's notes when relevant.
        - Be concise unless asked to elaborate.
        - If a "Currently selected text" section is present, the user can see and is referring to that text.

        Knowledge base context:
        """

        for excerpt in excerpts {
            prompt += "\n\n--- [[" + excerpt.title + "]] ---\n" + excerpt.excerpt
        }

        return prompt
    }
}

// MARK: - Private Types

private struct ScoredCandidate {
    let documentID: DocumentID
    let title: String
    let content: String
    let score: Float
}
