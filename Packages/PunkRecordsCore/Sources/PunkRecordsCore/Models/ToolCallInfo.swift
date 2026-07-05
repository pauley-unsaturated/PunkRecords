import Foundation

/// Metadata captured for a single agent tool invocation. Stored on the
/// corresponding ``ChatMessage`` when `role == .tool`.
///
/// Pure data — the presentation helpers (icon, verb, argument summary) live in
/// an App-layer extension so Core stays free of SF Symbol / UI-copy concerns.
public struct ToolCallInfo: Sendable {
    public let name: String
    public let arguments: String   // raw JSON from the agent event
    public var output: String
    public var isError: Bool
    public var isInFlight: Bool

    public init(
        name: String,
        arguments: String,
        output: String = "",
        isError: Bool = false,
        isInFlight: Bool = true
    ) {
        self.name = name
        self.arguments = arguments
        self.output = output
        self.isError = isError
        self.isInFlight = isInFlight
    }
}
