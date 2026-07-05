#!/usr/bin/env bash
# Enforces the three-layer dependency direction documented in CLAUDE.md:
#
#   App    (Sources/PunkRecordsApp)        -> may import Core and Infra
#   Infra  (Packages/PunkRecordsInfra)     -> may import Core; must never import App
#   Core   (Packages/PunkRecordsCore)      -> pure; must never import Infra, App,
#                                              FoundationModels, or AnyLanguageModel
#
# Checks:
#   1. Packages/PunkRecordsCore/Sources — no import of PunkRecordsInfra,
#      PunkRecordsApp, FoundationModels, or AnyLanguageModel.
#   2. Packages/PunkRecordsInfra/Sources — no import of PunkRecordsApp.
#   3. Packages/PunkRecordsCore/Package.swift — no dependency declaration on
#      PunkRecordsInfra or AnyLanguageModel.
#
# Deterministic, offline, no build required. Run before committing, alongside
# swiftlint, as a local quality gate.
#
# Usage: scripts/check-architecture.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

violations=0

# Reports one violation line (file:line: message).
report() {
    echo "$1:$2: $3"
    violations=$((violations + 1))
}

# Scans every *.swift file under $1 for "import X" / "@testable import X"
# statements naming one of the modules in $2 (a "|"-separated ERE
# alternation). Skips whole-line "//" comments; deliberately does not try to
# strip inline or block comments.
check_imports() {
    local dir="$1"
    local modules_pattern="$2"
    local label="$3"

    [ -d "$dir" ] || return 0

    local import_re="^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(${modules_pattern})([[:space:]./;]|\$)"
    local comment_re="^[[:space:]]*//"

    while IFS= read -r -d '' file; do
        local lineno=0
        while IFS= read -r line || [ -n "$line" ]; do
            lineno=$((lineno + 1))
            if [[ "$line" =~ $comment_re ]]; then
                continue
            fi
            if [[ "$line" =~ $import_re ]]; then
                report "$file" "$lineno" "$label: ${line#"${line%%[![:space:]]*}"}"
            fi
        done < "$file"
    done < <(find "$dir" -name '*.swift' -print0)
}

# Scans a single manifest file for bare-word references to any of the names
# in $2 (a bash array passed by name via nameref), outside of "//" comments.
check_manifest() {
    local file="$1"
    shift
    local forbidden_names=("$@")

    [ -f "$file" ] || return 0

    local comment_re="^[[:space:]]*//"
    local lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        if [[ "$line" =~ $comment_re ]]; then
            continue
        fi
        for name in "${forbidden_names[@]}"; do
            if [[ "$line" == *"$name"* ]]; then
                report "$file" "$lineno" "Core manifest must not depend on $name: ${line#"${line%%[![:space:]]*}"}"
            fi
        done
    done < "$file"
}

check_imports "Packages/PunkRecordsCore/Sources" \
    "PunkRecordsInfra|PunkRecordsApp|FoundationModels|AnyLanguageModel" \
    "Core must not import Infra/App/FoundationModels/AnyLanguageModel"

check_imports "Packages/PunkRecordsInfra/Sources" \
    "PunkRecordsApp" \
    "Infra must not import App"

check_manifest "Packages/PunkRecordsCore/Package.swift" "PunkRecordsInfra" "AnyLanguageModel"

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "Architecture check FAILED: $violations violation(s) found." >&2
    exit 1
fi

echo "Architecture check OK: no forbidden cross-layer imports or dependencies found."
exit 0
