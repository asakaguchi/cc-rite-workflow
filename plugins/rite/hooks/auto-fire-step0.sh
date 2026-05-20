#!/bin/bash
# rite workflow - PostToolUse Skill Return Auto-Fire Step 0 Hook
#
# Fires after a Skill tool invocation completes. When the current flow-state
# `.phase` indicates a "pre-X" state in the rite workflow's flow-state ring
# (e.g. `ingest_pre_lint`, `cleanup_pre_ingest`), this hook performs the
# caller's Step 0 Immediate Bash Action automatically:
#   1. Patches flow state to the corresponding post-X phase (idempotent with
#      the caller's Mandatory After Step 0/Step 1 dual patch).
#   2. Emits `hookSpecificOutput.additionalContext` via stdout JSON to inject
#      a "MUST continue" signal into the next LLM turn input.
#
# Design rationale: Wiki experiential knowledge
# "Declarative enforcement で LLM の stop_reason: end_turn は抑制できない"
# implies prompt-side defense alone cannot prevent implicit stop after
# sub-skill return. This hook is a mechanical enforcement layer that
# advances flow-state to the recovery-correct state regardless of whether
# the LLM emits end_turn. AC-1 (no manual `continue` intervention) becomes
# probabilistic — best-effort, not guaranteed.
#
# Opt-out: rite-config.yml `workflow.auto_fire_step0.enabled` (default: true).
#
# Reference:
#   - plugins/rite/skills/rite-workflow/references/sub-skill-return-protocol.md
#   - plugins/rite/commands/pr/cleanup.md Mandatory After Wiki Ingest
#   - plugins/rite/commands/wiki/ingest.md Mandatory After Auto-Lint

set -uo pipefail

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# Recursion guard.
[ -z "${_RITE_AUTO_FIRE_STEP0_RUNNING:-}" ] || exit 0
export _RITE_AUTO_FIRE_STEP0_RUNNING=1

# Read input from stdin (PostToolUse JSON: tool_name, tool_input, cwd, session_id, ...).
INPUT=$(cat 2>/dev/null) || INPUT=""
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

# Only fire for Skill tool invocations. hooks.json matcher restricts this,
# but a defensive check guards against future matcher drift.
case "$TOOL_NAME" in
  Skill|skill) ;;
  *) exit 0 ;;
esac

[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root and per-session flow-state file.
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"
if FLOW_STATE=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT" 2>/dev/null); then
  :
else
  FLOW_STATE="$STATE_ROOT/.rite-flow-state"
fi
[ -f "$FLOW_STATE" ] || exit 0

CURRENT_PHASE=$(jq -r '.phase // empty' "$FLOW_STATE" 2>/dev/null) || exit 0
ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || exit 0
[ "$ACTIVE" = "true" ] || exit 0
[ -n "$CURRENT_PHASE" ] || exit 0

# Opt-out check: rite-config.yml `workflow.auto_fire_step0.enabled`.
CONFIG_FILE="$CWD/rite-config.yml"
if [ -f "$CONFIG_FILE" ]; then
  AUTO_FIRE_ENABLED=$(awk '
    /^workflow:/ { in_workflow=1; next }
    in_workflow && /^[a-zA-Z]/ { in_workflow=0 }
    in_workflow && /^[[:space:]]+auto_fire_step0:/ { in_block=1; next }
    in_block && /^[[:space:]]+[a-z_]+:/ && !/^[[:space:]]{4,}enabled:/ { in_block=0 }
    in_block && /^[[:space:]]+enabled:/ {
      sub(/.*enabled:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*/, "")
      gsub(/["'"'"']/, "")
      print tolower($0)
      exit
    }
  ' "$CONFIG_FILE" 2>/dev/null)
  case "$AUTO_FIRE_ENABLED" in
    false|no|0) exit 0 ;;
  esac
fi

# Caller mapping: (current_phase) -> (post_phase, caller_name, next_action_text).
#
# Each entry covers a "pre-X" state where a sub-skill is mid-flight via the
# flow-state ring pattern. After the Skill tool returns, this hook advances
# to the corresponding "post-X" state (matching the caller's Mandatory After
# Step 0 Immediate Bash Action).
#
# DRIFT WARNING: Adding new entries requires synchronizing with:
#   - plugins/rite/commands/pr/cleanup.md Mandatory After Wiki Ingest Step 0
#   - plugins/rite/commands/wiki/ingest.md Mandatory After Auto-Lint Step 0
#   - plugins/rite/hooks/phase-transition-whitelist.sh whitelist entries
#   - plugins/rite/hooks/tests/cross-orchestrator-step0-symmetry.test.sh

POST_PHASE=""
NEXT_ACTION=""
CALLER_NAME=""

case "$CURRENT_PHASE" in
  ingest_pre_lint)
    POST_PHASE="ingest_post_lint"
    CALLER_NAME="rite:wiki:ingest"
    NEXT_ACTION="auto-fire-step0: ingest_post_lint patched. Proceed to Phase 8.3-8.5 then Phase 9 Completion Report in the SAME response turn. Do NOT stop."
    ;;
  cleanup_pre_ingest)
    POST_PHASE="cleanup_post_ingest"
    CALLER_NAME="rite:pr:cleanup"
    NEXT_ACTION="auto-fire-step0: cleanup_post_ingest patched. Proceed to Phase 5 Cleanup Result Summary in the SAME response turn. Do NOT stop."
    ;;
  *)
    # Unknown pre-X state -- silent no-op (e.g. /rite:issue:start-execute
    # delegation phases handled by their own Mandatory After sections).
    exit 0
    ;;
esac

# Idempotent patch. The caller's Mandatory After Step 0 also fires this same
# patch (--if-exists --preserve-error-count). Either side's success is
# sufficient; double-patch is harmless and serves as defense-in-depth.
#
# Note: flow-state-update.sh resolves STATE_ROOT via state-path-resolve.sh based
# on `$(pwd)`, so we MUST cd into $CWD (PostToolUse hook receives the user's cwd
# but is itself executed with the harness's cwd) before invoking. Use a
# sub-shell to keep the cd local.
if ! (
  cd "$CWD" && bash "$SCRIPT_DIR/flow-state-update.sh" patch \
      --phase "$POST_PHASE" \
      --active true \
      --next "$NEXT_ACTION" \
      --if-exists --preserve-error-count
) >&2; then
  echo "[CONTEXT] AUTO_FIRE_STEP0_PATCH_FAILED=1; caller=$CALLER_NAME; phase=$POST_PHASE" >&2
fi

# Inject context into the next LLM turn input via
# hookSpecificOutput.additionalContext (Claude Code official JSON output).
ADDITIONAL_CONTEXT="[auto-fire-step0] Hook detected return from sub-skill (caller: ${CALLER_NAME}). Flow state has been auto-patched to '${POST_PHASE}'. You MUST continue immediately with the caller's next phase -- do NOT emit stop_reason: end_turn. The sub-skill return is NOT a turn boundary."

jq -n \
  --arg ctx "$ADDITIONAL_CONTEXT" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": $ctx
    }
  }' 2>/dev/null || true

exit 0
