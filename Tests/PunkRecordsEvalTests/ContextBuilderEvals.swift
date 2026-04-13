import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsTestSupport

/// Evaluates ContextBuilder document selection quality: precision, recall, and budget utilization.
@Suite("Context Builder Evals")
struct ContextBuilderEvals {

    // MARK: - Document Selection Precision/Recall

    @Test("Large tier selects relevant documents with high precision")
    func largeTierPrecision() async throws {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()

        // Seed vault with 5 docs, only 3 are relevant to concurrency
        for doc in EvalVaultFixtures.standardVault {
            try await mockRepo.save(doc)
        }
        await mockSearch.setSearchResults(EvalVaultFixtures.concurrencySearchResults)
        await mockSearch.setBacklinkMap([
            EvalVaultFixtures.concurrencyDocID: [EvalVaultFixtures.reentrancyDocID]
        ])

        let builder = ContextBuilder(searchService: mockSearch, repository: mockRepo)
        let (_, excerpts) = try await builder.buildContext(
            prompt: "Tell me about Swift concurrency",
            scope: .global,
            currentDocumentID: EvalVaultFixtures.concurrencyDocID,
            maxTokens: 64_000,
            vaultName: "Eval"
        )

        let selectedIDs = Set(excerpts.map(\.documentID))
        let relevantIDs: Set<DocumentID> = [
            EvalVaultFixtures.concurrencyDocID,
            EvalVaultFixtures.reentrancyDocID,
            EvalVaultFixtures.sendableDocID,
        ]

        let truePositives = selectedIDs.intersection(relevantIDs)
        let precision = selectedIDs.isEmpty ? 0 : Double(truePositives.count) / Double(selectedIDs.count)
        let recall = Double(truePositives.count) / Double(relevantIDs.count)

        #expect(precision >= 0.6, "Precision \(precision) should be >= 0.6")
        #expect(recall >= 0.6, "Recall \(recall) should be >= 0.6")
    }

    @Test("Medium tier respects token budget")
    func mediumTierBudget() async throws {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()

        for doc in EvalVaultFixtures.standardVault {
            try await mockRepo.save(doc)
        }
        await mockSearch.setSearchResults(EvalVaultFixtures.concurrencySearchResults)

        let builder = ContextBuilder(searchService: mockSearch, repository: mockRepo)
        let budget = 8_000
        let (systemPrompt, _) = try await builder.buildContext(
            prompt: "Tell me about concurrency",
            scope: .global,
            currentDocumentID: EvalVaultFixtures.concurrencyDocID,
            maxTokens: budget,
            vaultName: "Eval"
        )

        let usedTokens = TokenEstimator.estimateTokens(in: systemPrompt)
        #expect(usedTokens <= budget, "System prompt tokens \(usedTokens) should not exceed budget \(budget)")
    }

    @Test("Context tier classification is correct")
    func tierClassification() async throws {
        #expect(ContextBuilder.ContextTier(maxTokens: 2_000) == .small)
        #expect(ContextBuilder.ContextTier(maxTokens: 3_999) == .small)
        #expect(ContextBuilder.ContextTier(maxTokens: 4_000) == .medium)
        #expect(ContextBuilder.ContextTier(maxTokens: 31_999) == .medium)
        #expect(ContextBuilder.ContextTier(maxTokens: 32_000) == .large)
        #expect(ContextBuilder.ContextTier(maxTokens: 200_000) == .large)
    }

    // MARK: - Prompt Template Override

    @Test("Custom prompt template is used when provided")
    func promptTemplateOverride() async throws {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()

        let doc = EvalVaultFixtures.concurrencyDoc
        try await mockRepo.save(doc)

        let builder = ContextBuilder(searchService: mockSearch, repository: mockRepo)
        let template = "You are a coding tutor for {vault_name}. Be encouraging."

        let (systemPrompt, _) = try await builder.buildContext(
            prompt: "Help me",
            scope: .document(doc.id),
            currentDocumentID: doc.id,
            maxTokens: 8_000,
            vaultName: "My Vault",
            systemPromptTemplate: template
        )

        #expect(systemPrompt.contains("coding tutor"), "Should use custom template")
        #expect(systemPrompt.contains("My Vault"), "Should substitute vault name")
        #expect(!systemPrompt.contains("research assistant"), "Should not use default template")
    }
}

// ContextTier needs Equatable for testing
extension ContextBuilder.ContextTier: Equatable {}
