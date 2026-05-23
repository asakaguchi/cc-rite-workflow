#!/bin/bash
# rite workflow - Unified flow-state management (schema_version=3)
# Subcommands: set | get | deactivate | migrate
# Replaces: flow-state-update.sh, state-read.sh, _resolve-flow-state-path.sh,
#           _resolve-schema-version.sh, resume-active-flag-restore.sh, phase-transition-whitelist.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-path-resolve.sh
source "$SCRIPT_DIR/state-path-resolve.sh"

# Callers may pre-resolve STATE_ROOT (e.g., session-start.sh resolves it from
# the hook payload's `cwd` field, which differs from flow-state.sh's own CWD)
# and pass it via the RITE_STATE_ROOT env var so the resolver does not silently
# fall back to its own pwd. Falls back to the CWD-based resolver when unset.
if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "$RITE_STATE_ROOT" ]; then
  STATE_ROOT="$RITE_STATE_ROOT"
else
  STATE_ROOT=$(resolve_state_root)
fi
SESSION_DIR="$STATE_ROOT/.rite/sessions"
LEGACY_STATE="$STATE_ROOT/.rite-flow-state"
SESSION_ID_FILE="$STATE_ROOT/.rite-session-id"

# Phase enum SoT (13 values) — PR 2a refactor; SoT also referenced from resume.md cross-check.
PHASE_ENUM_V3="init branch plan implement lint pr review fix ready ready_error cleanup ingest completed"
SCHEMA_VERSION_V3=3

_phase_is_valid() {
  for v in $PHASE_ENUM_V3; do [ "$v" = "$1" ] && return 0; done
  return 1
}

# Legacy v1/v2 phase → v3 reduction (PR 2a SoT). Unknown values pass through.
_phase_migrate() {
  case "$1" in
    cleanup_pre_ingest|cleanup_post_ingest|cleanup_completed) echo cleanup ;;
    ingest_pre_lint|ingest_post_lint|ingest_completed) echo ingest ;;
    implementing) echo implement ;;
    create_*|parent_progress_sync|unknown) echo init ;;
    *) echo "$1" ;;
  esac
}

_resolve_session_id() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    case "$override" in *..*|*/*) echo "ERROR: invalid session_id: $override" >&2; return 1 ;; esac
    printf '%s\n' "$override"; return 0
  fi
  if [ -f "$SESSION_ID_FILE" ]; then
    local sid; sid=$(tr -d '[:space:]' < "$SESSION_ID_FILE" 2>/dev/null) || sid=""
    [ -n "$sid" ] && printf '%s\n' "$sid" && return 0
  fi
  [ -n "${CLAUDE_SESSION_ID:-}" ] && { printf '%s\n' "$CLAUDE_SESSION_ID"; return 0; }
  echo "ERROR: cannot resolve session_id" >&2; return 1
}

_state_path() {
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
  printf '%s\n' "$SESSION_DIR/${1}.flow-state"
}

_atomic_write() {
  local target="$1" content="$2" lockfile="${1}.lock" tmpfile rc=0
  tmpfile=$(mktemp "${target}.XXXXXX") || return 1
  printf '%s' "$content" > "$tmpfile"
  ( flock -w 3 9 || { echo "ERROR: flock timeout: $lockfile" >&2; exit 1; }
    mv "$tmpfile" "$target" ) 9>"$lockfile" || rc=$?
  [ -f "$tmpfile" ] && rm -f "$tmpfile" 2>/dev/null || true
  return $rc
}

cmd_set() {
  # Merge semantics: unspecified scalar fields preserve existing values (旧 patch 互換).
  # Required: --phase, --next. Optional fields fall back to existing JSON or defaults.
  local phase="" next="" session="" if_exists=0 preserve_error=0
  local issue="" branch="" pr="" parent_issue="" active=""
  while [ $# -gt 0 ]; do case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --parent-issue) parent_issue="$2"; shift 2 ;;
    --next) next="$2"; shift 2 ;;
    --active) active="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --if-exists) if_exists=1; shift ;;
    --preserve-error-count) preserve_error=1; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  [ -z "$phase" ] && { echo "ERROR: --phase is required" >&2; return 1; }
  [ -z "$next" ] && { echo "ERROR: --next is required" >&2; return 1; }
  _phase_is_valid "$phase" || echo "WARNING: unknown phase: $phase (allowed: $PHASE_ENUM_V3)" >&2
  local sid path; sid=$(_resolve_session_id "$session") || return 1
  path=$(_state_path "$sid")
  [ $if_exists -eq 1 ] && [ ! -f "$path" ] && return 0
  # Pull existing values for fields the caller did not specify (merge behavior).
  # `cur_last_synced` は post-tool-wm-sync.sh が runtime-only field として書き続けるため、
  # cmd_set が schema 構築時に既存値を merge しないと毎回 wipe され、wm-sync の diff guard
  # が常に「変化あり」と判定 → GitHub API spam (issue-comment-wm-sync 連発、PR #1089 H1)。
  # 既存値が無い場合は空文字 → null として書き込み、wm-sync 側の `// "" | tostring` で
  # 空文字に縮退する (空 vs 非空 を別値として扱う wm-sync の diff guard と整合)。
  #
  # Single composite jq read (PR #1089 H3): 6 つの独立 jq 呼び出しの silent fallback chain
  # では既存 state が corrupt JSON でも全フィールドが default に縮退して silent overwrite
  # される。1 回の composite jq + stderr capture に集約し、jq 失敗時に WARNING を stderr emit
  # して operator が corrupt overwrite を検出できるようにする。Unit separator () で field
  # を分割し、IFS で安全に split (whitespace collapse 防止)。
  local cur_issue=0 cur_branch="" cur_pr=0 cur_parent=0 cur_active=true cur_err=0 cur_last_synced=""
  if [ -f "$path" ]; then
    local _cur_jq_err _cur_data _cur_rc=0
    _cur_jq_err=$(mktemp 2>/dev/null) || _cur_jq_err=""
    _cur_data=$(jq -r '[(.issue_number // 0 | tostring),
                       (.branch // ""),
                       (.pr_number // 0 | tostring),
                       (.parent_issue_number // 0 | tostring),
                       (.active // true | tostring),
                       (.error_count // 0 | tostring),
                       (.last_synced_phase // "")] | join("")' "$path" 2>"${_cur_jq_err:-/dev/null}") || _cur_rc=$?
    if [ "$_cur_rc" -ne 0 ]; then
      echo "WARNING: flow-state.sh cmd_set: existing state read failed for $path (may be corrupt; merged write will use defaults)" >&2
      [ -n "$_cur_jq_err" ] && [ -s "$_cur_jq_err" ] && head -3 "$_cur_jq_err" | sed 's/^/  /' >&2
    else
      IFS=$'\x1f' read -r cur_issue cur_branch cur_pr cur_parent cur_active cur_err cur_last_synced <<< "$_cur_data"
    fi
    [ -n "$_cur_jq_err" ] && rm -f "$_cur_jq_err"
  fi
  [ -z "$issue" ] && issue=$cur_issue
  [ -z "$branch" ] && branch=$cur_branch
  [ -z "$pr" ] && pr=$cur_pr
  [ -z "$parent_issue" ] && parent_issue=$cur_parent
  [ -z "$active" ] && active=$cur_active
  local err_count=0
  [ $preserve_error -eq 1 ] && err_count=$cur_err
  local now new; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  new=$(jq -n \
    --argjson schema "$SCHEMA_VERSION_V3" --arg session "$sid" \
    --arg phase "$phase" --argjson issue "$issue" --arg branch "$branch" \
    --argjson pr "$pr" --argjson parent "$parent_issue" \
    --arg next "$next" --argjson active "$active" \
    --argjson err "$err_count" --arg ts "$now" \
    --arg lsp "$cur_last_synced" \
    '{schema_version:$schema, session_id:$session, phase:$phase,
      issue_number:$issue, branch:$branch, pr_number:$pr,
      parent_issue_number:$parent, next_action:$next, active:$active,
      error_count:$err, updated_at:$ts}
     | (if $lsp != "" then .last_synced_phase = $lsp else . end)') || return 1
  _atomic_write "$path" "$new"
}

cmd_get() {
  local field="" default="" session="" jq_filter=""
  while [ $# -gt 0 ]; do case "$1" in
    --field) field="$2"; shift 2 ;;
    --default) default="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --jq-filter) jq_filter="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid path
  sid=$(_resolve_session_id "$session" 2>/dev/null) || { printf '%s\n' "$default"; return 0; }
  path=$(_state_path "$sid")
  [ ! -f "$path" ] && { printf '%s\n' "$default"; return 0; }
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter" "$path" 2>/dev/null || printf '%s\n' "$default"
    return 0
  fi
  [ -z "$field" ] && { echo "ERROR: --field or --jq-filter required" >&2; return 1; }
  jq -r --arg d "$default" ".${field} // \$d" "$path" 2>/dev/null || printf '%s\n' "$default"
}

cmd_deactivate() {
  local next="" session=""
  while [ $# -gt 0 ]; do case "$1" in
    --next) next="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid path; sid=$(_resolve_session_id "$session") || return 1
  path=$(_state_path "$sid"); [ ! -f "$path" ] && return 0
  local now updated; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  updated=$(jq --argjson a false --arg n "$next" --arg ts "$now" \
    '.active = $a | (if $n != "" then .next_action = $n else . end) | .updated_at = $ts' "$path") || return 1
  _atomic_write "$path" "$updated"
}

_migrate_file() {
  local f="$1" dry="$2" verbose="$3" sv cp np
  sv=$(jq -r '.schema_version // 1' "$f" 2>/dev/null) || sv=1
  cp=$(jq -r '.phase // ""' "$f" 2>/dev/null) || cp=""
  [ "$sv" = "$SCHEMA_VERSION_V3" ] && { [ "$verbose" = 1 ] && echo "  skip (already v3): $f" >&2; return 1; }
  np=$(_phase_migrate "$cp")
  [ "$dry" = 1 ] && { echo "  would migrate: $f (schema v$sv→v$SCHEMA_VERSION_V3, phase $cp→$np)"; return 0; }
  local now updated; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # v3 schema: drop legacy `previous_phase` (replaced by step name discrimination in v3) and
  # normalize legacy `branch_name` → `branch`. `last_synced_phase` is preserved because
  # post-tool-wm-sync.sh continues to use it as a runtime-only diff guard field (PR #1089 H1);
  # dropping it during migrate would cause one round of unnecessary GitHub API spam right after
  # migration.
  updated=$(jq --argjson s "$SCHEMA_VERSION_V3" --arg p "$np" --arg ts "$now" \
    'del(.previous_phase)
     | (if .branch_name and (.branch | not) then .branch = .branch_name else . end)
     | del(.branch_name)
     | .schema_version = $s | .phase = $p | .updated_at = $ts' "$f") || return 1
  _atomic_write "$f" "$updated"
  [ "$verbose" = 1 ] && echo "  migrated: $f (v$sv→v$SCHEMA_VERSION_V3, $cp→$np)" >&2
  return 0
}

cmd_migrate() {
  local dry=0 verbose=0 migrated=0
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift ;;
    --verbose) verbose=1; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  if [ -d "$SESSION_DIR" ]; then
    for f in "$SESSION_DIR"/*.flow-state; do
      [ -f "$f" ] || continue
      _migrate_file "$f" "$dry" "$verbose" && migrated=$((migrated + 1)) || true
    done
  fi
  [ -f "$LEGACY_STATE" ] && _migrate_file "$LEGACY_STATE" "$dry" "$verbose" && migrated=$((migrated + 1)) || true
  echo "Migration complete: $migrated file(s) processed"
}

cmd_path() {
  local session=""
  while [ $# -gt 0 ]; do case "$1" in
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid; sid=$(_resolve_session_id "$session") || return 1
  _state_path "$sid"
}

case "${1:-}" in
  set) shift; cmd_set "$@" ;;
  get) shift; cmd_get "$@" ;;
  deactivate) shift; cmd_deactivate "$@" ;;
  migrate) shift; cmd_migrate "$@" ;;
  path) shift; cmd_path "$@" ;;
  *)
    cat >&2 <<EOF
Usage: $0 {set|get|deactivate|migrate|path} [options]
  set --phase <P> --next <T> [--issue N] [--branch S] [--pr N] [--parent-issue N]
      [--active true|false] [--session UUID] [--if-exists] [--preserve-error-count]
  get --field <F> [--default V] [--session UUID]
      | --jq-filter <FILTER> [--default V] [--session UUID]
  deactivate [--next T] [--session UUID]
  migrate [--dry-run] [--verbose]
  path [--session UUID]
Phase enum (v3): $PHASE_ENUM_V3
EOF
    exit 1
    ;;
esac
