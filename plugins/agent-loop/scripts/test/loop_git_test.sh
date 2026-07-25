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

# --- publish_ci_ref / stray_ci_refs / cleanup_ci_ref ---
publish_ci_ref 1
stray_ci_refs | grep -q 'refs/heads/ci/issue-1' || fail "ci/issue-1 not on origin"
cleanup_ci_ref 1
[ -z "$(stray_ci_refs)" ] || fail "ci/issue-1 not cleaned up"

# --- publish_ci_ref is force: re-publishing over a diverged ci ref succeeds ---
publish_ci_ref 2
first_ci="$(git ls-remote origin 'refs/heads/ci/issue-2' | awk '{print $1}')"
git commit -q --amend -m "C1': diverge from the pushed ci ref (Refs: #2)"   # rewrites HEAD off the old ci ref
publish_ci_ref 2 || fail "force re-publish of diverged ci ref should succeed"
second_ci="$(git ls-remote origin 'refs/heads/ci/issue-2' | awk '{print $1}')"
[ "$first_ci" != "$second_ci" ] || fail "ci/issue-2 did not advance to the rebased HEAD"
cleanup_ci_ref 2

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

# --- discard_to_baseline: drop ungated commit AND staged changes, CLEAN tree ---
echo blocked-work > h.txt; git add h.txt; git commit -qm "C4: ungated (Refs: #3)"
echo more-staged > i.txt; git add i.txt   # a staged change on top of the ungated commit
discard_to_baseline
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "discard_to_baseline did not return HEAD to origin/main"
[ -z "$(git status --porcelain)" ] || fail "discard_to_baseline left the tree dirty"

echo "PASS (git: all model-Y invariants)"
