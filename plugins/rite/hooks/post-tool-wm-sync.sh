#!/bin/bash
# rite workflow - PostToolUse Work Memory Sync Hook
# Auto-creates local work memory when missing during an active workflow.
# Also auto-syncs Issue comment work memory when phase changes (Issue #167).
# Fires after every Bash tool use; quick-exits in most cases.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_POSTTOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_POSTTOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# Recursion guard
[ -z "${RITE_WM_HOOK_ACTIVE:-}" ] || exit 0
export RITE_WM_HOOK_ACTIVE=1

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Per-session state path resolution (Issue #681): _resolve-flow-state-path.sh
# returns the per-session file (`<root>/.rite/sessions/<session_id>.flow-state`)
# when schema_version=2 with a valid SID, or the legacy `.rite-flow-state` path
# otherwise. The atomic write below (last_synced_phase update) targets whichever
# file the resolver returns, preserving per-session isolation under schema 2 and
# falling back to the single-file lock under schema 1.
if FLOW_STATE=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT" 2>/dev/null); then
  :
else
  # Resolver failed (helper deploy regression / path validation rejection).
  # stderr was suppressed above to keep the hook silent in the common case;
  # surface the failure under RITE_DEBUG so deploy regressions are observable.
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: _resolve-flow-state-path.sh failed, falling back to legacy path" \
    >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
  FLOW_STATE="$STATE_ROOT/.rite-flow-state"
fi
[ -f "$FLOW_STATE" ] || exit 0

# Unit separator (\x1f) prevents POSIX IFS from collapsing adjacent
# whitespace delimiters. With tab, .phase="" + non-empty .last_synced_phase
# would left-shift every field so _phase and _last_synced_phase swap,
# making the diff guard fire erroneously and sending the wrong value
# through issue-comment-wm-sync.sh --transform update-phase.
_flow_data=$(jq -r '[(.active // false | tostring), (.issue_number // "" | tostring), (.phase // "" | tostring), (.last_synced_phase // "" | tostring)] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r _active issue_number _phase _last_synced_phase <<< "$_flow_data"
[ "$_active" = "true" ] || exit 0
[ -n "$issue_number" ] || exit 0
# Session ownership check (#173): skip sync for other session's state.
#
# Note (Issue #681 F-04): under schema_version=2 with a per-session $FLOW_STATE,
# `check_session_ownership` returns "own" via its schema-2 fast-path without
# invoking jq, so the failure path is structurally absent and the
# `|| _ownership="own"` defensive default is dead code in that branch. The
# fallback remains active for schema_version=1 (legacy single-file path),
# where extract_session_id / get_state_session_id may fail under
# environmental issues (jq error, IO error). Keep both branches.
_ownership=$(check_session_ownership "$INPUT" "$FLOW_STATE") || _ownership="own"
[ "$_ownership" != "other" ] || exit 0
# Defense-in-depth: don't recreate WM for completed workflows (#776)
[ "$_phase" != "completed" ] || exit 0
[ "$_phase" != "cleanup" ] || exit 0

LOCAL_WM="$STATE_ROOT/.rite-work-memory/issue-${issue_number}.md"

# Debug logging (moved before LOCAL_WM check for use in both code paths)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: $1" \
    >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

if [ ! -f "$LOCAL_WM" ]; then
  # --- Existing logic: auto-create local WM when missing ---
  log_debug "local WM missing for issue #${issue_number}, auto-creating"

  cd "$STATE_ROOT" || exit 0
  source "$SCRIPT_DIR/work-memory-update.sh" || { log_debug "failed to source work-memory-update.sh"; exit 0; }
  export WM_PLUGIN_ROOT="${WM_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"

  # cycle 12 HIGH F-01: unit separator 統一 (L33 と同じ理由)
  _wm_data=$(jq -r '[(.phase // "unknown"), (.next_action // "")] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || _wm_data=$'unknown\x1f'
  IFS=$'\x1f' read -r phase next_action <<< "$_wm_data"

  export WM_SOURCE="auto_hook"
  export WM_PHASE="$phase"
  export WM_PHASE_DETAIL="Auto-created by PostToolUse hook"
  export WM_NEXT_ACTION="$next_action"
  export WM_BODY_TEXT="Local work memory auto-created by PostToolUse hook."
  export WM_ISSUE_NUMBER="$issue_number"

  if update_local_work_memory; then
    log_debug "local WM created successfully"
  else
    log_debug "update_local_work_memory failed (exit $?)"
  fi
  exit 0
fi

# === Phase diff detection & Issue comment auto-sync (Issue #167) ===
# Scope: phase changes only. next_action and loop_count changes are
# handled by explicit calls in command files (Phase 2 follow-up).
[ -n "$_phase" ] || exit 0
[ "$_phase" != "$_last_synced_phase" ] || exit 0

log_debug "phase changed: $_last_synced_phase -> $_phase, syncing to issue comment"

# --- 1. Phase update ---
_phase_detail=""
_phase_detail=$(python3 "$SCRIPT_DIR/work-memory-parse.py" "$LOCAL_WM" 2>/dev/null \
  | jq -r '.data.phase_detail // ""' 2>/dev/null) || _phase_detail=""
[ -n "$_phase_detail" ] || _phase_detail="$_phase"

# Capture sync rc so a failed phase update does NOT advance last_synced_phase —
# advancing on failure makes the same phase skip its retry indefinitely until
# the user changes phase again, producing a silent drift in Issue comment work
# memory (gh auth expiry / rate limit / network failure all leave no trace
# under the previous `2>/dev/null || log_debug` swallow).
# Tag the WARNING with `stderr_capture=disabled` when mktemp fails so triagers
# can distinguish "sync failed AND we lost the root-cause stderr" from "sync
# failed and the captured stderr below tells us why". Without this flag a
# rate-limit / auth-expiry failure on a hardened CI runner (read-only /tmp,
# inode exhaustion, SELinux deny) is indistinguishable from "the helper
# emitted no stderr at all".
_phase_sync_err=$(mktemp 2>/dev/null) || _phase_sync_err=""
_phase_sync_stderr_tag=""
[ -z "$_phase_sync_err" ] && _phase_sync_stderr_tag=" stderr_capture=disabled"
_phase_sync_ok=0
if "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
    --issue "$issue_number" \
    --transform update-phase \
    --phase "$_phase" \
    --phase-detail "$_phase_detail" 2>"${_phase_sync_err:-/dev/null}"; then
  _phase_sync_ok=1
else
  _rc=$?
  echo "[rite] WARNING: post-tool-wm-sync: update-phase failed (rc=$_rc${_phase_sync_stderr_tag}) — last_synced_phase will NOT be advanced so next hook invocation retries" >&2
  [ -n "$_phase_sync_err" ] && [ -s "$_phase_sync_err" ] && head -3 "$_phase_sync_err" | sed 's/^/  /' >&2
fi
[ -n "$_phase_sync_err" ] && rm -f "$_phase_sync_err"

# --- 2. Progress table + changed files update (per-commit and post-implementation phases) ---
# Flat phase `implement` fires for every commit during implementation (so the
# progress table can track files added/modified incrementally); legacy
# `phase5_post_execute` is the pre-flat equivalent. lint/pr/review/fix/completed
# trigger end-of-cycle refresh.
case "$_phase" in
  phase5_lint|phase5_post_lint|phase5_post_execute|phase5_pr*|phase5_post_review|phase5_post_ready|implement|lint|pr|review|fix|completed)
    cd "$STATE_ROOT" || { log_debug "cd STATE_ROOT failed"; exit 0; }

    _base_branch=$(grep -E '^  base:' "$STATE_ROOT/rite-config.yml" 2>/dev/null | sed 's/.*base:[[:space:]]*"\?\([^"]*\)"\?.*/\1/' || echo "develop")
    [ -n "$_base_branch" ] || _base_branch="develop"

    # mktemp fallback uses $$ + $RANDOM to avoid TOCTOU collision when two
    # Claude Code sessions share a PID; pure $$ on /tmp is race-prone.
    _changed_files_tmp=$(mktemp 2>/dev/null) || _changed_files_tmp="/tmp/rite-wm-sync-files.$$.${RANDOM}"
    _git_diff_err=$(mktemp 2>/dev/null) || _git_diff_err=""
    _diff_raw=$(git diff --name-status "origin/${_base_branch}...HEAD" 2>"${_git_diff_err:-/dev/null}") || _diff_raw=""
    if [ -n "$_git_diff_err" ] && [ -s "$_git_diff_err" ]; then
      echo "[rite] WARNING: post-tool-wm-sync: git diff failed — progress table may show stale or empty file list:" >&2
      head -3 "$_git_diff_err" | sed 's/^/  /' >&2
    fi
    [ -n "$_git_diff_err" ] && rm -f "$_git_diff_err"

    echo "$_diff_raw" | while IFS=$'\t' read -r status file; do
      [ -n "$status" ] || continue
      case "$status" in
        A) echo "- \`$file\` - 追加" ;;
        M) echo "- \`$file\` - 変更" ;;
        D) echo "- \`$file\` - 削除" ;;
        R*) echo "- \`$file\` - 名前変更" ;;
      esac
    done > "$_changed_files_tmp" 2>/dev/null || true

    _diff_files=$(echo "$_diff_raw" | awk -F'\t' '{print $2}')
    _impl_status="✅ 完了"
    _test_status="⬜ 未着手"
    _doc_status="⬜ 未着手"
    # Here-string avoids SIGPIPE from `grep -q` early-exit reaching the upstream `echo`.
    grep -qE '\.(test|spec)\.|test_|tests/' <<< "$_diff_files" 2>/dev/null && _test_status="✅ 完了"
    grep -qE '(docs/.*\.md|README\.md|CHANGELOG\.md|API\.md)' <<< "$_diff_files" 2>/dev/null && _doc_status="✅ 完了"

    _progress_sync_err=$(mktemp 2>/dev/null) || _progress_sync_err=""
    _progress_sync_stderr_tag=""
    [ -z "$_progress_sync_err" ] && _progress_sync_stderr_tag=" stderr_capture=disabled"
    # `if ! cmd; then _rc=$?` forces rc=0 inside the then-branch (POSIX `!` inverts
    # status). Use the else-branch to preserve the real exit code so triage logs
    # show `rc=N` (auth=1, rate-limit=4 etc.), not the misleading `rc=0`.
    if "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
        --issue "$issue_number" \
        --transform update-progress \
        --impl-status "$_impl_status" \
        --test-status "$_test_status" \
        --doc-status "$_doc_status" \
        --changed-files-file "$_changed_files_tmp" 2>"${_progress_sync_err:-/dev/null}"; then
      :
    else
      _rc=$?
      echo "[rite] WARNING: post-tool-wm-sync: update-progress failed (rc=$_rc${_progress_sync_stderr_tag}) — last_synced_phase will NOT be advanced" >&2
      [ -n "$_progress_sync_err" ] && [ -s "$_progress_sync_err" ] && head -3 "$_progress_sync_err" | sed 's/^/  /' >&2
      _phase_sync_ok=0
    fi
    [ -n "$_progress_sync_err" ] && rm -f "$_progress_sync_err"

    rm -f "$_changed_files_tmp"

    _plan_sync_err=$(mktemp 2>/dev/null) || _plan_sync_err=""
    _plan_sync_stderr_tag=""
    [ -z "$_plan_sync_err" ] && _plan_sync_stderr_tag=" stderr_capture=disabled"
    if "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
        --issue "$issue_number" \
        --transform update-plan-status 2>"${_plan_sync_err:-/dev/null}"; then
      :
    else
      _rc=$?
      echo "[rite] WARNING: post-tool-wm-sync: update-plan-status failed (rc=$_rc${_plan_sync_stderr_tag}) — last_synced_phase will NOT be advanced" >&2
      [ -n "$_plan_sync_err" ] && [ -s "$_plan_sync_err" ] && head -3 "$_plan_sync_err" | sed 's/^/  /' >&2
      _phase_sync_ok=0
    fi
    [ -n "$_plan_sync_err" ] && rm -f "$_plan_sync_err"

    log_debug "progress sync completed"
    ;;
esac

# --- 3. Update last_synced_phase only when ALL sync calls succeeded ---
# Advancing on partial failure would silently lose retry opportunity for the
# subset that failed; gating on _phase_sync_ok ensures the next hook invocation
# re-attempts every transformer that has not yet succeeded for this phase.
if [ "$_phase_sync_ok" = "1" ]; then
  _tmp_fs=$(mktemp "${FLOW_STATE}.tmp.XXXXXX" 2>/dev/null) || _tmp_fs="${FLOW_STATE}.tmp.$$.${RANDOM}"
  if jq --arg p "$_phase" '.last_synced_phase = $p' "$FLOW_STATE" > "$_tmp_fs" 2>/dev/null; then
    mv "$_tmp_fs" "$FLOW_STATE"
  else
    rm -f "$_tmp_fs"
  fi
fi

log_debug "phase sync completed ($_last_synced_phase -> $_phase)"
exit 0
