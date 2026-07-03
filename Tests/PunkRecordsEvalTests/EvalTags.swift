import Testing

/// Shared tags for the eval bundle. `.eval` marks suites that hit real LLM
/// APIs and cost money — run them intentionally (see PUNK-056 for gating).
extension Tag {
    @Tag static var eval: Self
}
