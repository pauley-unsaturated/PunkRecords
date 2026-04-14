import Foundation
import AppKit
import PunkRecordsCore

/// Snapshot of the context surrounding a chat message, captured at submission time.
/// Attached to `ChatMessage` so "Report Issue" can later reconstruct what the user did.
struct MessageContext: Sendable {
    let scope: QueryScope
    let scopeLabel: String
    let currentDocumentID: DocumentID?
    let selection: String?
    let wasAgentMode: Bool
    let variantID: String
    let userPrompt: String
}

/// Full structured bug report captured from a chat turn.
struct IssueReport: Sendable {
    let timestamp: Date
    let vaultName: String
    let appVersion: String
    let osVersion: String
    let context: MessageContext
    let assistantResponse: String
    let priorMessages: [(role: String, content: String)]
    /// Looked up from the repository at report time, not at message creation time.
    let currentDocumentPath: String?
    let currentDocumentTitle: String?

    /// Short slug derived from the first few words of the prompt, safe for filenames.
    var slug: String {
        let base = context.userPrompt
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "-")
        return base.isEmpty ? "issue" : String(base.prefix(40))
    }
}

/// Builds, saves, and copies bug report markdown.
struct IssueReporter {

    static let defaultIssuesDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".punkrecords/issues", isDirectory: true)
    }()

    /// Format a report as human-readable markdown, suitable for pasting into GitHub.
    static func markdown(for report: IssueReport) -> String {
        var lines: [String] = []
        let ctx = report.context

        lines.append("# PunkRecords Issue Report")
        lines.append("")
        lines.append("**Timestamp:** \(iso8601(report.timestamp))")
        lines.append("**Vault:** \(report.vaultName)")
        lines.append("**App version:** \(report.appVersion)")
        lines.append("**macOS:** \(report.osVersion)")
        lines.append("**Prompt variant:** `\(ctx.variantID)`")
        lines.append("**Mode:** \(ctx.wasAgentMode ? "Agent" : "Chat")")
        lines.append("**Scope:** \(ctx.scopeLabel)")
        if let title = report.currentDocumentTitle {
            lines.append("**Current document:** \(title)" + (report.currentDocumentPath.map { " (`\($0)`)" } ?? ""))
        } else if let docID = ctx.currentDocumentID {
            lines.append("**Current document ID:** `\(docID.uuidString)`")
        }

        if let selection = ctx.selection, !selection.isEmpty {
            lines.append("")
            lines.append("## Selection at submission")
            lines.append("")
            lines.append("```")
            lines.append(selection)
            lines.append("```")
        }

        lines.append("")
        lines.append("## User prompt")
        lines.append("")
        lines.append("```")
        lines.append(ctx.userPrompt)
        lines.append("```")

        lines.append("")
        lines.append("## Assistant response")
        lines.append("")
        // Wrap in ~~~~ fence to allow internal ``` without collision
        lines.append("~~~~")
        lines.append(report.assistantResponse)
        lines.append("~~~~")

        if !report.priorMessages.isEmpty {
            lines.append("")
            lines.append("## Prior conversation (most recent first)")
            lines.append("")
            for msg in report.priorMessages.suffix(6).reversed() {
                lines.append("### \(msg.role)")
                lines.append("")
                lines.append("~~~~")
                lines.append(msg.content)
                lines.append("~~~~")
                lines.append("")
            }
        }

        lines.append("")
        lines.append("---")
        lines.append("_Captured by PunkRecords. Paste this into a GitHub issue or share as needed._")
        return lines.joined(separator: "\n")
    }

    /// Write the report's markdown to `~/.punkrecords/issues/{timestamp}-{slug}.md`. Returns the URL.
    @discardableResult
    static func save(_ report: IssueReport, to directory: URL = defaultIssuesDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: report.timestamp).replacingOccurrences(of: ":", with: "-")
        let filename = "\(stamp)-\(report.slug).md"
        let url = directory.appendingPathComponent(filename)
        try markdown(for: report).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Put the report's markdown onto the system pasteboard.
    static func copyToClipboard(_ report: IssueReport) {
        let md = markdown(for: report)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    /// Build a report from an assistant message + the app state that produced it.
    /// Does an async lookup against the document repository to resolve the current
    /// document's title/path.
    @MainActor
    static func build(
        assistantResponse: String,
        context: MessageContext,
        priorMessages: [(role: String, content: String)],
        appState: AppState
    ) async -> IssueReport {
        var title: String?
        var path: String?
        if let docID = context.currentDocumentID,
           let repo = appState.repository,
           let doc = try? await repo.document(withID: docID) {
            title = doc.title
            path = doc.path
        }

        return IssueReport(
            timestamp: Date(),
            vaultName: appState.currentVault?.name ?? "Unknown",
            appVersion: appVersion(),
            osVersion: osVersion(),
            context: context,
            assistantResponse: assistantResponse,
            priorMessages: priorMessages,
            currentDocumentPath: path,
            currentDocumentTitle: title
        )
    }

    // MARK: - Private

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
