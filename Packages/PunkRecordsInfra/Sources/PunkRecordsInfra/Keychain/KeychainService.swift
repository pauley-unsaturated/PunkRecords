import Foundation
@preconcurrency import KeychainAccess

/// Stores and retrieves API keys from the macOS Keychain.
public final class KeychainService: @unchecked Sendable {
    private let keychain: Keychain

    public init(service: String = "com.markpauley.PunkRecords") {
        self.keychain = Keychain(service: service)
    }

    public func apiKey(for provider: String) throws -> String? {
        try keychain.get("api-key-\(provider)")
    }

    public func setAPIKey(_ key: String, for provider: String) throws {
        try keychain.set(key, key: "api-key-\(provider)")
    }

    public func removeAPIKey(for provider: String) throws {
        try keychain.remove("api-key-\(provider)")
    }
}
