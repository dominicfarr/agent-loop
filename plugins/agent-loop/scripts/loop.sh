#!/usr/bin/env bash
# agent-loop loop library: single-writer work-queue mechanics.
# Source-only — no top-level side effects. The /agent-loop-work command and the
# test harness both source this file.
#
# Operating model (deliberate, YAGNI): ONE writer (the agent), nothing consumes
# trunk, and the loop improves its OWN repo. There is no concurrency to guard
# against — no CI-ref dance, no freeze/Andon, no fast-forward choreography. The
# single surviving guard is self-preservation: the change's own tests must pass
# before it lands, because a red commit bricks the next loop iteration.
set -euo pipefail

# --- working tree inspection ---
# True iff the working tree has any change (tracked, staged, or untracked).
working_tree_dirty() { [ -n "$(git status --porcelain)" ]; }

# --- trunk sync + land ---
# Start each run from the latest trunk tip.
sync_rebase() { git pull --rebase origin main; }

# Land local main onto origin/main. Non-forced, so git accepts only a
# fast-forward — always the case with one writer. Literal HEAD (no parameter)
# keeps the refspec zsh-safe; do NOT rewrite as "$sha:refs/...".
land() { git push origin HEAD:refs/heads/main; }

# Discard ALL local divergence from origin/main — commits AND working-tree/staged
# changes — leaving a clean tree at the trunk tip. Used to abandon partial work
# on BLOCKED or when resuming a crashed run.
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
