import Foundation
import PunkRecordsCore

/// Single source of truth for local-LLM connection settings persisted in
/// `UserDefaults`. Both `AppState` (constructing providers) and the SwiftUI
/// settings/chat views (`@AppStorage`) key off these constants.
enum LocalProviderSettings {
    static let ollamaEndpointKey = "ollamaEndpoint"
    static let ollamaModelKey = "ollamaModel"
    static let lmStudioEndpointKey = "lmStudioEndpoint"
    static let lmStudioModelKey = "lmStudioModel"

    static let defaultOllamaEndpoint = "http://localhost:11434"
    static let defaultLMStudioEndpoint = "http://localhost:1234/v1"

    /// Posted when the user saves local-provider settings, so an open vault can
    /// rebuild its providers without a relaunch.
    static let didChangeNotification = Notification.Name("LocalProviderSettingsDidChange")

    static func endpoint(for id: LLMProviderID, defaults: UserDefaults = .standard) -> URL {
        switch id {
        case .ollama:
            return url(defaults.string(forKey: ollamaEndpointKey), fallback: defaultOllamaEndpoint)
        case .lmStudio:
            return url(defaults.string(forKey: lmStudioEndpointKey), fallback: defaultLMStudioEndpoint)
        default:
            return url(nil, fallback: defaultOllamaEndpoint)
        }
    }

    static func model(for id: LLMProviderID, defaults: UserDefaults = .standard) -> String {
        switch id {
        case .ollama: return defaults.string(forKey: ollamaModelKey) ?? ""
        case .lmStudio: return defaults.string(forKey: lmStudioModelKey) ?? ""
        default: return ""
        }
    }

    private static func url(_ raw: String?, fallback: String) -> URL {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let url = URL(string: trimmed) { return url }
        return URL(string: fallback)!
    }
}
