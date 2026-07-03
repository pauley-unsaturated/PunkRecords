import SwiftUI
import PunkRecordsCore

struct ChatAttachmentChip: View {
    let metadata: ChatAttachmentMetadata
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .imageScale(.small)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(metadata.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(byteCountText)
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
        .accessibilityLabel("\(metadata.type.displayName) attachment \(metadata.filename), \(byteCountText)")
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
}
