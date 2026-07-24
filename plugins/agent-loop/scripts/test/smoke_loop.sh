#!/usr/bin/env bash
# End-to-end plumbing smoke test against a THROWAWAY GitHub repo.
# Opt-in (hits the network + creates/deletes a repo): run explicitly.
#   bash plugins/agent-loop/scripts/test/smoke_loop.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../loop.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

name="agent-loop-loop-smoketest-$$"
work="$(mktemp -d)"; cd "$work"
git init -q; git config user.email a@b.c; git config user.name t
echo "# $name" > README.md; git add README.md; git commit -qm "C0: seed"
gh repo create "$name" --private --source=. --remote=origin --push >/dev/null
cleanup() { gh repo delete "$name" --yes >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

# labels + a todo item (mirrors what init + a human would set up)
for l in todo agent blocked bug; do gh label create "$l" --force >/dev/null; done
issue_url="$(gh issue create --title "smoke: add a line" --body "acceptance: file changed" --label todo)"
N="${issue_url##*/}"

# --- drive the plumbing path (no LLM) ---
[ "$(pick_next)" = "$N" ] || fail "pick_next did not return the todo ($N)"
base="$(git rev-parse origin/main)"
claim "$N" "$base"
[ "$(open_agent_issue)" = "$N" ] || fail "issue not claimed as agent"

echo "a change" >> README.md; git commit -qam "feat: smoke change (Refs: #$N)"
sync_rebase
publish_ci_ref "$N"
stray_ci_refs | grep -q "ci/issue-$N" || fail "CI ref not published"

sha="$(git rev-parse HEAD)"
land_ff_only "$sha" || fail "ff-only land failed on green trunk"
cleanup_ci_ref "$N"
[ -z "$(stray_ci_refs)" ] || fail "CI ref not cleaned up after land"
close_item "$N" "landed $sha"
[ "$(gh issue view "$N" --json state --jq .state)" = "CLOSED" ] || fail "issue not closed"

echo "PASS (smoke: end-to-end plumbing against $name)"
