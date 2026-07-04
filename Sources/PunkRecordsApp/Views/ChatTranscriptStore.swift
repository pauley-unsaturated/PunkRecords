import Foundation
import PunkRecordsCore

enum ChatTranscriptStore {
    static func load(vaultRoot: URL) throws -> [ChatMessage] {
        let url = transcriptURL(vaultRoot: vaultRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let text = try String(contentsOf: url, encoding: .utf8)
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
                        content: contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
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

    static func save(messages: [ChatMessage], vaultRoot: URL) throws {
        let url = transcriptURL(vaultRoot: vaultRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown(for: messages).write(to: url, atomically: true, encoding: .utf8)
    }

    static func markdown(for messages: [ChatMessage]) throws -> String {
        var chunks = ["<!-- punkrecords-chat-transcript-v1 -->"]

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

    static func transcriptURL(vaultRoot: URL) -> URL {
        vaultRoot
            .appendingPathComponent(".punkrecords", isDirectory: true)
            .appendingPathComponent("chat-transcript.md")
    }

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
        let metadata = try JSONDecoder().decode(
            ChatAttachmentMetadata.self,
            from: Data(line[jsonStart..<jsonEnd].utf8)
        )
        _ = resolvedURL(for: metadata)
        return metadata
    }

    private static func resolvedURL(for metadata: ChatAttachmentMetadata) -> URL? {
        guard let bookmarkData = Data(base64Encoded: metadata.bookmarkBase64) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
