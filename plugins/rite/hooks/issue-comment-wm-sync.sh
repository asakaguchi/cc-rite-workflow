#!/bin/bash
# rite workflow - Issue Comment Work Memory Sync
# Deterministic script for Issue comment work memory operations.
# Handles: comment creation (init), retrieval, transformation, safety checks, and PATCH.
# Text transformations are delegated to issue-comment-wm-update.py (stdin→stdout).
#
# Usage:
#   Init mode (create new work memory comment):
#     bash issue-comment-wm-sync.sh init --issue 42 --branch "feat/issue-42-test"
#
#   Update mode (transform and PATCH existing comment):
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform update-phase --phase "phase5_review" --phase-detail "レビュー中"
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform update-progress \
#       --impl-status "✅ 完了" --test-status "⬜ 未着手" --doc-status "⬜ 未着手" \
#       --changed-files-file /tmp/files.md
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform append-section --section "品質チェック履歴" --content-file /tmp/lint.md
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform append-eof --content-file /tmp/completion.md
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform merge-checklist --section 進捗 --content-file /tmp/items.md
#
# Options:
#   --issue          Issue number (required)
#   --branch         Branch name (init mode)
#   --transform      Python subcommand to apply (update mode, required)
#   (remaining args are passed through to the Python script)
#
# Exit codes:
#   0: Success or non-blocking skip (WARNING on stderr)
#   1: Argument error
#
# Status output (stdout, update mode) — caller shim 用の機械可読 1 行:
#   status=success                          PATCH 成功
#   status=skipped; reason=no_comment       作業メモリ comment 不在 (初回 fix 等, legitimate no-op)
#   status=skipped; reason=body_fetch_failed gh api での body 取得失敗 (auth/rate/network/404)
#   status=skipped; reason=safety_check_failed body 空 / header 欠落 / <50% で PATCH 拒否
#   status=error; reason=transform_failed   Python transform が非ゼロ exit
#   status=error; reason=patch_failed       jq | gh api PATCH が失敗
#   commands/pr/fix.md ステップ 4.5.2 はこの行を read し、no_comment 以外の skipped/error を
#   `[CONTEXT] WM_UPDATE_FAILED=1` にマップする (`[fix:pushed-wm-stale]` routing 用)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/issue-comment-wm-update.py"

# Resolve repository root for .rite-flow-state access
CWD="${CWD:-$(pwd)}"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"
FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Get owner/repo ---
# stderr を完全抑止すると、auth expiry / network outage / cwd outside repo の区別がつかず
# 「owner/repo 取得不能 = Issue comment 経路の機能停止」が silent に発生する。stderr を
# tempfile capture して、失敗時に WARNING で根本原因を expose する。
get_owner_repo() {
  local _err _rc=0 _out
  _err=$(mktemp 2>/dev/null) || _err=""
  _out=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>"${_err:-/dev/null}") || _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "$_out" ]; then
    if [ -n "$_err" ] && [ -s "$_err" ]; then
      echo "[rite] WARNING: issue-comment-wm-sync: gh repo view failed (rc=$_rc)" >&2
      head -3 "$_err" | sed 's/^/  /' >&2
    fi
    _out=""
  fi
  [ -n "$_err" ] && rm -f "$_err"
  printf '%s' "$_out"
}

# Caching is best-effort because get_comment_id() falls back to a full gh api
# scan, but a silent cache failure makes every subsequent invocation re-scan
# all comments — accelerating rate-limit hits. Surface mktemp / jq / mv
# failures so this degradation can be diagnosed instead of mistaken for normal
# behaviour.
cache_comment_id() {
  local cid="$1"
  [ -f "$FLOW_STATE" ] || return 0
  local tmp
  if ! tmp=$(mktemp 2>/dev/null); then
    echo "[rite] WARNING: issue-comment-wm-sync: cache_comment_id mktemp failed; wm_comment_id will not be cached (gh api full-scan every call)" >&2
    return 0
  fi
  local _jq_err
  _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
  local _jq_rc=0
  if jq --arg cid "$cid" '. + {wm_comment_id: ($cid | tonumber)}' "$FLOW_STATE" > "$tmp" 2>"${_jq_err:-/dev/null}"; then
    # Capture both rc and stderr so EXDEV / EACCES / ENOSPC / SELinux deny is
    # distinguishable. `if ! mv ...; then _rc=$?` would zero $? in its
    # then-branch (bash `!` semantics) and collapse the real errno.
    local _cid_mv_err
    _cid_mv_err=$(mktemp 2>/dev/null) || _cid_mv_err=""
    if mv "$tmp" "$FLOW_STATE" 2>"${_cid_mv_err:-/dev/null}"; then
      :
    else
      local _mv_rc=$?
      echo "[rite] WARNING: issue-comment-wm-sync: cache_comment_id mv failed (rc=$_mv_rc)" >&2
      [ -n "$_cid_mv_err" ] && [ -s "$_cid_mv_err" ] && head -3 "$_cid_mv_err" | sed 's/^/  /' >&2
      rm -f "$tmp"
    fi
    [ -n "$_cid_mv_err" ] && rm -f "$_cid_mv_err"
  else
    _jq_rc=$?
    echo "[rite] WARNING: issue-comment-wm-sync: cache_comment_id jq failed (rc=$_jq_rc — FLOW_STATE may be corrupt or cid='$cid' not numeric)" >&2
    [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  /' >&2
    rm -f "$tmp"
  fi
  [ -n "$_jq_err" ] && rm -f "$_jq_err"
}

# --- Get comment ID (with flow-state cache) ---
# 各 gh / jq 呼び出しの stderr を tempfile capture することで、rate limit / auth expiry /
# 真の comment 不在 を区別する。stderr を /dev/null に落とすと「キャッシュ無効」と
# 「rate limit」を同一視し、full-scan に降格して rate limit を増幅する経路ができる。
get_comment_id() {
  local issue="$1"
  local owner_repo="$2"
  local _err _rc

  if [ -f "$FLOW_STATE" ]; then
    local cached
    _err=$(mktemp 2>/dev/null) || _err=""
    _rc=0
    cached=$(jq -r '.wm_comment_id // empty' "$FLOW_STATE" 2>"${_err:-/dev/null}") || _rc=$?
    if [ "$_rc" -ne 0 ]; then
      echo "[rite] WARNING: issue-comment-wm-sync: cache 読み取り jq 失敗 (rc=$_rc — FLOW_STATE may be corrupt)" >&2
      [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | sed 's/^/  /' >&2
      cached=""
    fi
    [ -n "$_err" ] && rm -f "$_err"

    if [ -n "$cached" ] && [ "$cached" != "null" ]; then
      local verify
      _err=$(mktemp 2>/dev/null) || _err=""
      _rc=0
      verify=$(gh api "repos/${owner_repo}/issues/comments/${cached}" --jq '.id // empty' 2>"${_err:-/dev/null}") || _rc=$?
      if [ "$_rc" -ne 0 ]; then
        # cached id が 404 になっただけ (legitimate cache invalidation) と rate-limit / auth
        # 失敗を区別する。auth / rate limit エラーは WARNING で operator に通知。
        if [ -n "$_err" ] && [ -s "$_err" ] && grep -qiE 'rate limit|HTTP 401|HTTP 403|network' "$_err"; then
          echo "[rite] WARNING: issue-comment-wm-sync: cache 検証 gh api 失敗 (rc=$_rc, auth/rate/network 系)" >&2
          head -3 "$_err" | sed 's/^/  /' >&2
        fi
        verify=""
      fi
      [ -n "$_err" ] && rm -f "$_err"
      if [ -n "$verify" ]; then
        echo "$cached"
        return 0
      fi
    fi
  fi

  local comment_id
  _err=$(mktemp 2>/dev/null) || _err=""
  _rc=0
  comment_id=$(gh api "repos/${owner_repo}/issues/${issue}/comments" \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty' 2>"${_err:-/dev/null}") || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: comment 一覧取得 gh api 失敗 (rc=$_rc — auth/rate/network 系の可能性)" >&2
    [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | sed 's/^/  /' >&2
    comment_id=""
  fi
  [ -n "$_err" ] && rm -f "$_err"

  if [ -z "$comment_id" ]; then
    return 1
  fi

  cache_comment_id "$comment_id"

  echo "$comment_id"
  return 0
}

# --- Safety checks ---
safety_check() {
  local updated_file="$1"
  local original_length="$2"
  local backup_file="$3"
  local transform="${4:-}"

  # Empty or too short
  if [ ! -s "$updated_file" ] || [[ "$(wc -c < "$updated_file")" -lt 10 ]]; then
    echo "WARNING: Updated body is empty or too short. Skipping PATCH. Backup: $backup_file" >&2
    return 1
  fi

  # Header validation
  if ! grep -q '📜 rite 作業メモリ' "$updated_file"; then
    echo "WARNING: Updated body missing work memory header. Skipping PATCH. Backup: $backup_file" >&2
    return 1
  fi

  # 50% rule (only for update-progress, update-phase, update-plan-status, update-checkboxes)
  # Skip for append-section, replace-section, append-eof, and merge-checklist (content grows or changes size unpredictably)
  case "$transform" in
    append-section|replace-section|append-eof|merge-checklist)
      ;;
    *)
      local updated_length
      updated_length=$(wc -c < "$updated_file")
      if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
        echo "WARNING: Updated body < 50% of original (${updated_length}/${original_length}). Skipping PATCH. Backup: $backup_file" >&2
        return 1
      fi
      ;;
  esac

  return 0
}

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

ISSUE=""
BRANCH=""
TRANSFORM=""
TRANSFORM_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)     ISSUE="$2"; shift 2 ;;
    --branch)    BRANCH="$2"; shift 2 ;;
    --transform) TRANSFORM="$2"; shift 2 ;;
    --)
      shift
      TRANSFORM_ARGS+=("$@")
      break
      ;;
    *)
      # Forward to Python script (issue-comment-wm-update.py validates and rejects unknown options)
      TRANSFORM_ARGS+=("$1")
      shift
      ;;
  esac
done

# --- Validation ---
if [ -z "$ISSUE" ]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

case "$MODE" in
  init)
    ;;
  update)
    if [ -z "$TRANSFORM" ]; then
      echo "ERROR: update mode requires --transform" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Unknown mode: $MODE. Use 'init' or 'update'" >&2
    exit 1
    ;;
esac

# --- Get owner/repo ---
OWNER_REPO=$(get_owner_repo)
if [ -z "$OWNER_REPO" ]; then
  echo "WARNING: Could not determine owner/repo. Skipping." >&2
  exit 0
fi

# ============================================================
# INIT MODE
# ============================================================
if [ "$MODE" = "init" ]; then
  TIMESTAMP=$(date +'%Y-%m-%dT%H:%M:%S+09:00')

  # set -e 配下で mktemp が /tmp full / inode 枯渇 / readonly fs で失敗すると、trap 設定前
  # に abort する。明示 rc check で degrade させ、init mode を skip して上位で続行する。
  tmpfile=""
  if ! tmpfile=$(mktemp 2>/dev/null); then
    echo "[rite] WARNING: issue-comment-wm-sync: init mode mktemp failed (/tmp full or readonly?). Skipping comment creation." >&2
    exit 0
  fi
  trap 'rm -f "$tmpfile"' EXIT

  cat <<INIT_EOF > "$tmpfile"
## 📜 rite 作業メモリ

### セッション情報
- **Issue**: #${ISSUE}
- **開始**: ${TIMESTAMP}
- **ブランチ**: ${BRANCH}
- **最終更新**: ${TIMESTAMP}
- **コマンド**: /rite:pr:open
- **フェーズ**: branch
- **フェーズ詳細**: ブランチ作成完了

### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ⬜ 未着手 | - |
| テスト | ⬜ 未着手 | - |
| ドキュメント | ⬜ 未着手 | - |

### 要確認事項
<!-- 作業中に発生した確認事項を蓄積。セッション終了時にまとめて確認 -->
_確認事項はありません_

### 変更ファイル
<!-- 自動更新 -->
_まだ変更はありません_

### 決定事項・メモ
<!-- 重要な判断や発見 -->

### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->
_計画逸脱はありません_

### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->
_ボトルネック検出はありません_

### レビュー対応履歴
<!-- レビュー対応時に自動記録 -->
_レビュー対応はありません_

### 次のステップ
1. Issue の内容を確認
2. 実装を開始
INIT_EOF

  # gh の成功時 stdout は comment URL なので、`2>&1` で merge すると失敗時の stderr 詳細と
  # 成功時の URL の見分けがつかない。stderr は tempfile に分離 capture して根本原因を残す。
  _init_err=""
  _init_err=$(mktemp 2>/dev/null) || _init_err=""
  _init_rc=0
  result=$(gh issue comment "$ISSUE" --body-file "$tmpfile" 2>"${_init_err:-/dev/null}") || _init_rc=$?
  if [ "$_init_rc" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: gh issue comment 作成失敗 (rc=$_init_rc)" >&2
    [ -n "$_init_err" ] && [ -s "$_init_err" ] && head -3 "$_init_err" | sed 's/^/  /' >&2
    [ -n "$_init_err" ] && rm -f "$_init_err"
    exit 0
  fi
  [ -n "$_init_err" ] && rm -f "$_init_err"

  # Validate creation (retry up to 3 times with 1s intervals).
  # Capture per-attempt gh stderr so transient rate-limit / auth / network
  # failures surface in the WARNING instead of silently routing to
  # status=unverified — symmetric with the get_comment_id and init write paths
  # above.
  created_id=""
  for attempt in 1 2 3; do
    _verify_err=$(mktemp 2>/dev/null) || _verify_err=""
    _verify_rc=0
    created_id=$(gh api "repos/${OWNER_REPO}/issues/${ISSUE}/comments" \
      --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty' \
      2>"${_verify_err:-/dev/null}") || _verify_rc=$?
    if [ "$_verify_rc" -ne 0 ]; then
      _verify_tag=""
      [ -z "$_verify_err" ] && _verify_tag=" stderr_capture=disabled"
      echo "[rite] WARNING: issue-comment-wm-sync: validation gh api 失敗 (attempt=$attempt, rc=$_verify_rc${_verify_tag})" >&2
      [ -n "$_verify_err" ] && [ -s "$_verify_err" ] && head -3 "$_verify_err" | sed 's/^/  /' >&2
      created_id=""
    fi
    [ -n "$_verify_err" ] && rm -f "$_verify_err"
    [ -n "$created_id" ] && break
    [ "$attempt" -lt 3 ] && sleep 1
  done

  if [ -n "$created_id" ]; then
    cache_comment_id "$created_id"
    echo "status=success"
  else
    echo "WARNING: Could not verify work memory comment creation." >&2
    echo "status=unverified"
  fi

  exit 0
fi

# ============================================================
# UPDATE MODE
# ============================================================

# Step 1: Get comment ID
COMMENT_ID=$(get_comment_id "$ISSUE" "$OWNER_REPO") || {
  echo "WARNING: Work memory comment not found for Issue #${ISSUE}. Skipping update." >&2
  # reason=no_comment は legitimate no-op (初回 fix / コメント削除済み)。caller の WM_UPDATE_FAILED
  # shim はこの reason のみ flag を立てない (他の skipped/error reason とは区別する必要がある)。
  echo "status=skipped; reason=no_comment"
  exit 0
}

# Step 2: Get current body
# /tmp 関連の failure (inode 枯渇 / readonly fs / quota) は set -e 配下で trap 設定前に
# abort し orphan tempfile を残しうる。各 mktemp で rc を見て degrade させる。
body_tmp=""
updated_tmp=""
py_err_tmp=""
if ! body_tmp=$(mktemp 2>/dev/null); then
  echo "[rite] WARNING: issue-comment-wm-sync: update mode body_tmp mktemp 失敗。skip." >&2
  exit 0
fi
if ! updated_tmp=$(mktemp 2>/dev/null); then
  rm -f "$body_tmp"
  echo "[rite] WARNING: issue-comment-wm-sync: update mode updated_tmp mktemp 失敗。skip." >&2
  exit 0
fi
if ! py_err_tmp=$(mktemp 2>/dev/null); then
  rm -f "$body_tmp" "$updated_tmp"
  echo "[rite] WARNING: issue-comment-wm-sync: update mode py_err_tmp mktemp 失敗。skip." >&2
  exit 0
fi
# Backup は失敗時の post-mortem 用。/tmp に蓄積した場合は `rm -f /tmp/rite-wm-backup-*` で手動清掃。
backup_file="/tmp/rite-wm-backup-${ISSUE}-$(date +%s).md"
trap 'rm -f "$body_tmp" "$updated_tmp" "$py_err_tmp"' EXIT

# Capture gh stderr so that auth expiry / rate limit / 404 / network failure are
# distinguishable in the operator log instead of collapsing into an empty body.
_cb_err=$(mktemp 2>/dev/null) || _cb_err=""
_cb_rc=0
current_body=$(gh api "repos/${OWNER_REPO}/issues/comments/${COMMENT_ID}" --jq '.body // empty' 2>"${_cb_err:-/dev/null}") || _cb_rc=$?
if [ "$_cb_rc" -ne 0 ]; then
  echo "[rite] WARNING: issue-comment-wm-sync: comment body 取得 gh api 失敗 (rc=$_cb_rc — auth/rate/network/404 系)" >&2
  [ -n "$_cb_err" ] && [ -s "$_cb_err" ] && head -3 "$_cb_err" | sed 's/^/  /' >&2
  current_body=""
fi
[ -n "$_cb_err" ] && rm -f "$_cb_err"

if [ -z "$current_body" ]; then
  echo "WARNING: Could not retrieve comment body. Skipping update." >&2
  # reason=body_fetch_failed は gh api 失敗 (auth/rate/network/404)。comment は存在するが更新
  # 不可のため、caller の shim は WM_UPDATE_FAILED を立てる (no_comment とは区別する)。
  echo "status=skipped; reason=body_fetch_failed"
  exit 0
fi

# Step 3: Backup
printf '%s' "$current_body" > "$backup_file"
printf '%s' "$current_body" > "$body_tmp"
original_length=$(printf '%s' "$current_body" | wc -c)

# Step 4: Apply Python transformation
# pipefail を local subshell で有効にすることで、cat 失敗 (permission denied / IO error) が
# python3 の rc に隠蔽されず transform_status に反映される。直接リダイレクトに切り替えれば
# cat のみ確実だが、後続の transform で stdin が pipe 終端であることを期待しているため pipe 形式を保つ。
transform_status=0
( set -o pipefail; cat "$body_tmp" | python3 "$PYTHON_SCRIPT" "$TRANSFORM" "${TRANSFORM_ARGS[@]}" > "$updated_tmp" 2>"$py_err_tmp" ) || transform_status=$?

if [ "$transform_status" -ne 0 ]; then
  py_err=$(cat "$py_err_tmp" 2>/dev/null)
  echo "WARNING: Python transform failed (exit $transform_status). Skipping PATCH. Backup: $backup_file" >&2
  [ -n "$py_err" ] && echo "  Detail: $py_err" >&2
  echo "status=error; reason=transform_failed"
  exit 0
fi

# Step 5: Safety checks
if ! safety_check "$updated_tmp" "$original_length" "$backup_file" "$TRANSFORM"; then
  # safety_check 失敗は body が空 / header 欠落 / <50% で PATCH を拒否したケース。caller の
  # shim は WM_UPDATE_FAILED を立てる (no_comment とは区別する)。
  echo "status=skipped; reason=safety_check_failed"
  exit 0
fi

# Step 6: PATCH
# stderr を `/dev/null` に流すと auth / rate-limit / 404 / network outage / jq rawfile 失敗を
# すべて generic exit code に潰すため、原因分類が出来ない。stderr を tempfile capture し
# pipefail を local subshell で有効化することで上流 jq の失敗も rc に反映する。
patch_err=$(mktemp 2>/dev/null) || patch_err=""
patch_status=0
( set -o pipefail; jq -n --rawfile body "$updated_tmp" '{"body": $body}' \
  | gh api "repos/${OWNER_REPO}/issues/comments/${COMMENT_ID}" -X PATCH --input - > /dev/null 2>"${patch_err:-/dev/null}" ) || patch_status=$?

if [ "$patch_status" -ne 0 ]; then
  echo "[rite] WARNING: issue-comment-wm-sync: PATCH failed (rc=$patch_status, Backup: $backup_file)" >&2
  [ -n "$patch_err" ] && [ -s "$patch_err" ] && head -3 "$patch_err" | sed 's/^/  /' >&2
  [ -n "$patch_err" ] && rm -f "$patch_err"
  echo "status=error; reason=patch_failed"
  exit 0
fi
[ -n "$patch_err" ] && rm -f "$patch_err"

# Clean up backup on success (only needed on failure for post-mortem)
rm -f "$backup_file"
echo "status=success"
exit 0
