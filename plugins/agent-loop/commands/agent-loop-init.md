---
description: Make the current repo adoptable by the agent-loop work queue (labels, marker, issue templates). Idempotent and non-destructive.
allowed-tools: Bash(bash:*), Bash(gh label:*), Bash(gh auth:*)
---

Adopt the current repository into the agent-loop work queue.

1. Confirm `gh` is authenticated for this repo: run `gh auth status`. If not
   authenticated, stop and tell the user to run `gh auth login`.
2. Run the bootstrap script against the current directory:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
   ```

3. Report what it did: the labels created/updated (`todo`, `agent`, `blocked`,
   `bug`), the files dropped (`.github/ISSUE_TEMPLATE/work-item.md`,
   `.github/ISSUE_TEMPLATE/bug.md`, `.claude/agent-loop.json`, `CONTRIBUTING.md`,
   `.gitmessage`), and that `commit.template` was set to `.gitmessage`. Note that
   existing files were left untouched (non-destructive).
