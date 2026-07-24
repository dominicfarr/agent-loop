---
description: Drain this repo's issue queue onto trunk (model-Y). Claims one item (WIP=1), implements it, gates on ci/**, lands fast-forward-only, and self-heals on trunk breakage. Idempotent per run.
allowed-tools: Bash(bash:*), Bash(git:*), Bash(gh:*), Bash(source:*), Bash(jq:*)
---

Run one pass of the agent-loop work queue on the current repository. All
mechanical git/gh operations are functions in the loop library — **use them; do
not hand-roll git/gh**:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/loop.sh"
```

First confirm `gh auth status` succeeds; if not, stop and tell the user to run
`gh auth login`. Then execute the protocol. You own only the judgment calls
(what to implement; fix-forward vs. block; revert vs. hotfix); everything else is
a library call.

**0 · RECOVER (before anything else).**
- `open_agent_issue` non-empty → an item was mid-flight (crash). Resume it as the
  claimed item; do not claim a new one (WIP=1).
- `frozen` true or `open_bug_issue` non-empty → trunk is (or was) broken. Handle
  the incident FIRST: treat that `bug` as the claimed item and go to FIXING-MODE.
- `local_ahead_of_origin` > 0 with no claimed item → ungated commits from a dead
  run. Discard them: `reset_soft_baseline` then `git checkout -- .`.
- `stray_ci_refs` non-empty with no active gate → GC each: `cleanup_ci_ref <N>`.

**1 · PICK.** If `working_tree_dirty`, STOP and report — a human is mid-edit;
never touch their tree. Otherwise `N="$(pick_next)"`. Empty → go to REPORT.

**2 · CLAIM.** Record the baseline: `base="$(git rev-parse origin/main)"`, then
`claim "$N" "$base"`.

**3 · IMPLEMENT.** Implement the item on **local main** (real TBD — no feature
branch), test-first. Every commit footer carries `Refs: #N`. Keep changes scoped
to the issue's acceptance criteria. If the spec is too vague to implement or
needs a human/secret you don't have, go to BLOCKED.
(Plan 3 dispatches the Shape/Inception/Implement phase-agents here; for now,
implement directly, writing tests first.)

**4 · GATE.**
- `sync_rebase` (sync BEFORE the gate, never after).
- Run each local gate from `read_local_gates` in order; any non-zero → treat as
  gate red (fix-forward or BLOCKED). These are a fast pre-check only.
- `publish_ci_ref "$N"`, then `watch_gate "$N"`.
  - Red → fix-forward on local main and re-gate (back to the top of GATE), **or**
    if you cannot fix it, go to BLOCKED. Trunk stays green either way.
  - Green → GATE passed. **Do not rebase or merge now** (gate-SHA == land-SHA).

**5 · LAND.** `sha="$(git rev-parse HEAD)"`, then `land_ff_only "$sha"`.
- Rejected (trunk moved) → `sync_rebase` and go back to GATE (re-gate the
  rebased commit). Never force.
- Success → `cleanup_ci_ref "$N"`; then close the item:
  `close_item "$N" "landed $sha"`.
- If the item carried the `bug` label (`issue_has_label "$N" bug` is `true`) and
  `frozen`, the incident is resolved: confirm trunk is green, then `unfreeze`.
- (Optional) watch post-merge trunk CI; red → FIXING-MODE.
- Return to PICK for the next item.

**6 · REPORT.** Summarize what landed / was blocked, or "queue empty". Stop — do
not poll.

**7 · BLOCKED.** State exactly what's needed (missing secret, ambiguous
acceptance criteria, external dependency). Then `block "$N" "<what's needed>"`,
`reset_soft_baseline`, `git checkout -- .` (discard the kept diff), and
`cleanup_ci_ref "$N"` if you published one this run. Return to PICK.

**FIXING-MODE (trunk red — Andon stop-the-line).** `freeze` immediately. If no
`bug` issue exists yet for this breakage, `file_bug "trunk red: <signal>"
"<what broke / offending SHA / revert-or-hotfix decision>"`. Then treat that
`bug` as the claimed item and drive it through IMPLEMENT→GATE→LAND as a normal
gated change — reverting the offending commit or hotfixing forward, your call.
On green land of the fix, `unfreeze` (handled by LAND above). In v1, if you crash
mid-incident, the next run's RECOVER re-enters here via the freeze + open `bug`.
