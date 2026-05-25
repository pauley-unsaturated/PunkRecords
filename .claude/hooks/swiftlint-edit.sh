#!/bin/bash
# PostToolUse hook: lint the just-edited Swift file with SwiftLint.
#
# Acts as a style backstop. Blocks (exit 2, feeding the findings back to the
# agent) only when there are error-severity violations; surfaces warnings
# advisorily without blocking. No-ops gracefully when SwiftLint isn't installed
# or the edited file isn't Swift.

input="$(cat)"

# Extract the edited file path from the tool-input JSON.
file="$(printf '%s' "$input" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    print("")' 2>/dev/null)"

[ -z "${file:-}" ] && exit 0
case "$file" in
  *.swift) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
command -v swiftlint >/dev/null 2>&1 || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$root" || exit 0

out="$(swiftlint lint --quiet --config "$root/.swiftlint.yml" "$file" 2>/dev/null)"
[ -z "$out" ] && exit 0

if printf '%s\n' "$out" | grep -q ' error: '; then
  printf 'SwiftLint errors in %s — fix before continuing:\n%s\n' "$file" "$out" >&2
  exit 2
fi

printf 'SwiftLint warnings in %s (advisory):\n%s\n' "$file" "$out" >&2
exit 0
