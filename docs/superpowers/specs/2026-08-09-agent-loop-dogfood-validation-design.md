# Dogfood validation of the single-writer loop — design

**Date:** 2026-08-09
**Status:** approved (brainstorming)
**Goal:** See the relaxed single-writer loop actually build something real, for
the first time, by pointing it at its own repo. This is both the first live
exercise of the loop and true dogfooding — the loop editing the very repo that
defines it, gated by that repo's real test suite.

## Why this shape

- The loop has never been used to build anything. Prior runs (`dom-loop-test-3`,
  see `logs.txt`) exercised the *old* CI-gated machinery and surfaced the zsh
  `:r` bug that motivated `land`'s literal-`HEAD` refspec. Nothing has validated
  the *relaxed* model end-to-end.
- Dogfooding this repo is the design's north star: "the loop improves its own
  repo." The real `run-all.sh` gate makes a bad landing safe — a red suite
  blocks the push, so the worst case is a `blocked` issue, not corrupted trunk.
- Single writer, private repo, one watched pass: maximum learning from first
  contact, minimum blast radius.

## Setup (one-time)

1. Publish this repo private and wire `origin`:
   `gh repo create dominicfarr/agent-loop --private --source=. --remote=origin --push`
2. Run `/agent-loop-init` once to create the GitHub kanban labels
   (`todo`/`agent`/`blocked`/`bug`). It is idempotent and never overwrites local
   files; the marker and `gates.local` already exist.
3. Confirm preconditions: `origin/main` is the trunk baseline; `gh auth status`
   is green (account `dominicfarr`); `.claude/agent-loop.json` gates on
   `bash plugins/agent-loop/scripts/test/run-all.sh`.

## First work item — retry circuit-breaker

A real backlog item (`feature-ideas.md` → *Agent-loop failure-mode hardening*),
chosen because it is small, self-contained, test-first-friendly, and exercises
the real gate.

### The hole it closes

In the relaxed protocol a gate failure already routes to `BLOCKED` (step 7), so
a failing item leaves the `todo`/`bug` queue — no infinite retry there. The
actual unbounded-retry hole is the **RECOVER path (step 0)**: if a session
crashes *mid-item* it leaves the issue labelled `agent`; the next run re-claims
it via `open_agent_issue` + `discard_to_baseline` and retries. A poisoned item
that crashes the session every time is retried forever.

### Behaviour

- The loop is stateless between runs, so the attempt count must live in **GitHub
  state**. The circuit-breaker introduces a recovery marker comment: on each
  RECOVER the loop posts a distinct comment (`agent-loop: recovery attempt <k>`),
  and the count is the number of such comments on the issue.
- A new library function `recovery_count "$N"` prints how many recovery-attempt
  markers issue `N` carries (0 if none), via `gh issue view --json comments`.
- A `RECOVERY_LIMIT` constant (default **3**) caps it. On RECOVER, if
  `recovery_count >= RECOVERY_LIMIT`, the loop calls
  `block "$N" "circuit-breaker: recovered <k> times without landing; needs a human."`
  and returns to PICK **instead of** resuming the item.
- Below the limit, the loop posts the next `recovery attempt <k>` marker and
  resumes as today.

### Acceptance criteria (issue body)

1. `recovery_count N` returns the integer count of `agent-loop: recovery attempt`
   markers on issue `N`; `0` when there are none.
2. A `RECOVERY_LIMIT` default of 3 exists and is overridable via env.
3. On RECOVER at/above the limit, the item is moved `agent`→`blocked` with a
   circuit-breaker comment and is NOT resumed.
4. Below the limit, RECOVER posts the next attempt marker and resumes.
5. A test in `loop_gh_test.sh` (stubbing `gh`) covers: count parsing, the
   at-limit block path, and the below-limit resume path — written RED first.
6. `run-all.sh` stays green. No `ci.yml`, no files outside `loop.sh`,
   `loop_gh_test.sh`, and the `agent-loop-work.md` RECOVER step.

The protocol's RECOVER step (`agent-loop-work.md` §0) gains one sentence wiring
`recovery_count` + `RECOVERY_LIMIT` into the recover-vs-block decision.

## Run protocol

File the item with the `todo` label (work-item template), then run a single
`/agent-loop-work` pass and observe it live: RECOVER → PICK → SYNC+CLAIM →
IMPLEMENT (test-first) → GATE (`run-all.sh`) → LAND → REPORT. Review before
queueing anything else.

## Success criteria

- Issue moves `todo`→`agent` on claim (WIP=1).
- A failing test is written and shown RED, then GREEN — implementation follows
  the test.
- `run-all.sh` passes as the gate; the change lands via a plain non-forced
  `git push origin HEAD:refs/heads/main` onto `origin/main`.
- Issue closed with the landed SHA.
- **No `ci.yml` created, no improvisation** beyond the acceptance criteria.
- If anything can't be met, the loop `BLOCKED`s the item cleanly and reports why
  — that is a *successful* observation of the guardrail, not a failure of the
  exercise.

## Out of scope

- Publishing public; building more than the one watched item this pass; Plan 3
  phase agents; any of the other `feature-ideas.md` entries (queued only after
  the first pass is reviewed).
