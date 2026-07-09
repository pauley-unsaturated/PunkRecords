import AppKit
import Foundation
import PunkRecordsCore
import PunkRecordsInfra

/// Minimal per-call inputs the URL-summarize flow needs: which provider/model
/// config runs the one-shot summarization completion. Deliberately smaller
/// than ``ChatTurnParameters`` — this flow has no chat scope, selection, or
/// vault-name banner, just "which backend does the completion run on."
struct URLSummarizeParameters: Sendable {
    let provider: LLMProviderID
    let config: LanguageModelFactory.Config

    /// Resolve the SAME provider/config the chat panel's picker/Settings
    /// currently point at, read directly from `UserDefaults` (no `@AppStorage`
    /// property wrapper needed outside a View). Used by the clipboard-driven
    /// entry point, which fires from a menu command with no view in scope.
    static func fromUserDefaults() -> URLSummarizeParameters {
        let providerRaw = UserDefaults.standard.string(forKey: ProviderRegistry.DefaultsKey.chatProvider)
        return URLSummarizeParameters(
            provider: ProviderRegistry.chatProvider(from: providerRaw),
            config: .fromUserDefaults()
        )
    }
}

/// Progress phases the status view renders. The issue's suggested sequence is
/// fetching → extracting → summarizing → writing; "extracting" is folded into
/// ``fetching`` here because ``WebContentFetcher/fetch(url:)`` performs the
/// network fetch AND on-device extraction as one opaque async call (by
/// design — Infra/WebFetch internals are out of scope for this issue), so
/// there's no real intermediate point to observe between them. Labeling that
/// single step "Fetching page…" stays honest about what's actually
/// happening instead of faking a phase boundary that doesn't exist.
enum URLSummaryPhase: Sendable, Equatable {
    case fetching
    case summarizing
    case writing

    var label: String {
        switch self {
        case .fetching: return "Fetching page…"
        case .summarizing: return "Summarizing…"
        case .writing: return "Saving note…"
        }
    }
}

/// The URL→note pipeline (PUNK-ddq): WebFetch → ``WebSummaryPrompt`` → the
/// current provider's ``TextCompleter`` → ``WebSummaryPostProcessor`` →
/// ``WebSummaryNoteWriter`` → save through the repository, mirroring how
/// ``AppState/createNewNote()`` and the summarize-to-note flow
/// (``ChatSessionController/summarizeToNote(_:)``) create documents: repository
/// save, `session.upsert`, search-index update, then select the new note.
///
/// Shared by two entry points — the chat composer's "Summarize this URL"
/// affordance and the "Summarize URL from Clipboard" menu command — which both
/// just resolve a URL and call ``summarizeURL(_:parameters:)``.
@MainActor
extension ChatSessionController {

    /// Entry point #1: the composer contains a lone summarizable URL (typed or
    /// pasted — see ``ComposerURLDetector``). Clears the composer (the URL was
    /// never meant to be sent as a chat message) and runs the pipeline.
    func summarizeURLFromComposer(_ parameters: URLSummarizeParameters) {
        guard let url = composerSummarizableURL else { return }
        prompt = ""
        summarizeURL(url, parameters: parameters)
    }

    /// Entry point #2: "Summarize URL from Clipboard". Validates the pasteboard
    /// holds exactly one http(s) URL (the same rule as the composer affordance)
    /// before running the pipeline; surfaces an error and no-ops otherwise.
    func summarizeURLFromClipboard(_ parameters: URLSummarizeParameters) {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let url = ComposerURLDetector.summarizableURL(in: raw) else {
            appState.errorMessage = "Clipboard doesn't contain a single http(s) URL to summarize."
            return
        }
        summarizeURL(url, parameters: parameters)
    }

    /// Cancel the in-flight flow, if any. Cancels the held `Task`, which
    /// propagates cooperative cancellation into the awaited fetch/completion
    /// call — both are built on URLSession/AnyLanguageModel async APIs, which
    /// check for cancellation and abort their underlying request rather than
    /// merely having their result discarded.
    func cancelURLSummary() {
        urlSummaryTask?.cancel()
    }

    // MARK: - Pipeline

    private func summarizeURL(_ url: URL, parameters: URLSummarizeParameters) {
        guard urlSummaryTask == nil, let repository = appState.repository else { return }

        urlSummaryTargetURL = url
        urlSummaryPhase = .fetching

        urlSummaryTask = Task {
            defer {
                urlSummaryTask = nil
                urlSummaryPhase = nil
                urlSummaryTargetURL = nil
            }
            do {
                let content = try await fetchWebContent(url: url)
                try Task.checkCancellation()

                urlSummaryPhase = .summarizing
                let completer = DeferredSessionTextCompleter(
                    provider: parameters.provider,
                    keychain: appState.keychainService,
                    config: parameters.config
                )
                let raw = try await completer.complete(prompt: WebSummaryPrompt.build(content: content))
                try Task.checkCancellation()

                let result = try WebSummaryPostProcessor.process(rawResponse: raw, content: content)
                let issueCount = WebSummaryValidator.validate(payload: result.payload, content: content).count
                try Task.checkCancellation()

                urlSummaryPhase = .writing
                let now = Date()
                let modelID = LanguageModelFactory.modelIdentifier(for: parameters.provider, config: parameters.config)
                let note = WebSummaryNoteWriter.write(
                    content: content,
                    summary: result,
                    validatorIssueCount: issueCount,
                    summaryModel: modelID,
                    now: now,
                    existingPaths: Set(appState.documents.map(\.path))
                )

                let document = Document(
                    id: note.id,
                    title: note.title,
                    content: note.markdown,
                    path: note.path,
                    tags: note.tags,
                    created: now,
                    modified: now,
                    frontmatter: ["id": note.id.uuidString]
                )

                try await repository.save(document)
                appState.session.upsert(document)
                if let index = appState.searchIndex {
                    try? await index.index(document: document)
                }
                appState.selectedDocumentPath = document.path
            } catch is CancellationError {
                // User-initiated; nothing to report.
            } catch {
                appState.errorMessage = "Failed to summarize URL: \(error.localizedDescription)"
            }
        }
    }

    /// Build the three-tier fetcher exactly as the chat's `web_fetch` tool does
    /// (see ``runTurn(_:images:context:turn:)``) and fetch `url`.
    private func fetchWebContent(url: URL) async throws -> WebContent {
        let consentStore = WebFetchConsentStore()
        let fetcher = ThreeTierWebContentFetcher.makeDefault(
            vaultRoot: appState.currentVault?.rootURL,
            jinaConsent: WebFetchConsentPrompt.makeConsentClosure(store: consentStore)
        )
        return try await fetcher.fetch(url: url)
    }
}
