---
description: Make the current repo adoptable by the agent-loop work queue (git, labels, marker, issue templates, commit conventions). Idempotent and non-destructive.
allowed-tools: Bash(bash:*), Bash(gh label:*), Bash(gh auth:*), Bash(gh repo:*)
---

Adopt the current repository into the agent-loop work queue.

1. Run the bootstrap script against the current directory:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
   ```

   It always does the safe **local half** — `git init` if needed, drops the
   issue templates + `.claude/agent-loop.json` marker + `CONTRIBUTING.md` +
   `.gitmessage`, and points `commit.template` at `.gitmessage`. It creates the
   kanban labels only if a GitHub repo already exists for this directory.

2. If the script reports **labels are pending** (no GitHub repo yet):
   - Run `gh auth status`. If not authenticated, tell the user to run
     `gh auth login`, then stop.
   - This next step is outward-facing, so **confirm with the user first**:
     propose a repo name (default: the folder name) and visibility (default:
     private). On confirmation, create the repo:

     ```bash
     gh repo create <name> --source=. --remote=origin --private
     ```

   - Then re-run the bootstrap to create the labels:

     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
     ```

   - If the user declines, relay the manual command above and stop.

3. Report what was created/updated: labels (`todo`/`agent`/`blocked`/`bug`), the
   files dropped (`.github/ISSUE_TEMPLATE/work-item.md`,
   `.github/ISSUE_TEMPLATE/bug.md`, `.claude/agent-loop.json`, `CONTRIBUTING.md`,
   `.gitmessage`), and that `commit.template` was set to `.gitmessage`. Existing
   files are left untouched (non-destructive).
