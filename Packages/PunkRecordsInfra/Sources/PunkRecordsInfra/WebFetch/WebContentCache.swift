import Foundation
import PunkRecordsCore

/// Writes fetched raw HTML to `{vault}/Web/_cache/{slug}.html` so anchors can be
/// rendered offline later. Path derivation is the tested Core
/// ``VaultPaths/webCachePath(forURL:)``; this shell just performs the write.
/// Best-effort — caching failures never fail a fetch.
struct WebContentCache: Sendable {
    /// The vault root, or `nil` to disable caching (e.g. a fetch with no vault
    /// open, or in tests).
    let vaultRoot: URL?

    /// Absolute on-disk location where `url`'s HTML would be cached, or `nil`
    /// when caching is disabled.
    func location(for url: URL) -> URL? {
        guard let vaultRoot else { return nil }
        let relative = VaultPaths.webCachePath(forURL: url)
        return vaultRoot.appendingPathComponent(relative)
    }

    /// Persist `html` for `url`. Creates intermediate directories. Returns the
    /// written location on success, `nil` if caching was disabled or failed.
    @discardableResult
    func store(html: String, for url: URL) -> URL? {
        guard let destination = location(for: url) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try html.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            return nil
        }
    }
}
