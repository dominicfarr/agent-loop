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

# Publish the current commit as the CI ref for issue N (the gate artifact).
publish_ci_ref() { git push origin "HEAD:refs/heads/ci/issue-$1"; }

# Fast-forward-only land of the gated SHA. Never forced. Non-zero ⇒ trunk moved.
land_ff_only() { git push origin "$1:refs/heads/main"; }

# Delete the remote-only CI ref for issue N after landing.
cleanup_ci_ref() { git push origin --delete "ci/issue-$1"; }

# Discard ungated local commits but KEEP their diff staged (BLOCKED handoff).
reset_soft_baseline() { git fetch -q origin main && git reset --soft origin/main; }
