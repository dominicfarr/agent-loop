# agent-loop — design

Date: 2026-07-24
Status: approved (design); implementation plan pending

## Goal

Take the bespoke GitHub-issue work-queue loop that currently lives inside
`jackpot-watcher` and turn it into a **reusable, centrally-maintained agent
development loop** that drops into any of the author's projects. An autonomous
Claude Code agent drains a project's issue queue, lands verified work on trunk,
and — because the loop lives in one place — every project picks up loop
improvements without being re-touched.

Original verbs: **distribute** into new projects, **retro-apply** to existing
ones, **improve centrally**. This spec covers v1 = *distribute into new
projects* + *improve centrally*. Retro-apply is deferred
([feature-ideas.md](../../feature-ideas.md)).

## Where this came from

Reference (bespoke, copied into one repo): `../jackpot-watcher`'s
`.claude/skills/work-queue/SKILL.md`, `docs/ard/0002-agent-work-queue.md`,
`.github/ISSUE_TEMPLATE/work-item.md`. RSI platform studied for fit:
`../V3API`, `../rsi-games`, `../ci-pipelines` (Terraform stacks, workspace
isolation, reusable composite actions, OIDC, `prod-gate`).

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Audience | **Personal** — the author's own repos ("islands"). No team/semver ceremony. |
| Distribution vehicle | A **Claude Code plugin** from a **private marketplace** (a local dir or an RSI-org repo). No OSS. |
| Where the protocol lives | **Plugin-only.** Never copied into a repo, so it can't go stale. |
| Per-repo footprint | Irreducible GitHub state only: **labels + a tiny marker/config + issue templates**. |
| Update propagation | Improve the plugin → next run in any repo uses new logic. **Zero per-repo re-sync.** |
| Isolation model | Each project is an **island** with its own env; never touches shared `dev`/`prod`. |
| Project shape | **Agnostic / free.** Could be HTML→S3, Docker on Lightsail, FaaS, tiered, EC2, a plugin. `init` prescribes **no stack**. |
| Definition of done | **Trunk-Based Development**, land on `main`. PoC: no rulesets/PR gate. |
| Verification | **Pre-push gates (model Y)** — gate before trunk, keeping trunk always green. |
| Gates | **Author-your-own**, none predefined; verify is gate-set-agnostic. |
| Disciplines | Attached to **loop phases**: phase-owners = tuned agents; cross-cutting = skills. |
| Failure model | **Two tiers** — per-item gate red (cheap) vs. trunk red (Andon fixing-mode). |

## Architecture

### Distribution: plugin-only, private

The plugin holds all *logic* (`/work-queue`, `init`, the phase-agents,
fixing-mode). Each project holds only *GitHub state* (labels, a marker/config,
issue templates). Improving the loop is a plugin edit; propagation is automatic
on next run.

The marketplace stays **private** — either a **local directory** on the author's
machine or an **RSI-org repo**; no OSS publishing. Any reusable gates likewise
live in a private catalog (or just in-repo), and RSI-specifics (role ARNs,
tenant IDs, tokens) always stay as per-repo inputs, never baked into shared code.

**Accepted tradeoff:** the plugin must be installed on each machine the author
works from.

### Per-repo footprint (created by `init`)

- **Labels:** `todo`, `agent`, `blocked`, `bug`.
- **Marker/config:** a small committed file (assume `.claude/agent-loop.json`) —
  near-empty for PoC; the seam where future config (rulesets, gate hints) lands.
- **Issue templates:** work-item **+ bug** under `.github/ISSUE_TEMPLATE/`.

`init` stays minimal and stack-free — it does **not** scaffold a language/deploy
template. What the project *is* and how it deploys is a free choice, established
later by the walking skeleton.

### Isolation model — "islands"

Standalone projects consuming nothing from shared product envs. Isolation tiers,
cheapest first: own Terraform workspace · own account · no shared infra at all.
Isolation *is* the safety model: an autonomous agent's blast radius is exactly
one project's env, with no path to a critical environment.

## The loop protocol (model Y: real TBD + ephemeral CI ref)

### Kanban states

| State | Representation | Set by |
| --- | --- | --- |
| backlog | open issue, no status label | human files it; invisible to the agent |
| `todo` | open + `todo` | human/shape-phase, when the spec is ready |
| `bug` | open + `bug` | fixing-mode; **priority — preempts `todo`** |
| `agent` | open + `agent` | agent, on claim |
| `blocked` | open + `blocked` | agent, when it cannot proceed (never re-touched) |
| completed | closed as completed | agent, after landing on trunk |

WIP = 1, enforced behaviorally: never claim while any open issue carries
`agent`; resume such an issue on startup (crash recovery).

### Per-run steps

```
0. RECOVER
   - open `agent` issue? resume it.
   - local main ahead of origin/main (git rev-list origin/main..HEAD)?
     ungated commits from a dead run — re-gate or discard.
   - stray ci/* refs? GC them.
   - open `bug` / frozen trunk? resume the incident FIRST.

1. PICK        oldest open `bug` (preempt) else oldest `todo` (FIFO).
               Dirty WORKING TREE → stop and report (a human is mid-edit).
               Queue empty → step 6.

2. CLAIM       label → agent; comment "claiming", recording the baseline
               origin/main SHA for recovery.

3. IMPLEMENT   commit to LOCAL main (real TBD), `Refs: #N` in every footer.
               Apply the Implement-phase disciplines (TDD, …).

4. GATE        git pull --rebase origin main          # sync BEFORE the gate
               git push origin HEAD:refs/heads/ci/issue-N
               run local checks, then the project's CI gates
                 → gh run watch --exit-status
                 red  → fix-forward & re-gate, or → BLOCKED (step 7)
                 green→ step 5
               INVARIANT: the commit that passed the gate is the exact commit
               that lands. Do NOT rebase/merge after the gate.

5. LAND        git push origin main            # fast-forward-only, to the gated SHA
                 rejected (trunk moved)? discard, rebase, RE-GATE (back to 4).
               git push origin --delete ci/issue-N     # remote-only ref
               gh issue close N --reason completed  (comment lists SHAs)
               (optional) watch post-merge trunk CI; red → FIXING-MODE.

6. REPORT      completed / blocked summary, or "queue empty". Stop — no poll.

7. BLOCKED     comment exactly what's needed; git reset --soft origin/main
               (discard ungated commits, keep the diff); delete any ci/* ref
               this run created; label agent → blocked; return to step 1.
```

### Gate mechanics (why model Y is safe)

- **Sync before the gate, never after** — rebase local `main` onto `origin/main`
  right before publishing the CI ref, so the gate runs on real trunk + change.
- **`gate-SHA == push-SHA`** — the passing commit is the exact commit landed. A
  post-gate rebase/merge would land un-gated code (forbidden).
- **Fast-forward-only, never forced** — if trunk moved, the push is rejected
  (fails safe) and the item redoes from rebase.
- **The branch is a pure CI artifact** — `ci/issue-N` exists only for the gate
  window; work never lives on a long-lived branch. Tight to TBD.

### Two-tier failure

- **Per-item gate red** (CI ref): not an incident. The item doesn't land; agent
  fix-forwards or blocks. Trunk stays green. The common case.
- **Trunk red** (a *scheduled* scan, a *newly-added* gate flagging existing
  trunk code, a deploy, a flake): **fixing-mode**.

### Fixing-mode (Andon stop-the-line)

Trunk red → 1) halt/alert, 2) **freeze** further landings/deploys (simple:
a `DEPLOY_FREEZE` repo var the workflow hard-fails on), 3) file a `bug`, 4)
**preempt** (step 1 drains it first), 5) **revert vs. hotfix** as a normal gated
item, 6) confirm green, 7) **unfreeze**, resume. In v1 fixing-mode is
**best-effort**: mid-incident crash recovery is manual (step 0 detects the
freeze + open `bug` and resumes).

## Gates (author-your-own, project-shape-agnostic)

agent-loop ships **no** predefined gates. You author your project's gates in
your own repo; if one proves reusable, publish it to your private catalog (or
keep it in-repo) and consume by version tag — RSI-specifics stay per-repo inputs.

A gate = **one command (exits 0/≠0)** with up to three surfaces:

| Surface | Trigger | Role |
| --- | --- | --- |
| **Local** | agent runs it in-session | fast fail before a CI round-trip |
| **CI ref** | `push` to `ci/**` | authoritative pre-push gate; what `gh run watch` reads |
| **Trunk** | `push: main` / `schedule` | post-merge gate; red → fixing-mode |

Add one: **author & prove locally → codify as a `ci/**`-triggered CI job**
(ideally a reusable action) → optionally register a local fast-fail copy →
promote to your catalog if reusable.

**CI gates are self-declaring:** verify watches the aggregate `ci/**` run, so a
new gate is enforced with **no loop change**. Cheap checks gate the CI ref;
expensive ones (CodeQL-class) run on `main`/`schedule` as trunk gates.

> Correction from an earlier draft: RSI's stock gates trigger `on:
> pull_request`; model Y has no PR. "Reuse" therefore means reuse gate *logic*
> (composite actions) wired to the `ci/**` trigger — not the PR workflows as-is.

## Disciplines & phases (the spine as orchestrator)

The work-queue loop is the **spine**; engineering disciplines attach to its
**phases**. Phase-owners with a clean input→output contract are **tuned agents**
(each centrally improvable in the plugin — the recursive-self-improvement lever);
cross-cutting disciplines woven into writing code are **skills** the implementer
follows. The spine dispatches a phase-agent with item context, consumes its
output, continues.

| Phase | Delivered as | Discipline | v1 |
| --- | --- | --- | --- |
| **Shape** (backlog → todo) | agent | **grill-me** — Socratic spec extraction (human present), yields sharp acceptance criteria | **v1** |
| **Inception** (fresh repo) | agent / first item | **walking-skeleton** — minimal end-to-end slice through the chosen deploy target, CI green | **v1** |
| **Implement** (each item) | skill | **TDD** — test-first (reuse `superpowers:test-driven-development`) | **v1** |
| **Implement** | skill | ubiquitous-language, ports & adapters | deferred |
| **Review / gate** | agent | improve-codebase-architecture — architecture conformance, pass/fail | deferred |

Shape runs when a human is present (they get grilled) and produces good `todo`
specs; draining is unattended. Inception runs once, when a repo has no skeleton
yet, and is where the free deploy-target choice gets made real.

## Components to build (v1)

1. **Plugin scaffold + marketplace** (OSS-capable): `plugin.json`, marketplace
   manifest, secret-free.
2. **`/work-queue` orchestrator** — the protocol above + phase dispatch (Shape /
   Inception / Implement) + two-tier failure + fixing-mode + recovery +
   guardrails.
3. **`/agent-loop-init`** — minimal, stack-free: create labels, drop
   marker/config + work-item/bug templates, verify `gh` auth.
4. **grill-me agent** (Shape phase).
5. **walking-skeleton** (Inception phase).
6. **TDD** wired as the Implement-phase skill (reuse existing superpowers skill).
7. **Guardrail behaviors** in the protocol: `reset --soft` on red; recovery of
   ungated local commits + stray `ci/*` refs; dirty-tree guard; ff-only
   never-forced push.

## Out of scope (deferred — see [feature-ideas.md](../../feature-ideas.md))

- **Retro-apply** to existing repos.
- **Loop-failure hardening**: retry circuit-breaker, crash-during-fixing-mode
  resilience, and the **loop-bug feedback path** (recursive self-improvement — a
  protocol fault flows back to the central plugin).
- **Configurable rulesets / done-strategy** (PR-gate, branch protection) via the
  marker/config seam.
- **Deployment**: isolated per-project deploy, ephemeral deploy workspaces,
  `prod-gate`, **orphan-workspace GC**, and the fixing-mode freeze primitive.
- **Further disciplines**: ubiquitous-language + ports-&-adapters skills, and the
  architecture-review gate agent.

## Open questions (answered / residual)

- **Gate discovery — ANSWERED.** CI gates are self-declaring (verify watches the
  aggregate `ci/**` run); local gates via a project convention (a check
  command / marker-config list).
- **Fresh-repo detection** (→ run Inception): marker absence / empty-repo
  heuristic — confirm during implementation.
- **grill-me invocation** — explicit command (`/agent-loop shape`) vs. auto on a
  rough backlog item. Lean explicit for v1.
- **Marker location/schema** — `.claude/agent-loop.json` assumed; confirm when
  the first real config field lands.
- **Freeze primitive shape** — deferred with deployment; only matters once a
  project has pipelines that can redden trunk.
