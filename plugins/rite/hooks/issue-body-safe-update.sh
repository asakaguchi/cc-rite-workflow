#!/bin/bash
# rite workflow - Issue Body Safe Update
# Deterministic script for the fetch/validate and validate/apply steps
# of the 3-step safe Issue body update pattern.
#
# The 3-step pattern:
#   Step 1 (fetch):  issue-body-safe-update.sh fetch --issue <number>
#   Step 2 (edit):   Claude reads tmpfile_read, writes updated body to tmpfile_write
#   Step 3 (apply):  issue-body-safe-update.sh apply --issue <number> \
#                      --tmpfile-read <path> --tmpfile-write <path> --original-length <n>
#
# Fetch mode outputs:
#   tmpfile_read=<path>
#   tmpfile_write=<path>
#   original_length=<n>
#
# Apply mode validates and applies the update:
#   - Rejects empty write file
#   - Rejects body shrinkage below 50% of original (body loss prevention)
#   - Uses --body-file for safe gh issue edit
#
# Options:
#   --issue           Issue number (required)
#   --tmpfile-read    Path to temp file with original body (apply mode)
#   --tmpfile-write   Path to temp file with updated body (apply mode)
#   --original-length Original body length in bytes (apply mode)
#   --parent          Indicate parent Issue update (accepted for backward compatibility — current
#                     err_level is WARNING for all callers; flag is reserved for future severity
#                     differentiation between parent / non-parent body updates)
#   --diff-check      Verify a change was actually made (skip apply if identical)
#
# Exit codes:
#   0: Success or skip (non-blocking)
#   1: Argument error
set -euo pipefail

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

ISSUE=""
TMPFILE_READ=""
TMPFILE_WRITE=""
ORIGINAL_LENGTH=""
IS_PARENT=false
DIFF_CHECK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)           ISSUE="$2"; shift 2 ;;
    --tmpfile-read)    TMPFILE_READ="$2"; shift 2 ;;
    --tmpfile-write)   TMPFILE_WRITE="$2"; shift 2 ;;
    --original-length) ORIGINAL_LENGTH="$2"; shift 2 ;;
    --parent)          IS_PARENT=true; shift ;;
    --diff-check)      DIFF_CHECK=true; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$ISSUE" ]]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

# err_level is currently WARNING for all callers (parent / non-parent both use WARNING because
# body update failures are non-blocking in both contexts: checklist append for the working Issue
# and Sub-Issues section append for the parent Issue). The --parent flag is preserved in the
# arg parser for future severity differentiation, but does not change behavior today (PR #1079
# review: TI-1 dead-branch removed).
err_level="WARNING"

case "$MODE" in
  fetch)
    tmpfile_read=$(mktemp)
    tmpfile_write=$(mktemp)
    tmpfile_err=$(mktemp)
    trap 'rm -f "$tmpfile_read" "$tmpfile_write" "$tmpfile_err"' EXIT

    # gh API 失敗 (auth / network / 404) と「body が本当に空」を区別するため、stderr を捕捉する。
    # set -e 下で gh が non-zero exit すると trap が走り tmpfile leak を防ぐ。
    if ! gh issue view "$ISSUE" --json body --jq '.body' >"$tmpfile_read" 2>"$tmpfile_err"; then
      rc=$?
      err_snippet=$(head -c 500 "$tmpfile_err" 2>/dev/null | tr -d '\r' || echo "")
      echo "${err_level}: gh issue view 失敗 (rc=$rc): ${err_snippet}" >&2
      echo "fetch_failure_reason=gh_view_failed"
      exit 0
    fi

    if [ ! -s "$tmpfile_read" ]; then
      echo "${err_level}: Issue body が空。更新をスキップします" >&2
      echo "fetch_failure_reason=body_empty"
      exit 0
    fi

    original_length=$(wc -c < "$tmpfile_read")
    echo "original_length=$original_length"
    echo "tmpfile_read=$tmpfile_read"
    echo "tmpfile_write=$tmpfile_write"

    # err tmpfile は fetch 内で完結するため、persist は read/write のみ。
    rm -f "$tmpfile_err"
    # Disable trap so read/write files persist for Step 2/3
    trap - EXIT
    ;;

  apply)
    if [[ -z "$TMPFILE_READ" || -z "$TMPFILE_WRITE" || -z "$ORIGINAL_LENGTH" ]]; then
      echo "ERROR: apply mode requires --tmpfile-read, --tmpfile-write, --original-length" >&2
      exit 1
    fi

    if [ ! -s "$TMPFILE_WRITE" ]; then
      echo "${err_level}: 更新内容が空。更新をスキップします" >&2
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    # Body length comparison safety check
    updated_length=$(wc -c < "$TMPFILE_WRITE")
    if [[ "${updated_length:-0}" -lt $(( ${ORIGINAL_LENGTH:-1} / 2 )) ]]; then
      echo "${err_level}: 更新後の body が元の50%未満 (${updated_length}/${ORIGINAL_LENGTH})。body 消失の可能性があるためスキップします" >&2
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    # Diff check (optional, for idempotent updates like checkbox toggle)
    if [[ "$DIFF_CHECK" == true ]]; then
      if diff -q "$TMPFILE_READ" "$TMPFILE_WRITE" > /dev/null 2>&1; then
        echo "INFO: 変更なし（既に更新済み）"
        rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
        exit 0
      fi
    fi

    # gh issue edit 失敗を silent に通さない: stderr を捕捉して呼び出し元に root cause を渡し、
    # 失敗時も tmpfile を必ず clean up する。本 script は non-blocking 設計 (err_level=WARNING)
    # のため、API 失敗時も exit 0 を返す (呼び出し元の workflow を止めない)。
    apply_err=$(mktemp)
    trap 'rm -f "$apply_err"' EXIT
    if ! gh issue edit "$ISSUE" --body-file "$TMPFILE_WRITE" 2>"$apply_err"; then
      rc=$?
      err_snippet=$(head -c 500 "$apply_err" 2>/dev/null | tr -d '\r' || echo "")
      echo "${err_level}: gh issue edit 失敗 (rc=$rc): ${err_snippet}" >&2
      echo "apply_failure_reason=gh_edit_failed"
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE (expected: fetch, apply)" >&2
    exit 1
    ;;
esac
