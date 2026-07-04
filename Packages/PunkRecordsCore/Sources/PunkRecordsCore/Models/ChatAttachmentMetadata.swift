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
    public let pageCount: Int?
    public let processingNote: String?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let thumbnailPNGBase64: String?

    public init(
        id: UUID = UUID(),
        bookmarkBase64: String,
        filename: String,
        byteCount: Int64,
        type: ChatAttachmentType,
        estimatedTokens: Int? = nil,
        pageCount: Int? = nil,
        processingNote: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        thumbnailPNGBase64: String? = nil
    ) {
        self.id = id
        self.bookmarkBase64 = bookmarkBase64
        self.filename = filename
        self.byteCount = byteCount
        self.type = type
        self.estimatedTokens = estimatedTokens
        self.pageCount = pageCount
        self.processingNote = processingNote
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.thumbnailPNGBase64 = thumbnailPNGBase64
    }
}
