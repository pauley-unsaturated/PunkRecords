import PunkRecordsCore
import SwiftUI

struct ChatAttachmentChip: View {
    let metadata: ChatAttachmentMetadata
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnailImage {
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 4))
            } else {
                Image(systemName: iconName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(metadata.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 150, alignment: .leading)

            Button("Remove \(metadata.filename)", systemImage: "xmark") {
                onRemove()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove attachment")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metadata.type.displayName) attachment \(metadata.filename), \(detailText)")
    }

    private var iconName: String {
        switch metadata.type {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        }
    }

    private var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: metadata.byteCount, countStyle: .file)
    }

    private var detailText: String {
        if let width = metadata.imageWidth, let height = metadata.imageHeight {
            return "\(width) x \(height) · \(byteCountText)"
        }
        if let processingNote = metadata.processingNote {
            return "\(processingNote) · \(byteCountText)"
        }
        return byteCountText
    }

    private var thumbnailImage: NSImage? {
        guard let thumbnailPNGBase64 = metadata.thumbnailPNGBase64,
              let data = Data(base64Encoded: thumbnailPNGBase64) else {
            return nil
        }
        return NSImage(data: data)
    }
}
