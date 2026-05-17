import Testing
import Foundation
import AppKit
import CoreGraphics

/// Lightweight CI guard for the SwiftUI preview snapshots. Pixel-level
/// comparison happens through `Scripts/check-snapshots.sh` (agent workflow,
/// since RenderPreview is an MCP tool that CI can't invoke), but the
/// baselines themselves can drift in dumber ways — getting accidentally
/// truncated, replaced with the wrong file, or removed from the repo.
/// This suite checks for those.
@Suite("Snapshot baseline sanity")
struct SnapshotBaselineSanityTests {

    private static let expectedBaselines = [
        "MarkdownPreviewView_Sample",
        "ToolCallBubble_InFlight",
        "ToolCallBubble_Completed",
        "ToolCallBubble_Error",
    ]

    /// Walks up from the test file's path to the repo root, then resolves
    /// the baselines directory. Keeps the suite runnable from xcodebuild
    /// where the cwd is set somewhere under DerivedData.
    private static func baselinesDirectory(file: StaticString = #filePath) -> URL {
        let testFile = URL(fileURLWithPath: String(describing: file))
        let repoRoot = testFile
            .deletingLastPathComponent() // Tests/PunkRecordsIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("Tests/SnapshotBaselines", isDirectory: true)
    }

    @Test("Every expected baseline file is present")
    func baselineFilesPresent() {
        let dir = Self.baselinesDirectory()
        for name in Self.expectedBaselines {
            let url = dir.appendingPathComponent("\(name).png")
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "Missing snapshot baseline at \(url.path)")
        }
    }

    @Test("Every baseline decodes as a non-empty PNG with reasonable bounds")
    func baselinesDecode() throws {
        let dir = Self.baselinesDirectory()
        for name in Self.expectedBaselines {
            let url = dir.appendingPathComponent("\(name).png")
            let data = try Data(contentsOf: url)
            #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                    "\(name): file is not a PNG (missing 89 50 4E 47 header)")

            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                Issue.record("\(name): CGImageSource could not decode the PNG")
                continue
            }

            // RenderPreview emits @2x PNGs, so widths/heights are in pixels
            // not points. Anything below 100×100 means the preview wasn't
            // captured properly; anything above 4000 means it captured a
            // whole window of chrome we didn't intend.
            #expect(image.width > 100 && image.width < 4000,
                    "\(name): unexpected width \(image.width)")
            #expect(image.height > 100 && image.height < 4000,
                    "\(name): unexpected height \(image.height)")
        }
    }
}
