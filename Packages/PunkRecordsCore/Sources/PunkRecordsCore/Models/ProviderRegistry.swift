import Foundation

/// Single source of truth for per-provider LLM configuration knowledge.
///
/// Before this seam, the same facts were scattered across the App layer and the
/// Infra factory: `@AppStorage`/`UserDefaults` key literals in `SettingsView`,
/// `LLMChatPanel`, and `AppState`; default model ids and endpoints inside
/// `LanguageModelFactory.Config`; endpoint-parsing logic duplicated between the
/// chat panel's `factoryConfig` and `Config.fromUserDefaults`; the
/// image-capability switch on ``LLMProviderID``; and a private `contextBudget`
/// table in the chat panel. This type collapses all of that into one place.
///
/// It is **pure and Core-legal**: it names only Foundation and Core's own
/// ``LLMProviderID`` — never AnyLanguageModel / FoundationModels — so it obeys
/// the App → Core → Infra dependency direction. Infra's `LanguageModelFactory`
/// consumes the default model ids / endpoints; the App layer points its
/// `@AppStorage` wrappers at the ``DefaultsKey`` constants and reads the
/// capability / budget lookups; the Keychain account names live here too.
public enum ProviderRegistry {

    // MARK: - Persistence keys

    /// `UserDefaults` keys the Settings UI writes and every non-view call site
    /// reads. These are **load-bearing**: renaming one silently drops users'
    /// saved settings, so they are declared exactly once, here.
    public enum DefaultsKey {
        /// Selected chat / note-compilation provider (an ``LLMProviderID`` raw value).
        public static let chatProvider = "chatProviderID"
        /// Ollama model id for `.anyLanguageModel`.
        public static let ollamaModel = "ollama.model"
        /// Ollama server base URL for `.anyLanguageModel`.
        public static let ollamaBaseURL = "ollama.baseURL"
        /// OpenAI-compatible base-URL override for `.openAI` (blank = official API).
        public static let openAIBaseURL = "openai.baseURL"
    }

    /// Keychain account names under which API keys are stored. These match the
    /// literal provider strings the Settings UI and factory have always used;
    /// changing one would orphan a stored key.
    public enum KeychainAccount {
        public static let anthropic = "anthropic"
        public static let openAI = "openai"
    }

    /// The Keychain account name for `provider`, or `nil` for providers that
    /// need no stored key (local Ollama, on-device Apple Intelligence).
    public static func keychainAccount(for provider: LLMProviderID) -> String? {
        switch provider {
        case .anthropic: return KeychainAccount.anthropic
        case .openAI: return KeychainAccount.openAI
        case .anyLanguageModel, .foundationModels: return nil
        }
    }

    // MARK: - Defaults

    /// Provider selected when nothing is persisted yet.
    public static let chatProviderDefault: LLMProviderID = .anthropic

    /// Default Ollama server base URL (`.anyLanguageModel`).
    public static let defaultOllamaBaseURL = "http://localhost:11434"
    /// Default Ollama model id.
    public static let defaultOllamaModel = "qwen3"
    /// Default OpenAI model id.
    public static let defaultOpenAIModel = "gpt-4o"
    /// Default Anthropic (Claude) model id.
    public static let defaultClaudeModel = "claude-sonnet-4-6"
    /// Default OpenAI base-URL override — blank means the official OpenAI API.
    public static let defaultOpenAIBaseURL = ""

    /// Default Ollama endpoint as a `URL`. Force-unwrap is safe: the literal is
    /// a well-formed URL validated at every use since the app shipped.
    public static var defaultOllamaEndpoint: URL {
        URL(string: defaultOllamaBaseURL)!
    }

    // MARK: - Endpoint / model parsing

    /// Resolve a persisted Ollama model string, falling back to the default id
    /// when it is `nil` or blank.
    public static func ollamaModel(from raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultOllamaModel }
        return raw
    }

    /// Resolve a persisted Ollama base-URL string into a `URL`, falling back to
    /// the default endpoint when it is `nil`, blank, or unparseable.
    public static func ollamaEndpoint(from raw: String?) -> URL {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else {
            return defaultOllamaEndpoint
        }
        return url
    }

    /// Resolve a persisted OpenAI base-URL override. A `nil`, blank, or
    /// unparseable string means "use the official OpenAI endpoint" (`nil`).
    public static func openAIEndpoint(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return url
    }

    /// Resolve a persisted provider raw value into an ``LLMProviderID``, falling
    /// back to `fallback` (default ``chatProviderDefault``) when it is `nil` or
    /// unrecognized.
    public static func chatProvider(
        from raw: String?,
        default fallback: LLMProviderID = chatProviderDefault
    ) -> LLMProviderID {
        raw.flatMap(LLMProviderID.init(rawValue:)) ?? fallback
    }

    // MARK: - Capabilities

    /// Whether `provider` accepts image attachments natively.
    public static func nativeImageInput(_ provider: LLMProviderID) -> Bool {
        switch provider {
        case .foundationModels:
            return false
        case .anthropic, .openAI, .anyLanguageModel:
            return true
        }
    }

    /// Longest image edge (px) `provider` accepts before an attachment is
    /// downscaled. `0` for providers that take no image input.
    public static func maximumImageEdge(_ provider: LLMProviderID) -> Int {
        switch provider {
        case .anthropic:
            return 1_568
        case .openAI, .anyLanguageModel:
            return 2_048
        case .foundationModels:
            return 0
        }
    }

    /// Conservative context-window budget (tokens) for `provider`, used to size
    /// the `ContextBuilder` instructions so the session path selects the same
    /// context tier each backend's own budget implies.
    public static func contextBudget(for provider: LLMProviderID) -> Int {
        switch provider {
        case .foundationModels: return 4_000
        case .anyLanguageModel: return 8_192
        case .openAI: return 128_000
        case .anthropic: return 200_000
        }
    }
}
