import Foundation

public struct LLMCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let streaming = LLMCapabilities(rawValue: 1 << 0)
    public static let functionCalls = LLMCapabilities(rawValue: 1 << 1)
    public static let longContext = LLMCapabilities(rawValue: 1 << 2)
    public static let onDevice = LLMCapabilities(rawValue: 1 << 3)
}
