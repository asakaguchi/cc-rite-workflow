#!/bin/bash
# Tests for plugins/rite/hooks/stop-loop-continuation.sh (Issue #1168)
# Verifies the Stop hook re-injects the review↔fix loop continuation command when a
# handoff marker is present, allows the stop otherwise, and consumes the marker one-shot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOK="$PLUGIN_ROOT/hooks/stop-loop-continuation.sh"
FS="$PLUGIN_ROOT/hooks/flow-state.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: $HOOK not found or not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

# Create a git sandbox so state-path-resolve.sh returns the sandbox root.
new_sandbox() {
  local d
  d=$(make_plain_sandbox --soft) || return 1
  (cd "$d" && git init -q && echo a > a && git add a && \
    git -c user.email=t@test.local -c user.name=test commit -q -m init) >/dev/null
  echo "$d"
}

# Emit a Stop payload JSON for the given cwd / session_id.
stop_payload() {
  local cwd="$1" sid="${2:-$SID}" active="${3:-false}"
  jq -nc --arg c "$cwd" --arg s "$sid" --argjson a "$active" \
    '{session_id:$s, cwd:$c, hook_event_name:"Stop", stop_hook_active:$a}'
}

state_file_for() { echo "$1/.rite/sessions/${SID}.flow-state"; }

# --- TC-1: handoff present → block with continuation command in reason ---
echo "=== TC-1: handoff present → decision:block re-injects the command ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase review --issue 1168 --branch b --pr 99 \
  --next n --handoff "/rite:pr:fix 99" --session "$SID" >/dev/null
out=$(stop_payload "$d" | bash "$HOOK")
assert "TC-1: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "/rite:pr:fix 99"; then
  pass "TC-1: reason contains the handoff command"
else
  fail "TC-1: reason missing handoff command: $out"
fi

# --- TC-2: handoff consumed (deleted) after the block (one-shot) ---
echo ""
echo "=== TC-2: handoff is deleted from flow-state after block (one-shot consume) ==="
sf=$(state_file_for "$d")
assert "TC-2: handoff deleted after block" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf")"
out2=$(stop_payload "$d" true | bash "$HOOK")
assert "TC-2: second stop allows (no output)" "" "$out2"

# --- TC-3: no flow-state file → allow stop ---
echo ""
echo "=== TC-3: no flow-state file → allow (no output) ==="
d3=$(new_sandbox)
out=$(stop_payload "$d3" | bash "$HOOK")
assert "TC-3: allow when no flow-state" "" "$out"

# --- TC-4: flow-state without handoff → allow stop ---
echo ""
echo "=== TC-4: flow-state without handoff → allow (no output) ==="
d4=$(new_sandbox)
RITE_STATE_ROOT="$d4" bash "$FS" set --phase review --issue 1168 --branch b --pr 99 \
  --next n --session "$SID" >/dev/null
out=$(stop_payload "$d4" | bash "$HOOK")
assert "TC-4: allow when handoff absent" "" "$out"

# --- TC-5: missing session_id in payload → allow stop ---
echo ""
echo "=== TC-5: payload missing session_id → allow (no output) ==="
d5=$(new_sandbox)
RITE_STATE_ROOT="$d5" bash "$FS" set --phase fix --issue 1168 --branch b --pr 99 \
  --next n --handoff "/rite:pr:review 99" --session "$SID" >/dev/null
out=$(jq -nc --arg c "$d5" '{cwd:$c, hook_event_name:"Stop"}' | bash "$HOOK")
assert "TC-5: allow when session_id missing" "" "$out"

# --- TC-6: fix→review direction (handoff = /rite:pr:review) blocks ---
echo ""
echo "=== TC-6: fix→review handoff also blocks with the review command ==="
d6=$(new_sandbox)
RITE_STATE_ROOT="$d6" bash "$FS" set --phase fix --issue 1168 --branch b --pr 99 \
  --next n --handoff "/rite:pr:review 99" --session "$SID" >/dev/null
out=$(stop_payload "$d6" | bash "$HOOK")
assert "TC-6: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "/rite:pr:review 99"; then
  pass "TC-6: reason contains the review command"
else
  fail "TC-6: reason missing review command: $out"
fi

if ! print_summary "$(basename "$0")" "stop-loop-continuation.sh (Issue #1168 review↔fix loop continuation)"; then
  exit 1
fi
