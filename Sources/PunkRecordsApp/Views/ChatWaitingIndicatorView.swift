import SwiftUI

/// Assistant-styled placeholder bubble shown while a turn is in flight and no
/// visible assistant text has streamed yet. Mirrors ``ChatBubble``'s assistant
/// chrome (padding, background, corner radius) exactly, so the moment real
/// text replaces it there is no layout jump — same shape, new content.
///
/// Shown/hidden per the pure ``ChatWaitingIndicator/shouldShow(isStreaming:messages:)``
/// decision; this view owns only the animation, not the decision of whether
/// to render at all.
struct ChatWaitingIndicatorView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TypingDotsView()
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for response")
        .accessibilityIdentifier("chatWaitingIndicator")
    }
}

/// Three dots with a staggered opacity/scale loop, evoking a "typing"
/// indicator. Falls back to a static ellipsis when Reduce Motion is enabled.
private struct TypingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        Group {
            if reduceMotion {
                Text("…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .scaleEffect(isAnimating ? 1 : 0.6)
                            .opacity(isAnimating ? 1 : 0.4)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.15),
                                value: isAnimating
                            )
                    }
                }
                .onAppear { isAnimating = true }
            }
        }
    }
}

#Preview("Waiting Indicator") {
    ChatWaitingIndicatorView()
        .padding()
        .frame(width: 300)
}
