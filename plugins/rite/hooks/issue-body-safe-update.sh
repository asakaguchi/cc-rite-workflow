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

# Resolve plugin root so callers don't have to pass it. workflow-incident-emit.sh sits next to
# this file under plugins/rite/hooks/. We follow the same resolution pattern used by
# wiki-ingest-trigger.sh / wiki-query-inject.sh / session-end.sh.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EMIT_SH="$_SCRIPT_DIR/workflow-incident-emit.sh"

# Helper: emit issue_body_fetch_failed sentinel via workflow-incident-emit.sh.
# Caller-side parsing of `fetch_failure_reason=` / `apply_failure_reason=` stdout
# is not guaranteed in every code path, so persistent body-update failures can
# slip through silently. Emit a sentinel into `.rite/incidents/` directly so the
# orchestrator's workflow-incident-detection grep always picks it up.
_emit_body_update_incident() {
  local reason="$1" rc="$2" stderr_snippet="$3"
  if [ -x "$_EMIT_SH" ]; then
    bash "$_EMIT_SH" \
      --type issue_body_fetch_failed \
      --details "Issue #$ISSUE issue-body-safe-update.sh $MODE failed: reason=$reason rc=$rc stderr=$stderr_snippet" \
      --root-cause-hint "$reason" \
      --pr-number 0 >&2 || echo "[rite] WARNING: issue-body-safe-update: workflow-incident-emit.sh exited non-zero (reason=$reason); incident may not be recorded" >&2
  else
    # Fallback for partial installs / stripped exec permission. Without this,
    # the incident would vanish entirely in degraded deployments where the
    # emit script is missing — and incident observability is the whole point
    # of this helper.
    echo "[rite][incident] type=issue_body_fetch_failed root_cause_hint=$reason rc=$rc details=Issue #${ISSUE:-unknown} issue-body-safe-update.sh ${MODE:-unknown} failed (workflow-incident-emit.sh not executable at $_EMIT_SH; using fallback sentinel) stderr=$stderr_snippet" >&2
  fi
}

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

# All callers (parent / non-parent) treat body-update failures as non-blocking:
# checklist append for the working Issue and Sub-Issues section append for the
# parent are both fail-soft. The --parent flag is preserved in the arg parser
# for future severity differentiation but currently has no behavioral effect.
err_level="WARNING"

case "$MODE" in
  fetch)
    # The script's non-blocking contract requires exit 0 on transient failure,
    # but unguarded mktemp under `set -euo pipefail` would abort silently when
    # /tmp is exhausted. Surface mktemp failure as a normal fetch_failure_reason
    # so the caller can branch on it instead of getting a mute exit.
    tmpfile_read=$(mktemp /tmp/rite-issue-body-read-XXXXXX) || {
      echo "${err_level}: issue-body-safe-update fetch: mktemp tmpfile_read failed (disk full / inode / permission?)" >&2
      echo "fetch_failure_reason=mktemp_failed"
      _emit_body_update_incident "mktemp_failed" "1" "tmpfile_read mktemp failed"
      exit 0
    }
    tmpfile_write=$(mktemp /tmp/rite-issue-body-write-XXXXXX) || {
      echo "${err_level}: issue-body-safe-update fetch: mktemp tmpfile_write failed" >&2
      echo "fetch_failure_reason=mktemp_failed"
      _emit_body_update_incident "mktemp_failed" "1" "tmpfile_write mktemp failed"
      rm -f "$tmpfile_read"
      exit 0
    }
    tmpfile_err=$(mktemp /tmp/rite-issue-body-err-XXXXXX) || {
      echo "${err_level}: issue-body-safe-update fetch: mktemp tmpfile_err failed" >&2
      echo "fetch_failure_reason=mktemp_failed"
      _emit_body_update_incident "mktemp_failed" "1" "tmpfile_err mktemp failed"
      rm -f "$tmpfile_read" "$tmpfile_write"
      exit 0
    }
    trap 'rm -f "$tmpfile_read" "$tmpfile_write" "$tmpfile_err"' EXIT

    # gh API 失敗 (auth / network / 404) と「body が本当に空」を区別するため、stderr を捕捉する。
    # set -e 下で gh が non-zero exit すると trap が走り tmpfile leak を防ぐ。
    if ! gh issue view "$ISSUE" --json body --jq '.body' >"$tmpfile_read" 2>"$tmpfile_err"; then
      rc=$?
      err_snippet=$(head -c 500 "$tmpfile_err" 2>/dev/null | tr -d '\r' || echo "")
      echo "${err_level}: gh issue view 失敗 (rc=$rc): ${err_snippet}" >&2
      echo "fetch_failure_reason=gh_view_failed"
      _emit_body_update_incident "gh_view_failed" "$rc" "$err_snippet"
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

    # Capture gh issue edit stderr so failures (auth / network / 404) can be
    # attributed in the incident rather than reported as "API failed, reason
    # unknown". The script is non-blocking, so mktemp failure degrades to
    # "no stderr capture" rather than aborting the caller's workflow.
    apply_err=$(mktemp /tmp/rite-issue-body-apply-err-XXXXXX) || {
      echo "${err_level}: issue-body-safe-update apply: mktemp apply_err failed; stderr capture disabled" >&2
      _emit_body_update_incident "mktemp_failed" "1" "apply_err mktemp failed"
      apply_err=""
    }
    trap 'rm -f "$apply_err" 2>/dev/null || true' EXIT
    if ! gh issue edit "$ISSUE" --body-file "$TMPFILE_WRITE" 2>"${apply_err:-/dev/null}"; then
      rc=$?
      err_snippet=$(head -c 500 "${apply_err:-/dev/null}" 2>/dev/null | tr -d '\r' || echo "")
      echo "${err_level}: gh issue edit 失敗 (rc=$rc): ${err_snippet}" >&2
      echo "apply_failure_reason=gh_edit_failed"
      _emit_body_update_incident "gh_edit_failed" "$rc" "$err_snippet"
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
