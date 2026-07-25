#!/usr/bin/env bash
# agent-loop loop library: model-Y work-queue mechanics.
# Source-only — no top-level side effects. The /agent-loop-work command and the
# test harness both source this file.
set -euo pipefail

# --- working tree / recovery inspection (git-only) ---

# True iff the working tree has any change (tracked, staged, or untracked).
working_tree_dirty() { [ -n "$(git status --porcelain)" ]; }

# Prints the count of local commits not yet on origin/main (ungated leftovers).
local_ahead_of_origin() {
  git fetch -q origin main
  git rev-list --count origin/main..HEAD
}

# Prints any ci/* branches still on origin (one ref per line; empty if none).
stray_ci_refs() { git ls-remote --heads origin 'ci/*' | awk '{print $2}'; }

# --- model-Y gate/land mechanics (git-only) ---

# Rebase local main onto origin/main right before gating (sync BEFORE, never after).
sync_rebase() { git pull --rebase origin main; }

# Publish the current commit as the CI ref for issue N (a disposable per-attempt
# artifact). Force is safe here — the never-force invariant applies to main only,
# and this must succeed even when a re-gate rebased HEAD off the old ci ref, or a
# stale ref survives a dead run.
publish_ci_ref() { git push --force origin "HEAD:refs/heads/ci/issue-$1"; }

# Fast-forward-only land of the gated SHA. Never forced. Non-zero ⇒ trunk moved.
land_ff_only() { git push origin "$1:refs/heads/main"; }

# Delete the remote-only CI ref for issue N after landing.
cleanup_ci_ref() { git push origin --delete "ci/issue-$1"; }

# Discard ALL local divergence from origin/main — ungated commits AND their
# working-tree/staged changes — leaving a clean tree at the trunk tip. Used by
# RECOVER (dead-run leftovers) and BLOCKED (abandon partial work).
discard_to_baseline() { git fetch -q origin main && git reset --hard origin/main; }

# --- GitHub queue layer (gh) ---

# Prints the number of the oldest open issue carrying LABEL, or empty.
_oldest_open() {
  gh issue list --state open --label "$1" --json number \
    --jq 'sort_by(.number) | .[0].number // empty'
}

# Oldest open bug preempts oldest open todo. Prints the chosen number, or empty.
pick_next() {
  local n; n="$(_oldest_open bug)"
  [ -n "$n" ] || n="$(_oldest_open todo)"
  printf '%s' "$n"
}

open_agent_issue() { _oldest_open agent; }
open_bug_issue()   { _oldest_open bug; }

# Prints "true"/"false": does issue N carry LABEL?
issue_has_label() {
  gh issue view "$1" --json labels --jq "any(.labels[]?; .name == \"$2\")"
}

# Claim: status label -> agent (leaving a `bug` marker intact for fix items),
# and record the recovery baseline in a comment.
claim() {
  gh issue edit "$1" --remove-label todo --add-label agent
  gh issue comment "$1" --body "agent-loop: claiming. baseline origin/main @ $2"
}

block() {
  gh issue comment "$1" --body "agent-loop: BLOCKED. $2"
  gh issue edit "$1" --remove-label agent --add-label blocked
}

close_item() { gh issue close "$1" --reason completed --comment "$2"; }

file_bug() { gh issue create --title "$1" --body "$2" --label bug; }

# --- fixing-mode freeze primitive (a DEPLOY_FREEZE repo variable) ---
frozen()   { [ "$(gh variable get DEPLOY_FREEZE 2>/dev/null || echo 0)" = "1" ]; }
freeze()   { gh variable set DEPLOY_FREEZE --body 1; }
unfreeze() { gh variable set DEPLOY_FREEZE --body 0; }

# --- local gates (config seam) ---
# Prints each .gates.local[] command from the marker (one per line); empty if none.
read_local_gates() {
  local marker="${1:-.claude/agent-loop.json}"
  [ -f "$marker" ] || return 0
  jq -r '(.gates.local // [])[]' "$marker" 2>/dev/null || true
}

# --- CI-ref gate watch ---
# Blocks until the ci/issue-N run for the CURRENT HEAD commit finishes; non-zero
# if it is red or never appears. Binding to the pushed SHA is essential: a
# re-gate force-pushes a new commit to the same ref, and an earlier attempt's
# completed run must never be mistaken for this one — that could land un-gated code.
watch_gate() {
  local branch="ci/issue-$1" want id= i
  want="$(git rev-parse HEAD)"
  for i in $(seq 1 60); do
    id="$(gh run list --branch "$branch" --json databaseId,headSha \
          --jq "map(select(.headSha == \"$want\")) | .[0].databaseId // empty")"
    [ -n "$id" ] && break
    sleep 2
  done
  [ -n "$id" ] || { echo "agent-loop: no CI run for $branch @ $want" >&2; return 2; }
  gh run watch "$id" --exit-status
}
