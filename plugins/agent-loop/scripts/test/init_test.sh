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

# --- ensure_git initializes a bare (non-git) directory ---
bare="$(mktemp -d)"
ensure_git "$bare"
[ -d "$bare/.git" ] || fail "ensure_git did not create .git"
rm -rf "$bare"

# --- main on a repo with NO remote: local success, labels pending, exit 0 ---
noremote="$(mktemp -d)"
out="$( main "$noremote" 2>&1 )" || fail "main aborted on a no-remote repo"
[ -d "$noremote/.git" ]                    || fail "main did not init git"
[ -f "$noremote/CONTRIBUTING.md" ]         || fail "main did not drop files"
[ "$(git -C "$noremote" config --local --get commit.template)" = ".gitmessage" ] \
  || fail "main did not set commit.template"
printf '%s' "$out" | grep -qi "pending"    || fail "main did not report labels pending"
rm -rf "$noremote"

echo "PASS"
