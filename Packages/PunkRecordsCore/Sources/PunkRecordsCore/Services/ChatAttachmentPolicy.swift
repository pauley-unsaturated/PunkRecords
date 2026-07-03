import Foundation

public enum ChatAttachmentPolicy {
    public static let confirmationTokenThreshold = 50_000
    public static let singleAttachmentConfirmationByteThreshold: Int64 = 20 * 1_024 * 1_024

    public static func estimatedTokens(prompt: String, attachments: [ChatAttachmentMetadata]) -> Int {
        TokenEstimator.estimateTokens(in: prompt) + attachments.reduce(0) { total, attachment in
            total + estimatedTokens(for: attachment)
        }
    }

    public static func estimatedTokens(for attachment: ChatAttachmentMetadata) -> Int {
        switch attachment.type {
        case .text:
            max(1, Int(attachment.byteCount / 4))
        case .pdf:
            max(1, Int(attachment.byteCount / 4))
        case .image:
            max(85, Int(attachment.byteCount / 1_024))
        }
    }

    public static func needsConfirmation(prompt: String, attachments: [ChatAttachmentMetadata]) -> Bool {
        estimatedTokens(prompt: prompt, attachments: attachments) > confirmationTokenThreshold
            || attachments.contains { $0.byteCount > singleAttachmentConfirmationByteThreshold }
    }

    public static func transcriptComments(for attachments: [ChatAttachmentMetadata]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        return try attachments.map { attachment in
            let data = try encoder.encode(attachment)
            guard let json = String(data: data, encoding: .utf8) else {
                throw EncodingError.invalidValue(
                    attachment,
                    EncodingError.Context(
                        codingPath: [],
                        debugDescription: "Attachment metadata was not valid UTF-8 JSON"
                    )
                )
            }
            return "<!-- attachment: \(json) -->"
        }
        .joined(separator: "\n")
    }
}
