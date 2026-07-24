#!/usr/bin/env bash
# agent-loop init: make a repo adoptable by the work-queue loop.
# Idempotent and non-destructive.
set -euo pipefail

AGENT_LOOP_ROOT="${AGENT_LOOP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

copy_if_absent() {
  # Non-destructive and portable: BSD `cp -n` returns non-zero when it skips an
  # existing file, which trips `set -e`. Guard on existence instead.
  [ -e "$2" ] || cp "$1" "$2"
}

drop_files() {
  local target="$1"
  mkdir -p "$target/.github/ISSUE_TEMPLATE" "$target/.claude"
  copy_if_absent "$AGENT_LOOP_ROOT/templates/work-item.md"    "$target/.github/ISSUE_TEMPLATE/work-item.md"
  copy_if_absent "$AGENT_LOOP_ROOT/templates/bug.md"          "$target/.github/ISSUE_TEMPLATE/bug.md"
  copy_if_absent "$AGENT_LOOP_ROOT/templates/agent-loop.json" "$target/.claude/agent-loop.json"
  copy_if_absent "$AGENT_LOOP_ROOT/templates/CONTRIBUTING.md" "$target/CONTRIBUTING.md"
  copy_if_absent "$AGENT_LOOP_ROOT/templates/gitmessage"      "$target/.gitmessage"
}

set_commit_template() {
  local target="$1"
  # Repo-local; commit.template does not travel with clones, so init sets it.
  git -C "$target" config --local commit.template .gitmessage 2>/dev/null || true
}

create_labels() {
  # --force makes this idempotent (create or update); colours/descriptions fixed.
  gh label create todo    -c "0E8A16" -d "Ready for the agent to pick up"          --force
  gh label create agent   -c "1D76DB" -d "Claimed by the agent (WIP=1)"            --force
  gh label create blocked -c "B60205" -d "Needs a human; the agent will not touch" --force
  gh label create bug     -c "D93F0B" -d "Fixing-mode incident; preempts todo"     --force
}

main() {
  local target="${1:-$(pwd)}"
  drop_files "$target"
  set_commit_template "$target"
  create_labels
  echo "agent-loop: initialized $target"
}

# Only run main when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
