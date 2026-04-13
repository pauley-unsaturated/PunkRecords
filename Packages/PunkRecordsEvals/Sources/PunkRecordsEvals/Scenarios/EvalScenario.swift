import Foundation
import PunkRecordsCore

/// A self-contained eval scenario with inputs, fixture data, and ground truth.
public struct EvalScenario: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let category: ScenarioCategory

    // Inputs
    public let vaultDocuments: [Document]
    public let queryResultMap: [String: [SearchResult]]
    public let backlinkMap: [DocumentID: [DocumentID]]
    public let userPrompt: String
    public let currentDocumentID: DocumentID?
    public let scope: QueryScope

    // Expected behavior
    public let groundTruth: GroundTruth

    public init(
        id: String,
        name: String,
        description: String,
        category: ScenarioCategory,
        vaultDocuments: [Document],
        queryResultMap: [String: [SearchResult]] = [:],
        backlinkMap: [DocumentID: [DocumentID]] = [:],
        userPrompt: String,
        currentDocumentID: DocumentID? = nil,
        scope: QueryScope = .global,
        groundTruth: GroundTruth
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.vaultDocuments = vaultDocuments
        self.queryResultMap = queryResultMap
        self.backlinkMap = backlinkMap
        self.userPrompt = userPrompt
        self.currentDocumentID = currentDocumentID
        self.scope = scope
        self.groundTruth = groundTruth
    }
}

public enum ScenarioCategory: String, Codable, Sendable {
    case simpleQA
    case vaultSearchSynthesize
    case noteCreation
    case multiStepResearch
    case edgeCaseEmpty
    case edgeCaseContradiction
}
