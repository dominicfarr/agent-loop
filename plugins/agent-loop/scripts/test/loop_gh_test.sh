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

# --- claim emits the label swap + a claiming comment ---
: > "$GH_LOG"
claim 5
grep -qx 'issue edit 5 --remove-label todo --add-label agent' "$GH_LOG" || fail "claim label edit wrong"
grep -qx 'issue comment 5 --body agent-loop: claiming.' "$GH_LOG" || fail "claim comment wrong"

# --- block emits comment + label swap ---
: > "$GH_LOG"
block 5 "needs a secret"
grep -qx 'issue edit 5 --remove-label agent --add-label blocked' "$GH_LOG" || fail "block label swap wrong"
grep -q  'issue comment 5 --body agent-loop: BLOCKED. needs a secret' "$GH_LOG" || fail "block comment wrong"

# --- issue_has_label reads the labels array ---
[ "$(FIX_VIEW='{"labels":[{"name":"bug"}]}' issue_has_label 5 bug)" = "true" ]  || fail "issue_has_label true case"
[ "$(FIX_VIEW='{"labels":[{"name":"todo"}]}' issue_has_label 5 bug)" = "false" ] || fail "issue_has_label false case"

# --- recovery_count: counts "recovery attempt" marker comments ---
export FIX_VIEW='{"comments":[{"body":"agent-loop: claiming."},{"body":"agent-loop: recovery attempt 1"},{"body":"agent-loop: recovery attempt 2"}]}'
[ "$(recovery_count 5)" = "2" ] || fail "recovery_count should count marker comments (2)"
export FIX_VIEW='{"comments":[]}'
[ "$(recovery_count 5)" = "0" ] || fail "recovery_count should be 0 when no marker comments"
unset FIX_VIEW

# --- recovery_exhausted: true at/above RECOVERY_LIMIT (block path), false below (resume path) ---
export FIX_VIEW='{"comments":[{"body":"agent-loop: recovery attempt 1"},{"body":"agent-loop: recovery attempt 2"},{"body":"agent-loop: recovery attempt 3"}]}'
RECOVERY_LIMIT=3 recovery_exhausted 5 || fail "recovery_exhausted should be true at the limit (block path)"
export FIX_VIEW='{"comments":[{"body":"agent-loop: recovery attempt 1"},{"body":"agent-loop: recovery attempt 2"}]}'
RECOVERY_LIMIT=3 recovery_exhausted 5 && fail "recovery_exhausted should be false below the limit (resume path)"
[ "$(recovery_count 5)" = "2" ] && [ "${RECOVERY_LIMIT:-3}" = "3" ] || fail "RECOVERY_LIMIT should default to 3"

# --- note_recovery_attempt: posts the next-numbered marker (count+1) ---
: > "$GH_LOG"
export FIX_VIEW='{"comments":[{"body":"agent-loop: recovery attempt 1"},{"body":"agent-loop: recovery attempt 2"}]}'
note_recovery_attempt 5
grep -qx 'issue comment 5 --body agent-loop: recovery attempt 3' "$GH_LOG" || fail "note_recovery_attempt should post the next marker (3)"
unset FIX_VIEW

# --- read_local_gates parses the marker (no gh involved) ---
m="$bin/agent-loop.json"
printf '{"gates":{"local":["npm test","npm run lint"]}}' > "$m"
[ "$(read_local_gates "$m" | tr '\n' '|')" = "npm test|npm run lint|" ] || fail "read_local_gates list wrong"
printf '{"version":1}' > "$m"
[ -z "$(read_local_gates "$m")" ] || fail "read_local_gates should be empty when absent"

echo "PASS (gh: all queue-layer functions)"
