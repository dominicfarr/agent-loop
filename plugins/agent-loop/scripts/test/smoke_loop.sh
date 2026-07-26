#!/usr/bin/env bash
# End-to-end plumbing smoke test against a THROWAWAY GitHub repo.
# Opt-in (hits the network + creates/deletes a repo): run explicitly.
#   bash plugins/agent-loop/scripts/test/smoke_loop.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../loop.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# GitHub has a ~1-2s read-after-write lag on issue queries, so a just-written
# change may not be readable yet. Poll until CMD's output equals WANT (up to
# ~15s) before asserting. (The real loop never writes-then-immediately-reads —
# this lag is a smoke-test artifact, not a loop concern.)
wait_for() {
  local want="$1"; shift
  local _ got
  for _ in $(seq 1 15); do got="$("$@")" || true; [ "$got" = "$want" ] && return 0; sleep 1; done
  return 1
}

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
wait_for "$N" pick_next || fail "pick_next did not return the todo ($N)"
claim "$N"
wait_for "$N" open_agent_issue || fail "issue not claimed as agent"

echo "a change" >> README.md; git commit -qam "feat: smoke change (Refs: #$N)"
sync_rebase
sha="$(git rev-parse HEAD)"
land || fail "land failed on clean trunk"
git fetch -q origin main
[ "$(git rev-parse origin/main)" = "$sha" ] || fail "land did not advance origin/main"
close_item "$N" "landed $sha"
wait_for CLOSED gh issue view "$N" --json state --jq .state || fail "issue not closed"

echo "PASS (smoke: end-to-end plumbing against $name)"
