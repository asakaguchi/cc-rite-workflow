#!/usr/bin/env bash
# Step 0 observation script.
# Determines parent_continuation_success for a single trial by examining the
# result flag files and (optionally) the session JSONL log.
#
# Usage:
#   observe.sh <variant> <trial_id> [session_jsonl_path]
#
# Variant names: a-skill-completion, b-task-completion, c-bash-completion,
#                d-inline-completion, e-task-non-completion
#
# Output: JSON to stdout summarizing the trial.

set -uo pipefail

VARIANT="${1:-}"
TRIAL_ID="${2:-}"
SESSION_JSONL="${3:-}"

if [ -z "$VARIANT" ] || [ -z "$TRIAL_ID" ]; then
  echo "usage: $0 <variant> <trial_id> [session_jsonl_path]" >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
RESULTS_DIR="$REPO_ROOT/tests/step0-experiment/results/$VARIANT"

STEP1_FLAG="$RESULTS_DIR/trial-$TRIAL_ID-step1.flag"
STEP3_FLAG="$RESULTS_DIR/trial-$TRIAL_ID-step3.flag"

step1_present=false
step3_present=false
[ -f "$STEP1_FLAG" ] && step1_present=true
[ -f "$STEP3_FLAG" ] && step3_present=true

# Determine outcome
if [ "$step1_present" = false ]; then
  outcome="excluded_no_start"
  parent_continuation_success="null"
elif [ "$step3_present" = true ]; then
  outcome="success"
  parent_continuation_success="true"
else
  outcome="failure_implicit_stop"
  parent_continuation_success="false"
fi

# Session log analysis (optional)
session_summary='""'
if [ -n "$SESSION_JSONL" ] && [ -f "$SESSION_JSONL" ]; then
  if command -v jq >/dev/null 2>&1; then
    skill_calls=$(grep -c '"name":"Skill"' "$SESSION_JSONL" 2>/dev/null || true)
    task_calls=$(grep -c '"name":"Task"' "$SESSION_JSONL" 2>/dev/null || true)
    bash_calls=$(grep -c '"name":"Bash"' "$SESSION_JSONL" 2>/dev/null || true)
    end_turn_count=$(grep -c '"stop_reason":"end_turn"' "$SESSION_JSONL" 2>/dev/null || true)
    : "${skill_calls:=0}"; : "${task_calls:=0}"; : "${bash_calls:=0}"; : "${end_turn_count:=0}"
    session_summary=$(jq -n \
      --argjson sc "$skill_calls" \
      --argjson tc "$task_calls" \
      --argjson bc "$bash_calls" \
      --argjson et "$end_turn_count" \
      '{skill_calls: $sc, task_calls: $tc, bash_calls: $bc, end_turn_count: $et}')
  fi
fi

# Emit JSON
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg variant "$VARIANT" \
    --arg trial_id "$TRIAL_ID" \
    --arg outcome "$outcome" \
    --argjson step1 "$step1_present" \
    --argjson step3 "$step3_present" \
    --argjson pcs "$parent_continuation_success" \
    --argjson session "$session_summary" \
    '{
      variant: $variant,
      trial_id: $trial_id,
      outcome: $outcome,
      step1_flag_present: $step1,
      step3_flag_present: $step3,
      parent_continuation_success: $pcs,
      session_summary: $session
    }'
else
  cat <<EOF
{
  "variant": "$VARIANT",
  "trial_id": "$TRIAL_ID",
  "outcome": "$outcome",
  "step1_flag_present": $step1_present,
  "step3_flag_present": $step3_present,
  "parent_continuation_success": $parent_continuation_success
}
EOF
fi
