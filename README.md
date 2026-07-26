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
WIP=1, implements it on trunk test-first, and lands it with a plain
non-forced push.

The loop runs a deliberately **single-writer** model: one agent, no concurrent
writers, nothing consuming trunk. The one guard is self-preservation — a
change's own tests must pass before it lands. Define that gate in
`.claude/agent-loop.json` under `gates.local`: each listed command must exit `0`
before a change lands (e.g. a script that runs your test suite). An empty
`gates.local` opts out of gating entirely.

## Design & roadmap

The full design — a trunk-based loop with pre-push gating, self-healing on trunk
breakage, and a phased spine of tuned agents (grill-me, walking-skeleton) and
cross-cutting skills (TDD) — lives in
[the design spec](docs/superpowers/specs/2026-07-24-agent-loop-design.md), with
deferred scope in [feature-ideas](docs/feature-ideas.md). Adoption
(`/agent-loop-init`) ships first; the phase agents (grill-me, walking-skeleton) follow in Plan 3.
