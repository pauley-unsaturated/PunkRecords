import Foundation

public struct Vault: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rootURL: URL
    public var settings: VaultSettings

    public init(
        id: UUID = UUID(),
        name: String,
        rootURL: URL,
        settings: VaultSettings = VaultSettings()
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.settings = settings
    }
}
