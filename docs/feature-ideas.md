# Feature ideas — deferred scope

Backlog of things intentionally cut from v1 to keep the proof-of-concept tight.
Each entry records the idea and the options already discussed, so re-opening it
doesn't restart the analysis.

## Retro-apply to existing repos

Adopt the loop into a repo that already has its own labels, issue templates,
`CONTRIBUTING.md`, CI, and history — without clobbering them. v1 targets **new**
repos only.

Options discussed:
- **Additive + non-destructive** — create only what's missing; never overwrite an
  existing file/label; print a found-vs-added report. Existing repo choices win.
- **Impose standard, with confirm** — show a diff of what it'd change, apply on
  confirm. Maximal consistency, can override repo-specific choices.
- **Interactive per-conflict** — ask per conflict (keep theirs / take canonical).
  Most careful, most friction; poor fit for unattended runs.

## Agent-loop failure-mode hardening

Beyond the reference loop's crash-recovery (re-claim orphaned `agent` issue on
startup) and `blocked` escape hatch:
- **Retry circuit-breaker** — an item failed N times auto-moves to `blocked`
  instead of being re-picked forever (no infinite retry on a poisoned item).
- **Crash-during-fixing-mode resilience** — if the session dies mid-incident, the
  next run detects the trunk is still locked / bug still open and resumes the
  incident before anything else. (In v1, fixing-mode is best-effort; mid-incident
  recovery is manual.)
- **Loop-bug feedback path** — when the failure is the loop *protocol's* own fault
  (not the target repo's), capture it as a fix to the central `agent-loop` plugin
  so every repo benefits. The recursive-self-improvement path; needs a defined
  channel back to this repo.

## Further disciplines (phases beyond v1)

The loop spine dispatches to phase-owning tuned agents and hands the implementer
cross-cutting skills (see the design doc's *Disciplines & phases*). v1 ships
grill-me (Shape), walking-skeleton (Inception), and TDD (Implement). Deferred:

- **ubiquitous-language** skill — DDD naming discipline applied while writing.
- **ports & adapters** skill — hexagonal boundaries enforced while writing.
- **improve-codebase-architecture** — an architecture-review *gate agent* with a
  pass/fail verdict (ports-&-adapters conformance, coupling, etc.).
- Others as they surface (e.g. more of the "patterns to follow" set).

Each phase-agent is centrally improvable in the plugin, so improving one lifts
every repo's loop — the recursive-self-improvement lever.

## Configurable rulesets / done-strategy

v1 hard-codes trunk-based development, direct push to `main`, no restrictions.
Later: a per-repo config (e.g. `.claude/agent-loop.json`) that can declare
stricter rules — PR-gate, branch-per-issue, protected-branch/ruleset awareness —
so the same central protocol adapts per repo instead of assuming open trunk.

## Deployment

v1's pipeline is the **gate stack** (quality/security/architecture), grown per
project as work items — deployment is a separate, under-explored concern and
most islands deploy nothing in v1. Deferred pieces when a project *does* need to
deploy:

- **Isolated per-project deploy** into its own Terraform workspace (or account),
  via RSI's `ci-pipelines` `terraform-deploy` action (`apply-auto` for
  unattended non-prod; `prod-gate` human approval keeps prod unreachable).
- **Ephemeral workspace lifecycle** — `terraform workspace select -or-create` on
  deploy, `terraform-workspace-delete` (refuses `prod/production/live/default`)
  on teardown.
- **Orphan-workspace GC** — a dead run can leave an ephemeral workspace holding
  live resources; needs a sweep to list and delete stale `agent-*` workspaces.
  (Cousin of the in-v1 stray-`ci/*`-ref cleanup, but for Terraform state.)
- **Freeze primitive** for fixing-mode's "lock downstream deploys" step
  (`DEPLOY_FREEZE` repo var vs. `gh workflow disable` vs. required check).
