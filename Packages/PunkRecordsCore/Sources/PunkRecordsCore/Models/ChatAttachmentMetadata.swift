import Foundation

public enum ChatAttachmentType: String, Codable, CaseIterable, Sendable {
    case text
    case pdf
    case image

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .pdf: "PDF"
        case .image: "Image"
        }
    }
}

public struct ChatAttachmentMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let bookmarkBase64: String
    public let filename: String
    public let byteCount: Int64
    public let type: ChatAttachmentType
    public let estimatedTokens: Int?

    public init(
        id: UUID = UUID(),
        bookmarkBase64: String,
        filename: String,
        byteCount: Int64,
        type: ChatAttachmentType,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.bookmarkBase64 = bookmarkBase64
        self.filename = filename
        self.byteCount = byteCount
        self.type = type
        self.estimatedTokens = estimatedTokens
    }
}
