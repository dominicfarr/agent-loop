#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../loop.sh
source "$HERE/../loop.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- fake gh: logs every invocation, emits fixtures, honours --jq (via real jq) ---
bin="$(mktemp -d)"; export GH_LOG="$bin/log"; : > "$GH_LOG"
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
prev= ; jqexpr= ; label=
for a in "$@"; do
  case "$prev" in --jq) jqexpr="$a";; --label) label="$a";; esac
  prev="$a"
done
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s' "$1"; fi; }
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  case "$label" in
    bug)   emit "${FIX_BUG:-[]}";;
    todo)  emit "${FIX_TODO:-[]}";;
    agent) emit "${FIX_AGENT:-[]}";;
    *)     emit "[]";;
  esac
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  view="${FIX_VIEW:-}"; [ -n "$view" ] || view='{"labels":[]}'
  emit "$view"; exit 0
fi
if [ "${1:-}" = "variable" ] && [ "${2:-}" = "get" ]; then
  [ -n "${FIX_VAR:-}" ] && { printf '%s' "$FIX_VAR"; exit 0; } || exit 1
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
  emit "${FIX_RUNS:-[]}"; exit 0
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "watch" ]; then
  exit 0   # invocation already logged above
fi
exit 0
EOF
chmod +x "$bin/gh"
export PATH="$bin:$PATH"

# --- pick_next: bug preempts todo, oldest (lowest number) wins ---
export FIX_BUG='[{"number":7},{"number":3}]' FIX_TODO='[{"number":2}]'
[ "$(pick_next)" = "3" ] || fail "pick_next should prefer oldest bug (3)"
export FIX_BUG='[]' FIX_TODO='[{"number":9},{"number":2}]'
[ "$(FIX_BUG='[]' pick_next)" = "2" ] || fail "pick_next should fall back to oldest todo (2)"
[ "$(FIX_BUG='[]' FIX_TODO='[]' pick_next)" = "" ] || fail "pick_next should be empty when queue is empty"

# --- claim emits the right gh calls ---
: > "$GH_LOG"
claim 5 abc1234
grep -qx 'issue edit 5 --remove-label todo --add-label agent' "$GH_LOG" || fail "claim label edit wrong"
grep -q  'issue comment 5 --body agent-loop: claiming. baseline origin/main @ abc1234' "$GH_LOG" || fail "claim comment wrong"

# --- block emits comment + label swap ---
: > "$GH_LOG"
block 5 "needs a secret"
grep -qx 'issue edit 5 --remove-label agent --add-label blocked' "$GH_LOG" || fail "block label swap wrong"
grep -q  'issue comment 5 --body agent-loop: BLOCKED. needs a secret' "$GH_LOG" || fail "block comment wrong"

# --- issue_has_label reads the labels array ---
[ "$(FIX_VIEW='{"labels":[{"name":"bug"}]}' issue_has_label 5 bug)" = "true" ]  || fail "issue_has_label true case"
[ "$(FIX_VIEW='{"labels":[{"name":"todo"}]}' issue_has_label 5 bug)" = "false" ] || fail "issue_has_label false case"

# --- frozen reflects the repo variable ---
FIX_VAR=1 frozen  || fail "frozen should be true when DEPLOY_FREEZE=1"
if frozen; then fail "frozen should be false when DEPLOY_FREEZE is unset"; fi

# --- read_local_gates parses the marker (no gh involved) ---
m="$bin/agent-loop.json"
printf '{"gates":{"local":["npm test","npm run lint"]}}' > "$m"
[ "$(read_local_gates "$m" | tr '\n' '|')" = "npm test|npm run lint|" ] || fail "read_local_gates list wrong"
printf '{"version":1}' > "$m"
[ -z "$(read_local_gates "$m")" ] || fail "read_local_gates should be empty when absent"

# --- watch_gate binds to the CURRENT HEAD sha, never a stale run on the ref ---
# Needs BOTH a real repo (git rev-parse HEAD) and the fake gh (run list/watch).
repo="$(mktemp -d)"
( cd "$repo" && git init -q && git config user.email a@b.c && git config user.name t \
  && echo v0 > f.txt && git add f.txt && git commit -qm seed )
cd "$repo"
want="$(git rev-parse HEAD)"
# FIX_RUNS holds a STALE run from a previous attempt (id 111, other sha) AND the
# current run (id 222, headSha == want). The match is present, so the loop breaks
# on iteration 1 — no sleeps, fast.
export FIX_RUNS="[{\"databaseId\":111,\"headSha\":\"0000000000000000000000000000000000000000\"},{\"databaseId\":222,\"headSha\":\"$want\"}]"
: > "$GH_LOG"
watch_gate 7 || fail "watch_gate should succeed when the SHA-matched run is green"
grep -qx 'run watch 222 --exit-status' "$GH_LOG" || fail "watch_gate must watch the SHA-matched run (222)"
grep -q  'run watch 111'              "$GH_LOG" && fail "watch_gate must NOT watch the stale run (111)" || true

echo "PASS (gh: all queue-layer functions)"
