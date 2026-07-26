#!/usr/bin/env bash
# Dev helper: seed a dummy work item so a fresh repo's queue has something to
# drain. Used for the manual end-to-end test of the agent-loop plugin.
#
# Full manual e2e (run against a throwaway GitHub repo, NOT this plugin repo):
#   1. In a new empty project:  /agent-loop:agent-loop-init
#        → creates the GitHub repo, labels, scaffolding, and (since the
#          establish-trunk fix) pushes origin/main so the loop has a baseline.
#   2. Seed the queue:          bash .../seed-slugify-issue.sh
#        → files one `todo` work item (the "slugify" spec below).
#   3. Drain it:                /agent-loop:agent-loop-work
#        → the loop claims #N, implements slugify test-first, gates on ci/**,
#          lands fast-forward-only, and closes the issue.
#   4. Verify:                  queue empty, issue closed, slug() on trunk.
#
# gh resolves the repo from the current working directory, so run this from
# inside the checkout of the test project you want to seed.
set -euo pipefail

gh issue create \
  --title "Add a slugify helper" \
  --label todo \
  --body '## Context
The loop needs a small, self-contained work item to prove the queue drains
end-to-end. A pure text-to-slug helper fits: no I/O, no secrets, trivially
gateable.

## Requirements
Add a `slug` shell function (in the project as appropriate) that turns an
arbitrary title string into a URL/branch-safe kebab-case slug.

## Acceptance criteria
- [ ] `slug "Add Retry Logic"` prints `add-retry-logic`
- [ ] Lowercases all letters
- [ ] Collapses any run of non-alphanumeric characters to a single `-`
- [ ] Strips leading and trailing `-`
- [ ] `slug "  Hello, World!  "` prints `hello-world`
- [ ] Covered by a test that is written first and fails before the implementation

## Out of scope
- Unicode transliteration (ASCII input only for v1)'
