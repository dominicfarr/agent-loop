# Contributing

## Commits

[Conventional Commits](https://www.conventionalcommits.org):

    <type>(<scope>): <summary>

    <body — why, not what; wrap ~72 chars>

    <footer — Refs/Fixes #N, BREAKING CHANGE, Co-Authored-By>

- Imperative, ≤50-char subject, no trailing period.
- **`Refs: #N` in the footer of every commit for a work-queue item** — the loop
  keys on it. (`Fixes #N` only auto-closes on the default branch.)
- One logical change per commit.

| type | use for | | type | use for |
|---|---|---|---|---|
| `feat` | new capability | | `perf` | performance |
| `fix` | bug fix | | `test` | tests |
| `docs` | docs only | | `build` | build system / deps |
| `refactor` | neither fix nor feat | | `ci` | CI config |
| `chore` | tooling / housekeeping | | | |

A template lives in [.gitmessage](.gitmessage) — `/agent-loop-init` runs
`git config --local commit.template .gitmessage` for you, so `git commit` (no
`-m`) opens your editor prefilled.

## Work items & decisions

Specs are GitHub issues drained by the loop — the `/work-queue` skill is the
single source of truth for the kanban. File with the **Work item** template,
write verifiable acceptance criteria, label `todo`. Architecture decisions worth
keeping go in `docs/ard/` (optional).
