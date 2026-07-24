#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../init.sh
source "$HERE/../init.sh"   # sourcing must NOT run main (guarded)

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- drops the five files into an empty target ---
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
drop_files "$tmp"
[ -f "$tmp/.github/ISSUE_TEMPLATE/work-item.md" ] || fail "work-item.md not dropped"
[ -f "$tmp/.github/ISSUE_TEMPLATE/bug.md" ]       || fail "bug.md not dropped"
[ -f "$tmp/.claude/agent-loop.json" ]             || fail "agent-loop.json not dropped"
[ -f "$tmp/CONTRIBUTING.md" ]                      || fail "CONTRIBUTING.md not dropped"
[ -f "$tmp/.gitmessage" ]                          || fail ".gitmessage not dropped"

# --- non-destructive: does not overwrite an existing template ---
echo "CUSTOM" > "$tmp/.github/ISSUE_TEMPLATE/work-item.md"
drop_files "$tmp"
[ "$(cat "$tmp/.github/ISSUE_TEMPLATE/work-item.md")" = "CUSTOM" ] \
  || fail "drop_files overwrote an existing template"

echo "PASS"
