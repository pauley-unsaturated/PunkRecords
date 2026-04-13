import Foundation

/// Versioned prompt template. Each eval run is tagged with the variant that was active,
/// enabling before/after comparison when you change a prompt.
public struct PromptVariant: Codable, Identifiable, Sendable {
    public let id: String              // e.g. "system-v1" or "tool-descriptions-v2"
    public let name: String
    public let version: Int
    public let description: String     // What changed and why
    public let template: String        // The actual prompt template (may contain {vault_name} etc.)
    public let createdAt: Date
    public let parentVariantID: String?  // nil for root; otherwise the variant this was derived from

    public init(
        id: String,
        name: String,
        version: Int,
        description: String,
        template: String,
        parentVariantID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.template = template
        self.parentVariantID = parentVariantID
        self.createdAt = createdAt
    }

    /// Built-in baseline that mirrors the current default ContextBuilder prompt.
    /// Use this as `parentVariantID` for derived variants.
    public static let baseline = PromptVariant(
        id: "baseline-v1",
        name: "Default research assistant",
        version: 1,
        description: "Original hardcoded system prompt in ContextBuilder",
        template: """
        You are a personal research assistant for a knowledge base called "{vault_name}".
        The user's notes are provided below as context. Your job is to:
        - Answer questions by cross-referencing the provided notes.
        - Cite specific notes when drawing on them (use the format [[Note Title]]).
        - Point out contradictions or gaps in the user's notes when relevant.
        - Be concise unless asked to elaborate.
        - If a "Currently selected text" section is present, the user can see and is referring to that text.
        """,
        parentVariantID: nil,
        createdAt: Date(timeIntervalSince1970: 1744416000)  // stable date for tests
    )
}
