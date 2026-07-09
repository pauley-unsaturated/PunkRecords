import SwiftUI

/// Lightweight status row shown near the composer while a URL-summarize flow
/// (PUNK-ddq) is fetching/summarizing/writing: a spinner, the current phase
/// label, the target URL, and Cancel. All decisions (which phase, what label,
/// whether cancellation actually aborts the in-flight fetch/LLM call) live in
/// ``ChatSessionController``; this view only renders its published state.
struct URLSummaryStatusView: View {
    let controller: ChatSessionController

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.urlSummaryPhase?.label ?? "Working…")
                    .font(.caption)
                    .accessibilityIdentifier("urlSummaryPhaseLabel")
                if let url = controller.urlSummaryTargetURL {
                    Text(url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button("Cancel") {
                controller.cancelURLSummary()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("urlSummaryCancelButton")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("urlSummaryStatusView")
    }
}

#Preview("URL Summary Status") {
    let state = PreviewData.makePreviewAppState()
    let controller = ChatSessionController(appState: state)
    controller.urlSummaryPhase = .summarizing
    controller.urlSummaryTargetURL = URL(string: "https://example.com/a-long-article-about-something")
    return URLSummaryStatusView(controller: controller)
        .padding()
        .frame(width: 320)
}
