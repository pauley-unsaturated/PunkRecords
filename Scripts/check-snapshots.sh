#!/usr/bin/env bash
# Compares freshly-rendered preview PNGs to the committed baselines in
# Tests/SnapshotBaselines. Pass a directory containing the fresh PNGs
# (named exactly like the baselines).
#
# Typical agent workflow:
#   1. For each baseline, ask the xcode MCP server to RenderPreview the
#      matching #Preview definition in the source file.
#   2. Copy each result into a temp directory using the baseline's name.
#   3. Run this script with that temp directory.
#
# Exits 0 on a clean run, 1 if any baseline failed to match within the
# pixel-diff threshold.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINES_DIR="$REPO_ROOT/Tests/SnapshotBaselines"
DIFF="$REPO_ROOT/Scripts/snapshot-diff.swift"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <fresh-pngs-directory> [threshold=2.0]" >&2
    exit 64
fi

FRESH_DIR="$1"
THRESHOLD="${2:-2.0}"

if [[ ! -d "$FRESH_DIR" ]]; then
    echo "fresh directory not found: $FRESH_DIR" >&2
    exit 1
fi

failures=0
for baseline in "$BASELINES_DIR"/*.png; do
    name="$(basename "$baseline")"
    fresh="$FRESH_DIR/$name"
    if [[ ! -f "$fresh" ]]; then
        echo "missing fresh render for $name (expected at $fresh)" >&2
        failures=$((failures + 1))
        continue
    fi
    if ! "$DIFF" "$baseline" "$fresh" "$THRESHOLD"; then
        failures=$((failures + 1))
    fi
done

if [[ $failures -gt 0 ]]; then
    echo "snapshot check failed: $failures mismatch(es)" >&2
    exit 1
fi

echo "all snapshots match"
