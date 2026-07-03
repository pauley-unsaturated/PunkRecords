import Foundation
import PunkRecordsCore
import UniformTypeIdentifiers

struct PendingChatAttachment: Equatable, Identifiable {
    let url: URL
    let metadata: ChatAttachmentMetadata

    var id: UUID { metadata.id }

    static let allowedContentTypes: [UTType] = [.text, .sourceCode, .pdf, .image, .json, .xml]

    static func make(for url: URL) throws -> PendingChatAttachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard let attachmentType = chatAttachmentType(for: values.contentType, url: url) else {
            throw AttachmentError.unsupportedType(url.lastPathComponent)
        }

        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let metadata = ChatAttachmentMetadata(
            bookmarkBase64: bookmark.base64EncodedString(),
            filename: url.lastPathComponent,
            byteCount: try byteCount(for: url, resourceFileSize: values.fileSize),
            type: attachmentType
        )
        return PendingChatAttachment(url: url, metadata: metadata)
    }

    private static func chatAttachmentType(for contentType: UTType?, url: URL) -> ChatAttachmentType? {
        if contentType?.conforms(to: .pdf) == true { return .pdf }
        if contentType?.conforms(to: .image) == true { return .image }
        if contentType?.conforms(to: .text) == true { return .text }
        if contentType?.conforms(to: .sourceCode) == true { return .text }

        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt", "swift", "py", "js", "ts", "json", "yaml", "yml",
             "toml", "html", "css", "sh", "rb", "go", "rs", "c", "cpp", "h", "java",
             "kt", "sql", "csv", "log", "xml":
            return .text
        case "pdf":
            return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            return .image
        default:
            return nil
        }
    }

    private static func byteCount(for url: URL, resourceFileSize: Int?) throws -> Int64 {
        if let resourceFileSize {
            return Int64(resourceFileSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private enum AttachmentError: LocalizedError {
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let filename):
            "Unsupported attachment type: \(filename)"
        }
    }
}
