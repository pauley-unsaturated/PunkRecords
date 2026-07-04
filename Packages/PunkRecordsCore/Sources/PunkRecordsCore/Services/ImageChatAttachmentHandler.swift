import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageChatAttachmentInput {
    public let url: URL
    public let metadata: ChatAttachmentMetadata

    public init(url: URL, metadata: ChatAttachmentMetadata) {
        self.url = url
        self.metadata = metadata
    }
}

public struct ImageChatAttachmentPayload: Equatable, Sendable {
    public let metadata: ChatAttachmentMetadata
    public let data: Data
    public let mimeType: String
}

public enum ImageChatAttachmentHandler {
    public static let thumbnailMaxEdge = 40

    public static func metadata(for input: ImageChatAttachmentInput) throws -> ChatAttachmentMetadata {
        let didAccess = input.url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                input.url.stopAccessingSecurityScopedResource()
            }
        }

        let source = try imageSource(for: input.url, filename: input.metadata.filename)
        let dimensions = try imageDimensions(from: source, filename: input.metadata.filename)
        let image = try cgImage(from: source, filename: input.metadata.filename)
        let thumbnail = try encodedData(
            for: resize(image, maxEdge: thumbnailMaxEdge),
            mimeType: "image/png"
        )

        return ChatAttachmentMetadata(
            id: input.metadata.id,
            bookmarkBase64: input.metadata.bookmarkBase64,
            filename: input.metadata.filename,
            byteCount: input.metadata.byteCount,
            type: .image,
            estimatedTokens: ChatAttachmentPolicy.estimatedTokens(for: input.metadata),
            processingNote: "\(dimensions.width) x \(dimensions.height)",
            imageWidth: dimensions.width,
            imageHeight: dimensions.height,
            thumbnailPNGBase64: thumbnail.base64EncodedString()
        )
    }

    public static func payload(
        for input: ImageChatAttachmentInput,
        provider: LLMProviderID
    ) throws -> ImageChatAttachmentPayload {
        guard input.metadata.type == .image else {
            throw ImageChatAttachmentError.unsupportedType(input.metadata.filename)
        }
        guard provider.nativeImageInput else {
            throw ImageChatAttachmentError.providerUnsupported(provider.displayName)
        }

        let didAccess = input.url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                input.url.stopAccessingSecurityScopedResource()
            }
        }

        let source = try imageSource(for: input.url, filename: input.metadata.filename)
        let image = try cgImage(from: source, filename: input.metadata.filename)
        let resized = resize(image, maxEdge: provider.maximumImageEdge)
        let mimeType = outputMimeType(for: input.url, source: source)
        let data = try encodedData(for: resized, mimeType: mimeType)
        let dimensions = (width: resized.width, height: resized.height)
        let metadata = ChatAttachmentMetadata(
            id: input.metadata.id,
            bookmarkBase64: input.metadata.bookmarkBase64,
            filename: input.metadata.filename,
            byteCount: input.metadata.byteCount,
            type: .image,
            estimatedTokens: ChatAttachmentPolicy.estimatedTokens(for: input.metadata),
            processingNote: "\(dimensions.width) x \(dimensions.height)",
            imageWidth: dimensions.width,
            imageHeight: dimensions.height,
            thumbnailPNGBase64: input.metadata.thumbnailPNGBase64
        )
        return ImageChatAttachmentPayload(metadata: metadata, data: data, mimeType: mimeType)
    }

    private static func imageSource(for url: URL, filename: String) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageChatAttachmentError.unreadable(filename)
        }
        return source
    }

    private static func imageDimensions(
        from source: CGImageSource,
        filename: String
    ) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageChatAttachmentError.unreadable(filename)
        }
        return (width, height)
    }

    private static func cgImage(from source: CGImageSource, filename: String) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true,
        ] as CFDictionary) else {
            throw ImageChatAttachmentError.unreadable(filename)
        }
        return image
    }

    private static func resize(_ image: CGImage, maxEdge: Int) -> CGImage {
        guard maxEdge > 0, max(image.width, image.height) > maxEdge else { return image }

        let scale = CGFloat(maxEdge) / CGFloat(max(image.width, image.height))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func outputMimeType(for url: URL, source: CGImageSource) -> String {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "heic" || pathExtension == "heif" {
            return "image/jpeg"
        }
        guard let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String) else {
            return "image/png"
        }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .png) { return "image/png" }
        return "image/png"
    }

    private static func encodedData(for image: CGImage, mimeType: String) throws -> Data {
        let data = NSMutableData()
        let type = mimeType == "image/jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ImageChatAttachmentError.encodingFailed
        }
        let options: [CFString: Any] = mimeType == "image/jpeg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageChatAttachmentError.encodingFailed
        }
        return data as Data
    }
}

public enum ImageChatAttachmentError: LocalizedError, Equatable {
    case unsupportedType(String)
    case unreadable(String)
    case providerUnsupported(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let filename):
            return "\(filename) is not an image attachment."
        case .unreadable(let filename):
            return "\(filename) could not be opened as an image."
        case .providerUnsupported(let provider):
            return "\(provider) does not support image attachments. Switch to Claude or GPT to send images."
        case .encodingFailed:
            return "Image attachment could not be encoded."
        }
    }
}
