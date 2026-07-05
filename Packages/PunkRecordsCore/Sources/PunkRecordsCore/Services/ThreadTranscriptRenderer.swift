import Foundation

/// Renders a ``ChatThread`` (or a bare message list) into compact plain text for
/// LLM consumption: one role-prefixed block per message, tool calls collapsed to
/// a single-line marker, and an optional per-message note-context annotation
/// (`re: <scope>`) so the reader knows which note a turn was about.
///
/// Token-budget aware: when a `budget` is given and the full transcript exceeds
/// it, the middle is elided — head and tail messages are kept and the gap between
/// them is replaced by a `… [N messages elided] …` marker — so both the opening
/// context and the most recent turns survive. Budgeting uses ``TokenEstimator``
/// (1 token ≈ 4 chars).
///
/// A general Core utility with no tool/UI coupling: `read_thread` renders a
/// fetched thread with it, the Infra embedding index uses it to build embedding
/// input, and the queued summarize-conversation feature (PUNK-cbx) reuses it.
public enum ThreadTranscriptRenderer {

    /// Rendering knobs. Defaults render everything (title, tool markers, context).
    public struct Options: Sendable, Equatable {
        /// Emit a leading `# <title>` line when the title is non-empty.
        public var includeTitle: Bool
        /// Render `.tool` rows as one-line markers (otherwise they are dropped).
        public var includeToolCalls: Bool
        /// Annotate a message with the note/scope its turn was about, when present.
        public var includeContextAnnotations: Bool

        public init(
            includeTitle: Bool = true,
            includeToolCalls: Bool = true,
            includeContextAnnotations: Bool = true
        ) {
            self.includeTitle = includeTitle
            self.includeToolCalls = includeToolCalls
            self.includeContextAnnotations = includeContextAnnotations
        }

        public static let `default` = Options()
    }

    /// Render a full thread. Pass `budget` (in tokens) to enable head+tail
    /// elision; omit it for the complete transcript.
    public static func render(
        _ thread: ChatThread,
        budget: Int? = nil,
        options: Options = .default
    ) -> String {
        render(
            title: options.includeTitle ? thread.title : nil,
            messages: thread.messages,
            budget: budget,
            options: options
        )
    }

    /// Render a bare message list, optionally under a `title` header.
    public static func render(
        title: String?,
        messages: [ChatMessage],
        budget: Int? = nil,
        options: Options = .default
    ) -> String {
        let header: String? = {
            guard options.includeTitle, let title else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "# \(trimmed)"
        }()
        let blocks = messages.compactMap { block(for: $0, options: options) }

        func joinAll() -> String {
            ((header.map { [$0] } ?? []) + blocks).joined(separator: "\n")
        }

        guard let budget else { return joinAll() }
        let full = joinAll()
        if TokenEstimator.estimateTokens(in: full) <= budget { return full }
        return packHeadTail(header: header, blocks: blocks, budget: budget)
    }

    // MARK: - Per-message rendering

    /// One rendered block per message, or `nil` when the message is dropped
    /// (a tool row while `includeToolCalls` is off).
    static func block(for message: ChatMessage, options: Options) -> String? {
        switch message.role {
        case .tool:
            guard options.includeToolCalls else { return nil }
            return toolMarker(message)
        case .user, .assistant:
            var head = message.role == .user ? "User" : "Assistant"
            if options.includeContextAnnotations,
               let annotation = contextAnnotation(message.context) {
                head += " (\(annotation))"
            }
            let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "\(head):" : "\(head): \(body)"
        }
    }

    /// A `.tool` message collapsed to a single line: `[tool: name] → output`,
    /// with status (in progress / error) folded in.
    static func toolMarker(_ message: ChatMessage) -> String {
        guard let call = message.toolCall else { return "[tool]" }
        let status: String
        if call.isInFlight {
            status = " (in progress)"
        } else if call.isError {
            status = " (error)"
        } else {
            status = ""
        }
        let output = singleLine(call.output)
        let outPart = output.isEmpty ? "" : " → \(output)"
        return "[tool: \(call.name)\(status)]\(outPart)"
    }

    /// Human-readable note-context annotation for a message, e.g. `re: My Note`.
    /// `nil` when there is no context or its scope label is empty.
    static func contextAnnotation(_ context: MessageContext?) -> String? {
        guard let context else { return nil }
        let label = context.scopeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return "re: \(label)"
    }

    /// Collapse text to a single trimmed line, truncated with an ellipsis.
    static func singleLine(_ text: String, maxChars: Int = 160) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }

    // MARK: - Budget-aware elision

    static func elisionMarker(elidedCount: Int) -> String {
        "… [\(elidedCount) message\(elidedCount == 1 ? "" : "s") elided] …"
    }

    /// Greedily pack blocks from both ends until the budget is exhausted, then
    /// stitch head + marker + tail. Reserves budget for the header and for a
    /// worst-case elision marker up front so the result stays within budget.
    static func packHeadTail(header: String?, blocks: [String], budget: Int) -> String {
        var used = 0
        if let header { used += TokenEstimator.estimateTokens(in: header) }
        let markerReserve = TokenEstimator.estimateTokens(in: elisionMarker(elidedCount: blocks.count))
        used += markerReserve

        var headCount = 0
        var tailCount = 0
        var lo = 0
        var hi = blocks.count - 1
        var addToHead = true
        while lo <= hi {
            let index = addToHead ? lo : hi
            let cost = TokenEstimator.estimateTokens(in: blocks[index]) + 1 // +1 ≈ newline
            if used + cost > budget { break }
            used += cost
            if addToHead {
                headCount += 1
                lo += 1
            } else {
                tailCount += 1
                hi -= 1
            }
            addToHead.toggle()
        }

        let elided = blocks.count - headCount - tailCount

        // Budget too small to admit any whole message: still surface the most
        // recent one, truncated, so the caller gets something usable.
        if headCount == 0 && tailCount == 0 {
            guard let last = blocks.last else { return header ?? "" }
            let remaining = max(1, budget - markerReserve)
            let truncated = TokenEstimator.truncateToTokenBudget(last, budget: remaining)
            var lines = header.map { [$0] } ?? []
            if blocks.count > 1 {
                lines.append(elisionMarker(elidedCount: blocks.count - 1))
            }
            lines.append(truncated)
            return lines.joined(separator: "\n")
        }

        var lines = header.map { [$0] } ?? []
        lines.append(contentsOf: blocks.prefix(headCount))
        if elided > 0 {
            lines.append(elisionMarker(elidedCount: elided))
        }
        lines.append(contentsOf: blocks.suffix(tailCount))
        return lines.joined(separator: "\n")
    }
}
