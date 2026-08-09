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

# --- found-vs-added report: every file `added:` on an empty target ---
rep="$(mktemp -d)"
out1="$(drop_files "$rep")"
for f in .github/ISSUE_TEMPLATE/work-item.md .github/ISSUE_TEMPLATE/bug.md \
         .claude/agent-loop.json CONTRIBUTING.md .gitmessage; do
  printf '%s\n' "$out1" | grep -qx "added: $f" || fail "drop_files did not report 'added: $f'"
done
# --- ...and `exists:` for a file already present on a second drop ---
out2="$(drop_files "$rep")"
printf '%s\n' "$out2" | grep -qx "exists: CONTRIBUTING.md" \
  || fail "drop_files did not report 'exists: CONTRIBUTING.md' on a second drop"
rm -rf "$rep"

# --- ensure_git initializes a bare (non-git) directory ---
bare="$(mktemp -d)"
ensure_git "$bare"
[ -d "$bare/.git" ] || fail "ensure_git did not create .git"
rm -rf "$bare"

# --- establish_trunk: a virgin repo gets its scaffolding pushed as origin/main ---
# The work loop presupposes an origin/main baseline; init must leave one behind.
origin="$(mktemp -d)"; git init -q --bare "$origin"
virgin="$(mktemp -d)"
git init -q "$virgin"
git -C "$virgin" config user.email "test@agent-loop"; git -C "$virgin" config user.name "test"
git -C "$virgin" remote add origin "$origin"
drop_files "$virgin"
establish_trunk "$virgin" || fail "establish_trunk aborted on a virgin repo"
git -C "$virgin" rev-parse --verify -q HEAD >/dev/null 2>&1 \
  || fail "establish_trunk did not create the initial commit"
git ls-remote --exit-code --heads "$origin" main >/dev/null 2>&1 \
  || fail "establish_trunk did not establish origin/main"
rm -rf "$origin" "$virgin"

# --- establish_trunk: a repo that already has history is left untouched ---
# Never sweep a user's working tree into a bootstrap commit.
origin2="$(mktemp -d)"; git init -q --bare "$origin2"
existing="$(mktemp -d)"
git init -q "$existing"
git -C "$existing" config user.email "test@agent-loop"; git -C "$existing" config user.name "test"
git -C "$existing" remote add origin "$origin2"
git -C "$existing" commit -q --allow-empty -m "pre-existing history"
before="$(git -C "$existing" rev-list --count HEAD)"
drop_files "$existing"
establish_trunk "$existing" || fail "establish_trunk aborted on a repo with history"
after="$(git -C "$existing" rev-list --count HEAD)"
[ "$before" = "$after" ] || fail "establish_trunk created a commit on a repo with history"
rm -rf "$origin2" "$existing"

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
