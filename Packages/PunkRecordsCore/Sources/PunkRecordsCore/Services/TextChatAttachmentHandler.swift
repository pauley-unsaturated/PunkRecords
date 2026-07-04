import Foundation

public struct TextChatAttachmentInput {
    public let url: URL
    public let metadata: ChatAttachmentMetadata

    public init(url: URL, metadata: ChatAttachmentMetadata) {
        self.url = url
        self.metadata = metadata
    }
}

public struct TextChatAttachmentPayload: Equatable, Sendable {
    public let metadata: ChatAttachmentMetadata
    public let promptBlock: String
    public let content: String
    public let warning: String?
}

public enum TextChatAttachmentHandler {
    public static let warningByteThreshold: Int64 = 1 * 1_024 * 1_024
    public static let maximumByteCount: Int64 = 10 * 1_024 * 1_024
    public static let binaryScanByteCount = 8 * 1_024

    public static func metadata(
        for url: URL,
        bookmarkBase64: String,
        filename: String? = nil
    ) throws -> TextChatAttachmentPayload {
        let payload = try payload(
            for: TextChatAttachmentInput(
                url: url,
                metadata: ChatAttachmentMetadata(
                    bookmarkBase64: bookmarkBase64,
                    filename: filename ?? url.lastPathComponent,
                    byteCount: byteCount(for: url),
                    type: .text
                )
            )
        )
        return payload
    }

    public static func prompt(
        userText: String,
        attachments: [TextChatAttachmentInput],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let textAttachments = attachments.filter { $0.metadata.type == .text }
        guard !textAttachments.isEmpty else { return userText }

        let blocks = try textAttachments.map {
            try payload(for: $0, homeDirectory: homeDirectory).promptBlock
        }
        var parts: [String] = []
        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUserText.isEmpty {
            parts.append(trimmedUserText)
        }
        parts.append("Attached text files:\n\n" + blocks.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    public static func payload(
        for input: TextChatAttachmentInput,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> TextChatAttachmentPayload {
        guard input.metadata.type == .text else {
            throw TextChatAttachmentError.unsupportedType(input.metadata.filename)
        }

        let didAccess = input.url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                input.url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try data(from: input.url, byteCount: input.metadata.byteCount)
        try rejectBinary(data: data, filename: input.metadata.filename)
        guard let content = String(data: data, encoding: .utf8) else {
            throw TextChatAttachmentError.encodingNotSupported(input.metadata.filename)
        }

        let estimatedTokens = TokenEstimator.estimateTokens(in: content)
        let metadata = ChatAttachmentMetadata(
            id: input.metadata.id,
            bookmarkBase64: input.metadata.bookmarkBase64,
            filename: input.metadata.filename,
            byteCount: input.metadata.byteCount,
            type: .text,
            estimatedTokens: estimatedTokens
        )
        return TextChatAttachmentPayload(
            metadata: metadata,
            promptBlock: promptBlock(
                filename: metadata.filename,
                path: displayPath(for: input.url, homeDirectory: homeDirectory),
                content: content
            ),
            content: content,
            warning: warning(for: metadata)
        )
    }

    private static func data(from url: URL, byteCount: Int64) throws -> Data {
        guard byteCount <= maximumByteCount else {
            throw TextChatAttachmentError.fileTooLarge(byteCount: byteCount, limit: maximumByteCount)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumByteCount else {
            throw TextChatAttachmentError.fileTooLarge(byteCount: Int64(data.count), limit: maximumByteCount)
        }
        return data
    }

    private static func byteCount(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func rejectBinary(data: Data, filename: String) throws {
        let prefix = data.prefix(binaryScanByteCount)
        if prefix.contains(0) {
            throw TextChatAttachmentError.binaryContent(filename)
        }
    }

    private static func promptBlock(filename: String, path: String, content: String) -> String {
        let language = languageIdentifier(for: filename)
        let fence = markdownFence(for: content)
        return """
        ### \(filename) (\(path))

        \(fence)\(language)
        \(content)
        \(fence)
        """
    }

    private static func markdownFence(for content: String) -> String {
        let longestRun = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: "`", omittingEmptySubsequences: false).count - 1
            }
            .max() ?? 0
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    private static func languageIdentifier(for filename: String) -> String {
        let languages = [
            "swift": "swift",
            "py": "python",
            "js": "javascript",
            "ts": "typescript",
            "json": "json",
            "yaml": "yaml",
            "yml": "yaml",
            "toml": "toml",
            "html": "html",
            "css": "css",
            "sh": "bash",
            "rb": "ruby",
            "go": "go",
            "rs": "rust",
            "c": "c",
            "cpp": "cpp",
            "h": "c",
            "java": "java",
            "kt": "kotlin",
            "sql": "sql",
            "csv": "csv",
            "xml": "xml",
            "md": "markdown",
            "markdown": "markdown",
        ]
        let pathExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return languages[pathExtension] ?? "text"
    }

    private static func displayPath(for url: URL, homeDirectory: URL) -> String {
        let homePath = homeDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath == homePath {
            return "~"
        }
        if filePath.hasPrefix(homePath + "/") {
            return "~/" + String(filePath.dropFirst(homePath.count + 1))
        }
        return filePath
    }

    private static func warning(for metadata: ChatAttachmentMetadata) -> String? {
        guard metadata.byteCount >= warningByteThreshold else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: metadata.byteCount, countStyle: .file)
        return "\(metadata.filename) is \(size). Large text attachments can make chat responses slower."
    }
}

public enum TextChatAttachmentError: LocalizedError, Equatable {
    case unsupportedType(String)
    case binaryContent(String)
    case encodingNotSupported(String)
    case fileTooLarge(byteCount: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let filename):
            return "\(filename) is not a text attachment."
        case .binaryContent(let filename):
            return "\(filename) appears to be binary and cannot be attached as text."
        case .encodingNotSupported(let filename):
            return "\(filename) encoding not supported. Attach UTF-8 text files only."
        case .fileTooLarge(let byteCount, let limit):
            let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "Text attachment is \(size), which exceeds the \(limit) limit."
        }
    }
}
