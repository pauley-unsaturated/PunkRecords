import Foundation

/// Summarizes a chat conversation into a saved wiki note.
///
/// Two-phase, because the UI asks the user *where* to save only after the
/// summary exists:
///  1. ``summarize(transcript:threadTitle:)`` runs a one-shot completion through
///     the injected ``TextCompleter`` (the session/completer path in Infra) and
///     returns the markdown summary body — no tools, no fabrication.
///  2. ``saveSummaryNote(summaryBody:title:folder:)`` writes that body as a
///     new note through the ``DocumentRepository`` with generated frontmatter and
///     a collision-safe filename.
///
/// The two phases are deliberately separate so the App layer can present the
/// destination picker between them and keep the summary in hand if the user
/// cancels. Mirrors ``NoteCompiler``: it depends only on the minimal
/// ``TextCompleter`` seam (Core stays pure; Infra injects the concrete
/// session-path completer, evals inject a mock/scripted one).
///
/// The prompt builder, default-title derivation, destination-path derivation,
/// and the "is there anything to summarize?" gate are exposed as pure `static`
/// functions so they are unit-testable without the actor, the LLM, or the
/// filesystem.
public actor ConversationSummarizer {
    private let completer: any TextCompleter
    private let repository: any DocumentRepository
    private let parser: MarkdownParser

    public init(
        completer: any TextCompleter,
        repository: any DocumentRepository,
        parser: MarkdownParser = MarkdownParser()
    ) {
        self.completer = completer
        self.repository = repository
        self.parser = parser
    }

    // MARK: - Phase 1: summarize

    /// Run a one-shot summarization over an already-rendered transcript and
    /// return the model's markdown summary body.
    ///
    /// The caller renders the transcript with ``ThreadTranscriptRenderer`` (with a
    /// provider-sized token budget) and passes it in, so this type never touches
    /// the thread model or the token estimator — it only builds the prompt and
    /// drives the completer.
    public func summarize(transcript: String, threadTitle: String) async throws -> String {
        let prompt = Self.summarizationPrompt(transcript: transcript, threadTitle: threadTitle)
        let raw = try await completer.complete(prompt: prompt)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phase 2: save

    /// Write a produced summary body as a new note and return the created
    /// ``Document``. Generates frontmatter (id + timestamps), wraps the body under
    /// an H1 taken from `title`, and lands it at a collision-safe path derived from
    /// `folder` + `title` (probing `Base.md`, `Base 2.md`, … via the same
    /// ``FilenameHelpers/uniqueNotePath(baseName:exists:)`` precedent the app's
    /// note-creation paths use). Any stray frontmatter the model emitted in the
    /// body is stripped so the note has exactly one frontmatter block.
    public func saveSummaryNote(
        summaryBody: String,
        title: String,
        folder: RelativePath
    ) async throws -> Document {
        let effectiveTitle = Self.effectiveTitle(title)
        // Defense in depth: strip any frontmatter block the model added to the
        // body so we don't emit two `---` blocks.
        let body = parser.parseFrontmatter(from: summaryBody).body
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let id = DocumentID()
        let now = Date()
        let frontmatter = parser.generateFrontmatter(id: id, tags: [], created: now, modified: now)
        let content = frontmatter + "\n\n# \(effectiveTitle)\n\n" + body + "\n"

        let baseName = Self.uniquingBaseName(inFolder: folder, title: effectiveTitle)
        let path = await FilenameHelpers.uniqueNotePath(baseName: baseName) { [repository] candidate in
            (try? await repository.document(atPath: candidate)) != nil
        }

        let document = Document(
            id: id,
            title: effectiveTitle,
            content: content,
            path: path,
            tags: [],
            created: now,
            modified: now,
            frontmatter: ["id": id.uuidString],
            linkedDocumentIDs: []
        )

        try await repository.save(document)
        return document
    }

    // MARK: - Pure helpers

    /// Whether the active conversation holds anything worth summarizing: at least
    /// one user or assistant message with non-empty content. Tool-call rows and
    /// blank turns don't count, so an empty or tool-only thread can't be
    /// summarized. Backs the "Summarize to Note" action's disabled state.
    public static func hasSummarizableContent(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            (message.role == .user || message.role == .assistant)
                && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Build the summarization prompt from a rendered transcript and the thread
    /// title. Asks for a faithful, structured markdown summary (topic, key points,
    /// decisions/outcomes, open questions) with no title, no frontmatter, and no
    /// fabrication — the App wraps the returned body under a user-chosen H1.
    public static func summarizationPrompt(transcript: String, threadTitle: String) -> String {
        let trimmedTitle = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLine = trimmedTitle.isEmpty ? "" : "Conversation title: \(trimmedTitle)\n"
        return """
        You are summarizing a conversation into a note for a personal knowledge base.
        \(titleLine)
        Write a faithful, well-structured markdown summary of the conversation below. Requirements:
        - Organize the summary under these `##` sections, in this order:
          ## Topic
          ## Key Points
          ## Decisions & Outcomes
          ## Open Questions
        - Use bullet lists under Key Points, Decisions & Outcomes, and Open Questions.
        - Be faithful to what was actually said. Do NOT invent facts, sources, decisions, \
        or outcomes. If a section has nothing to report, write "None." under it.
        - Do NOT include a top-level `#` title or YAML frontmatter — output only the section body.
        - Output ONLY the markdown summary, with no preamble or explanation.

        Conversation:
        \(transcript)
        """
    }

    /// The title pre-filled into the save dialog: `Summary — <thread title>`,
    /// or just `Summary` when the thread has no usable title. Trims the incoming
    /// title and collapses a placeholder / empty title to the bare form.
    public static func defaultNoteTitle(forThreadTitle threadTitle: String) -> String {
        let trimmed = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ChatThreadHelpers.defaultTitle else {
            return "Summary"
        }
        return "Summary — \(trimmed)"
    }

    /// The vault-relative destination path a summary titled `title` in `folder`
    /// lands at *before* collision-uniquing (`folder/<sanitized title>.md`, or
    /// `<sanitized title>.md` at the vault root). This is the first candidate
    /// ``saveSummaryNote(summaryBody:title:folder:)`` probes; a real collision
    /// bumps it to `… 2.md`, `… 3.md`.
    public static func destinationPath(inFolder folder: RelativePath, title: String) -> RelativePath {
        "\(uniquingBaseName(inFolder: folder, title: title)).md"
    }

    // MARK: - Private

    /// The (extension-less) base name handed to ``FilenameHelpers/uniqueNotePath``:
    /// the sanitized title, prefixed by the folder when one is given. Slashes in
    /// the returned value are intentional — `uniqueNotePath` appends `.md` and any
    /// ` N` disambiguator after the whole thing, keeping the note in `folder`.
    static func uniquingBaseName(inFolder folder: RelativePath, title: String) -> String {
        let sanitized = sanitizeFilename(effectiveTitle(title))
        let trimmedFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmedFolder.isEmpty ? sanitized : "\(trimmedFolder)/\(sanitized)"
    }

    /// Fall back to a stable title when the caller passes an empty/blank one, so
    /// both the H1 and the filename always have something usable.
    static func effectiveTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Summary" : trimmed
    }

    /// Mirror ``CreateNoteTool``/``NoteCompiler`` filename sanitization: strip the
    /// characters that are invalid in a `.md` filename, and cap the length.
    private static func sanitizeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: #"/\:*?"<>|"#)
        let sanitized = title.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Summary" : String(trimmed.prefix(100))
    }
}
