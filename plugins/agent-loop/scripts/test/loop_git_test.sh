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
