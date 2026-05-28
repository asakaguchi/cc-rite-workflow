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
# Symmetric to TC-7 (AC-3 bidirectional): the continuation branch must NOT use the
# FINALIZE completion-notice phrasing — pins both sides of the prefix split.
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  fail "TC-1: continuation reason wrongly used the FINALIZE completion-notice phrasing: $out"
else
  pass "TC-1: continuation reason is distinct from the FINALIZE branch"
fi

# --- TC-2: handoff consumed (deleted) after the block (one-shot) ---
echo ""
echo "=== TC-2: handoff is deleted from flow-state after block (one-shot consume) ==="
sf=$(state_file_for "$d")
assert "TC-2: handoff deleted after block" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf")"
out2=$(stop_payload "$d" "$SID" true | bash "$HOOK")
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
# Symmetric to TC-7 (AC-3 bidirectional): the fix→review continuation branch must NOT
# use the FINALIZE completion-notice phrasing.
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  fail "TC-6: continuation reason wrongly used the FINALIZE completion-notice phrasing: $out"
else
  pass "TC-6: continuation reason is distinct from the FINALIZE branch"
fi

# --- TC-7: FINALIZE handoff present → block with completion-notice reason (Issue #1176 AC-1/AC-3) ---
echo ""
echo "=== TC-7: FINALIZE handoff → decision:block re-injects the completion-notice directive ==="
d7=$(new_sandbox)
RITE_STATE_ROOT="$d7" bash "$FS" set --phase review --issue 1176 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
out=$(stop_payload "$d7" | bash "$HOOK")
assert "TC-7: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason7=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason7" | grep -q "完了通知"; then
  pass "TC-7: reason requests the ステップ5 completion notice"
else
  fail "TC-7: reason missing completion-notice directive: $out"
fi
# The FINALIZE branch must NOT re-inject a continuation command (would falsely restart the loop).
if printf '%s' "$_reason7" | grep -q "停止せず、次を実行してください"; then
  fail "TC-7: FINALIZE reason wrongly used the continuation phrasing: $out"
else
  pass "TC-7: FINALIZE reason is distinct from the continuation branch"
fi
# The terminal result identifier should be surfaced for context.
if printf '%s' "$_reason7" | grep -q "review:mergeable:99"; then
  pass "TC-7: reason surfaces the terminal result (review:mergeable:99)"
else
  fail "TC-7: reason missing the terminal result identifier: $out"
fi

# --- TC-8: FINALIZE handoff consumed one-shot → second stop allows (Issue #1176 AC-2/AC-5) ---
echo ""
echo "=== TC-8: FINALIZE handoff is one-shot — second stop allows (no infinite block) ==="
sf8=$(state_file_for "$d7")
assert "TC-8: FINALIZE handoff deleted after block" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf8")"
out8=$(stop_payload "$d7" "$SID" true | bash "$HOOK")
assert "TC-8: second stop allows (no output)" "" "$out8"

# --- TC-9: replied-only / cancelled-by-user FINALIZE variants also block with the finalize reason (AC-1) ---
echo ""
echo "=== TC-9: [fix:replied-only] / [fix:cancelled-by-user] FINALIZE handoffs block once ==="
for _ho in "FINALIZE:fix:replied-only:99" "FINALIZE:fix:cancelled-by-user:99"; do
  d9=$(new_sandbox)
  RITE_STATE_ROOT="$d9" bash "$FS" set --phase fix --issue 1176 --branch b --pr 99 \
    --next n --handoff "$_ho" --session "$SID" >/dev/null
  out=$(stop_payload "$d9" | bash "$HOOK")
  assert "TC-9: ${_ho} → decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
  if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
    pass "TC-9: ${_ho} reason requests the completion notice"
  else
    fail "TC-9: ${_ho} reason missing completion-notice directive: $out"
  fi
  # one-shot: second stop allows
  out_b=$(stop_payload "$d9" "$SID" true | bash "$HOOK")
  assert "TC-9: ${_ho} second stop allows (one-shot)" "" "$out_b"
done

# --- TC-10: FINALIZE handoff with empty result part still blocks once (edge case) ---
# ${HANDOFF#FINALIZE:} becomes "" when a sub-skill emits a malformed "FINALIZE:" handoff
# (e.g. a typo dropping the {result}:{pr} suffix). The hook must still take the FINALIZE
# branch and force the completion notice rather than silently allowing the stop.
echo ""
echo "=== TC-10: FINALIZE: (empty result part) still blocks with the completion-notice reason ==="
d10=$(new_sandbox)
RITE_STATE_ROOT="$d10" bash "$FS" set --phase review --issue 1176 --branch b --pr 99 \
  --next n --handoff "FINALIZE:" --session "$SID" >/dev/null
out=$(stop_payload "$d10" | bash "$HOOK")
assert "TC-10: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  pass "TC-10: empty-result FINALIZE still requests the completion notice"
else
  fail "TC-10: empty-result FINALIZE missing completion-notice directive: $out"
fi
# one-shot: second stop allows (no infinite block even for the malformed handoff)
out_b=$(stop_payload "$d10" "$SID" true | bash "$HOOK")
assert "TC-10: second stop allows (one-shot)" "" "$out_b"

if ! print_summary "$(basename "$0")" "stop-loop-continuation.sh (Issue #1168 review↔fix loop continuation + #1176 FINALIZE terminal backstop)"; then
  exit 1
fi
