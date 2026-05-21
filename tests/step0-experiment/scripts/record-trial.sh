#!/usr/bin/env bash
# Record a single Step 0 trial.
# Captures environment, runs observe.sh, and persists result JSON.
#
# Usage:
#   record-trial.sh <variant> <trial_id> [session_jsonl_path]
#
# Side effects: writes
#   tests/step0-experiment/results/<variant>/trial-<trial_id>.json
#
# Exit codes:
#   0 — recorded
#   1 — usage / invalid input
#   2 — observe.sh failed

set -uo pipefail

VARIANT="${1:-}"
TRIAL_ID="${2:-}"
SESSION_JSONL="${3:-}"

if [ -z "$VARIANT" ] || [ -z "$TRIAL_ID" ]; then
  echo "usage: $0 <variant> <trial_id> [session_jsonl_path]" >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
SCRIPT_DIR="$REPO_ROOT/tests/step0-experiment/scripts"
RESULTS_DIR="$REPO_ROOT/tests/step0-experiment/results/$VARIANT"
mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/trial-$TRIAL_ID.json"

# Capture environment context (matches preflight.sh categories)
SETTINGS_FILE="$HOME/.claude/settings.json"
marketplace="unknown"
if [ -f "$SETTINGS_FILE" ] && command -v jq >/dev/null 2>&1; then
  marketplace=$(jq -r '.enabledPlugins["rite@rite-marketplace"] // "absent"' "$SETTINGS_FILE" 2>/dev/null)
fi

git_head=$(git rev-parse HEAD 2>/dev/null || echo "")
git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
git_dirty="false"
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  git_dirty="true"
fi
cc_version=""
if command -v claude >/dev/null 2>&1; then
  cc_version=$(claude --version 2>/dev/null | head -1)
fi

# Auto-detect session JSONL if not provided
if [ -z "$SESSION_JSONL" ]; then
  proj_dir="$HOME/.claude/projects/-home-akiyoshi-Projects-personal-cc-rite-workflow"
  if [ -d "$proj_dir" ]; then
    SESSION_JSONL=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1)
  fi
fi

# Run observation
OBSERVE_OUT=$(bash "$SCRIPT_DIR/observe.sh" "$VARIANT" "$TRIAL_ID" "$SESSION_JSONL" 2>/dev/null)
observe_rc=$?
if [ "$observe_rc" -ne 0 ]; then
  echo "observe.sh failed (rc=$observe_rc)" >&2
  exit 2
fi

# Compose final record (merge env context with observation)
if command -v jq >/dev/null 2>&1; then
  echo "$OBSERVE_OUT" | jq \
    --arg ts "$(date -Iseconds)" \
    --arg head "$git_head" \
    --arg branch "$git_branch" \
    --arg dirty "$git_dirty" \
    --arg ccv "$cc_version" \
    --arg mp "$marketplace" \
    --arg sjl "$SESSION_JSONL" \
    '. + {
      recorded_at: $ts,
      git_head: $head,
      git_branch: $branch,
      git_dirty: ($dirty == "true"),
      claude_cli: $ccv,
      marketplace_rite: $mp,
      session_jsonl: $sjl
    }' > "$OUT"
else
  printf '%s\n' "$OBSERVE_OUT" > "$OUT"
fi

echo "recorded: $OUT"
