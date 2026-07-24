# agent-loop

A reusable **agentic development-loop system**: a GitHub-issue work queue that a
Claude Code agent drains autonomously, packaged so the same loop can be dropped
into any project — new or existing — and improved in one place so every project
that uses it picks up the improvements.

> **Status: design pending.** This repo was just scaffolded as a clean, standalone
> home for the work. Nothing about the architecture or distribution mechanism is
> settled yet — that's the next session's job.

## Where this came from

The working reference implementation lives in a sibling repo:

- `../jackpot-watcher/.claude/skills/work-queue/SKILL.md` — the loop protocol
- `../jackpot-watcher/docs/ard/0001-work-branch-direct-push.md`
- `../jackpot-watcher/docs/ard/0002-agent-work-queue.md`
- `../jackpot-watcher/docs/superpowers/specs/2026-07-13-agent-work-queue-design.md`
- `../jackpot-watcher/.github/ISSUE_TEMPLATE/work-item.md`

That version is bespoke to one repo. The goal here is to lift the pattern out into
something installable and centrally maintained.

## Next step

Open a fresh Claude Code session **in this repo** and start the brainstorm — e.g.
"Let's design the agent-loop system: how to distribute this work-queue loop into
any project and retro-apply it to existing ones."
