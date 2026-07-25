# agent-loop

A reusable **agentic development-loop system**: a GitHub-issue work queue that a
Claude Code agent drains autonomously, packaged as a plugin so the same loop
drops into any project and is improved in one place — every project that adopts
it picks up the improvements.

## Install (per machine)

```
/plugin marketplace add /Users/dfarr/RSI/agent-loop
/plugin install agent-loop@rsi-agent-loop
```

Update to pick up loop improvements: `/plugin marketplace update rsi-agent-loop`.

## Adopt a repo

In any repo you want the loop to drain, run `/agent-loop-init`. It creates the
kanban labels (`todo`/`agent`/`blocked`/`bug`), drops the work-item and bug
issue templates and a lean `CONTRIBUTING.md` + `.gitmessage` (pointing
`commit.template` at it), and writes a `.claude/agent-loop.json` marker. It is
idempotent and never overwrites existing files.

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

## Design & roadmap

The full design — a trunk-based loop with pre-push gating, self-healing on trunk
breakage, and a phased spine of tuned agents (grill-me, walking-skeleton) and
cross-cutting skills (TDD) — lives in
[the design spec](docs/superpowers/specs/2026-07-24-agent-loop-design.md), with
deferred scope in [feature-ideas](docs/feature-ideas.md). Adoption
(`/agent-loop-init`) ships first; the phase agents (grill-me, walking-skeleton) follow in Plan 3.
