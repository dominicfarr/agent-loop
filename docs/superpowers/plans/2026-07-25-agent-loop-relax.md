# agent-loop — Relax the loop to a single-writer, self-improving model

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the work-queue loop down to the operating model it actually runs
in — one writer, nothing consuming trunk, the loop improving its own repo — by
deleting all concurrency/multi-actor machinery and keeping a single guard: the
change's own tests must pass before it lands.

**Architecture:** `scripts/loop.sh` stays a source-only bash library and
`agent-loop-work.md` stays a thin orchestrator prompt, but both shrink by ~60%.
The `ci/issue-N` + GitHub-Actions gate, fast-forward choreography, and
freeze/Andon are removed. The `read_local_gates` seam — previously a "fast
pre-check" — is **promoted to the sole gate**: the commands under
`.gates.local` in the repo marker must all exit 0 before a change lands. For
this self-improving repo, that gate runs the library's own test suite, so a
red self-modification can never land and brick the next iteration.

**Tech Stack:** bash (source-only lib), `git`, `gh`, `jq`. No new dependencies.

## Global Constraints

- `loop.sh` is **source-only**: no top-level side effects beyond `set -euo pipefail`. The command and every test source it.
- The library is sourced into the **caller's shell, which is zsh** at runtime. Any refspec must avoid a `$var:` adjacency (zsh `:r` modifier). The surviving `land` uses a literal `HEAD`, so this is structural — do not reintroduce a `$sha:refs/...` form.
- Dependencies stay **`git` + `gh` + `jq` only**. Add nothing.
- **Operating model (do not re-add guards for absent problems):** ONE writer (the agent); nothing consumes trunk; the loop edits its OWN repo. The only surviving guard is self-preservation — tests-pass-before-land.
- `templates/agent-loop.json` (dropped into *adopted* repos) keeps `gates.local: []` — each adopter defines their own gate. Only **this** repo's `.claude/agent-loop.json` is wired to run the suite.
- **Do not touch** `scripts/init.sh` (the establish-trunk fix stays), `scripts/dev/seed-slugify-issue.sh`, or `templates/agent-loop.json`.

---

## File Structure

- **Modify** `plugins/agent-loop/scripts/loop.sh` — gut to the single-writer function set (target content given verbatim in Task 2/3).
- **Create** `plugins/agent-loop/scripts/test/run-all.sh` — globs and runs every `*_test.sh`; this repo's gate command.
- **Modify** `plugins/agent-loop/scripts/test/loop_git_test.sh` — slim to `working_tree_dirty` / `sync_rebase` / `land` / `discard_to_baseline`; delete ci-ref, ff-reject, and zsh-land blocks.
- **Modify** `plugins/agent-loop/scripts/test/loop_gh_test.sh` — delete `frozen` and `watch_gate` blocks; simplify the `claim` assertion.
- **Modify** `plugins/agent-loop/commands/agent-loop-work.md` — rewrite to the relaxed 0–7 protocol.
- **Modify** `.claude/agent-loop.json` (this repo's marker) — set `gates.local` to run `run-all.sh`.
- **Modify** `README.md` — drop ff-only / freeze / `ci/**` language; describe the local-gate model.

The **deleted** functions (removed across Tasks 2–3): `local_ahead_of_origin`,
`stray_ci_refs`, `publish_ci_ref`, `land_ff_only` (→ renamed `land`),
`cleanup_ci_ref`, `frozen`, `freeze`, `unfreeze`, `watch_gate`,
`open_bug_issue`. Renamed/kept-simpler: `land_ff_only`→`land` (no arg),
`claim` (drops the baseline arg).

---

### Task 1: Add the suite runner and wire it as this repo's gate

Additive — nothing breaks. Establishes the gate the later tasks rely on.

**Files:**
- Create: `plugins/agent-loop/scripts/test/run-all.sh`
- Modify: `.claude/agent-loop.json`

**Interfaces:**
- Produces: `run-all.sh` — exits `0` iff every `*_test.sh` in its directory exits `0`; the command later tasks put under `.gates.local`.

- [ ] **Step 1: Write the runner**

Create `plugins/agent-loop/scripts/test/run-all.sh`:

```bash
#!/usr/bin/env bash
# Run every *_test.sh in this directory; exit non-zero if any fails.
# This is the loop's self-preservation gate: no self-modification lands red.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for t in "$here"/*_test.sh; do
  echo ">> $(basename "$t")"
  bash "$t" || { echo "FAIL: $(basename "$t")" >&2; status=1; }
done
[ "$status" = 0 ] && echo "ALL GREEN"
exit "$status"
```

- [ ] **Step 2: Make it executable and run it (verify GREEN on today's suite)**

Run:
```bash
chmod +x plugins/agent-loop/scripts/test/run-all.sh
bash plugins/agent-loop/scripts/test/run-all.sh; echo "exit=$?"
```
Expected: all three current suites print, then `ALL GREEN`, `exit=0`.

- [ ] **Step 3: Wire this repo's marker gate**

Ensure the marker exists, then set `gates.local`:
```bash
[ -f .claude/agent-loop.json ] || cp plugins/agent-loop/templates/agent-loop.json .claude/agent-loop.json
tmp="$(mktemp)"
jq '.gates.local = ["bash plugins/agent-loop/scripts/test/run-all.sh"]' \
  .claude/agent-loop.json > "$tmp" && mv "$tmp" .claude/agent-loop.json
cat .claude/agent-loop.json
```
Expected: `.gates.local` is `["bash plugins/agent-loop/scripts/test/run-all.sh"]`.

- [ ] **Step 4: Verify the gate seam resolves the command**

Run:
```bash
source plugins/agent-loop/scripts/loop.sh
read_local_gates .claude/agent-loop.json
```
Expected output: `bash plugins/agent-loop/scripts/test/run-all.sh`

- [ ] **Step 5: Commit**

```bash
git add plugins/agent-loop/scripts/test/run-all.sh .claude/agent-loop.json
git commit -m "test(loop): add suite runner and wire it as this repo's gate"
```

---

### Task 2: Slim the git library and its tests to the single-writer set

Library and its test change together. This removes the ci-ref lifecycle, the
ff-only choreography (and its now-moot zsh guard), and `local_ahead_of_origin`;
renames `land_ff_only`→`land`.

**Files:**
- Modify: `plugins/agent-loop/scripts/loop.sh` (git section, lines 7–41)
- Modify: `plugins/agent-loop/scripts/test/loop_git_test.sh`

**Interfaces:**
- Produces: `working_tree_dirty` (unchanged), `sync_rebase` (`git pull --rebase origin main`), `land` (no arg; `git push origin HEAD:refs/heads/main`), `discard_to_baseline` (unchanged).
- Removes: `local_ahead_of_origin`, `stray_ci_refs`, `publish_ci_ref`, `land_ff_only`, `cleanup_ci_ref`.

- [ ] **Step 1: Rewrite the git test to the new API (write the failing test first)**

Replace the entire body of `plugins/agent-loop/scripts/test/loop_git_test.sh` (keep the header/`setup` scaffolding) so its assertions block reads exactly:

```bash
setup

# --- working_tree_dirty ---
working_tree_dirty && fail "clean tree reported dirty"
echo edit >> f.txt
working_tree_dirty || fail "dirty tree reported clean"
git checkout -q -- f.txt

# --- land: non-forced push advances origin/main to local HEAD ---
echo v1 > f.txt; git commit -qam "C1: local work (Refs: #1)"
sha="$(git rev-parse HEAD)"
land || fail "land rejected on a clean fast-forward"
git fetch -q origin main
[ "$(git rev-parse origin/main)" = "$sha" ] || fail "origin/main is not the landed SHA"

# --- land is refspec-safe under zsh (the /agent-loop-work shell) ---
# land uses a literal HEAD, so no $var:refs adjacency can trip zsh's :r modifier.
if command -v zsh >/dev/null 2>&1; then
  echo v2 > f.txt; git commit -qam "C2: zsh land (Refs: #1)"
  z="$(git rev-parse HEAD)"
  LOOP="$HERE/../loop.sh" zsh -c 'source "$LOOP"; land' \
    || fail "land failed when the library is sourced under zsh"
  git fetch -q origin main
  [ "$(git rev-parse origin/main)" = "$z" ] || fail "zsh land did not advance origin/main"
else
  echo "note: zsh not found — skipping zsh land guard" >&2
fi

# --- sync_rebase: pull a trunk that advanced, keeping local work on top ---
git clone -q "$root/origin.git" "$root/other"
( cd "$root/other" && git config user.email x@y.z && git config user.name o \
  && echo moved > g.txt && git add g.txt && git commit -qm "C3: trunk moved" \
  && git push -q origin HEAD:main )
echo local3 > f.txt; git commit -qam "C4: local work (Refs: #2)"
sync_rebase
git merge-base --is-ancestor "$(git rev-parse origin/main)" HEAD \
  || fail "sync_rebase did not put local work on top of advanced trunk"
land || fail "land after sync_rebase should succeed"

# --- discard_to_baseline: drop ungated commit AND staged changes, CLEAN tree ---
echo blocked-work > h.txt; git add h.txt; git commit -qm "C5: ungated (Refs: #3)"
echo more-staged > i.txt; git add i.txt
discard_to_baseline
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "discard_to_baseline did not return HEAD to origin/main"
[ -z "$(git status --porcelain)" ] || fail "discard_to_baseline left the tree dirty"

echo "PASS (git: single-writer land/sync/discard)"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash plugins/agent-loop/scripts/test/loop_git_test.sh; echo "exit=$?"`
Expected: FAIL — `land: command not found` (the library still defines `land_ff_only`, not `land`), `exit=1`.

- [ ] **Step 3: Rewrite the git section of the library**

In `plugins/agent-loop/scripts/loop.sh`, replace everything from the header comment through the `discard_to_baseline` line (the current lines 1–41, i.e. up to and including the `# --- GitHub queue layer (gh) ---` divider is NOT included) with:

```bash
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
```

(The `# --- GitHub queue layer (gh) ---` section and everything below it stays untouched in this task.)

- [ ] **Step 4: Run the git test to verify it passes**

Run: `bash plugins/agent-loop/scripts/test/loop_git_test.sh; echo "exit=$?"`
Expected: `PASS (git: single-writer land/sync/discard)`, `exit=0`.

- [ ] **Step 5: Confirm the gh test still passes (frozen/watch_gate untouched here)**

Run: `bash plugins/agent-loop/scripts/test/loop_gh_test.sh; echo "exit=$?"`
Expected: `PASS (gh: all queue-layer functions)`, `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add plugins/agent-loop/scripts/loop.sh plugins/agent-loop/scripts/test/loop_git_test.sh
git commit -m "refactor(loop): reduce git layer to single-writer land/sync/discard"
```

---

### Task 3: Remove the freeze primitive and CI-watch from the gh layer

Deletes `frozen`/`freeze`/`unfreeze`, `watch_gate`, and `open_bug_issue`;
simplifies `claim` to drop the recovery baseline.

**Files:**
- Modify: `plugins/agent-loop/scripts/loop.sh` (gh section)
- Modify: `plugins/agent-loop/scripts/test/loop_gh_test.sh`

**Interfaces:**
- Produces: `claim "$N"` (one arg; comment body `agent-loop: claiming.`), unchanged `pick_next` / `open_agent_issue` / `issue_has_label` / `block` / `close_item` / `file_bug` / `read_local_gates`.
- Removes: `frozen`, `freeze`, `unfreeze`, `watch_gate`, `open_bug_issue`.

- [ ] **Step 1: Update the gh test (write the failing test first)**

In `plugins/agent-loop/scripts/test/loop_gh_test.sh`:

(a) Change the `claim` assertion block (currently lines 55–59) to:
```bash
# --- claim emits the label swap + a claiming comment ---
: > "$GH_LOG"
claim 5
grep -qx 'issue edit 5 --remove-label todo --add-label agent' "$GH_LOG" || fail "claim label edit wrong"
grep -qx 'issue comment 5 --body agent-loop: claiming.' "$GH_LOG" || fail "claim comment wrong"
```

(b) Delete the `frozen` block (currently lines 71–73).

(c) Delete the `watch_gate` block (currently lines 82–96), leaving the
`read_local_gates` block and the final `echo "PASS ..."`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash plugins/agent-loop/scripts/test/loop_gh_test.sh; echo "exit=$?"`
Expected: FAIL at the claim comment assertion — the library still emits `agent-loop: claiming. baseline origin/main @ ...`, so `grep -qx 'agent-loop: claiming.'` does not match. `exit=1`.

- [ ] **Step 3: Edit the gh section of the library**

In `plugins/agent-loop/scripts/loop.sh`:

(a) Delete `open_bug_issue` (the line `open_bug_issue()   { _oldest_open bug; }`).

(b) Replace the `claim` function with:
```bash
# Claim: todo -> agent (WIP=1).
claim() {
  gh issue edit "$1" --remove-label todo --add-label agent
  gh issue comment "$1" --body "agent-loop: claiming."
}
```

(c) Delete the entire freeze block:
```bash
# --- fixing-mode freeze primitive (a DEPLOY_FREEZE repo variable) ---
frozen()   { [ "$(gh variable get DEPLOY_FREEZE 2>/dev/null || echo 0)" = "1" ]; }
freeze()   { gh variable set DEPLOY_FREEZE --body 1; }
unfreeze() { gh variable set DEPLOY_FREEZE --body 0; }
```

(d) Delete the entire `# --- CI-ref gate watch ---` block and the `watch_gate` function (through its closing `}`).

`read_local_gates` stays as the final function in the file.

- [ ] **Step 4: Run both suites via the runner**

Run: `bash plugins/agent-loop/scripts/test/run-all.sh; echo "exit=$?"`
Expected: all suites print, `ALL GREEN`, `exit=0`.

- [ ] **Step 5: Confirm no dangling references to deleted functions**

Run:
```bash
grep -nE 'watch_gate|publish_ci_ref|cleanup_ci_ref|stray_ci_refs|land_ff_only|local_ahead_of_origin|open_bug_issue|frozen|freeze|unfreeze' \
  plugins/agent-loop/scripts/loop.sh plugins/agent-loop/scripts/test/*.sh || echo "clean"
```
Expected: `clean` (no matches).

- [ ] **Step 6: Commit**

```bash
git add plugins/agent-loop/scripts/loop.sh plugins/agent-loop/scripts/test/loop_gh_test.sh
git commit -m "refactor(loop): drop freeze primitive and CI-watch from gh layer"
```

---

### Task 4: Rewrite the work command to the relaxed protocol

**Files:**
- Modify: `plugins/agent-loop/commands/agent-loop-work.md`

**Interfaces:**
- Consumes: every function the slimmed `loop.sh` still defines (Tasks 2–3). References no deleted function.

- [ ] **Step 1: Replace the command body**

Replace everything in `plugins/agent-loop/commands/agent-loop-work.md` **below the YAML frontmatter** with:

```markdown
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
```

- [ ] **Step 2: Verify the command references only surviving functions**

Run:
```bash
grep -oE '`[a-z_]+ ?[^`]*`' plugins/agent-loop/commands/agent-loop-work.md \
  | grep -oE '\b(watch_gate|publish_ci_ref|cleanup_ci_ref|land_ff_only|freeze|unfreeze|frozen|open_bug_issue|stray_ci_refs)\b' \
  && echo "DANGLING REFERENCE" || echo "clean"
```
Expected: `clean`.

- [ ] **Step 3: Commit**

```bash
git add plugins/agent-loop/commands/agent-loop-work.md
git commit -m "docs(loop): rewrite work protocol for the single-writer model"
```

---

### Task 5: Update the README to match the relaxed model

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the "Drain the queue" section**

In `README.md`, replace the `## Drain the queue` section (its heading and the
three paragraphs under it, down to but not including `## Design & roadmap`) with:

```markdown
## Drain the queue

In an adopted repo, run `/agent-loop-work` to make one pass of the loop. It
recovers any interrupted run, claims the oldest `bug` (else oldest `todo`) with
WIP=1, implements it on trunk test-first, and lands it with a plain
non-forced push.

The loop runs a deliberately **single-writer** model: one agent, no concurrent
writers, nothing consuming trunk. The one guard is self-preservation — a
change's own tests must pass before it lands. Define that gate in
`.claude/agent-loop.json` under `gates.local`: each listed command must exit `0`
before a change lands (e.g. a script that runs your test suite). An empty
`gates.local` opts out of gating entirely.

```

- [ ] **Step 2: Verify no stale guarantees remain in the README**

Run:
```bash
grep -niE 'fast-forward|ff-only|freeze|fixing-mode|ci/\*\*|gate the change on' README.md \
  && echo "STALE COPY — revise" || echo "clean"
```
Expected: `clean`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe the single-writer local-gate model in the README"
```

---

### Task 6: Full-suite green + end-to-end self-check

Final verification that the reduced loop is internally consistent.

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite through the gate command**

Run: `bash plugins/agent-loop/scripts/test/run-all.sh; echo "exit=$?"`
Expected: `ALL GREEN`, `exit=0`.

- [ ] **Step 2: Confirm the loop library is fully self-consistent**

Run:
```bash
bash -n plugins/agent-loop/scripts/loop.sh && echo "syntax ok"
source plugins/agent-loop/scripts/loop.sh && \
  for f in working_tree_dirty sync_rebase land discard_to_baseline pick_next \
           open_agent_issue issue_has_label claim block close_item file_bug \
           read_local_gates; do
    type "$f" >/dev/null 2>&1 || echo "MISSING: $f"
  done; echo "surface checked"
```
Expected: `syntax ok`, `surface checked`, no `MISSING:` lines.

- [ ] **Step 3: Confirm the marker gate resolves and runs**

Run:
```bash
source plugins/agent-loop/scripts/loop.sh
for cmd in $(read_local_gates .claude/agent-loop.json | head -1); do :; done
eval "$(read_local_gates .claude/agent-loop.json)"; echo "gate exit=$?"
```
Expected: the runner executes, `ALL GREEN`, `gate exit=0`.

- [ ] **Step 4: No commit** — verification only. If any check failed, return to the owning task.

---

## Self-Review

**Spec coverage** (against the agreed keep/delete model):
- Keep queue + WIP=1 → `pick_next`, `open_agent_issue`, `claim`, `block`, `close_item`, `file_bug` retained (Task 3). ✓
- Keep `working_tree_dirty` guard → retained + tested (Task 2), used in PICK (Task 4). ✓
- Promote `read_local_gates` to the sole gate → Task 1 wires it; Task 4 GATE step runs it; Task 6 executes it. ✓
- Delete concurrency machinery (ff-only, sync-choreography, ci-ref dance, freeze/Andon, `local_ahead_of_origin`) → Tasks 2–3, verified clean by grep (Task 3 Step 5). ✓
- Keep one self-preservation guard (tests before land) → the marker gate runs `run-all.sh` (Task 1); protocol lands only on green (Task 4). ✓
- Preserve cheap seams for "tomorrow" → issues-as-queue, `Refs: #N` commits, `gates.local` config all retained. ✓
- Leave `init.sh`, seed helper, `templates/agent-loop.json` untouched → stated in Global Constraints; no task modifies them. ✓
- zsh refspec safety preserved structurally → `land` uses literal `HEAD`; Task 2 keeps a zsh guard test. ✓

**Placeholder scan:** no TBD/TODO; every code step shows full content; deletions specify exact functions/line-ranges. ✓

**Type/name consistency:** `land` (no arg) used consistently in Task 2 test, library, and Task 4 protocol; `claim` takes one arg in Task 3 test, library, and protocol; deleted-function list matches across Tasks 2, 3, 4, 5 grep guards. ✓
