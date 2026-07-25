# agent-loop — Plan 2: `/work-queue` orchestrator + guardrails

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `/agent-loop-work` command — an autonomous work-queue
orchestrator that drains a repo's issue queue onto trunk using the model-Y
protocol (steps 0–7), with all dangerous git/gh mechanics living in a tested
bash library and the LLM only orchestrating and making judgment calls.

**Architecture:** Same split as Plan 1's `init`: a thin slash command
(`/agent-loop-work`) sources a deterministic, testable bash library
(`scripts/loop.sh`) for every mechanical operation — issue selection, label
transitions, the CI-ref lifecycle, fast-forward-only landing, hard-reset
discard/recovery, and the freeze primitive. The library's model-Y **git** invariants are
unit-tested offline against local bare repos; its **gh** wrappers are tested by
stubbing `gh` on `PATH`; the assembled loop is proven end-to-end by a plumbing
smoke test against a throwaway GitHub repo. The command markdown is the
orchestrator prompt that calls these functions and owns only the judgment calls
(fix-forward vs. block; revert vs. hotfix; what to implement).

**Tech Stack:** Claude Code plugin command (markdown), Bash (`set -euo pipefail`,
sourced function library), `git` plumbing, `gh` CLI (issues, labels, variables,
`run watch`), `jq` (marker + issue JSON), plain-bash test harness (bare-repo
fixtures + a stubbed `gh`).

> **Amendments (post-implementation, from review).** The listings below were
> corrected to match the shipped, reviewed code: (1) `issue_has_label` uses a
> single `gh --jq` expression (real `gh` takes one); (2) `publish_ci_ref`
> **force**-pushes the disposable `ci/*` ref (never `main`) so re-gate and
> stale-ref recovery work; (3) `watch_gate` binds to the gated HEAD SHA so a
> re-gate never mistakes an earlier attempt's run for this one (would land
> un-gated code); (4) `discard_to_baseline` (`git reset --hard`) replaced
> `reset_soft_baseline` on the RECOVER/BLOCKED discard paths — soft-reset left
> the tree dirty and wedged the loop. `loop.sh` and its tests are the source of
> truth.

## Global Constraints

- **Model-Y invariant — `gate-SHA == land-SHA`:** the commit that passed the CI-ref gate is the exact commit landed. **Never** rebase or merge after the gate. (Design §Gate mechanics)
- **Fast-forward-only, never forced:** landing pushes ff-only; a rejected push (trunk moved) fails safe and the item redoes from rebase. No `--force`, ever. (Design §Gate mechanics)
- **Sync before the gate, never after:** rebase local `main` onto `origin/main` immediately *before* publishing the CI ref, so the gate runs on real trunk + change. (Design §Gate mechanics)
- **WIP = 1, behavioral:** never claim while any open issue carries `agent`; resume such an issue on startup (crash recovery). (Design §Kanban states)
- **The CI branch is a pure artifact:** `ci/issue-N` exists only for the gate window; delete it (remote-only) after landing. Work never lives on a long-lived branch. (Design §Gate mechanics)
- **Priority:** oldest open `bug` preempts oldest `todo` (both FIFO by issue number). (Design §Per-run steps §1)
- **Dirty working tree → stop and report** — a human is mid-edit; never proceed. (Design §Per-run steps §1)
- **Two-tier failure:** per-item gate red is *not* an incident (fix-forward or block; trunk stays green). Only **trunk red** triggers fixing-mode. (Design §Two-tier failure)
- **Fixing-mode is best-effort in v1:** freeze → file `bug` → preempt → gated revert/hotfix → confirm green → unfreeze. Mid-incident crash recovery is manual (step 0 detects freeze + open `bug`). (Design §Fixing-mode)
- **Commit convention:** every work-item commit footer carries `Refs: #N` (Conventional Commits). (CONTRIBUTING.md)
- **Label set is exactly** `todo`, `agent`, `blocked`, `bug` (created by Plan 1's `init`). This plan reads/writes them; it never invents new ones. (Design §Kanban states)
- **Dependencies:** `git`, `gh` (authenticated), `jq`. Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- **`loop.sh` is source-only** — a function library with no top-level side effects, so the command and the tests can source it safely.

---

## File structure (this plan)

- Create: `plugins/agent-loop/scripts/loop.sh` — the deterministic loop library (git + gh mechanics, source-only)
- Create: `plugins/agent-loop/scripts/test/loop_git_test.sh` — offline model-Y invariant tests (local bare repos)
- Create: `plugins/agent-loop/scripts/test/loop_gh_test.sh` — gh-layer + config tests (stubbed `gh`)
- Create: `plugins/agent-loop/scripts/test/smoke_loop.sh` — end-to-end plumbing smoke test against a scratch GitHub repo (manual/opt-in)
- Create: `plugins/agent-loop/commands/agent-loop-work.md` — the `/agent-loop-work` orchestrator command
- Modify: `plugins/agent-loop/templates/agent-loop.json` — add the optional `gates.local` seam
- Modify: `README.md` — document `/agent-loop-work`

**Naming:** the command is `/agent-loop-work` (the design's `/work-queue`, under
the `agent-loop-*` flat command convention Plan 1 established with
`/agent-loop-init`). The library exposes: `working_tree_dirty`,
`local_ahead_of_origin`, `stray_ci_refs`, `sync_rebase`, `publish_ci_ref`,
`land_ff_only`, `cleanup_ci_ref`, `discard_to_baseline`, `pick_next`,
`open_agent_issue`, `open_bug_issue`, `issue_has_label`, `claim`, `block`,
`close_item`, `file_bug`, `frozen`, `freeze`, `unfreeze`, `read_local_gates`,
`watch_gate`.

---

### Task 1: Git plumbing — model-Y invariants (TDD, offline)

**Files:**
- Create: `plugins/agent-loop/scripts/loop.sh` (git-only half)
- Create: `plugins/agent-loop/scripts/test/loop_git_test.sh`

**Interfaces:**
- Produces: source-only `loop.sh` exposing the **git** functions —
  `working_tree_dirty` (true iff `git status --porcelain` non-empty),
  `local_ahead_of_origin` (prints count of commits `origin/main..HEAD`),
  `stray_ci_refs` (prints any `ci/*` refs on origin, one per line),
  `sync_rebase` (`git pull --rebase origin main`),
  `publish_ci_ref N` (push `HEAD` to `origin refs/heads/ci/issue-N`),
  `land_ff_only SHA` (ff-only push `SHA` to `origin main`; non-zero ⇒ trunk moved),
  `cleanup_ci_ref N` (delete remote `ci/issue-N`),
  `discard_to_baseline` (`git reset --hard origin/main` — clean tree).
  Task 2 appends the gh half to the same file; Task 3's command sources it.

- [ ] **Step 1: Write the failing test (setup helper + working-tree + ahead-of-origin)**

Create `plugins/agent-loop/scripts/test/loop_git_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../loop.sh
source "$HERE/../loop.sh"   # sourcing must NOT run anything (source-only lib)

fail() { echo "FAIL: $1" >&2; exit 1; }

# Build a bare "origin" with main@C0 and a working clone; cd into the clone.
setup() {
  root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT
  git init -q --bare "$root/origin.git"
  git clone -q "$root/origin.git" "$root/work"
  cd "$root/work"
  git config user.email a@b.c; git config user.name t
  echo v0 > f.txt; git add f.txt; git commit -qm "C0: seed"
  git push -q origin HEAD:main
  git branch -q --set-upstream-to=origin/main main 2>/dev/null || true
}

# A second, independent clone that can advance origin/main behind our back.
advance_origin() {
  git clone -q "$root/origin.git" "$root/other"
  ( cd "$root/other" && git config user.email x@y.z && git config user.name o \
    && echo moved > g.txt && git add g.txt && git commit -qm "C2: trunk moved" \
    && git push -q origin HEAD:main )
}

setup

# --- working_tree_dirty ---
working_tree_dirty && fail "clean tree reported dirty"
echo edit >> f.txt
working_tree_dirty || fail "dirty tree reported clean"
git checkout -q -- f.txt   # back to clean

# --- local_ahead_of_origin ---
[ "$(local_ahead_of_origin)" = "0" ] || fail "expected 0 ahead after clone"
echo v1 > f.txt; git commit -qam "C1: local work (Refs: #1)"
[ "$(local_ahead_of_origin)" = "1" ] || fail "expected 1 ahead after local commit"

echo "PASS (git: tree + ahead)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/agent-loop/scripts/test/loop_git_test.sh`
Expected: FAIL — `loop.sh` does not exist (`source` error / `working_tree_dirty: command not found`).

- [ ] **Step 3: Write the minimal `loop.sh` git half**

Create `plugins/agent-loop/scripts/loop.sh`:

```bash
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

# Publish the current commit as the CI ref for issue N (a disposable per-attempt
# artifact). Force is safe here — the never-force invariant applies to main only,
# and this must succeed even when a re-gate rebased HEAD off the old ci ref, or a
# stale ref survives a dead run.
publish_ci_ref() { git push --force origin "HEAD:refs/heads/ci/issue-$1"; }

# Fast-forward-only land of the gated SHA. Never forced. Non-zero ⇒ trunk moved.
land_ff_only() { git push origin "$1:refs/heads/main"; }

# Delete the remote-only CI ref for issue N after landing.
cleanup_ci_ref() { git push origin --delete "ci/issue-$1"; }

# Discard ALL local divergence from origin/main — ungated commits AND their
# working-tree/staged changes — leaving a clean tree at the trunk tip. Used by
# RECOVER (dead-run leftovers) and BLOCKED (abandon partial work).
discard_to_baseline() { git fetch -q origin main && git reset --hard origin/main; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash plugins/agent-loop/scripts/test/loop_git_test.sh`
Expected: `PASS (git: tree + ahead)`.

- [ ] **Step 5: Extend the test — CI-ref lifecycle + ff-only land + reject + sync-then-land + reset-soft**

In `loop_git_test.sh`, replace the final `echo "PASS (git: tree + ahead)"` line with:

```bash
# --- publish_ci_ref / stray_ci_refs / cleanup_ci_ref ---
publish_ci_ref 1
stray_ci_refs | grep -q 'refs/heads/ci/issue-1' || fail "ci/issue-1 not on origin"
cleanup_ci_ref 1
[ -z "$(stray_ci_refs)" ] || fail "ci/issue-1 not cleaned up"

# --- land_ff_only: happy path (origin/main unchanged) ---
sha="$(git rev-parse HEAD)"
land_ff_only "$sha" || fail "ff-only land rejected on clean fast-forward"
git fetch -q origin main
[ "$(git rev-parse origin/main)" = "$sha" ] || fail "origin/main is not the landed SHA"

# --- land_ff_only: reject when trunk moved under us ---
echo v2 > f.txt; git commit -qam "C3: more local work (Refs: #2)"
c3="$(git rev-parse HEAD)"
advance_origin
if land_ff_only "$c3"; then fail "ff-only land should have been REJECTED (trunk moved)"; fi

# --- sync_rebase then land: the mid-flight-move recovery ---
sync_rebase
rebased="$(git rev-parse HEAD)"
land_ff_only "$rebased" || fail "land after sync_rebase should succeed"
git fetch -q origin main
[ "$(git rev-parse origin/main)" = "$rebased" ] || fail "rebased SHA did not land"
git merge-base --is-ancestor "$c3" HEAD && fail "pre-rebase SHA must not be trunk (gate-SHA==land-SHA)" || true

# --- discard_to_baseline: drop ungated commit AND staged changes, clean tree ---
echo blocked-work > h.txt; git add h.txt; git commit -qm "C4: ungated (Refs: #3)"
echo more > i.txt; git add i.txt   # a staged change on top of the ungated commit
discard_to_baseline
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "discard did not return HEAD to origin/main"
[ -z "$(git status --porcelain)" ] || fail "discard left the tree dirty"

echo "PASS (git: all model-Y invariants)"
```

- [ ] **Step 6: Run the extended test — expect PASS (the git half is already implemented)**

Run: `bash plugins/agent-loop/scripts/test/loop_git_test.sh`
Expected: `PASS (git: all model-Y invariants)`. If the reject or reset-soft
assertions fail, the library — not the test — is wrong; fix `loop.sh`.

- [ ] **Step 7: Commit**

```bash
git add plugins/agent-loop/scripts/loop.sh plugins/agent-loop/scripts/test/loop_git_test.sh
git commit -m "feat(loop): model-Y git mechanics with offline invariant tests"
```

---

### Task 2: GitHub queue layer + config seam (stubbed-gh tests)

**Files:**
- Modify: `plugins/agent-loop/scripts/loop.sh` (append the gh half)
- Modify: `plugins/agent-loop/templates/agent-loop.json` (add `gates.local` seam)
- Create: `plugins/agent-loop/scripts/test/loop_gh_test.sh`

**Interfaces:**
- Consumes: nothing from Task 1 at runtime (same file, independent functions).
- Produces: the **gh** functions —
  `pick_next` (prints oldest open `bug` number, else oldest open `todo`, else empty),
  `open_agent_issue` / `open_bug_issue` (prints oldest open issue with that label, else empty),
  `issue_has_label N LABEL` (prints `true`/`false`),
  `claim N BASESHA` (removes `todo`, adds `agent`, comments the baseline),
  `block N REASON` (comments, swaps `agent`→`blocked`),
  `close_item N BODY` (closes as completed with a comment),
  `file_bug TITLE BODY` (creates an issue labeled `bug`, prints its URL),
  `frozen` (true iff `DEPLOY_FREEZE` repo var is `1`), `freeze` / `unfreeze` (set it),
  `read_local_gates [MARKER]` (prints each `.gates.local[]` command, empty if absent),
  `watch_gate N` (blocks on the `ci/issue-N` run; non-zero if red).
  Task 3's command consumes all of these.

- [ ] **Step 1: Add the `gates.local` seam to the marker template**

Replace the contents of `plugins/agent-loop/templates/agent-loop.json` with:

```json
{
  "adoptedBy": "agent-loop",
  "version": 1,
  "gates": {
    "local": []
  }
}
```

`gates.local` is an ordered list of shell commands the loop runs locally as a
fast pre-gate before publishing the CI ref (each must exit 0). Empty by default
— the authoritative gate is always the `ci/**` CI run.

- [ ] **Step 2: Write the failing test (fake `gh` on PATH + pick_next ordering)**

Create `plugins/agent-loop/scripts/test/loop_gh_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../loop.sh
source "$HERE/../loop.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- fake gh: logs every invocation, emits fixtures, honours --jq (via real jq) ---
bin="$(mktemp -d)"; export GH_LOG="$bin/log"; : > "$GH_LOG"
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
prev= ; jqexpr= ; label=
for a in "$@"; do
  case "$prev" in --jq) jqexpr="$a";; --label) label="$a";; esac
  prev="$a"
done
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s' "$1"; fi; }
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  case "$label" in
    bug)   emit "${FIX_BUG:-[]}";;
    todo)  emit "${FIX_TODO:-[]}";;
    agent) emit "${FIX_AGENT:-[]}";;
    *)     emit "[]";;
  esac
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then emit "${FIX_VIEW:-{\"labels\":[]}}"; exit 0; fi
if [ "${1:-}" = "variable" ] && [ "${2:-}" = "get" ]; then
  [ -n "${FIX_VAR:-}" ] && { printf '%s' "$FIX_VAR"; exit 0; } || exit 1
fi
exit 0
EOF
chmod +x "$bin/gh"
export PATH="$bin:$PATH"

# --- pick_next: bug preempts todo, oldest (lowest number) wins ---
FIX_BUG='[{"number":7},{"number":3}]' FIX_TODO='[{"number":2}]'
[ "$(pick_next)" = "3" ] || fail "pick_next should prefer oldest bug (3)"
FIX_BUG='[]' FIX_TODO='[{"number":9},{"number":2}]'
[ "$(FIX_BUG='[]' pick_next)" = "2" ] || fail "pick_next should fall back to oldest todo (2)"
[ "$(FIX_BUG='[]' FIX_TODO='[]' pick_next)" = "" ] || fail "pick_next should be empty when queue is empty"

echo "PASS (gh: pick_next)"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash plugins/agent-loop/scripts/test/loop_gh_test.sh`
Expected: FAIL — `pick_next: command not found` (gh half not written yet).

- [ ] **Step 4: Append the gh half to `loop.sh`**

Append to `plugins/agent-loop/scripts/loop.sh`:

```bash

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

# Prints "true"/"false": does issue N carry LABEL? (real `gh --jq` takes a
# single expression; LABEL is a fixed vocabulary — todo/agent/blocked/bug.)
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
```

- [ ] **Step 5: Run the pick_next test to verify it passes**

Run: `bash plugins/agent-loop/scripts/test/loop_gh_test.sh`
Expected: `PASS (gh: pick_next)`.

- [ ] **Step 6: Extend the test — command emission, issue_has_label, frozen, read_local_gates**

In `loop_gh_test.sh`, replace the final `echo "PASS (gh: pick_next)"` line with:

```bash
# --- claim emits the right gh calls ---
: > "$GH_LOG"
claim 5 abc1234
grep -qx 'issue edit 5 --remove-label todo --add-label agent' "$GH_LOG" || fail "claim label edit wrong"
grep -q  'issue comment 5 --body agent-loop: claiming. baseline origin/main @ abc1234' "$GH_LOG" || fail "claim comment wrong"

# --- block emits comment + label swap ---
: > "$GH_LOG"
block 5 "needs a secret"
grep -qx 'issue edit 5 --remove-label agent --add-label blocked' "$GH_LOG" || fail "block label swap wrong"
grep -q  'issue comment 5 --body agent-loop: BLOCKED. needs a secret' "$GH_LOG" || fail "block comment wrong"

# --- issue_has_label reads the labels array ---
[ "$(FIX_VIEW='{"labels":[{"name":"bug"}]}' issue_has_label 5 bug)" = "true" ]  || fail "issue_has_label true case"
[ "$(FIX_VIEW='{"labels":[{"name":"todo"}]}' issue_has_label 5 bug)" = "false" ] || fail "issue_has_label false case"

# --- frozen reflects the repo variable ---
FIX_VAR=1 frozen  || fail "frozen should be true when DEPLOY_FREEZE=1"
if frozen; then fail "frozen should be false when DEPLOY_FREEZE is unset"; fi

# --- read_local_gates parses the marker (no gh involved) ---
m="$bin/agent-loop.json"
printf '{"gates":{"local":["npm test","npm run lint"]}}' > "$m"
[ "$(read_local_gates "$m" | tr '\n' '|')" = "npm test|npm run lint|" ] || fail "read_local_gates list wrong"
printf '{"version":1}' > "$m"
[ -z "$(read_local_gates "$m")" ] || fail "read_local_gates should be empty when absent"

echo "PASS (gh: all queue-layer functions)"
```

- [ ] **Step 7: Run the extended test — expect PASS**

Run: `bash plugins/agent-loop/scripts/test/loop_gh_test.sh`
Expected: `PASS (gh: all queue-layer functions)`.

- [ ] **Step 8: Commit**

```bash
git add plugins/agent-loop/scripts/loop.sh plugins/agent-loop/scripts/test/loop_gh_test.sh plugins/agent-loop/templates/agent-loop.json
git commit -m "feat(loop): gh queue layer, freeze primitive, and local-gate seam"
```

---

### Task 3: The `/agent-loop-work` orchestrator + end-to-end smoke test

**Files:**
- Create: `plugins/agent-loop/commands/agent-loop-work.md`
- Create: `plugins/agent-loop/scripts/test/smoke_loop.sh`

**Interfaces:**
- Consumes: every function from Tasks 1–2, via
  `source "${CLAUDE_PLUGIN_ROOT}/scripts/loop.sh"`.
- Produces: the `/agent-loop-work` slash command (the protocol steps 0–7 +
  fixing-mode as an orchestrator prompt) and `smoke_loop.sh`, an opt-in test
  that drives the plumbing path (claim → publish CI ref → land → close) against
  a real throwaway GitHub repo, with **no** LLM implement phase.

- [ ] **Step 1: Write the smoke test (plumbing path, real GitHub, opt-in)**

Create `plugins/agent-loop/scripts/test/smoke_loop.sh`:

```bash
#!/usr/bin/env bash
# End-to-end plumbing smoke test against a THROWAWAY GitHub repo.
# Opt-in (hits the network + creates/deletes a repo): run explicitly.
#   bash plugins/agent-loop/scripts/test/smoke_loop.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../loop.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

name="agent-loop-loop-smoketest-$$"
work="$(mktemp -d)"; cd "$work"
git init -q; git config user.email a@b.c; git config user.name t
echo "# $name" > README.md; git add README.md; git commit -qm "C0: seed"
gh repo create "$name" --private --source=. --remote=origin --push >/dev/null
cleanup() { gh repo delete "$name" --yes >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

# labels + a todo item (mirrors what init + a human would set up)
for l in todo agent blocked bug; do gh label create "$l" --force >/dev/null; done
issue_url="$(gh issue create --title "smoke: add a line" --body "acceptance: file changed" --label todo)"
N="${issue_url##*/}"

# --- drive the plumbing path (no LLM) ---
[ "$(pick_next)" = "$N" ] || fail "pick_next did not return the todo ($N)"
base="$(git rev-parse origin/main)"
claim "$N" "$base"
[ "$(open_agent_issue)" = "$N" ] || fail "issue not claimed as agent"

echo "a change" >> README.md; git commit -qam "feat: smoke change (Refs: #$N)"
sync_rebase
publish_ci_ref "$N"
stray_ci_refs | grep -q "ci/issue-$N" || fail "CI ref not published"

sha="$(git rev-parse HEAD)"
land_ff_only "$sha" || fail "ff-only land failed on green trunk"
cleanup_ci_ref "$N"
[ -z "$(stray_ci_refs)" ] || fail "CI ref not cleaned up after land"
close_item "$N" "landed $sha"
[ "$(gh issue view "$N" --json state --jq .state)" = "CLOSED" ] || fail "issue not closed"

echo "PASS (smoke: end-to-end plumbing against $name)"
```

- [ ] **Step 2: Run the smoke test against real GitHub**

Run: `bash plugins/agent-loop/scripts/test/smoke_loop.sh`
Expected: `PASS (smoke: end-to-end plumbing against agent-loop-loop-smoketest-<pid>)`,
and the scratch repo is auto-deleted on exit. (Requires `gh auth status` OK and
the `delete_repo` scope; if deletion is denied, delete the repo manually.)

- [ ] **Step 3: Write the `/agent-loop-work` command**

Create `plugins/agent-loop/commands/agent-loop-work.md`:

```markdown
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
  run. Discard them: `discard_to_baseline`.
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
`discard_to_baseline` (drop the partial work, clean tree), and
`cleanup_ci_ref "$N"` if you published one this run. Return to PICK.

**FIXING-MODE (trunk red — Andon stop-the-line).** `freeze` immediately. If no
`bug` issue exists yet for this breakage, `file_bug "trunk red: <signal>"
"<what broke / offending SHA / revert-or-hotfix decision>"`. Then treat that
`bug` as the claimed item and drive it through IMPLEMENT→GATE→LAND as a normal
gated change — reverting the offending commit or hotfixing forward, your call.
On green land of the fix, `unfreeze` (handled by LAND above). In v1, if you crash
mid-incident, the next run's RECOVER re-enters here via the freeze + open `bug`.
```

- [ ] **Step 4: Reinstall and confirm the command is discoverable**

```
/plugin marketplace update rsi-agent-loop
```

Expected: `/agent-loop-work` appears alongside `/agent-loop-init` (`/help` or
typing `/agent-loop`).

- [ ] **Step 5: Manual acceptance (interactive, one item end-to-end)**

In a scratch repo that has been through `/agent-loop-init`, file one sharp `todo`
issue, then run `/agent-loop-work`. Expected: the agent claims it (label →
`agent`), implements with a test, gates on `ci/**`, lands ff-only, closes the
issue as completed, and deletes the `ci/issue-N` ref. This exercises the LLM
orchestration that the bash tests cannot. (No new file — this is an operator
check; record the outcome in the PR/commit message.)

- [ ] **Step 6: Commit**

```bash
git add plugins/agent-loop/commands/agent-loop-work.md plugins/agent-loop/scripts/test/smoke_loop.sh
git commit -m "feat(loop): /agent-loop-work orchestrator + end-to-end smoke test"
```

---

### Task 4: Docs

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above (`/agent-loop-work`, the model-Y guarantees).

- [ ] **Step 1: Document `/agent-loop-work` in the README**

In `README.md`, immediately after the "Adopt a repo" section, add:

```markdown
## Drain the queue

In an adopted repo, run `/agent-loop-work` to make one pass of the loop. It
recovers any interrupted run, claims the oldest `bug` (else oldest `todo`) with
WIP=1, implements it on trunk test-first, gates the change on your `ci/**`
workflows, and lands it **fast-forward-only** — so the commit that passed the
gate is exactly the commit on `main`. A per-item gate failure just blocks or
fix-forwards (trunk stays green); a **trunk** failure trips fixing-mode
(freeze → file a `bug` → gated revert/hotfix → unfreeze).

Author your own gates as `ci/**`-triggered workflows; the loop watches the
aggregate run, so a new gate is enforced with no loop change. Optional fast local
pre-checks go in `.claude/agent-loop.json` under `gates.local`.
```

Then update the closing line of the "Design & roadmap" section: replace
"`/work-queue` and the phase agents follow" with "the phase agents (grill-me,
walking-skeleton) follow in Plan 3."

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document /agent-loop-work"
```

---

## Self-Review

**Spec coverage (Plan 2's slice):**
- Per-run steps 0–7 → Task 3 command, one section each. ✅
- Model-Y gate mechanics (sync-before, gate-SHA==land-SHA, ff-only-never-forced, CI ref is a pure artifact) → Task 1 functions + invariant tests (reject + sync-then-land + reset-soft all asserted). ✅
- Kanban states / WIP=1 / priority (bug preempts todo, FIFO) → Task 2 `pick_next`/`open_agent_issue` + Task 3 RECOVER/PICK. ✅
- Two-tier failure → Task 3 GATE (per-item: fix-forward/block) vs. FIXING-MODE (trunk). ✅
- Fixing-mode (freeze → bug → preempt → gated fix → unfreeze; best-effort recovery) → Task 2 `frozen/freeze/unfreeze/file_bug` + Task 3 FIXING-MODE & RECOVER. ✅
- Guardrails (hard-reset discard on block; recover ungated commits + stray ci refs; dirty-tree guard; ff-only) → Task 1 `discard_to_baseline`/`local_ahead_of_origin`/`stray_ci_refs`/`working_tree_dirty`/`land_ff_only`, wired in Task 3. ✅
- Gates author-your-own, self-declaring; local via marker-config list → Task 2 `read_local_gates` + `watch_gate`, `gates.local` seam; Task 4 docs. ✅
- Phase agents (grill-me, walking-skeleton), TDD dispatch → **intentionally out of Plan 2** (Plan 3); IMPLEMENT is a direct test-first step with a forward pointer.

**Placeholder scan:** every step has concrete file content, commands, and
expected output. IMPLEMENT's "implement directly" is a deliberate v1 behavior
(phase dispatch is Plan 3), not an unfilled blank. No TBD/TODO. ✅

**Type/name consistency:** function names are identical across the library
(Tasks 1–2), the tests, the smoke test, and the command (Task 3):
`working_tree_dirty`, `local_ahead_of_origin`, `stray_ci_refs`, `sync_rebase`,
`publish_ci_ref`, `land_ff_only`, `cleanup_ci_ref`, `discard_to_baseline`,
`pick_next`, `open_agent_issue`, `open_bug_issue`, `issue_has_label`, `claim`,
`block`, `close_item`, `file_bug`, `frozen`/`freeze`/`unfreeze`,
`read_local_gates`, `watch_gate`. Command `/agent-loop-work`; library path
`${CLAUDE_PLUGIN_ROOT}/scripts/loop.sh`. ✅

## Follow-on plan (not yet written)

- **Plan 3 — Phase agents + TDD wiring**: grill-me (Shape) agent, walking-skeleton
  (Inception) agent, TDD skill wiring, and spine dispatch from IMPLEMENT.
