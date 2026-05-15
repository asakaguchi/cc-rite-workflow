#!/bin/bash
# rite workflow - Stop event hook: create-interview implicit stop blocker (#920)
#
# 累積系列 (#910 / #917 / #634 / #651 / #622 / #552 / #687) で実証された
# /rite:issue:create の create-interview return 後 orchestrator implicit stop に対する
# 機械的 enforcement layer。prompt-side defense (4-line return block invariant +
# imperative phrasing) が turn-boundary heuristic を完全には抑止できない (Issue #910 で実証)
# ため、Stop event を block して resume 経路を保証する back-stop として動作する。
#
# Detection logic:
#   - flow-state file の .phase == "create_post_interview"
#   - .active == true
#   - .pr_number == 0 (Issue/PR 未作成、resume すべき)
#
# Action on detect:
#   - workflow-incident-emit.sh で manual_fallback_adopted sentinel を stderr に emit
#     (workflow_incident.enabled=true / 未設定時のみ、AC-4 充足)
#   - user-facing ACTION message を stderr に出力 (Step 0 / Step 1 patch literal を含む)
#   - exit 2 で Stop event を block (Claude Code が stderr を user/LLM に提示し resume を促す)
#
# Allow paths (exit 0):
#   - stop_hook_active=true (recursion guard)
#   - .rite-flow-state file 不在
#   - phase 不一致 / active=false / pr_number != 0
#   - workflow_incident.enabled=false (settings respect、ただし incident emit のみ skip し block 自体は実行)
#
# Exit codes:
#   0 — allow (no block, no output)
#   2 — block stop (stderr contains ACTION message + incident sentinel)

set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_STOP_CREATE_INTERVIEW:-}" ] || exit 0
export _RITE_HOOK_RUNNING_STOP_CREATE_INTERVIEW=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# Fail-open: any unexpected error → allow (do not block legitimate Stop events)
trap 'exit 0' ERR

INPUT=$(cat) || INPUT=""
[ -n "$INPUT" ] || exit 0

# Only inspect Stop events
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null) || HOOK_EVENT=""
if [ "$HOOK_EVENT" != "Stop" ]; then
  exit 0
fi

# Recursion guard: when Claude Code re-fires Stop after a previous block,
# stop_hook_active is true. Allow it through to avoid infinite block loops.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || STOP_HOOK_ACTIVE="false"
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state file path (per-session schema_version=2 or legacy .rite-flow-state).
# Fall back silently when the resolver is unavailable — Stop blocking is opt-in
# (only when the resolver chain works correctly the lifecycle gate fires).
STATE_ROOT_PATH=""
if STATE_ROOT_PATH=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null); then
  :
else
  exit 0
fi
[ -n "$STATE_ROOT_PATH" ] || exit 0

STATE_FILE_PATH=""
if STATE_FILE_PATH=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT_PATH" 2>/dev/null); then
  :
else
  STATE_FILE_PATH="${STATE_ROOT_PATH}/.rite-flow-state"
fi
[ -f "$STATE_FILE_PATH" ] || exit 0

STATE_PHASE=$(jq -r '.phase // empty' "$STATE_FILE_PATH" 2>/dev/null) || STATE_PHASE=""
STATE_ACTIVE=$(jq -r '.active // false' "$STATE_FILE_PATH" 2>/dev/null) || STATE_ACTIVE="false"
STATE_PR=$(jq -r '.pr_number // 0' "$STATE_FILE_PATH" 2>/dev/null) || STATE_PR="0"

# Gate condition: implicit stop at create-interview return boundary
[ "$STATE_PHASE" = "create_post_interview" ] || exit 0
[ "$STATE_ACTIVE" = "true" ] || exit 0
[ "$STATE_PR" = "0" ] || exit 0

# Read workflow_incident.enabled (default true — opt-out semantics).
# Canonical SoT: see workflow-incident-detection.md "Canonical bash literal" section.
# The canonical chain assumes `set -e` is not strict — under our `set -euo pipefail`
# + `trap 'exit 0' ERR` (fail-open), `grep -E` returning exit 1 on no-match would
# propagate via pipefail and trip the ERR trap, silently aborting the hook with
# exit 0 even when the gate condition matches. `|| true` keeps the chain compatible
# with strict-mode contexts (no-match → empty result → default-on fallback).
WORKFLOW_INCIDENT_ENABLED="true"
if [ -f "$CWD/rite-config.yml" ]; then
  workflow_incident_enabled=$(sed -n '/^workflow_incident:/,/^[a-zA-Z]/p' "$CWD/rite-config.yml" 2>/dev/null \
    | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/#.*//' \
    | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]' || true)
  value=$(printf '%s' "$workflow_incident_enabled" | tr -d '"'"'"'' | tr '[:upper:]' '[:lower:]')
  case "$value" in
    false|no|0) WORKFLOW_INCIDENT_ENABLED="false" ;;
  esac
fi

# Emit workflow_incident sentinel via stderr (AC-4).
# workflow-incident-emit.sh outputs to stdout, redirect to stderr so the sentinel
# reaches the orchestrator's conversation context (Claude Code captures stderr
# from Stop hooks) without contaminating the stop hook's own output channel.
if [ "$WORKFLOW_INCIDENT_ENABLED" != "false" ] && [ -x "$SCRIPT_DIR/workflow-incident-emit.sh" ]; then
  bash "$SCRIPT_DIR/workflow-incident-emit.sh" \
    --type "manual_fallback_adopted" \
    --details "create-interview return implicit stop blocked by stop-create-interview-block hook (Issue #920)" \
    --root-cause-hint "orchestrator did not fire Mandatory After Interview Step 0 as VERY FIRST tool call after sub-skill return" \
    --pr-number 0 >&2 2>/dev/null || true
fi

# Block Stop and emit ACTION message to stderr (Claude Code surfaces this to LLM/user)
cat >&2 <<'STOP_ACTION'

🚨 [Issue #920] /rite:issue:create implicit stop detected — Stop event blocked.

phase=create_post_interview, active=true, pr_number=0 (Issue is NOT yet created).
The interview sub-skill returned, but Phase 2 (Task Decomposition Decision) has not started.

ACTION — Resume the workflow in the SAME response turn:

  1. Execute Mandatory After Interview Step 0 (idempotent re-fire):

     bash plugins/rite/hooks/flow-state-update.sh patch \
       --phase create_post_interview --active true \
       --next "Step 0 idempotent re-fire after stop-block. Proceeding to Phase 2." \
       --if-exists --preserve-error-count

  2. Proceed to Phase 2 (Task Decomposition Decision) → Phase 3 (Delegation Routing)
     → invoke terminal sub-skill (rite:issue:create-register or rite:issue:create-decompose).
     The terminal sub-skill emits <!-- [create:completed:{N}] --> when finished.

DO NOT stop the response turn. DO NOT re-invoke rite:issue:create-interview.
STOP_ACTION

exit 2
