import Foundation

/// Parser / renderer for the *legacy* single-transcript chat format
/// (`punkrecords-chat-transcript-v1`): the markdown-comment layout the app used
/// before per-thread JSON persistence. Kept as a pure Core function so the
/// migration path (`FileSystemThreadStore`) can read an old transcript and
/// convert it into a ``ChatThread`` without duplicating the parse, and so the
/// format is unit-testable off the filesystem.
///
/// Only `user` / `assistant` rows were ever persisted; tool-call chips are not
/// part of the legacy format.
public enum LegacyChatTranscript {
    public static let marker = "<!-- punkrecords-chat-transcript-v1 -->"

    /// Parse legacy transcript text into chat messages. Unrecognized lines are
    /// ignored; a malformed attachment comment throws.
    public static func parse(_ text: String) throws -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var currentRole: ChatMessage.Role?
        var contentLines: [String] = []
        var attachments: [ChatAttachmentMetadata] = []

        for line in text.components(separatedBy: .newlines) {
            if let role = roleMarker(in: line) {
                currentRole = role
                contentLines = []
                attachments = []
                continue
            }

            if isEndMarker(line) {
                if let currentRole {
                    messages.append(ChatMessage(
                        role: currentRole,
                        content: contentLines.joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        attachments: attachments,
                        attachmentTranscript: try ChatAttachmentPolicy.transcriptComments(for: attachments)
                    ))
                }
                currentRole = nil
                contentLines = []
                attachments = []
                continue
            }

            guard currentRole != nil else { continue }
            if let attachment = try attachmentMetadata(in: line) {
                attachments.append(attachment)
            } else if !line.hasPrefix("<!-- timestamp:") {
                contentLines.append(line)
            }
        }

        return messages
    }

    /// Render messages back into the legacy transcript format. Retained so tests
    /// (and any future export) can produce a canonical transcript; the running
    /// app no longer writes this format.
    public static func render(_ messages: [ChatMessage]) throws -> String {
        var chunks = [marker]

        for message in messages where message.role != .tool {
            var lines = [
                "<!-- message: \(message.role.rawValue) -->",
                "<!-- timestamp: \(message.timestamp.ISO8601Format()) -->",
            ]

            let attachmentComments = try ChatAttachmentPolicy.transcriptComments(for: message.attachments)
            if !attachmentComments.isEmpty {
                lines.append(attachmentComments)
            }
            if !message.content.isEmpty {
                lines.append(message.content)
            }
            lines.append("<!-- /message -->")
            chunks.append(lines.joined(separator: "\n"))
        }

        return chunks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Line parsing

    private static func roleMarker(in line: String) -> ChatMessage.Role? {
        if line == "<!-- message: user -->" { return .user }
        if line == "<!-- message: assistant -->" { return .assistant }
        return nil
    }

    private static func isEndMarker(_ line: String) -> Bool {
        line == "<!-- /message -->"
    }

    private static func attachmentMetadata(in line: String) throws -> ChatAttachmentMetadata? {
        let prefix = "<!-- attachment: "
        let suffix = " -->"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }

        let jsonStart = line.index(line.startIndex, offsetBy: prefix.count)
        let jsonEnd = line.index(line.endIndex, offsetBy: -suffix.count)
        return try JSONDecoder().decode(
            ChatAttachmentMetadata.self,
            from: Data(line[jsonStart..<jsonEnd].utf8)
        )
    }
}
