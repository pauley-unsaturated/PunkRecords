import SwiftUI
import MarkdownUI
import PunkRecordsCore

struct ChatBubble: View {
    let message: ChatMessage
    let onSaveAsNote: () -> Void
    let onReportIssueCopy: () -> Void
    let onReportIssueSave: () -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if !message.content.isEmpty {
                    Group {
                        if message.role == .assistant {
                            Markdown(message.content)
                                .markdownTheme(.gitHub)
                                .markdownTextStyle(\.text) { FontSize(.em(0.9)) }
                        } else {
                            Text(message.content)
                        }
                    }
                    .textSelection(.enabled)
                }

                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            Label(
                                "\(attachment.filename) · \(formattedByteCount(for: attachment))",
                                systemImage: iconName(for: attachment.type)
                            )
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(10)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.15)
                    : Color.secondary.opacity(0.1),
                in: .rect(cornerRadius: 10)
            )

            if message.role == .assistant && !message.content.isEmpty {
                HStack(spacing: 8) {
                    if let providerID = message.providerID {
                        Text("via \(providerID.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("messageProviderAttribution")
                    }

                    Button("Save as Note", systemImage: "doc.badge.plus") {
                        onSaveAsNote()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)

                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)

                    if message.context != nil {
                        Menu {
                            Button("Copy to Clipboard", systemImage: "doc.on.clipboard") {
                                onReportIssueCopy()
                            }
                            Button("Save to File", systemImage: "square.and.arrow.down") {
                                onReportIssueSave()
                            }
                        } label: {
                            Label("Report Issue", systemImage: "flag")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("Capture this turn's context as a bug report")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func iconName(for type: ChatAttachmentType) -> String {
        switch type {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        }
    }

    private func formattedByteCount(for attachment: ChatAttachmentMetadata) -> String {
        ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
    }
}
