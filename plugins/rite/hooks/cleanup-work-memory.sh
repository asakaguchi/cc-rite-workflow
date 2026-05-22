#!/bin/bash
# rite workflow - Cleanup Work Memory
# Deterministic script for deleting local work memory files after cleanup/close.
# Does NOT depend on LLM placeholder substitution.
#
# Usage:
#   bash plugins/rite/hooks/cleanup-work-memory.sh [--issue <number>]
#
# Without --issue: reads issue number from .rite-flow-state, resets flow state
#   to active:false, deletes ALL issue-*.md files and lockdirs (full cleanup).
# With --issue <number>: deletes only the specified issue's files (close mode).
#   Does NOT reset .rite-flow-state (close.md handles its own state).
#
# Exit codes:
#   0: Success (files deleted or nothing to delete)
#   1: Argument error (missing or non-numeric --issue value)
#   Other non-zero: Unexpected error (forced exit by set -euo pipefail)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve repository root
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"

FLOW_STATE="$STATE_ROOT/.rite-flow-state"
WM_DIR="$STATE_ROOT/.rite-work-memory"

# Parse arguments
ISSUE_NUMBER=""
CLOSE_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ -n "${2:-}" ] || { echo "ERROR: --issue requires a number" >&2; exit 1; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: --issue must be a positive integer, got: '$2'" >&2; exit 1; }
      ISSUE_NUMBER="$2"
      CLOSE_MODE=true
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

deleted_count=0
failed_count=0

# --- Full cleanup mode (no --issue) ---
if [ "$CLOSE_MODE" = false ]; then
  # Step 1: Reset .rite-flow-state to active:false BEFORE deleting files
  # This prevents post-tool-wm-sync.sh from recreating files
  if [ -f "$FLOW_STATE" ]; then
    # Read issue number from flow state for logging
    ISSUE_NUMBER=$(jq -r '.issue_number // empty' "$FLOW_STATE" 2>/dev/null) || ISSUE_NUMBER=""
    # Validate issue number from flow state (non-numeric values would break --argjson)
    if [ -n "$ISSUE_NUMBER" ] && ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "WARNING: .rite-flow-state の issue_number が数値でない: '$ISSUE_NUMBER'. 0 にフォールバック" >&2
      ISSUE_NUMBER=""
    fi

    # `set -euo pipefail` would abort the entire cleanup if mktemp fails before
    # the trap is installed — leaving compact-state, lockdir, and per-issue
    # work memory files un-removed. Guard explicitly so the remaining cleanup
    # steps still run on temp-file failure.
    if TMP_STATE=$(mktemp "$FLOW_STATE.tmp.XXXXXX" 2>/dev/null); then
      trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT
      _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
      if jq -n \
        --argjson active false \
        --argjson issue "${ISSUE_NUMBER:-0}" \
        --arg branch "" \
        --arg phase "completed" \
        --argjson pr 0 \
        --arg next "none" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
        '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, pr_number: $pr, next_action: $next, updated_at: $ts}' \
        > "$TMP_STATE" 2>"${_jq_err:-/dev/null}"; then
        _mv_err=$(mktemp 2>/dev/null) || _mv_err=""
        # if/else over `if !` preserves the real mv rc (EXDEV=18, EACCES=13,
        # ENOSPC=28), which is the diagnostic the WARNING is meant to carry.
        if mv "$TMP_STATE" "$FLOW_STATE" 2>"${_mv_err:-/dev/null}"; then
          :
        else
          _mv_rc=$?
          echo "WARNING: .rite-flow-state の更新に失敗しました (mv rc=$_mv_rc)" >&2
          [ -n "$_mv_err" ] && [ -s "$_mv_err" ] && head -3 "$_mv_err" | sed 's/^/  /' >&2
        fi
        [ -n "$_mv_err" ] && rm -f "$_mv_err"
      else
        _jq_rc=$?
        echo "WARNING: .rite-flow-state のリセットに失敗しました (jq rc=$_jq_rc — missing in PATH / locale / parse error を区別)" >&2
        [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  /' >&2
      fi
      [ -n "$_jq_err" ] && rm -f "$_jq_err"
    else
      echo "WARNING: .rite-flow-state TMP_STATE mktemp failed — flow-state reset skipped (subsequent cleanup steps will still run)" >&2
      echo "  hint: $(dirname "$FLOW_STATE") の permission / disk full / read-only を確認" >&2
    fi
  fi

  # Step 2: Clean up .rite-compact-state
  rm -f "$STATE_ROOT/.rite-compact-state" 2>/dev/null || true
  rm -rf "$STATE_ROOT/.rite-compact-state.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory" >&2

  # Step 3: Delete ALL work memory files
  if [ -d "$WM_DIR" ]; then
    for f in "$WM_DIR"/issue-*.md; do
      [ -f "$f" ] || continue
      if rm -f "$f" 2>/dev/null; then
        deleted_count=$((deleted_count + 1))
      else
        echo "WARNING: 削除失敗: $f" >&2
        failed_count=$((failed_count + 1))
      fi
      rm -rf "${f}.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory_wm_dir" >&2
    done
  fi

# --- Close mode (--issue specified) ---
else
  # Delete only the specified issue's files
  target_file="$WM_DIR/issue-${ISSUE_NUMBER}.md"
  if [ -f "$target_file" ]; then
    if rm -f "$target_file" 2>/dev/null; then
      deleted_count=1
    else
      echo "WARNING: 削除失敗: $target_file" >&2
      failed_count=1
    fi
  fi
  rm -rf "$WM_DIR/issue-${ISSUE_NUMBER}.md.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory_issue" >&2
fi

# Step 4: Verify and report
remaining=0
if [ -d "$WM_DIR" ]; then
  remaining=$(find "$WM_DIR" -name 'issue-*.md' -type f 2>/dev/null | wc -l | tr -d ' ') || remaining=0
fi

echo "削除: ${deleted_count} 件, 失敗: ${failed_count} 件, 残存: ${remaining} 件"
exit 0
