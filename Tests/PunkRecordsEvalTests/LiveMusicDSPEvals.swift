import Testing
import Foundation
import AnyLanguageModel
@testable import PunkRecordsCore
@testable import PunkRecordsInfra

/// Live evals that point the shipping session-agent path at an arbitrary
/// ON-DISK vault instead of in-memory fixtures. Scenarios are grounded in the
/// Music DSP research vault (paper notes + digests + project indexes) and
/// probe behaviors the fixture suites don't cover: grounding against real
/// retrieval, cross-note synthesis, negative knowledge (refusing to summarize
/// absent content), wikilink resolution in created notes, recency-scoped
/// digest generation, and steered capture placement.
///
/// Opt-in only, double-gated:
/// - `PUNKRECORDS_LIVE_EVALS=1` — real API calls, real cost.
/// - `PUNKRECORDS_EVAL_VAULT=/path/to/vault` — the vault to run against.
///   ALWAYS point this at a disposable COPY: `create_note` scenarios write
///   into the vault, and the index rebuild drops `.punkrecords/` inside it.
///
/// Each scenario prints a delimited summary and writes a full transcript to
/// `PUNKRECORDS_EVAL_OUTPUT` (default: `<vault>/_eval-output/`) for offline
/// analysis. Assertions are intentionally modest — these are evals, not unit
/// tests; the transcript is the primary artifact.
@Suite(
    "Live Music DSP Vault Evals",
    .tags(.eval),
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PUNKRECORDS_LIVE_EVALS"] == "1"
        && ProcessInfo.processInfo.environment["PUNKRECORDS_EVAL_VAULT"] != nil)
)
struct LiveMusicDSPEvals {

    static let keychain = KeychainService()

    /// Provider under eval, selectable via `PUNKRECORDS_EVAL_PROVIDER`
    /// (anthropic | openai | ollama | foundationmodels; default anthropic) so the
    /// same scenario set can measure every backend the app ships. PUNK-rl1 tracks
    /// the full parameterized matrix.
    static func evalProvider() -> LLMProviderID {
        switch ProcessInfo.processInfo.environment["PUNKRECORDS_EVAL_PROVIDER"]?.lowercased() {
        case "openai": .openAI
        case "ollama": .anyLanguageModel
        case "foundationmodels", "apple": .foundationModels
        default: .anthropic
        }
    }

    static func requireAPIKey() throws {
        let keyName: String? = switch evalProvider() {
        case .anthropic: "anthropic"
        case .openAI: "openai"
        default: nil // Ollama / FoundationModels are keyless; makeModel probes availability.
        }
        guard let keyName else { return }
        let key = try? keychain.apiKey(for: keyName)
        guard let key, !key.isEmpty else {
            throw VaultEvalSkip("No \(keyName) API key in keychain — skipping live vault eval")
        }
    }

    /// The model under eval — resolved through the same factory the app uses.
    static func evalModel() throws -> any LanguageModel {
        do {
            return try LanguageModelFactory.makeModel(for: evalProvider(), keychain: keychain)
        } catch {
            throw VaultEvalSkip("Provider \(evalProvider()) unavailable: \(error)")
        }
    }

    // MARK: - S1: grounded single-fact retrieval

    @Test("S1: audio-thread allocation advice is retrieved and attributed")
    func groundedRetrieval() async throws {
        try Self.requireAPIKey()
        let session = try await VaultEvalSession.make()

        let prompt = "What does my vault say about avoiding memory allocation on the audio thread? Which paper did that come from?"
        let result = try await session.runAgent(prompt: prompt, model: try Self.evalModel())
        session.writeTranscript(id: "s1-grounded-retrieval", prompt: prompt, result: result)

        print("[DSP-S1] tools=\(result.toolNames) chars=\(result.finalText.count)")
        #expect(!result.finalText.isEmpty)
        #expect(result.toolCalls.count >= 1, "Should search the vault, not answer from priors")
        let text = result.finalText.lowercased()
        #expect(
            text.contains("lock-free") || text.contains("grain pool") || text.contains("granular"),
            "Expected the granular-synthesis paper's advice (lock-free queues / grain pooling)"
        )
    }

    // MARK: - S2: cross-note synthesis (Chiba x VA filter papers)

    @Test("S2: Chiba filter advice synthesizes the VA filter papers")
    func crossNoteFilterSynthesis() async throws {
        try Self.requireAPIKey()
        let session = try await VaultEvalSession.make()

        let prompt = """
            I'm working on Chiba's dual-filter chain. Based on the VA filter papers in my vault, \
            what implementation approach should I use for stable cutoff modulation, and what should I watch out for?
            """
        let result = try await session.runAgent(prompt: prompt, model: try Self.evalModel())
        session.writeTranscript(id: "s2-filter-synthesis", prompt: prompt, result: result)

        print("[DSP-S2] tools=\(result.toolNames) chars=\(result.finalText.count)")
        #expect(!result.finalText.isEmpty)
        let text = result.finalText.lowercased()
        #expect(
            text.contains("tpt") || text.contains("topology-preserving") || text.contains("zero-delay"),
            "Expected TPT/ZDF recommendation sourced from The Art of VA Filter Design"
        )
    }

    // MARK: - S3: negative knowledge / hallucination probe

    @Test("S3: wavefolding probe admits the vault has nothing")
    func negativeKnowledgeProbe() async throws {
        try Self.requireAPIKey()
        let session = try await VaultEvalSession.make()

        let prompt = "Summarize what my research notes say about wavefolding and West Coast synthesis techniques."
        let result = try await session.runAgent(prompt: prompt, model: try Self.evalModel())
        session.writeTranscript(id: "s3-wavefolding-probe", prompt: prompt, result: result)

        print("[DSP-S3] tools=\(result.toolNames) chars=\(result.finalText.count)")
        #expect(result.toolCalls.count >= 1, "Must actually search before answering")
        let text = result.finalText.lowercased()
        let admissions = [
            "no notes", "not in your", "not in the vault", "doesn't", "does not",
            "couldn't find", "could not find", "no results", "don't have",
            "do not have", "nothing", "absent", "not covered", "no direct", "don't appear",
        ]
        #expect(
            admissions.contains(where: text.contains),
            "Vault has zero wavefolding content — the agent must say so, not fabricate a summary"
        )
    }

    // MARK: - S4: linked synthesis note creation

    @Test("S4: created synthesis note has resolvable wikilinks")
    func linkedNoteCreation() async throws {
        try Self.requireAPIKey()
        let session = try await VaultEvalSession.make()
        let started = Date()

        let prompt = """
            Create a note called 'Differentiable Synthesis — State of Play' that synthesizes the \
            differentiable DSP papers in my vault: what's mature, what's still research-grade, and \
            what's usable in a real-time instrument. Link to the papers you cite with [[wikilinks]] \
            and tag the note appropriately.
            """
        let result = try await session.runAgent(prompt: prompt, model: try Self.evalModel())

        let created = session.markdownFiles(changedAfter: started)
        var report = "Created/changed files: \(created)\n"

        var resolutionLine = "no created note found"
        if let notePath = created.first {
            let noteText = (try? String(contentsOf: session.vaultRoot.appendingPathComponent(notePath), encoding: .utf8)) ?? ""
            let targets = WikilinkScan.targets(in: noteText)
            let (resolved, unresolved) = try await session.resolve(targets: targets)
            resolutionLine = "wikilinks=\(targets.count) resolved=\(resolved.count) unresolved=\(unresolved)"
            report += resolutionLine + "\n"
            #expect(targets.count >= 3, "Synthesis note should cite several papers via wikilinks")
            if !targets.isEmpty {
                let rate = Double(resolved.count) / Double(targets.count)
                #expect(rate >= 0.6, "Most wikilinks must resolve to real notes; unresolved: \(unresolved)")
            }
        }
        session.writeTranscript(id: "s4-linked-note", prompt: prompt, result: result, extra: report)

        print("[DSP-S4] tools=\(result.toolNames) files=\(created) \(resolutionLine)")
        #expect(result.toolNames.contains("create_note"), "Expected the agent to create the note via create_note")
        #expect(!created.isEmpty, "A new note should exist on disk")
    }

    // MARK: - S5: recency-scoped digest generation

    @Test("S5: June digest sticks to June-added papers")
    func juneDigestScoping() async throws {
        try Self.requireAPIKey()
        let session = try await VaultEvalSession.make()

        let prompt = """
            Write me a digest of the papers that entered the vault in June 2026, in the style of my \
            Research Digests — a theme first, then per-paper summaries with project relevance for \
            FLATLINE and Vox. Answer in chat; don't create a note.
            """
        let result = try await session.runAgent(prompt: prompt, model: try Self.evalModel())
        session.writeTranscript(id: "s5-june-digest", prompt: prompt, result: result)

        // Distinctive titles among the 16 papers whose frontmatter says created: 2026-06.
        let juneMarkers = [
            "Four Decades of Digital Waveguides",
            "Stable Differentiable Modal Synthesis",
            "Wave Pulse Phase Modulation",
            "Evaluating Sound Similarity Metrics",
            "Interactive Neural Resonators",
            "NoiseBandNet",
        ]
        let hits = juneMarkers.filter { result.finalText.localizedCaseInsensitiveContains($0) }
        print("[DSP-S5] tools=\(result.toolNames) juneMarkers=\(hits.count)/\(juneMarkers.count)")
        #expect(hits.count >= 3, "Digest should cover several June papers; found only \(hits)")
        #expect(
            !result.finalText.localizedCaseInsensitiveContains("Art of VA Filter Design"),
            "The VA Filter Design note entered in May — including it means date scoping failed"
        )
    }

    // MARK: - S6: steered capture / refile judgment

    @Test("S6: waveguide idea is captured into a defensible Chiba location")
    func steeredCapture() async throws {
        try Self.requireAPIKey()
        let session = try await VaultEvalSession.make()
        let started = Date()

        let prompt = """
            I just read that the new Four Decades of Digital Waveguides survey argues waveguides are \
            'product-shaped' physical models: realtime-cheap, interpretable, and still compatible with \
            modern optimization. Capture that as an idea for Chiba's resonator section — put it \
            wherever it belongs in my vault and link it to the source paper. Tell me where you put it and why.
            """
        let result = try await session.runAgent(prompt: prompt, model: try Self.evalModel())

        let created = session.markdownFiles(changedAfter: started)
        session.writeTranscript(
            id: "s6-steered-capture",
            prompt: prompt,
            result: result,
            extra: "Created/changed files: \(created)\n"
        )

        print("[DSP-S6] tools=\(result.toolNames) files=\(created)")
        #expect(result.toolNames.contains("create_note"), "Expected a captured note")
        #expect(!created.isEmpty, "Captured idea should exist on disk")
        #expect(!result.finalText.isEmpty, "Agent must report where it filed the idea")
    }
}

// MARK: - Vault session plumbing

/// Repository + index + runner wiring over the on-disk eval vault.
private struct VaultEvalSession {
    let vaultRoot: URL
    let repo: FileSystemDocumentRepository
    let index: SQLiteSearchIndex

    /// Kept below chat-panel budgets deliberately: instructions are folded into
    /// EVERY round's prompt by the runner, so this bounds per-round cost.
    static let instructionTokenBudget = 24_000

    static func make() async throws -> VaultEvalSession {
        guard let path = ProcessInfo.processInfo.environment["PUNKRECORDS_EVAL_VAULT"] else {
            throw VaultEvalSkip("PUNKRECORDS_EVAL_VAULT not set")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw VaultEvalSkip("Eval vault does not exist at \(path)")
        }
        let repo = FileSystemDocumentRepository(vaultRoot: root)
        let index = try SQLiteSearchIndex(vaultRoot: root)
        try await index.rebuildIndex(documents: try await repo.allDocuments())
        return VaultEvalSession(vaultRoot: root, repo: repo, index: index)
    }

    struct RunResult {
        var toolCalls: [(name: String, arguments: String)] = []
        var toolResults: [(name: String, output: String, isError: Bool)] = []
        var finalText = ""
        var toolNames: [String] { toolCalls.map(\.name) }
    }

    func runAgent(prompt: String, model: any LanguageModel) async throws -> RunResult {
        let contextBuilder = ContextBuilder(searchService: index, repository: repo)
        let instructions = try await contextBuilder.buildInstructions(
            prompt: prompt,
            scope: .global,
            currentDocumentID: nil,
            maxTokens: Self.instructionTokenBudget,
            vaultName: vaultRoot.lastPathComponent
        )
        let runner = SessionAgentRunner(
            model: model,
            instructions: instructions,
            tools: [
                VaultSearchTool(searchService: index),
                ReadDocumentTool(repository: repo),
                ListDocumentsTool(repository: repo),
                CreateNoteTool(repository: repo),
            ]
        )

        var result = RunResult()
        for try await event in await runner.run(prompt: prompt) {
            switch event {
            case let .toolStart(name, arguments):
                result.toolCalls.append((name, arguments))
            case let .toolEnd(name, toolResult):
                result.toolResults.append((name, toolResult.content, toolResult.isError))
            case let .done(finalText):
                result.finalText = finalText
            default:
                break
            }
        }
        return result
    }

    /// Vault-relative paths of .md files modified after `date`, excluding
    /// derived data. Detects notes written by create_note during a scenario.
    func markdownFiles(changedAfter date: Date) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        var changed: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            let relative = url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
            if relative.hasPrefix(".punkrecords") || relative.hasPrefix("_eval-output") { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > date {
                changed.append(relative)
            }
        }
        return changed.sorted()
    }

    /// Split wikilink targets into (resolved, unresolved) against note titles,
    /// vault-relative paths (with and without folders), and file stems.
    func resolve(targets: [String]) async throws -> (resolved: [String], unresolved: [String]) {
        var keys = Set<String>()
        for doc in try await repo.allDocuments() {
            keys.insert(doc.title.lowercased())
        }
        keys.formUnion(Self.pathKeys(vaultRoot: vaultRoot))
        var resolved: [String] = []
        var unresolved: [String] = []
        for target in targets {
            if keys.contains(target.lowercased()) {
                resolved.append(target)
            } else {
                unresolved.append(target)
            }
        }
        return (resolved, unresolved)
    }

    /// Synchronous on purpose: `FileManager.DirectoryEnumerator` iteration is
    /// unavailable in async contexts under strict concurrency.
    private static func pathKeys(vaultRoot: URL) -> Set<String> {
        var keys = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: vaultRoot, includingPropertiesForKeys: nil) else {
            return keys
        }
        while let object = enumerator.nextObject() {
            guard let url = object as? URL, url.pathExtension == "md" else { continue }
            let relative = url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
            guard !relative.hasPrefix(".punkrecords") else { continue }
            keys.insert(String(relative.dropLast(3)).lowercased())
            keys.insert(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        return keys
    }

    /// Write the full transcript for offline analysis.
    func writeTranscript(id: String, prompt: String, result: RunResult, extra: String = "") {
        let outputDir: URL
        if let path = ProcessInfo.processInfo.environment["PUNKRECORDS_EVAL_OUTPUT"] {
            outputDir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDir = vaultRoot.appendingPathComponent("_eval-output", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var body = "# \(id)\n\n## Prompt\n\(prompt)\n\n## Tool calls (\(result.toolCalls.count))\n"
        for (index, call) in result.toolCalls.enumerated() {
            body += "\(index + 1). `\(call.name)` \(call.arguments)\n"
        }
        body += "\n## Tool results\n"
        for (index, entry) in result.toolResults.enumerated() {
            let flag = entry.isError ? " [ERROR]" : ""
            body += "\(index + 1). `\(entry.name)`\(flag): \(entry.output.prefix(400))\n"
        }
        body += "\n## Final text\n\(result.finalText)\n"
        if !extra.isEmpty {
            body += "\n## Checks\n\(extra)"
        }
        try? body.write(to: outputDir.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
    }
}

/// Wikilink extraction for grading — mirrors the app's `[[target|alias]]` and
/// `[[target#heading]]` forms.
private enum WikilinkScan {
    static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)

    static func targets(in text: String) -> [String] {
        let ns = text as NSString
        var targets: [String] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            var target = ns.substring(with: match.range(at: 1))
            if let pipe = target.firstIndex(of: "|") { target = String(target[..<pipe]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            let trimmed = target.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { targets.append(trimmed) }
        }
        return targets
    }
}

private struct VaultEvalSkip: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}
