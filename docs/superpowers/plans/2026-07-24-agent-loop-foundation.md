# agent-loop — Plan 1: Plugin foundation + `/agent-loop-init`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce an installable `agent-loop` Claude Code plugin whose
`/agent-loop-init` command mechanically makes any repo adoptable by the loop —
creating the kanban labels and dropping the marker + issue templates,
idempotently and non-destructively.

**Architecture:** The repo is a single-plugin **marketplace**: `.claude-plugin/marketplace.json` at the root lists one plugin living under `plugins/agent-loop/`. The plugin carries a thin slash command (`/agent-loop-init`) that shells out to a deterministic, testable bootstrap script (`scripts/init.sh`) — mechanical setup stays out of the LLM's hands. Template *sources* live in the plugin and are copied into the target repo.

**Tech Stack:** Claude Code plugin format (JSON manifests + markdown commands), Bash (bootstrap script, `set -euo pipefail`), `gh` CLI (labels), plain-bash test harness (no external test deps).

## Global Constraints

- **Distribution is private** — a local dir or RSI-org marketplace. No OSS. (Design §Distribution)
- **Per-repo footprint is minimal:** labels `todo`/`agent`/`blocked`/`bug`, a `.claude/agent-loop.json` marker, and work-item + bug issue templates. Nothing else. (Design §Per-repo footprint)
- **`init` is stack-agnostic** — it never scaffolds a language/deploy template. (Design §Per-repo footprint)
- **Retro-apply is out of scope** — but `init` must still be **non-destructive**: never overwrite an existing template or clobber a label's meaning. (Design §Out of scope; additive principle)
- **Label set is exactly:** `todo`, `agent`, `blocked`, `bug`. (Design §Kanban states)
- Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.

---

## File structure (this plan)

- Create: `.claude-plugin/marketplace.json` — marketplace listing the plugin
- Create: `plugins/agent-loop/.claude-plugin/plugin.json` — plugin manifest
- Create: `plugins/agent-loop/commands/agent-loop-init.md` — `/agent-loop-init` command (thin; runs the script)
- Create: `plugins/agent-loop/scripts/init.sh` — deterministic bootstrap (drop files + create labels)
- Create: `plugins/agent-loop/scripts/test/init_test.sh` — bash test for `init.sh` file-drop logic
- Create: `plugins/agent-loop/templates/work-item.md` — work-item issue template source
- Create: `plugins/agent-loop/templates/bug.md` — bug (fixing-mode) issue template source
- Create: `plugins/agent-loop/templates/agent-loop.json` — marker/config template source
- Modify: `README.md` — install + usage section

---

### Task 1: Scaffold the marketplace + plugin manifest

**Files:**
- Create: `.claude-plugin/marketplace.json`
- Create: `plugins/agent-loop/.claude-plugin/plugin.json`

**Interfaces:**
- Produces: an installable plugin named `agent-loop` in a marketplace named `rsi-agent-loop`. Later tasks add `commands/`, `scripts/`, `templates/` under `plugins/agent-loop/` (auto-discovered).

- [ ] **Step 1: Write the marketplace manifest**

Create `.claude-plugin/marketplace.json`:

```json
{
  "name": "rsi-agent-loop",
  "owner": { "name": "Dommo" },
  "plugins": [
    { "name": "agent-loop", "source": "./plugins/agent-loop" }
  ]
}
```

- [ ] **Step 2: Write the plugin manifest**

Create `plugins/agent-loop/.claude-plugin/plugin.json`:

```json
{
  "name": "agent-loop",
  "description": "Autonomous GitHub-issue work-queue development loop: drain the queue, gate pre-push on trunk, self-heal on trunk breakage. Centrally maintained.",
  "version": "0.1.0",
  "author": { "name": "Dommo" }
}
```

- [ ] **Step 3: Validate the plugin structure**

Dispatch the `plugin-dev:plugin-validator` agent against `plugins/agent-loop/`.
Expected: no structural errors (manifest valid; name matches). Fix anything it flags.

- [ ] **Step 4: Install locally and confirm discovery**

In a Claude Code session, add the marketplace and install the plugin:

```
/plugin marketplace add /Users/dfarr/RSI/agent-loop
/plugin install agent-loop@rsi-agent-loop
```

Expected: install succeeds. (No commands yet — Task 2 adds `/agent-loop-init`. If the CLI reports the plugin has zero components, that's fine at this step.)

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/marketplace.json plugins/agent-loop/.claude-plugin/plugin.json
git commit -m "feat(plugin): scaffold agent-loop marketplace and manifest"
```

---

### Task 2: The bootstrap script — file-drop logic (TDD)

**Files:**
- Create: `plugins/agent-loop/scripts/init.sh`
- Create: `plugins/agent-loop/scripts/test/init_test.sh`
- Create: `plugins/agent-loop/templates/work-item.md`
- Create: `plugins/agent-loop/templates/bug.md`
- Create: `plugins/agent-loop/templates/agent-loop.json`

**Interfaces:**
- Produces: `init.sh` exposing shell functions `drop_files <target_dir>` and `create_labels`, and a `main` guarded so the file is sourceable in tests (`main` runs only when executed directly). `drop_files` is non-destructive (`cp -n`). Task 3 consumes `create_labels` and wires the command.

- [ ] **Step 1: Write the template sources**

Create `plugins/agent-loop/templates/work-item.md`:

```markdown
---
name: Work item
about: A spec for the agent-loop work queue
title: ""
labels: []
---

## Context
<!-- Why this is wanted. Link anything relevant. -->

## Requirements
<!-- What to build or change. Be concrete. -->

## Acceptance criteria
<!-- Each line verifiable. Vague criteria get the issue labeled `blocked`, not guessed at. -->
- [ ]

## Out of scope
<!-- Optional fence. Delete if not needed. -->
```

Create `plugins/agent-loop/templates/bug.md`:

```markdown
---
name: Fixing-mode bug
about: A trunk-breakage incident filed by the loop (or a human)
title: "trunk red: "
labels: ["bug"]
---

## What broke
<!-- The failing gate / pipeline and its signal. -->

## Trunk state
<!-- Is the trunk frozen? Offending commit SHA. -->

## Fix decision
<!-- revert | hotfix — and why. -->

## Acceptance criteria
- [ ] pipeline green again
- [ ] trunk unfrozen
```

Create `plugins/agent-loop/templates/agent-loop.json`:

```json
{
  "adoptedBy": "agent-loop",
  "version": 1
}
```

- [ ] **Step 2: Write the failing test**

Create `plugins/agent-loop/scripts/test/init_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../init.sh
source "$HERE/../init.sh"   # sourcing must NOT run main (guarded)

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- drops the three files into an empty target ---
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
drop_files "$tmp"
[ -f "$tmp/.github/ISSUE_TEMPLATE/work-item.md" ] || fail "work-item.md not dropped"
[ -f "$tmp/.github/ISSUE_TEMPLATE/bug.md" ]       || fail "bug.md not dropped"
[ -f "$tmp/.claude/agent-loop.json" ]             || fail "agent-loop.json not dropped"

# --- non-destructive: does not overwrite an existing template ---
echo "CUSTOM" > "$tmp/.github/ISSUE_TEMPLATE/work-item.md"
drop_files "$tmp"
[ "$(cat "$tmp/.github/ISSUE_TEMPLATE/work-item.md")" = "CUSTOM" ] \
  || fail "drop_files overwrote an existing template"

echo "PASS"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash plugins/agent-loop/scripts/test/init_test.sh`
Expected: FAIL — `init.sh` does not exist yet (source error / `drop_files: command not found`).

- [ ] **Step 4: Write the minimal `init.sh`**

Create `plugins/agent-loop/scripts/init.sh`:

```bash
#!/usr/bin/env bash
# agent-loop init: make a repo adoptable by the work-queue loop.
# Idempotent and non-destructive.
set -euo pipefail

AGENT_LOOP_ROOT="${AGENT_LOOP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

drop_files() {
  local target="$1"
  mkdir -p "$target/.github/ISSUE_TEMPLATE" "$target/.claude"
  # cp -n = never overwrite existing files (non-destructive / additive)
  cp -n "$AGENT_LOOP_ROOT/templates/work-item.md" "$target/.github/ISSUE_TEMPLATE/work-item.md"
  cp -n "$AGENT_LOOP_ROOT/templates/bug.md"       "$target/.github/ISSUE_TEMPLATE/bug.md"
  cp -n "$AGENT_LOOP_ROOT/templates/agent-loop.json" "$target/.claude/agent-loop.json"
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
  create_labels
  echo "agent-loop: initialized $target"
}

# Only run main when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash plugins/agent-loop/scripts/test/init_test.sh`
Expected: `PASS`.

- [ ] **Step 6: Commit**

```bash
git add plugins/agent-loop/scripts/init.sh plugins/agent-loop/scripts/test/init_test.sh plugins/agent-loop/templates
git commit -m "feat(init): non-destructive file-drop bootstrap with tests"
```

---

### Task 3: Wire `/agent-loop-init` and verify labels end-to-end

**Files:**
- Create: `plugins/agent-loop/commands/agent-loop-init.md`

**Interfaces:**
- Consumes: `scripts/init.sh` (`main`, `create_labels`) from Task 2.
- Produces: the `/agent-loop-init` slash command. `${CLAUDE_PLUGIN_ROOT}` resolves to `plugins/agent-loop/` at runtime, so the command calls `${CLAUDE_PLUGIN_ROOT}/scripts/init.sh`.

- [ ] **Step 1: Write the command**

Create `plugins/agent-loop/commands/agent-loop-init.md`:

```markdown
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
   `bug`) and the files dropped (`.github/ISSUE_TEMPLATE/work-item.md`,
   `.github/ISSUE_TEMPLATE/bug.md`, `.claude/agent-loop.json`). Note that
   existing files were left untouched (non-destructive).
```

- [ ] **Step 2: Reinstall and confirm the command is discoverable**

```
/plugin marketplace update rsi-agent-loop
```

Expected: `/agent-loop-init` now appears in the command list (`/help` or typing `/agent-loop`).

- [ ] **Step 3: Functional test against a throwaway GitHub repo**

Create a scratch repo, run the command's script against it, and assert state.
Run:

```bash
scratch="$(mktemp -d)"; cd "$scratch"; git init -q
gh repo create rsi-agent-loop-smoketest --private --source=. --remote=origin >/dev/null
AGENT_LOOP_ROOT=/Users/dfarr/RSI/agent-loop/plugins/agent-loop \
  bash /Users/dfarr/RSI/agent-loop/plugins/agent-loop/scripts/init.sh "$scratch"
gh label list --json name --jq '.[].name' | sort | tr '\n' ' '
ls .github/ISSUE_TEMPLATE/ .claude/
```

Expected: label list includes `agent blocked bug todo`; the three files exist.

- [ ] **Step 4: Verify idempotency**

Run the same `init.sh` line again.
Expected: exit 0, no errors (labels `--force`-updated, files skipped by `cp -n`).

- [ ] **Step 5: Tear down the scratch repo**

```bash
gh repo delete rsi-agent-loop-smoketest --yes
```

- [ ] **Step 6: Commit**

```bash
git add plugins/agent-loop/commands/agent-loop-init.md
git commit -m "feat(init): add /agent-loop-init command wired to bootstrap"
```

---

### Task 4: Install + usage docs

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above (marketplace name `rsi-agent-loop`, plugin `agent-loop`, command `/agent-loop-init`).

- [ ] **Step 1: Replace the "Next step" stub with real install/usage docs**

In `README.md`, replace the `## Next step` section with:

```markdown
## Install (per machine)

```
/plugin marketplace add /Users/dfarr/RSI/agent-loop
/plugin install agent-loop@rsi-agent-loop
```

Update to pick up loop improvements: `/plugin marketplace update rsi-agent-loop`.

## Adopt a repo

In any repo you want the loop to drain, run `/agent-loop-init`. It creates the
kanban labels (`todo`/`agent`/`blocked`/`bug`), drops the work-item and bug
issue templates, and writes a `.claude/agent-loop.json` marker. It is
idempotent and never overwrites existing files.

> Draining the queue (`/work-queue`) and the phase agents (grill-me,
> walking-skeleton) arrive in Plans 2 and 3 — see
> [docs/superpowers/specs/2026-07-24-agent-loop-design.md](docs/superpowers/specs/2026-07-24-agent-loop-design.md).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: install and adopt-a-repo instructions"
```

---

## Self-Review

**Spec coverage (Plan 1's slice):**
- Plugin scaffold + private marketplace → Task 1. ✅
- Per-repo footprint (labels + marker + templates) → Tasks 2–3. ✅
- Non-destructive / additive → Task 2 (`cp -n`, tested). ✅
- Stack-agnostic init → no template scaffolding anywhere. ✅
- Exact label set `todo/agent/blocked/bug` → Task 2 `create_labels`, asserted in Task 3. ✅
- `/work-queue`, grill-me, walking-skeleton, fixing-mode → **intentionally out of Plan 1** (Plans 2–3).

**Placeholder scan:** every step has concrete file content, commands, and expected output. No TBD/TODO. ✅

**Type/name consistency:** `drop_files`/`create_labels`/`main` used identically across Tasks 2–3; marketplace `rsi-agent-loop`, plugin `agent-loop`, command `/agent-loop-init`, and `${CLAUDE_PLUGIN_ROOT}/scripts/init.sh` path consistent throughout. ✅

## Follow-on plans (not yet written)

- **Plan 2 — `/work-queue` orchestrator + guardrails**: model-Y protocol (steps 0–7), two-tier failure, fixing-mode, recovery, dirty-tree/ff-only/reset-soft guardrails.
- **Plan 3 — Phase agents + TDD wiring**: grill-me (Shape) agent, walking-skeleton (Inception) agent, TDD skill wiring, spine dispatch.
