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
(what to implement; fix-forward vs. block); everything else is a library call.

This loop runs a deliberately relaxed, **single-writer** model: one agent, no
concurrent writers, nothing consuming trunk. There is no CI-ref gate, no
freeze, no fast-forward choreography. The one guard is self-preservation —
**a change's own tests must pass before it lands**, because this loop improves
its own repo and a red commit breaks the next run.

**0 · RECOVER.** `open_agent_issue` non-empty → a prior run crashed mid-item.
`discard_to_baseline` (drop any partial commits/tree), then resume that issue as
the claimed item — do not claim a new one (WIP=1).

**1 · PICK.** If `working_tree_dirty`, STOP and report — a human is mid-edit;
never touch their tree. Otherwise `N="$(pick_next)"`. Empty → go to REPORT.

**2 · SYNC + CLAIM.** `sync_rebase` (start from the latest trunk), then
`claim "$N"`.

**3 · IMPLEMENT.** Implement the item on **local main**, test-first. Every commit
footer carries `Refs: #N`. Keep changes scoped to the issue's acceptance
criteria. If the spec is too vague to implement or needs a human/secret you
don't have, go to BLOCKED.

**4 · GATE.** Run each command from `read_local_gates` in order — these ARE the
gate. Any non-zero → red: fix-forward on local main and re-run the gate, **or**
if you cannot fix it, go to BLOCKED. Green → LAND. (If `read_local_gates` is
empty, the repo has opted out of gating; land directly.)

**5 · LAND.** `land`. If it is rejected (a second writer moved trunk — not
expected in this model), `sync_rebase`, re-run the GATE, and `land` again. On
success, `close_item "$N" "landed $(git rev-parse HEAD)"`. Return to PICK.

**6 · REPORT.** Summarize what landed / was blocked, or "queue empty". Stop — do
not poll.

**7 · BLOCKED.** State exactly what's needed (missing secret, ambiguous
acceptance criteria, external dependency). Then `block "$N" "<what's needed>"`,
`discard_to_baseline` (abandon the partial work), and return to PICK.
