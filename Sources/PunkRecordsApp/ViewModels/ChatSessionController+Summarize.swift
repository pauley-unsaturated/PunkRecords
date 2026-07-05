import AppKit
import Foundation
import PunkRecordsCore
import PunkRecordsInfra

/// The summarize-conversation-to-note flow, split out of ``ChatSessionController``
/// to keep the primary type focused. Renders the active thread with
/// ``ThreadTranscriptRenderer``, runs a one-shot summarization through the
/// `TextCompleter` seam (the same session/completer path note compilation uses),
/// then hands the produced body to a save sheet whose confirm writes the note via
/// the repository and opens it. A cancel keeps the summary and offers
/// Copy / Retry before anything is discarded.
@MainActor
extension ChatSessionController {
    /// Summarize the ACTIVE thread into a note. Renders the transcript with a
    /// provider-sized budget, runs a one-shot completion through the current
    /// provider's session/completer path, and on success opens the destination
    /// save sheet with a prefilled title. On failure it surfaces an alert and
    /// leaves the transcript untouched. A no-op when there's nothing to summarize
    /// or the vault isn't loaded.
    func summarizeToNote(_ turn: ChatTurnParameters) {
        guard canSummarize, let repository = appState.repository else { return }

        let threadTitle = activeThread?.title ?? ChatThreadHelpers.deriveTitle(from: messages)
        let transcript = ThreadTranscriptRenderer.render(
            title: threadTitle,
            messages: messages,
            budget: ProviderRegistry.contextBudget(for: turn.provider)
        )

        // The summary is a pure text-structuring step (no tools), so it rides the
        // same `TextCompleter` seam as note compilation — the deferred completer
        // follows the chat panel's live provider/config selection.
        let completer = DeferredSessionTextCompleter(
            provider: turn.provider,
            keychain: appState.keychainService,
            config: turn.config
        )
        let summarizer = ConversationSummarizer(completer: completer, repository: repository)
        self.summarizer = summarizer
        isSummarizing = true

        Task {
            do {
                let body = try await summarizer.summarize(transcript: transcript, threadTitle: threadTitle)
                summaryBody = body
                summaryTitle = ConversationSummarizer.defaultNoteTitle(forThreadTitle: threadTitle)
                summaryFolder = ""
                isShowingSummarySaveSheet = true
            } catch {
                appState.errorMessage = "Failed to summarize conversation: \(error.localizedDescription)"
                clearSummaryDraft()
            }
            isSummarizing = false
        }
    }

    /// Confirm the save sheet: write the summary as a note through the repository
    /// and open it (same selection-driven navigation QuickOpen/search use). On
    /// write failure, keep the summary and drop to the fallback so nothing is lost.
    func confirmSaveSummary() {
        guard let body = summaryBody, let summarizer else { return }
        let title = summaryTitle
        let folder = summaryFolder
        isShowingSummarySaveSheet = false

        Task {
            do {
                let doc = try await summarizer.saveSummaryNote(
                    summaryBody: body,
                    title: title,
                    folder: folder
                )
                appState.selectedDocumentPath = doc.path
                clearSummaryDraft()
            } catch {
                appState.errorMessage = "Failed to save summary note: \(error.localizedDescription)"
                isShowingSummaryFallback = true
            }
        }
    }

    /// Cancel the save sheet without discarding the summary: dismiss to the
    /// fallback alert offering Copy / Retry Save / Discard.
    func cancelSaveSummary() {
        isShowingSummarySaveSheet = false
        if summaryBody != nil {
            isShowingSummaryFallback = true
        }
    }

    /// Reopen the save sheet from the fallback, preserving the produced summary.
    func retrySaveSummary() {
        guard summaryBody != nil else { return }
        isShowingSummaryFallback = false
        isShowingSummarySaveSheet = true
    }

    /// Copy the produced summary body to the clipboard, then end the flow. The
    /// content is safely off in the pasteboard, so this is a terminal action.
    func copySummaryToClipboard() {
        guard let body = summaryBody else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        isShowingSummaryFallback = false
        clearSummaryDraft()
    }

    /// Explicitly discard the produced summary (the only path that throws it away).
    func discardSummary() {
        isShowingSummaryFallback = false
        clearSummaryDraft()
    }

    private func clearSummaryDraft() {
        summaryBody = nil
        summarizer = nil
        summaryTitle = ""
        summaryFolder = ""
    }
}
