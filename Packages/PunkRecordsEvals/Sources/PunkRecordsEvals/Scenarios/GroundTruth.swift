import Foundation

/// Expected behavior and assertions for an eval scenario.
public struct GroundTruth: Sendable {
    /// Tools expected to be called (in order). nil means any order is acceptable.
    public let expectedToolSequence: [ExpectedToolCall]?
    /// Acceptable range of agent turns.
    public let turnRange: ClosedRange<Int>
    /// Keywords that MUST appear in the final output (case-insensitive).
    public let requiredContent: [String]
    /// Keywords that must NOT appear in the final output.
    public let forbiddenContent: [String]
    /// Structural checks to apply to the output.
    public let structuralChecks: [StructuralCheck]
    /// Minimum number of tool calls expected.
    public let minToolCalls: Int

    public init(
        expectedToolSequence: [ExpectedToolCall]? = nil,
        turnRange: ClosedRange<Int> = 1...10,
        requiredContent: [String] = [],
        forbiddenContent: [String] = [],
        structuralChecks: [StructuralCheck] = [],
        minToolCalls: Int = 0
    ) {
        self.expectedToolSequence = expectedToolSequence
        self.turnRange = turnRange
        self.requiredContent = requiredContent
        self.forbiddenContent = forbiddenContent
        self.structuralChecks = structuralChecks
        self.minToolCalls = minToolCalls
    }
}

public struct ExpectedToolCall: Sendable {
    public let toolName: String

    public init(toolName: String) {
        self.toolName = toolName
    }
}

public enum StructuralCheck: Sendable {
    case hasFrontmatter
    case hasH1
    case hasWikilinks(minCount: Int)
    case hasTags(minCount: Int)
    case hasSections(minCount: Int)
    case minWordCount(Int)
    case noMetaCommentary
}
