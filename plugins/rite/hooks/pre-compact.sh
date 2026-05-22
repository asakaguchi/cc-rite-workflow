#!/bin/bash
# rite workflow - Pre-Compact Hook
# Sets blocked state and saves work memory snapshot before context compaction.
# compact itself cannot be prevented; this hook records state for safe resumption.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRECOMPACT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRECOMPACT=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
# Resolve active flow-state file path (Issue #680).
# Returns the per-session file when schema_version=2 with a valid SID; otherwise legacy.
#
# Issue #749: stderr pass-through for diagnostic visibility, via canonical helper
# `_mktemp-stderr-guard.sh`. 詳細は session-start.sh の同パターンを参照。
# filter は state-read.sh cross-session guard の 3-pattern を `^ERROR:` で
# superset 化した 4-pattern 拡張版 (resolver self-validation の ERROR: を捕捉)。
# success arm でも tempfile を inspect して helper graceful-degrade 経路の WARNING
# を silent drop しないようにする。
_resolve_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "pre-compact" \
  "resolve-flow-state-err" \
  "_resolve-flow-state-path.sh の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
# Single-pass branch (filter runs once regardless of resolver exit status).
_resolve_failed=0
FLOW_STATE=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT" 2>"${_resolve_err:-/dev/null}") || _resolve_failed=1
if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
  grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
fi
if [ "$_resolve_failed" -eq 1 ]; then
  FLOW_STATE="$STATE_ROOT/.rite-flow-state"
  echo "[rite] WARNING: flow-state path resolution failed, falling back to legacy ($FLOW_STATE)" >&2
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"
LOCKDIR="$COMPACT_STATE.lockdir"

# --- Cleanup function (covers all temp files) ---
TMP_FILE=""
TMP_COMPACT=""
cleanup() {
  # `_resolve_err` の synchronous rm は trap install より前で実行される (resolver 直後)
  # ため、ここで cleanup() に含める必要はない (dead code)。trap が発火する時点では既に
  # 削除済みで no-op となる。trap install 前の race window は同期 rm 自身でカバーされる。
  rm -f "$TMP_FILE" "$TMP_COMPACT" 2>/dev/null
  release_wm_lock "$LOCKDIR"
}

# --- Work memory update helper (reuses YAML frontmatter writing logic; also sources work-memory-lock.sh) ---
source "$SCRIPT_DIR/work-memory-update.sh"

trap cleanup EXIT TERM INT

# Session ownership check (#173): skip state updates for other session's state.
# Must run before lock to avoid holding the lock while doing nothing.
if [ -f "$FLOW_STATE" ]; then
  # Pass-through helper stderr so corrupt-state WARNINGs reach triage; the
  # helper's WARNING messages exist specifically to flag state-overwrite risk
  # against another active session, and a caller-side `2>/dev/null` would
  # silently negate them.
  _ownership=$(check_session_ownership "$INPUT" "$FLOW_STATE") || _ownership="own"
  if [ "$_ownership" = "other" ]; then
    exit 0
  fi
fi

# --- All state updates inside lock ---
if acquire_wm_lock "$LOCKDIR"; then
  # Update .rite-flow-state timestamp (inside lock for atomicity)
  if [ -f "$FLOW_STATE" ]; then
    TMP_FILE=$(mktemp "${FLOW_STATE}.XXXXXX" 2>/dev/null) || TMP_FILE="${FLOW_STATE}.tmp.$$"
    if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" '.updated_at = $ts' "$FLOW_STATE" > "$TMP_FILE"; then
      mv "$TMP_FILE" "$FLOW_STATE"
    else
      rm -f "$TMP_FILE"
    fi
    TMP_FILE=""
  fi

  # Determine active issue from flow state
  ACTIVE_ISSUE="null"
  if [ -f "$FLOW_STATE" ]; then
    ACTIVE_ISSUE=$(jq -r '.issue_number // "null"' "$FLOW_STATE" 2>/dev/null) || ACTIVE_ISSUE="null"
  fi

  # Validate ACTIVE_ISSUE is numeric before --argjson
  if [ "$ACTIVE_ISSUE" != "null" ] && ! [[ "$ACTIVE_ISSUE" =~ ^[0-9]+$ ]]; then
    ACTIVE_ISSUE="null"
  fi

  # If no active issue in flow state, try branch name
  if [ "$ACTIVE_ISSUE" = "null" ]; then
    BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null || echo "")
    if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
      ACTIVE_ISSUE="${BASH_REMATCH[1]}"
    fi
  fi

  # Write compact state — always set to "recovering" regardless of current state (#854, #133)
  # The previous "skip if resuming" guard (#851) was insufficient: when
  # post-compact-guard transitioned blocked→resuming on first denial, a second
  # compact would see "resuming" and skip, leaving all guards permissive.
  # Now PostCompact hook handles auto-recovery (recovering→normal), and pre-compact
  # always sets "recovering" to ensure every compact triggers PostCompact processing.
  TMP_COMPACT=$(mktemp "${COMPACT_STATE}.XXXXXX" 2>/dev/null) || TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
  # Capture jq stderr so a write failure (broken ACTIVE_ISSUE value, locale,
  # disk full) is diagnosable instead of being collapsed to the generic
  # "failed to write compact state" WARNING that loses the root cause.
  _jq_compact_err=$(mktemp 2>/dev/null) || _jq_compact_err=""
  if jq -n \
    --arg state "recovering" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson issue "$ACTIVE_ISSUE" \
    '{compact_state: $state, compact_state_set_at: $ts, active_issue: $issue}' \
    > "$TMP_COMPACT" 2>"${_jq_compact_err:-/dev/null}"; then
    mv "$TMP_COMPACT" "$COMPACT_STATE"
    chmod 600 "$COMPACT_STATE" 2>/dev/null || true
    TMP_COMPACT=""
  else
    _jq_compact_rc=$?
    rm -f "$TMP_COMPACT"
    TMP_COMPACT=""
    echo "rite: pre-compact: failed to write compact state (jq rc=$_jq_compact_rc)" >&2
    [ -n "$_jq_compact_err" ] && [ -s "$_jq_compact_err" ] && head -3 "$_jq_compact_err" | sed 's/^/  /' >&2
  fi
  [ -n "$_jq_compact_err" ] && rm -f "$_jq_compact_err"

  # --- Save local work memory snapshot ---
  # Only save snapshot when workflow is actively running (active: true).
  # Without this check, completed workflows would get their work memory files
  # recreated on compaction, causing stale file persistence. A jq parse
  # failure here (corrupt flow-state JSON) silently degrades to "skip
  # snapshot" — surface a WARNING so a corrupt state file doesn't quietly
  # cause snapshot loss in the middle of an active workflow.
  _flow_active_err=$(mktemp 2>/dev/null) || _flow_active_err=""
  if FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>"${_flow_active_err:-/dev/null}"); then
    :
  else
    _flow_active_rc=$?
    echo "rite: pre-compact: WARNING: failed to parse .active from $FLOW_STATE (jq rc=$_flow_active_rc) — workflow snapshot will be skipped, recovery may lose context" >&2
    [ -n "$_flow_active_err" ] && [ -s "$_flow_active_err" ] && head -3 "$_flow_active_err" | sed 's/^/  /' >&2
    FLOW_ACTIVE="false"
  fi
  [ -n "$_flow_active_err" ] && rm -f "$_flow_active_err"
  if [ "$FLOW_ACTIVE" = "true" ] && [ "$ACTIVE_ISSUE" != "null" ] && [ -f "$FLOW_STATE" ]; then
    # Read phase and next_action from flow state for env vars
    # Use unit separator () instead of tab so a future field containing
    # whitespace cannot shift later columns silently. next_action is trailing
    # today so the bug would not bite yet, but adding fields between them later
    # would corrupt downstream parsing without an obvious diff signal.
    FLOW_DATA=$(jq -r '[.phase // "unknown", .pr_number // "null", .loop_count // 0, .next_action // ""] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || FLOW_DATA=""
    if [ -n "$FLOW_DATA" ]; then
      IFS=$'\x1f' read -r PHASE PR_NUM LOOP_CNT NEXT_ACT <<< "$FLOW_DATA"
    else
      PHASE="unknown"
      PR_NUM="null"
      LOOP_CNT="0"
      NEXT_ACT=""
    fi

    # Delegate to shared helper (runs in subshell to isolate cd)
    # Issue #1003 AC-7/AC-8 observability: emit snapshot diag log so analysts can correlate
    # pre-compact write timing with subsequent post-compact phase. Without this, the
    # `create_delegation` snapshot fixation hypothesis is unverifiable (no record of which
    # phase value was captured at compact time).
    if (
      cd "$STATE_ROOT" || exit 1
      WM_ISSUE_NUMBER="$ACTIVE_ISSUE" \
      WM_SKIP_LOCK="true" \
      WM_SOURCE="pre_compact" \
      WM_PHASE="$PHASE" \
      WM_PHASE_DETAIL="compact 前 snapshot" \
      WM_NEXT_ACTION="$NEXT_ACT" \
      WM_BODY_TEXT="Pre-compact snapshot. PostCompact will auto-recover." \
      WM_PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")" \
      WM_PR_NUMBER="$PR_NUM" \
      WM_LOOP_COUNT="$LOOP_CNT" \
        update_local_work_memory
    ); then
      echo "[CONTEXT] PRE_COMPACT_SNAPSHOT_RECORDED=1; issue=$ACTIVE_ISSUE; phase=$PHASE; pr=$PR_NUM; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >&2
    else
      _wm_rc=$?
      echo "rite: pre-compact: work memory update failed (exit $_wm_rc)" >&2
      echo "[CONTEXT] PRE_COMPACT_SNAPSHOT_FAILED=1; issue=$ACTIVE_ISSUE; phase=$PHASE; pr=$PR_NUM; rc=$_wm_rc; reason=update_local_work_memory_failed" >&2
    fi
  fi

  release_wm_lock "$LOCKDIR"
fi

# Output advisory message only when workflow is active (#842, #776)
# FLOW_ACTIVE is set inside the lock block; defaults to "false" if lock was not acquired.
if [ "${FLOW_ACTIVE:-false}" = "true" ]; then
  # Provide defaults: PHASE may be unset when ACTIVE_ISSUE is null (line 96 guard)
  _ISSUE="${ACTIVE_ISSUE:-unknown}"
  _PHASE="${PHASE:-unknown}"

  # stderr: displayed directly to user's terminal (guaranteed visibility)
  echo "[rite] ⚠️ compact detected (Issue #${_ISSUE}, Phase: ${_PHASE}). Auto-recovery will proceed via PostCompact." >&2

  # stdout: fed to model as hook output (#887, #889)
  # Minimal message to reduce post-compaction token overhead.
  # System prompt alone is ~200K tokens; every token saved here helps stay under API limit.
  # PostCompact hook will restore full context after compaction completes.
  echo "STOP. Compact detected. Issue #${_ISSUE}. PostCompact will restore context. STOP."
fi
