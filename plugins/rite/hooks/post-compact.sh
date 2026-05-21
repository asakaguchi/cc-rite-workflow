#!/bin/bash
# rite workflow - Post-Compact Hook
# Restores workflow context after compaction by outputting state to stdout.
# stdout is injected into the model's context, enabling automatic workflow continuation.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_POSTCOMPACT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_POSTCOMPACT=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
SOURCE=$(echo "$INPUT" | jq -r '.source // "auto"' 2>/dev/null) || SOURCE="auto"
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD)
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
  "post-compact" \
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

# --- Cleanup helper ---
_cleanup_compact_state() {
  rm -f "$COMPACT_STATE" 2>/dev/null || true
  rm -rf "$LOCKDIR" 2>/dev/null || true
}

# --- No flow state: clean up and exit ---
if [ ! -f "$FLOW_STATE" ]; then
  _cleanup_compact_state
  exit 0
fi

# --- Flow not active: clean up and exit ---
FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || FLOW_ACTIVE="false"
if [ "$FLOW_ACTIVE" != "true" ]; then
  _cleanup_compact_state
  exit 0
fi

# --- No compact state or not recovering: nothing to do ---
if [ ! -f "$COMPACT_STATE" ]; then
  exit 0
fi
COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
if [ "$COMPACT_VAL" != "recovering" ]; then
  exit 0
fi

# --- Source work-memory-lock for acquire/release helpers ---
source "$SCRIPT_DIR/work-memory-lock.sh"

# --- Read flow state ---
# cycle 11 CRITICAL F-01: IFS=$'\t' + @tsv は POSIX whitespace collapse により next_action=""
# のとき全フィールドが左 shift し、PR 欄に branch 名が混入する silent データ汚染を起こす。
# stop-guard.sh cycle 10 F-01 と同じ修正を適用 — unit separator \x1f で empty field を preserve。
FLOW_DATA=$(jq -r '[
  (.issue_number // "unknown" | tostring),
  (.phase // "unknown"),
  (.next_action // ""),
  (.loop_count // 0 | tostring),
  (.pr_number // 0 | tostring),
  (.branch // "")
] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || FLOW_DATA=""

if [ -z "$FLOW_DATA" ]; then
  # Cannot read flow state — clean up and exit silently
  _cleanup_compact_state
  exit 0
fi

IFS=$'\x1f' read -r ISSUE PHASE NEXT_ACTION LOOP PR BRANCH <<< "$FLOW_DATA"

# --- Transition compact_state to normal (inside lock) ---
TMP_COMPACT=""
cleanup() {
  # `_resolve_err` の synchronous rm は trap install より前で実行される (resolver 直後)
  # ため、ここで cleanup() に含める必要はない (dead code)。trap が発火する時点では既に
  # 削除済みで no-op となる。trap install 前の race window は同期 rm 自身でカバーされる。
  # PR #1079 review (silent-failure-hunter M-2): disk full / readonly fs / inode 不足 で
  # rm が失敗した場合に WARNING を出す。trap 内 fatal exit はしない (cleanup の責務範囲外)。
  rm -f "$TMP_COMPACT" 2>/dev/null || echo "[rite] WARNING: post-compact cleanup: failed to remove $TMP_COMPACT (disk full / readonly fs / permission?)" >&2
  release_wm_lock "$LOCKDIR"
}
trap cleanup EXIT TERM INT

if acquire_wm_lock "$LOCKDIR"; then
  TMP_COMPACT=$(mktemp "${COMPACT_STATE}.XXXXXX" 2>/dev/null) || TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
  if jq -n \
    --arg state "normal" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{compact_state: $state, compact_state_set_at: $ts}' \
    > "$TMP_COMPACT" 2>/dev/null; then
    mv "$TMP_COMPACT" "$COMPACT_STATE"
    TMP_COMPACT=""
  else
    rm -f "$TMP_COMPACT"
    TMP_COMPACT=""
  fi
  release_wm_lock "$LOCKDIR"
fi

# --- Issue #1003 AC-2/AC-7: PR Ready/Status mismatch reconciliation safety net ---
# When workflow active + PR exists + PR is Ready (isDraft=false) + Status != In Review,
# attempt reconciliation by re-invoking projects-status-update.sh. Emit incident sentinel
# on failure so silent Status mismatch never persists past compaction (Issue #1003 root cause:
# observability gap when Phase 4.2 / 5.5.1 silently skips).
#
# Stderr policy: `gh pr view` / `gh api graphql` / `projects-status-update.sh` の stderr は
# tempfile capture して incident details に含める。`gh repo view` も cycle 8 で stderr capture
# 対応済 (C7-F01: auth / rate-limit / network / permission の区別)。`jq` stderr は
# C7-F04 cycle 8 で `jq_owner_err` / `jq_name_err` capture 化済。
if [ "${PR:-0}" != "0" ] && [ "${PR:-0}" != "null" ] && [ -n "${PR:-}" ]; then
  PLUGIN_ROOT_PC="$(dirname "$SCRIPT_DIR")"
  # Sub-shell + pipefail + signal-specific trap pattern (PR #1079 で start-finalize.md は削除済;
  # 現在の対称化対象は post-compact + watchdog-status-mismatch の 2 site)。
  # gh API 失敗時に silent fall-through せず incident emit する (F-07 Asymmetric Fix 対策)。
  # reconcile script の stderr も capture し、incident details に含める。
  (
    set -o pipefail
    pr_view_err=""
    repo_view_err=""
    jq_owner_err=""
    jq_name_err=""
    gql_err=""
    jq_err=""
    reconcile_err=""
    _pc_cleanup() {
      rm -f "${pr_view_err:-}" "${repo_view_err:-}" \
            "${jq_owner_err:-}" "${jq_name_err:-}" \
            "${gql_err:-}" "${jq_err:-}" "${reconcile_err:-}"
    }
    trap 'rc=$?; _pc_cleanup; exit $rc' EXIT
    trap '_pc_cleanup; exit 130' INT
    trap '_pc_cleanup; exit 143' TERM
    trap '_pc_cleanup; exit 129' HUP
    # PR #1079 review (silent-failure-hunter I-3 対応): mktemp 失敗時 (disk full / inode 不足 /
    # /tmp 書き込み不可) は stderr capture が `/dev/null` 経路に流れ、auth/rate-limit/permission
    # 等の root cause が消失する。stderr_capture_disabled フラグを立てて incident details に
    # 含め、保守側で「stderr が空」と「stderr capture 自体が無効」を区別可能にする。
    stderr_capture_disabled=0
    pr_view_err=$(mktemp /tmp/rite-pc-pr-err-XXXXXX) || { pr_view_err=""; stderr_capture_disabled=1; echo "[rite] WARNING: post-compact: mktemp failed for pr_view_err; gh pr view stderr will not be captured" >&2; }
    repo_view_err=$(mktemp /tmp/rite-pc-repo-err-XXXXXX) || { repo_view_err=""; stderr_capture_disabled=1; echo "[rite] WARNING: post-compact: mktemp failed for repo_view_err; gh repo view stderr will not be captured" >&2; }
    jq_owner_err=$(mktemp /tmp/rite-pc-jq-owner-err-XXXXXX) || { jq_owner_err=""; stderr_capture_disabled=1; }
    jq_name_err=$(mktemp /tmp/rite-pc-jq-name-err-XXXXXX) || { jq_name_err=""; stderr_capture_disabled=1; }
    gql_err=$(mktemp /tmp/rite-pc-gql-err-XXXXXX) || { gql_err=""; stderr_capture_disabled=1; }
    jq_err=$(mktemp /tmp/rite-pc-jq-err-XXXXXX) || { jq_err=""; stderr_capture_disabled=1; }

    # cycle 8 C7-F09: STATE_ROOT 不可達時の cd 短絡を early-emit branch で扱う。
    # 旧実装は `cd "$STATE_ROOT" 2>/dev/null && gh pr view ...` で STATE_ROOT inaccessible 時に
    # cd 失敗 (stderr silent suppress) → gh pr view 未実行で `gh_pr_view_failed` 誤分類していた
    # (実原因は state_root_inaccessible)。
    # cycle 10 F-04 対応: L184/200/241/281 の `cd ... 2>/dev/null` から 2>/dev/null を削除し、
    # TOCTOU race (L175 check 後の permission 変更 / unmount) 時に cd 失敗の stderr を捕捉可能にした。
    if [ ! -d "$STATE_ROOT" ]; then
      bash "$PLUGIN_ROOT_PC/hooks/workflow-incident-emit.sh" \
        --type projects_status_in_review_missing \
        --details "Issue #$ISSUE post-compact: STATE_ROOT inaccessible ($STATE_ROOT) — gh pr view skipped" \
        --root-cause-hint "state_root_inaccessible" \
        --pr-number "$PR" >&2 || true
      exit 0
    fi

    if PR_IS_DRAFT=$(cd "$STATE_ROOT" && gh pr view "$PR" --json isDraft --jq '.isDraft // null' 2>"${pr_view_err:-/dev/null}"); then
      :
    else
      pr_rc=$?
      pr_err_oneline=$(head -c 200 "${pr_view_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
      # PR が close/merge/delete されている legitimate な終了状態 (gh CLI 実出力 `Could not resolve to a PullRequest`
      # の CamelCase 連結 stderr) と auth/network/permission failure を区別する。前者は false positive のため、
      # caller ステップ 8.5 で偽 Issue を auto-register する経路を防ぐため別 hint で emit する。
      # regex は `pull\s*request` で空白あり/なし両対応 (CamelCase 連結も classic 表現も catch)。
      if printf '%s' "$pr_err_oneline" | grep -qiE 'could not resolve.*pull\s*request|no.*pull\s*request found'; then
        pr_root_cause_hint="pr_deleted_or_inaccessible"
      else
        pr_root_cause_hint="post_compact_gh_pr_view_failed"
      fi
      stderr_flag=""
      [ "$stderr_capture_disabled" = "1" ] && stderr_flag=" stderr_capture=disabled"
      bash "$PLUGIN_ROOT_PC/hooks/workflow-incident-emit.sh" \
        --type projects_status_in_review_missing \
        --details "Issue #$ISSUE post-compact: gh pr view failed (rc=$pr_rc, stderr=$pr_err_oneline${stderr_flag})" \
        --root-cause-hint "$pr_root_cause_hint" \
        --pr-number "$PR" >&2 || true
      PR_IS_DRAFT=""
    fi

    if [ "$PR_IS_DRAFT" = "false" ]; then
      # cycle 8 C7-F01: gh repo view stderr を tempfile capture して root cause attribution を可能にする。
      # 旧: 4-site 対称化 (post-compact / watchdog / start.md Step 1.5 / start-finalize.md Step 0)
      # 現: 2-site 対称化 (post-compact / watchdog-status-mismatch)。PR #1079 で start.md Step 1.5 と
      # start-finalize.md は削除/統合され、現在は post-compact と watchdog の 2 site のみが本 pattern を維持。
      if REPO_INFO=$(cd "$STATE_ROOT" && gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then
        :
      else
        repo_rc=$?
        repo_err_oneline=$(head -c 200 "${repo_view_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
        REPO_INFO=""
      fi
      # cycle 8 C7-F04: jq stderr を独立 capture し、parse 失敗 (gh 成功だが JSON 破損 / null field)
      # の根本原因を C6-F09 emit の details に注入する。
      REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>"${jq_owner_err:-/dev/null}") || REPO_OWNER=""
      REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>"${jq_name_err:-/dev/null}") || REPO_NAME=""
      PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$STATE_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
      PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$STATE_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""
      # cycle 8 C7-F05: cascade emit guard。_owner_repo_ok flag で後段 graphql 経路を skip する
      # (silent_omit_disables_defense_chain への 2-stage 防御: emit 後の dead branch 抑止)。
      _owner_repo_ok=1
      # cycle 6 C6-F09 + cycle 8 C7-F03/C7-F04 対応: gh repo view 失敗 OR jq parse 結果が空の場合に
      # silent skip を防止する。gate を `-z REPO_INFO` から `-z REPO_OWNER || -z REPO_NAME` へ拡張し、
      # null field 返却 (auth-scope 縮退) 経路も覆う。
      if [ "$PROJECTS_ENABLED" = "true" ] && { [ -z "$REPO_INFO" ] || [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; }; then
        echo "[rite] ⚠️ post-compact: gh repo view failed or parse empty — reconciliation safety net unavailable" >&2
        _owner_repo_ok=0
        jq_owner_err_oneline=""
        jq_name_err_oneline=""
        [ -n "${jq_owner_err:-}" ] && [ -s "$jq_owner_err" ] && jq_owner_err_oneline=$(head -c 200 "$jq_owner_err" | tr '\n' ' ')
        [ -n "${jq_name_err:-}" ] && [ -s "$jq_name_err" ] && jq_name_err_oneline=$(head -c 200 "$jq_name_err" | tr '\n' ' ')
        if [ -z "$REPO_INFO" ]; then
          bash "$PLUGIN_ROOT_PC/hooks/workflow-incident-emit.sh" \
            --type projects_status_in_review_missing \
            --details "Issue #$ISSUE post-compact: gh repo view failed (rc=${repo_rc:-NA}, stderr=${repo_err_oneline:-NA})" \
            --root-cause-hint "post_compact_gh_repo_view_failed" \
            --pr-number "$PR" >&2 || true
        else
          bash "$PLUGIN_ROOT_PC/hooks/workflow-incident-emit.sh" \
            --type projects_status_in_review_missing \
            --details "Issue #$ISSUE post-compact: gh repo view returned null fields (owner=$REPO_OWNER name=$REPO_NAME jq_owner_stderr=$jq_owner_err_oneline jq_name_stderr=$jq_name_err_oneline)" \
            --root-cause-hint "post_compact_gh_repo_view_returned_null" \
            --pr-number "$PR" >&2 || true
        fi
        # cycle 10 F-17 対応: cascade emit guard の semantic として `if _owner_repo_ok != "1"; then exit 0; fi`
        # と等価な `exit 0` を直書きする。PR #1079 で start.md Step 1.5 と start-finalize.md は削除/統合された
        # ため、本 pattern は post-compact 内部に完結した guard となっている (旧 3 site symmetry は historical)。
        exit 0
      fi
      if [ "$PROJECTS_ENABLED" = "true" ] && [ -n "$PROJECT_NUMBER" ] && [ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ] && [ "$ISSUE" != "unknown" ]; then
        if CURRENT_STATUS=$(cd "$STATE_ROOT" && gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project { number }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$ISSUE" 2>"${gql_err:-/dev/null}" \
          | jq -r --argjson pn "$PROJECT_NUMBER" \
            '[.data.repository.issue.projectItems.nodes[] | select(.project.number == $pn) | .fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // empty' 2>"${jq_err:-/dev/null}"); then
          :
        else
          gql_rc=$?
          gql_err_oneline=$(head -c 200 "${gql_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
          jq_err_oneline=$(head -c 200 "${jq_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
          bash "$PLUGIN_ROOT_PC/hooks/workflow-incident-emit.sh" \
            --type projects_status_in_review_missing \
            --details "Issue #$ISSUE post-compact: gh api graphql failed (rc=$gql_rc, gh_stderr=$gql_err_oneline, jq_stderr=$jq_err_oneline)" \
            --root-cause-hint "post_compact_gh_api_failed" \
            --pr-number "$PR" >&2 || true
          CURRENT_STATUS=""
        fi

        if [ -n "$CURRENT_STATUS" ] && [ "$CURRENT_STATUS" != "In Review" ] && [ "$CURRENT_STATUS" != "Done" ]; then
          echo "[rite] ⚠️ post-compact mismatch detected: Issue #$ISSUE PR=#$PR isDraft=false Status=\"$CURRENT_STATUS\" (expected In Review)" >&2
          # cycle 8 C7-F09 / C7-F14 対応: STATE_ROOT 存在 guard は sub-shell 冒頭に移動済 (state_root_inaccessible
          # で early emit + exit 0)、本 reconciliation 試行ブロックは STATE_ROOT 存在前提で reconcile を直接実行する。
          reconcile_err=$(mktemp /tmp/rite-pc-reconcile-err-XXXXXX) || reconcile_err=""
          RECONCILE_RESULT=$(cd "$STATE_ROOT" && bash "$PLUGIN_ROOT_PC/scripts/projects-status-update.sh" "$(jq -n \
            --argjson issue "$ISSUE" --arg owner "$REPO_OWNER" --arg repo "$REPO_NAME" \
            --argjson project_number "$PROJECT_NUMBER" --arg status "In Review" \
            --argjson auto_add false --argjson non_blocking true \
            '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>"${reconcile_err:-/dev/null}") || RECONCILE_RESULT=""
          RECONCILE_STATUS=$(printf '%s' "$RECONCILE_RESULT" | jq -r '.result // "failed"' 2>/dev/null) || RECONCILE_STATUS="failed"
          if [ "$RECONCILE_STATUS" = "updated" ]; then
            echo "[rite] ✅ post-compact reconciliation succeeded: Issue #$ISSUE Status → In Review" >&2
          else
            echo "[rite] ❌ post-compact reconciliation failed (result=$RECONCILE_STATUS)" >&2
            reconcile_err_oneline=$(head -c 200 "${reconcile_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
            bash "$PLUGIN_ROOT_PC/hooks/workflow-incident-emit.sh" \
              --type projects_status_in_review_missing \
              --details "Issue #$ISSUE post-compact reconciliation failed (PR=#$PR isDraft=false Status=$CURRENT_STATUS reconcile_result=$RECONCILE_STATUS stderr=$reconcile_err_oneline)" \
              --root-cause-hint "post_compact_reconciliation_failed" \
              --pr-number "$PR" >&2 || true
          fi
        fi
      fi
    fi
  )
fi

# --- stderr: user-facing notification ---
echo "[rite] compact 後の自動復帰を実行中 (Issue #${ISSUE}, Phase: ${PHASE})" >&2

# --- stdout: injected into model context ---
if [ "$SOURCE" = "auto" ]; then
  cat <<EOF
[rite] Auto-compact recovery: Issue #${ISSUE}, Phase: ${PHASE}, Branch: ${BRANCH}
Next action: ${NEXT_ACTION}
Loop: ${LOOP} | PR: #${PR}
Read .rite-flow-state and .rite-work-memory/issue-${ISSUE}.md for full context, then continue.
EOF
else
  # Manual compact: state re-injection only, no auto-continue instruction
  cat <<EOF
[rite] Compact recovery: Issue #${ISSUE}, Phase: ${PHASE}, Branch: ${BRANCH}
Next action: ${NEXT_ACTION}
Loop: ${LOOP} | PR: #${PR}
EOF
fi
