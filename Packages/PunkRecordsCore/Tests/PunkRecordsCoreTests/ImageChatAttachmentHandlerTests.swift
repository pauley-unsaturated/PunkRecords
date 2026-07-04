import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PunkRecordsCore

struct ImageChatAttachmentHandlerTests {
    @Test func pngMetadataIncludesDimensionsAndThumbnail() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("sample.png")
        try writeImage(url, width: 120, height: 80, type: .png)

        let metadata = try ImageChatAttachmentHandler.metadata(for: input(for: url))

        #expect(metadata.imageWidth == 120)
        #expect(metadata.imageHeight == 80)
        #expect(metadata.processingNote == "120 x 80")
        #expect(metadata.thumbnailPNGBase64 != nil)
    }

    @Test func heicExtensionNormalizesPayloadToJPEG() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("photo.heic")
        try writeImage(url, width: 100, height: 60, type: .png)

        let metadata = try ImageChatAttachmentHandler.metadata(for: input(for: url))
        let payload = try ImageChatAttachmentHandler.payload(
            for: ImageChatAttachmentInput(url: url, metadata: metadata),
            provider: .openAI
        )

        #expect(payload.mimeType == "image/jpeg")
        let dimensions = try imageDimensions(from: payload.data)
        #expect(dimensions == (100, 60))
    }

    @Test func anthropicPayloadResizesLargeImages() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("large.jpg")
        try writeImage(url, width: 2_000, height: 1_000, type: .jpeg)

        let metadata = try ImageChatAttachmentHandler.metadata(for: input(for: url))
        let payload = try ImageChatAttachmentHandler.payload(
            for: ImageChatAttachmentInput(url: url, metadata: metadata),
            provider: .anthropic
        )

        #expect(payload.mimeType == "image/jpeg")
        let dimensions = try imageDimensions(from: payload.data)
        #expect(dimensions == (1_568, 784))
    }

    @Test func foundationModelsProviderRejectsImages() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("sample.png")
        try writeImage(url, width: 20, height: 20, type: .png)

        #expect(throws: ImageChatAttachmentError.providerUnsupported("Apple")) {
            try ImageChatAttachmentHandler.payload(
                for: input(for: url),
                provider: .foundationModels
            )
        }
    }

    private func input(for url: URL) throws -> ImageChatAttachmentInput {
        let byteCount = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return ImageChatAttachmentInput(
            url: url,
            metadata: ChatAttachmentMetadata(
                bookmarkBase64: "bookmark",
                filename: url.lastPathComponent,
                byteCount: byteCount?.int64Value ?? 0,
                type: .image
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(_ url: URL, width: Int, height: Int, type: UTType) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func imageDimensions(from data: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (width, height)
    }
}
