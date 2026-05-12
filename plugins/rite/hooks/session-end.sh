#!/bin/bash
# rite workflow - Session End Hook
# Saves final state when session ends
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_SESSIONEND:-}" ] || exit 0
export _RITE_HOOK_RUNNING_SESSIONEND=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# # 旧実装 `source ... 2>/dev/null || true` 3 site は同 PR で pre-tool-bash-guard.sh / flow-state-update.sh
# が WARNING emit + stderr-tempfile pattern に置換されたのに対し、session-end.sh のみ doctrine から exempt
# だった。helper の deploy regression / syntax error 時に root cause が完全 silent に消えるため、
# 同型の mktemp + WARNING + head -3 pattern に統一する。
for _helper in hook-preamble.sh session-ownership.sh phase-transition-whitelist.sh; do
  _src_err=$(mktemp /tmp/rite-session-end-src-err-XXXXXX 2>/dev/null) || _src_err=""
  if ! source "$SCRIPT_DIR/$_helper" 2>"${_src_err:-/dev/null}"; then
    echo "WARNING: session-end: source $_helper failed (deploy regression / syntax error / permission?)" >&2
    if [ -n "$_src_err" ] && [ -s "$_src_err" ]; then
      head -3 "$_src_err" | sed 's/^/  /' >&2
    fi
  fi
  [ -n "$_src_err" ] && rm -f "$_src_err"
done
unset _helper _src_err

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# bash 5.2 デフォルト (`inherit_errexit` OFF) では `VAR=$(cmd)` の assignment は cmd 失敗で abort しないが、
# `|| INPUT=""` を明示することで cat 失敗時の rc を確実に 0 に正規化し、他 5 hook (notification.sh /
# post-compact.sh / pre-compact.sh / post-tool-wm-sync.sh / session-start.sh) と pattern を統一する。
# 失敗時の WARNING は `||` 右辺で emit する (cat 失敗のみを検出、EOF 空入力では出さない)。
INPUT=$(cat) || {
  echo "WARNING: session-end: stdin cat が失敗 (pipe broken / EBADF / SIGPIPE) — INPUT を空文字に fallback して continue" >&2
  echo "  影響: state deactivation 経路 skip → .active=true 残留 → 次 session-start で defensive reset signal 消失" >&2
  INPUT=""
}
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state file path using state-path-resolve.sh (consistent with other hooks)
# SCRIPT_DIR already set in preamble block above
# stderr 退避 + WARNING emit (pre-tool-bash-guard.sh / flow-state-update.sh の writer/reader 対称化
# doctrine と整合): script が deploy regression / syntax error で失敗した場合、silent CWD fallback
# だと root cause が完全に失われるため、WARNING + head -3 stderr pass-through で可視化する。
_state_path_err=$(mktemp /tmp/rite-session-end-state-path-err-XXXXXX 2>/dev/null) || _state_path_err=""
if ! STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>"${_state_path_err:-/dev/null}"); then
  echo "WARNING: session-end: state-path-resolve.sh 失敗 — CWD fallback します ($CWD)" >&2
  [ -n "$_state_path_err" ] && [ -s "$_state_path_err" ] && head -3 "$_state_path_err" | sed 's/^/  /' >&2
  STATE_ROOT="$CWD"
fi
[ -n "$_state_path_err" ] && rm -f "$_state_path_err"

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
  "session-end" \
  "resolve-flow-state-err" \
  "_resolve-flow-state-path.sh の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
# Single-pass branch (filter runs once regardless of resolver exit status).
_resolve_failed=0
STATE_FILE=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT" 2>"${_resolve_err:-/dev/null}") || _resolve_failed=1
if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
  # silent-failure-hunter M-3: grep の rc=1 (no match) と rc>=2 (IO error) を区別する
  # (flow-state-update.sh L284-290 の `_grep_classify_rc` pattern と writer/reader 対称化)。
  # 旧 `|| true` は grep IO error も silent suppress していた。
  grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2
  _grep_classify_rc=$?
  if [ "$_grep_classify_rc" -ge 2 ]; then
    echo "WARNING: session-end: resolver stderr の grep が IO error で失敗 (rc=$_grep_classify_rc)" >&2
  fi
fi
if [ "$_resolve_failed" -eq 1 ]; then
  STATE_FILE="$STATE_ROOT/.rite-flow-state"
  echo "[rite] WARNING: flow-state path resolution failed, falling back to legacy ($STATE_FILE)" >&2
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"

# Get current branch (stderr 退避 + WARNING emit、silent suppress を回避)
# cd 失敗 (CWD 不在 / permission denied) と git 失敗 (corrupt .git / detached HEAD) を独立 if-else で区別する。
# session-end は cleanup hook のため fail-fast せず WARNING + 続行 (Issue 番号 resolution 不能のみ)。
# detached HEAD では `git branch --show-current` は rc=0 で空文字を返すため空 BRANCH と cd 失敗は別経路として扱う。
_branch_err=$(mktemp /tmp/rite-session-end-branch-err-XXXXXX 2>/dev/null) || _branch_err=""
BRANCH=""
if [ ! -d "$CWD" ]; then
  echo "WARNING: session-end: CWD が存在しないかディレクトリではありません: $CWD" >&2
elif ! (cd "$CWD" 2>"${_branch_err:-/dev/null}"); then
  echo "WARNING: session-end: cd $CWD に失敗 (permission denied 等)" >&2
  [ -n "$_branch_err" ] && [ -s "$_branch_err" ] && head -3 "$_branch_err" | sed 's/^/  /' >&2
elif ! BRANCH=$(cd "$CWD" && git branch --show-current 2>"${_branch_err:-/dev/null}"); then
  echo "WARNING: session-end: git branch --show-current に失敗 (corrupt .git / git 未初期化)" >&2
  [ -n "$_branch_err" ] && [ -s "$_branch_err" ] && head -3 "$_branch_err" | sed 's/^/  /' >&2
  BRANCH=""
fi
[ -n "$_branch_err" ] && rm -f "$_branch_err"

# Check if on a feature branch with Issue number
if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
    ISSUE_NUMBER="${BASH_REMATCH[1]}"
    echo "rite: Saving final state for Issue #$ISSUE_NUMBER"
fi

# Deactivate flow state if it exists
if [ -f "$STATE_FILE" ]; then
    # Session ownership check (#173): only deactivate own/legacy/stale state.
    # Other session's fresh state (within 2h) must not be modified.
    # silent-failure-hunter M-1: 旧 `... 2>/dev/null || _ownership="own"` は
    # helper 関数定義漏れ / jq 失敗時に silent "own" 扱いで別 session の state を上書きする経路。
    # flow-state-update.sh IMP-4 (L62-71) の WARNING emit pattern と対称化し、fail-safe `"other"`
    # (= 触らずに残す) に倒す。"own と誤判定 → 他 session deactivate" より
    # "other と倒し → 触らずに残す" の方が安全。
    _ownership_err=$(mktemp /tmp/rite-session-end-ownership-err-XXXXXX 2>/dev/null) || _ownership_err=""
    if ! _ownership=$(check_session_ownership "$INPUT" "$STATE_FILE" 2>"${_ownership_err:-/dev/null}"); then
      echo "WARNING: session-end: check_session_ownership 失敗 — fail-safe 'other' に倒します (state を触らない)" >&2
      if [ -n "$_ownership_err" ] && [ -s "$_ownership_err" ]; then
        head -3 "$_ownership_err" | sed 's/^/  /' >&2
      fi
      _ownership="other"
    fi
    [ -n "$_ownership_err" ] && rm -f "$_ownership_err"
    if [ "$_ownership" = "other" ]; then
        # Another session's active state — do not modify
        echo "rite: skipping deactivation (state belongs to another session)" >&2
        exit 0
    fi

    # Lifecycle unfinished warnings (#475 AC-9, extended #608 follow-up for cleanup_*).
    # If the session is ending mid-lifecycle (active=true with a non-terminal phase),
    # emit an informational warning so the user knows what flow did NOT complete and
    # how to recover. session-end always proceeds with deactivation regardless.
    # Phase classification is delegated to phase-transition-whitelist.sh helpers as the
    # single source of truth (#501 HIGH).
    # 旧 `... 2>/dev/null || _state_*=""/false` は corrupt JSON 時に silent fallback で
    # lifecycle unfinished WARNING ブロックが skip され、ユーザーが「create / cleanup lifecycle が
    # 未完了」の最終警告を受け取れずに session 終了する経路。flow-state-update.sh の session-ownership
    # block (create mode 内 `if [[ -n "$SESSION" && -f "$FLOW_STATE" ]]` 配下の 4 jq site) の
    # WARNING emit pattern と対称化。
    _state_jq_err=$(mktemp /tmp/rite-session-end-state-jq-err-XXXXXX 2>/dev/null) || _state_jq_err=""
    if ! _state_phase=$(jq -r '.phase // empty' "$STATE_FILE" 2>"${_state_jq_err:-/dev/null}"); then
      echo "WARNING: session-end: jq .phase 抽出失敗 ($STATE_FILE) — lifecycle unfinished warning が skip される可能性" >&2
      [ -n "$_state_jq_err" ] && [ -s "$_state_jq_err" ] && head -3 "$_state_jq_err" | sed 's/^/  /' >&2
      _state_phase=""
    fi
    [ -n "$_state_jq_err" ] && : > "$_state_jq_err"
    if ! _state_active=$(jq -r '.active // false' "$STATE_FILE" 2>"${_state_jq_err:-/dev/null}"); then
      echo "WARNING: session-end: jq .active 抽出失敗 ($STATE_FILE) — lifecycle unfinished warning が skip される可能性" >&2
      [ -n "$_state_jq_err" ] && [ -s "$_state_jq_err" ] && head -3 "$_state_jq_err" | sed 's/^/  /' >&2
      _state_active="false"
    fi
    [ -n "$_state_jq_err" ] && rm -f "$_state_jq_err"
    _lifecycle_unfinished_kind=""
    if [ "$_state_active" = "true" ]; then
        # >>> DRIFT-CHECK ANCHOR: lifecycle_predicate_session_end_create <<<
        # phase-transition-whitelist.sh の create lifecycle predicate を runtime 参照する箇所。
        # create-interview.md などの docs はこの anchor 名で cite する (行番号 drift 回避)。
        if type rite_phase_is_create_lifecycle_in_progress >/dev/null 2>&1; then
            if rite_phase_is_create_lifecycle_in_progress "$_state_phase"; then
                _lifecycle_unfinished_kind="create"
            fi
        elif [[ "$_state_phase" == create_* ]] && [ "$_state_phase" != "create_completed" ]; then
            _lifecycle_unfinished_kind="create"
        fi
        if [ -z "$_lifecycle_unfinished_kind" ]; then
            # >>> DRIFT-CHECK ANCHOR: lifecycle_predicate_session_end_cleanup <<<
            # 同上、cleanup lifecycle predicate の runtime 参照箇所。
            if type rite_phase_is_cleanup_lifecycle_in_progress >/dev/null 2>&1; then
                if rite_phase_is_cleanup_lifecycle_in_progress "$_state_phase"; then
                    _lifecycle_unfinished_kind="cleanup"
                fi
            elif [[ "$_state_phase" == "cleanup" || "$_state_phase" == cleanup_* ]] && [ "$_state_phase" != "cleanup_completed" ]; then
                # `cleanup*` (underscore なし) は将来 `cleanupXYZ` 等の派生 phase を誤検出するリスクがあるため、
                # `cleanup` 完全一致 / `cleanup_*` のみを対象に精密化 (create_* 側との対称性、#608 follow-up)
                _lifecycle_unfinished_kind="cleanup"
            fi
        fi
    fi
    case "$_lifecycle_unfinished_kind" in
        create)
            cat >&2 <<WARN_MSG
⚠️  rite: /rite:issue:create lifecycle was not completed (phase=$_state_phase).
    No GitHub Issue was created. The sub-skill delegation flow
    (create-interview → 0.6 → create-register/create-decompose) did not reach completion.
    Re-run /rite:issue:create or use /rite:resume to recover.
WARN_MSG
            ;;
        cleanup)
            cat >&2 <<WARN_MSG
⚠️  rite: /rite:pr:cleanup lifecycle was not completed (phase=$_state_phase).
    The cleanup workflow halted before Phase 5 Completion Report.
    Depending on phase: cleanup → Phase 1-4 incomplete; cleanup_pre_ingest → wiki ingest
    not invoked or mid-execution; cleanup_post_ingest → wiki ingest returned but Phase 5
    completion report was never emitted; ingest_pre_lint → caller 経由 wiki ingest の
    Phase 8.2 Pre-write 直後または rite:wiki:lint --auto 実行中 (ring transient pin);
    ingest_post_lint → lint return 後 Phase 9 completion report が未出力 (ring transient pin,
    Phase 9.1 Step 3 terminal patch 未到達).
    Re-run /rite:pr:cleanup or use /rite:resume to recover.
WARN_MSG
            ;;
    esac

    # canonical pattern: 「パス先行宣言 → trap 先行設定 → mktemp」順序で race window を排除
    # (flow-state-update.sh の _rite_flow_state_atomic_cleanup block と同型 doctrine)。
    # 旧 `trap 'rm -f ... 2>/dev/null' EXIT TERM INT` は HUP signal を含まず、SSH 切断 / terminal close
    # 時に TMP_FILE が leak した。4-line signal-specific pattern で HUP も cover し、trap 内 rm の
    # `2>/dev/null` も削除して permission denied 等を可視化する。
    # 歴史的対称化: stop-guard.sh は #675 で撤去済、PID-suffix fallback は現役の慣行として残す。
    # 「全 tempfile lifecycle cover」doctrine: 本 if block 配下と後段の stale tempfile cleanup block
    # で生成される全 4 tempfile (_rm_err / _lock_rm_err / _find_err / TMP_FILE) を 1 trap で保護する。
    # verified-review HIGH-2 対応: jq stderr 退避 tempfile を追加。旧実装は jq parse error が
    # stderr (terminal) に直接出力されるか lost し、diagnostic 行/列番号が user の手に届かなかった。
    # flow-state-update.sh:901-919 (patch-mode jq) の stderr-tempfile pattern と writer/reader 対称化。
    TMP_FILE=""
    _rm_err=""
    _lock_rm_err=""
    _find_err=""
    _deactivate_jq_err=""
    _mv_err=""
    _legacy_lock_rm_err=""
    _session_end_tmp_cleanup() {
      rm -f "${TMP_FILE:-}" "${_rm_err:-}" "${_lock_rm_err:-}" "${_find_err:-}" "${_deactivate_jq_err:-}" "${_mv_err:-}" "${_legacy_lock_rm_err:-}"
    }
    trap 'rc=$?; _session_end_tmp_cleanup; exit $rc' EXIT
    trap '_session_end_tmp_cleanup; exit 130' INT
    trap '_session_end_tmp_cleanup; exit 143' TERM
    trap '_session_end_tmp_cleanup; exit 129' HUP
    # mktemp 失敗時は PID-suffix fallback ではなく fail-safe (skip + WARNING) に倒す。
    # flow-state-update.sh:601-606 で確立した「PID-suffix silent fallback は symlink race 攻撃面を増加」
    # doctrine と対称化。session-end は cleanup hook のため fail-fast せず deactivation を skip して continue する。
    if ! TMP_FILE=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null); then
        echo "WARNING: session-end: mktemp 失敗 ($STATE_FILE) — atomic write 不能のため deactivation を skip します" >&2
        echo "  対処: $(dirname "$STATE_FILE") の容量 / permission を確認してください" >&2
        TMP_FILE=""
    fi
    if [ -n "$TMP_FILE" ]; then
        # verified-review I-4 (#926): chmod 600 silent failure を flow-state-update.sh の _chmod_err pattern と対称化。
        # 旧 `chmod 600 ... 2>/dev/null || :` は permission denied / read-only fs を完全 silent suppress していた。
        _chmod_err=$(mktemp /tmp/rite-session-end-chmod-err-XXXXXX 2>/dev/null) || _chmod_err=""
        if ! chmod 600 "$TMP_FILE" 2>"${_chmod_err:-/dev/null}"; then
            echo "WARNING: session-end: chmod 600 $TMP_FILE が失敗 — tmpfile が 644 等で残る可能性" >&2
            if [ -n "$_chmod_err" ] && [ -s "$_chmod_err" ]; then
                head -3 "$_chmod_err" | sed 's/^/  /' >&2
            fi
        fi
        [ -n "$_chmod_err" ] && rm -f "$_chmod_err"
    fi
    _deactivate_jq_err=$(mktemp /tmp/rite-session-end-deactivate-jq-err-XXXXXX 2>/dev/null) || _deactivate_jq_err=""
    if [ -n "$TMP_FILE" ] && jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
       '.active = false | .updated_at = $ts' "$STATE_FILE" > "$TMP_FILE" 2>"${_deactivate_jq_err:-/dev/null}"; then
        # mv の rc / stderr を捕捉し、EXDEV / ENOSPC / permission denied 等を silent 化しない
        # (flow-state-update.sh の writer/reader 対称化 doctrine と整合)
        _mv_err=$(mktemp /tmp/rite-session-end-mv-err-XXXXXX 2>/dev/null) || _mv_err=""
        if ! mv "$TMP_FILE" "$STATE_FILE" 2>"${_mv_err:-/dev/null}"; then
            echo "rite: session-end: mv failed: $TMP_FILE -> $STATE_FILE (deactivate write lost)" >&2
            if [ -n "$_mv_err" ] && [ -s "$_mv_err" ]; then
                head -3 "$_mv_err" | sed 's/^/  /' >&2
            fi
            echo "  対処: disk full / permission denied / EXDEV / parent dir 削除済み を確認してください" >&2
            rm -f "$TMP_FILE"
        fi
    elif [ -z "$TMP_FILE" ]; then
        :  # mktemp 失敗時の skip 経路。WARNING は上で emit 済み。
    else
        # Intentionally not exit 1 here (unlike pre-compact.sh) — session-end
        # prioritizes cleanup over strict error propagation.
        # Issue #749: emit WARNING so the user knows the deactivate failed
        # (mirrors pre-compact.sh diagnostic line-prefix `rite: <hook>: ...`).
        # Without this, .active=false silently fails to be written and the
        # next session-start defensive reset has no signal that recovery is
        # needed (#475 / #608 follow-up).
        # WARNING に state_file path を含めることで、Issue 番号が解決できない
        # 経路 (detached HEAD / non-issue branch / git 未初期化) でも debug 情報
        # が残る。`${ISSUE_NUMBER:+ (Issue #$ISSUE_NUMBER)}` で issue 番号は
        # 解決できた場合のみ追記し、空の場合は `(Issue #...)` 部分そのものを省略する。
        echo "rite: session-end: failed to deactivate state file: $STATE_FILE${ISSUE_NUMBER:+ (Issue #$ISSUE_NUMBER)}" >&2
        # verified-review HIGH-2 対応: jq stderr の先頭 3 行を pass-through して原因特定を可能にする
        if [ -n "$_deactivate_jq_err" ] && [ -s "$_deactivate_jq_err" ]; then
            head -3 "$_deactivate_jq_err" | sed 's/^/  /' >&2
        fi
        echo "  対処: state file の JSON 妥当性確認 / disk full / permission denied / EXDEV (mv) を確認" >&2
        rm -f "$TMP_FILE"
    fi
    [ -n "$_deactivate_jq_err" ] && rm -f "$_deactivate_jq_err"
    _deactivate_jq_err=""

    # AC-10 (Issue #680): clean up per-session flow-state file on session end.
    # Note: this block also runs after the jq deactivation `else` arm above —
    # i.e. when the .active=false update failed. The per-session file is unique
    # to this session, so even a corrupt one has no value post-termination, and
    # leaving it would only confuse the next session-start defensive reset.
    # Detection: STATE_FILE matches `*/.rite/sessions/*.flow-state` (the per-session
    # path returned by `_resolve-flow-state-path.sh`).
    # Legacy `.rite-flow-state` is intentionally preserved (it may be the only
    # state file in repos still running schema_version=1, and active=false marks
    # it as terminated for /rite:resume's recovery flow).
    # Stale-file cleanup (long-running sessions / crash leftovers) is out of scope
    # for this Issue per Issue #680 §4.3 (handled by a follow-up).
    if [[ "$STATE_FILE" == *"/.rite/sessions/"*".flow-state" ]] && [ -f "$STATE_FILE" ]; then
        # silent-failure-hunter M-4: 旧 `rm -f ... 2>/dev/null || true` は permission denied 等の
        # rm 失敗を完全 silent suppress していた。per-session file が leak する経路を可視化する。
        # stop-guard.sh 撤去 (#675) 以降、leak 検出機構は audit-trail に依存するため WARNING emit する。
        _rm_err=$(mktemp /tmp/rite-session-end-rm-err-XXXXXX 2>/dev/null) || _rm_err=""
        if ! rm -f "$STATE_FILE" 2>"${_rm_err:-/dev/null}"; then
          echo "WARNING: session-end: per-session file の削除に失敗 ($STATE_FILE) — file leak の可能性" >&2
          if [ -n "$_rm_err" ] && [ -s "$_rm_err" ]; then
            head -3 "$_rm_err" | sed 's/^/  /' >&2
          fi
          echo "  対処: $STATE_FILE の permission / ownership を確認し、手動で削除してください" >&2
        fi
        [ -n "$_rm_err" ] && rm -f "$_rm_err"
        # Important I-2 (code-reviewer, #926) 対応:
        # flow-state-update.sh が advisory lock 用に作成する `${STATE_FILE}.lock` ファイルも同時に削除する。
        # flock(2) は kernel advisory lock を fd lifecycle に紐付け process exit で auto release するが、
        # lock ファイル自体は inode として disk に残留する (flock(2) man page で明示)。本 cleanup 経路で
        # 削除しないと `.rite/sessions/` に session 数分の `.flow-state.lock` が累積する。
        # Source: https://man7.org/linux/man-pages/man2/flock.2.html
        if [ -f "${STATE_FILE}.lock" ]; then
          _lock_rm_err=$(mktemp /tmp/rite-session-end-lockrm-err-XXXXXX 2>/dev/null) || _lock_rm_err=""
          if ! rm -f "${STATE_FILE}.lock" 2>"${_lock_rm_err:-/dev/null}"; then
            echo "WARNING: session-end: per-session lock file の削除に失敗 (${STATE_FILE}.lock) — accumulation risk" >&2
            if [ -n "$_lock_rm_err" ] && [ -s "$_lock_rm_err" ]; then
              head -3 "$_lock_rm_err" | sed 's/^/  /' >&2
            fi
          fi
          [ -n "$_lock_rm_err" ] && rm -f "$_lock_rm_err"
        fi
    elif [ "$STATE_FILE" = "$STATE_ROOT/.rite-flow-state" ] && [ -f "${STATE_FILE}.lock" ]; then
        # legacy schema_version=1: per-session 経路と対称化して `.rite-flow-state.lock` も cleanup する。
        # legacy file 自体は #680 の意図で保持するが、advisory lock file は 0 byte の inode 残骸でも
        # 累積すると lint / CI で unexpected file 扱いされるため削除する (flow-state-update.sh が
        # 作成した lock の lifecycle 補完)。
        _legacy_lock_rm_err=$(mktemp /tmp/rite-session-end-legacy-lockrm-err-XXXXXX 2>/dev/null) || _legacy_lock_rm_err=""
        if ! rm -f "${STATE_FILE}.lock" 2>"${_legacy_lock_rm_err:-/dev/null}"; then
            echo "WARNING: session-end: legacy lock file の削除に失敗 (${STATE_FILE}.lock)" >&2
            if [ -n "$_legacy_lock_rm_err" ] && [ -s "$_legacy_lock_rm_err" ]; then
                head -3 "$_legacy_lock_rm_err" | sed 's/^/  /' >&2
            fi
        fi
        [ -n "$_legacy_lock_rm_err" ] && rm -f "$_legacy_lock_rm_err"
    fi
fi

# Clean up stale temporary files (older than 1 minute to avoid deleting in-progress writes).
# Mirrors the same find command in session-start.sh (which is the canonical source).
# `-not -name '.rite-flow-state.legacy.*'` excludes the migration backup so it
# remains the manual-recovery source of truth (#679, #747 CRITICAL).
# DRY note: this cleanup is duplicated across session-start.sh and session-end.sh.
# Future hardening: extract into a shared helper to prevent one-sided regressions
# (the to session-start.sh missed this hook, surfacing as CRITICAL).
if [ -d "$CWD" ]; then
    # # 旧 `find ... -delete 2>/dev/null || true` は permission denied / IO error を完全 silent suppress
    # していた。stale tempfile cleanup が silent skip すると長期運用で disk 蓄積する。doctrine 統一の
    # ため WARNING emit に変更 (M-4/M-7/M-8 pattern と対称化)。
    _find_err=$(mktemp /tmp/rite-session-end-find-err-XXXXXX 2>/dev/null) || _find_err=""
    if ! find "$CWD" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -not -name ".rite-flow-state.legacy.*" -type f -mmin +1 -delete 2>"${_find_err:-/dev/null}"; then
        echo "WARNING: session-end: stale tempfile cleanup の find が失敗 ($CWD) — 蓄積の可能性" >&2
        if [ -n "$_find_err" ] && [ -s "$_find_err" ]; then
            head -3 "$_find_err" | sed 's/^/  /' >&2
        fi
    fi
    [ -n "$_find_err" ] && rm -f "$_find_err"
fi
