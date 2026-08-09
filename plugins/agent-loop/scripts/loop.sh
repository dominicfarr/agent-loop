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

# Prints "true"/"false": does issue N carry LABEL?
issue_has_label() {
  gh issue view "$1" --json labels --jq "any(.labels[]?; .name == \"$2\")"
}

# Claim: todo -> agent (WIP=1).
claim() {
  gh issue edit "$1" --remove-label todo --add-label agent
  gh issue comment "$1" --body "agent-loop: claiming."
}

block() {
  gh issue comment "$1" --body "agent-loop: BLOCKED. $2"
  gh issue edit "$1" --remove-label agent --add-label blocked
}

close_item() { gh issue close "$1" --reason completed --comment "$2"; }

file_bug() { gh issue create --title "$1" --body "$2" --label bug; }

# --- crash-recovery circuit-breaker ---
# A poisoned item that crashes the session mid-run is re-claimed and retried on
# every subsequent RECOVER. Cap the retries so one bad item can't loop forever.

# Number of "recovery attempt" marker comments on issue N (0 if none).
recovery_count() {
  gh issue view "$1" --json comments \
    --jq '[.comments[]? | select(.body | startswith("agent-loop: recovery attempt"))] | length'
}

# True (exit 0) once issue N has reached RECOVERY_LIMIT (default 3, override via
# env). RECOVER blocks the item instead of resuming when this is true.
recovery_exhausted() { [ "$(recovery_count "$1")" -ge "${RECOVERY_LIMIT:-3}" ]; }

# Record one more recovery attempt as a marker comment numbered count+1.
note_recovery_attempt() {
  gh issue comment "$1" --body "agent-loop: recovery attempt $(( $(recovery_count "$1") + 1 ))"
}

# --- local gates (config seam) ---
# Prints each .gates.local[] command from the marker (one per line); empty if none.
read_local_gates() {
  local marker="${1:-.claude/agent-loop.json}"
  [ -f "$marker" ] || return 0
  jq -r '(.gates.local // [])[]' "$marker" 2>/dev/null || true
}

