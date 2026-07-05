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

    /// The original verbose prompt — archived after being superseded by terse-v1
    /// on 2026-04-13. Kept as a reference point for future A/B comparisons.
    public static let baseline = PromptVariant(
        id: "baseline-v1",
        name: "Default research assistant",
        version: 1,
        description: "Original hardcoded system prompt in ContextBuilder (archived)",
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
        createdAt: Date(timeIntervalSince1970: 1744416000)
    )

    /// Promoted from baseline-v1 after a 20-scenario A/B run on 2026-04-13
    /// showed consistent ~6% token reduction at 100% task completion parity.
    /// Superseded by terse-v2 on 2026-05-16 once web_search shipped.
    public static let terseV1 = PromptVariant(
        id: "terse-v1",
        name: "Terse",
        version: 1,
        description: "Shorter directives; promoted to default 2026-04-13",
        template: """
        You are a terse research assistant for "{vault_name}". Rules:
        - Answer directly, no preamble.
        - Cite notes as [[Note Title]].
        - One short paragraph unless the user asks for more.
        - Flag contradictions or gaps in one line.
        """,
        parentVariantID: "baseline-v1",
        createdAt: Date(timeIntervalSince1970: 1744502400)
    )

    /// The current default prompt in ContextBuilder. Adds vault-vs-web tool
    /// routing and citation discipline once Anthropic's native web_search
    /// became available. Promoted from terse-v1 on 2026-05-16.
    public static let current = PromptVariant(
        id: "terse-v2",
        name: "Terse + tool routing",
        version: 2,
        description: "Adds vault-vs-web search routing and web citation rules",
        template: """
        You are a terse research assistant for "{vault_name}". Rules:
        - Answer directly, no preamble.
        - Prefer vault_search for anything the user has likely captured; use web_search only for \
        current events, external facts, or topics absent from the vault.
        - Cite vault notes as [[Note Title]]; cite web results inline as [Title](url) and only when you used them.
        - One short paragraph unless the user asks for more.
        - Flag contradictions or gaps in one line.
        """,
        parentVariantID: "terse-v1",
        createdAt: Date(timeIntervalSince1970: 1747353600) // 2026-05-16T00:00:00Z
    )
}
