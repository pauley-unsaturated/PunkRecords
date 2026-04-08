import Foundation

public struct VaultSettings: Codable, Sendable {
    public var defaultLLMProvider: LLMProviderID
    public var enabledProviders: [LLMProviderID]
    public var ignoredPaths: [String]
    public var autoIndexOnSave: Bool

    public init(
        defaultLLMProvider: LLMProviderID = .anthropic,
        enabledProviders: [LLMProviderID] = [.anthropic, .openAI],
        ignoredPaths: [String] = [".punkrecords/**", ".obsidian/**", ".git/**"],
        autoIndexOnSave: Bool = true
    ) {
        self.defaultLLMProvider = defaultLLMProvider
        self.enabledProviders = enabledProviders
        self.ignoredPaths = ignoredPaths
        self.autoIndexOnSave = autoIndexOnSave
    }
}
