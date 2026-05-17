# SwiftUI Preview Snapshots

Visual regression baselines for selected `#Preview` definitions in the
PunkRecords app. Each PNG in this directory was captured with the Xcode
MCP server's `RenderPreview` action so that the agent can re-render the
same previews on demand and compare them against these references.

## Files

| Baseline | Source | Preview index |
|---|---|---|
| `MarkdownPreviewView_Sample.png` | `Sources/PunkRecordsApp/Views/MarkdownPreviewView.swift` | 0 |
| `ToolCallBubble_InFlight.png` | `Sources/PunkRecordsApp/Views/ToolCallBubble.swift` | 0 |
| `ToolCallBubble_Completed.png` | `Sources/PunkRecordsApp/Views/ToolCallBubble.swift` | 1 |
| `ToolCallBubble_Error.png` | `Sources/PunkRecordsApp/Views/ToolCallBubble.swift` | 2 |

## Re-checking against the current code

The render side is agent-only (the MCP tool can't be invoked from CI), but
the diff side is automated.

1. For each baseline, ask the xcode MCP server to render the matching
   preview:
   ```
   RenderPreview(
     sourceFilePath: "PunkRecords/PunkRecordsApp/Views/...",
     previewDefinitionIndexInFile: <index>
   )
   ```
   Each call returns a path under `/var/folders/.../RenderPreview/...png`.
2. Copy the results into a temp directory using the baseline's filename:
   ```bash
   FRESH="$(mktemp -d)"
   cp /var/.../RenderPreview/...png "$FRESH/MarkdownPreviewView_Sample.png"
   # ...repeat for each baseline...
   ```
3. Run the diff:
   ```bash
   Scripts/check-snapshots.sh "$FRESH"
   ```

The diff script uses CGImage to decode both PNGs to raw RGBA and reports
the mean per-channel absolute difference. PNG metadata and compression
noise are ignored, so two visually identical renders compare equal. Real
visual changes — text, layout, colour — produce a non-zero mean and fail
the threshold (default 2.0 on a 0–255 scale).

## Refreshing a baseline intentionally

When a UI change is intentional, re-render with `RenderPreview`, copy the
result over the existing file in this directory, eyeball the diff in the
PR, and commit.
