import SwiftUI
import PunkRecordsCore

/// Distinct bubble for an agent tool call. Visually attributed to the
/// assistant via a leading accent stripe; an SF Symbol identifies the tool,
/// and a disclosure reveals the raw input/output.
struct ToolCallBubble: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.5))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 6) {
                header

                if isExpanded {
                    detailSection
                }
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolCallBubble")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: toolCall.isError ? "exclamationmark.triangle.fill" : toolCall.systemImageName)
                .foregroundStyle(toolCall.isError ? .red : .accentColor)
                .font(.caption)
                .frame(width: 16)

            Text(toolCall.displayName)
                .font(.caption.weight(.semibold))

            if !toolCall.summary.isEmpty {
                Text(toolCall.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if toolCall.isInFlight {
                ProgressView()
                    .controlSize(.mini)
            } else if !toolCall.output.isEmpty || !toolCall.arguments.isEmpty {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Hide tool details" : "Show tool details")
            }
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        if !toolCall.arguments.isEmpty {
            DetailBlock(label: "Input", text: prettyPrintedArguments)
        }
        if !toolCall.output.isEmpty {
            DetailBlock(label: toolCall.isError ? "Error" : "Output", text: toolCall.output)
        }
    }

    private var prettyPrintedArguments: String {
        guard
            let data = toolCall.arguments.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: pretty, encoding: .utf8)
        else {
            return toolCall.arguments
        }
        return s
    }
}

private struct DetailBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 4))
        }
    }
}

#Preview("Tool Call — In Flight") {
    ToolCallBubble(toolCall: ToolCallInfo(
        name: "vault_search",
        arguments: #"{"query":"swift concurrency"}"#
    ))
    .padding()
    .frame(width: 360)
}

#Preview("Tool Call — Completed") {
    ToolCallBubble(toolCall: ToolCallInfo(
        name: "read_document",
        arguments: #"{"path":"swift/concurrency.md"}"#,
        output: "# Swift Concurrency\n\nActors provide data-race safety...",
        isError: false,
        isInFlight: false
    ))
    .padding()
    .frame(width: 360)
}

#Preview("Tool Call — Error") {
    ToolCallBubble(toolCall: ToolCallInfo(
        name: "create_note",
        arguments: #"{"title":"New Note","content":"..."}"#,
        output: "Permission denied",
        isError: true,
        isInFlight: false
    ))
    .padding()
    .frame(width: 360)
}
