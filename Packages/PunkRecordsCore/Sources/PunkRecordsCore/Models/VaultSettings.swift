import Foundation

public struct VaultSettings: Codable, Sendable {
    public var defaultLLMProvider: LLMProviderID
    public var ignoredPaths: [String]
    public var autoIndexOnSave: Bool

    public init(
        defaultLLMProvider: LLMProviderID = .anthropic,
        ignoredPaths: [String] = [".punkrecords/**", ".obsidian/**", ".git/**", "Web/_cache/**"],
        autoIndexOnSave: Bool = true
    ) {
        self.defaultLLMProvider = defaultLLMProvider
        self.ignoredPaths = ignoredPaths
        self.autoIndexOnSave = autoIndexOnSave
    }
}
