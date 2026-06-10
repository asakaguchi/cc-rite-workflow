#!/usr/bin/env bash
# wiki-lint-skipped-refs.sh
#
# Build the `skipped_refs` set consumed by wiki/lint.md ステップ 6.2 (b) 分岐
# (`unregistered_raw` 判定). Read `log.md` (via `git show` for separate_branch,
# `cat` for same_branch), extract `ingest:skip` records, dedup, and emit the
# set inside a marker block alongside a 4-value log_read_ok enum.
#
# Why a helper:
#   The inline implementation in lint.md ステップ 6.0 was a ~165-line bash
#   block. Delegating it removes a malform / drift source while keeping the
#   cross-Bash-tool-boundary state-transfer contract verbatim.
#   See ../../commands/wiki/references/bash-cross-boundary-state-transfer.md
#   (Pattern 1: multi-value enum via key=value stdout, Pattern 2:
#   marker-delimited block).
#
# Symmetry note: this is the step 6.0 counterpart to step 6.2's
# `wiki-lint-source-refs.sh`. Both share the marker block +
# io_error enum shape and the legitimate-absence stderr pattern matching;
# keep them aligned.
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#
# stdout contract (LLM holds these in conversation context; lint.md ステップ 6.2 (b)
# 分岐と ステップ 9.1 の false-positive note 展開が参照する):
#   skipped_refs_count={n}
#   ---skipped_refs_begin---
#   {ref}            # 0..N lines, sort -u 済み (`raw/{type}/{filename}` 形式)
#   ---skipped_refs_end---
#   log_read_ok={unknown|true|absent|io_error}
#
# Exit codes:
#   0  正常 (log_read_ok は stdout enum で表現、読出失敗は absent / io_error 降格)
#   1  fail-fast (placeholder residue / unknown branch_strategy)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: this is a faithful port of the inline block which
# manages `$?` explicitly per command. A global `set -e` would break those
# explicit rc checks (git show / cat / awk / sort failures are handled, not
# fatal), so it is intentionally NOT set. `set -o pipefail` is toggled locally
# around the awk/sort pipeline exactly as the inline block did. `set -u` is
# likewise omitted to preserve verbatim behavior; all variable refs are
# `${var:-}`-guarded.

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-skipped-refs.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR]

Reads `.rite/wiki/log.md` per the branch strategy and emits the skipped_refs
marker block + log_read_ok enum on stdout.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (log_read_ok expressed via stdout enum)
  1  Fail-fast (placeholder residue / unknown branch_strategy)
  2  Invocation error
EOF
}

# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定下で無限ループに陥る。1 回目の shift で $# を
# 確実に 0 にし、2 回目は no-op で安全に抜ける (値欠落は下流の必須チェックが exit 2 で検出)。
while [ $# -gt 0 ]; do
  case "$1" in
    --branch-strategy) branch_strategy="${2:-}"; shift; shift ;;
    --wiki-branch) wiki_branch="${2:-}"; shift; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$branch_strategy" ]; then
  echo "ERROR: --branch-strategy は必須です" >&2
  usage >&2
  exit 2
fi

# ---- Placeholder residue fail-fast gate -------------------------------------
# (wiki-lint-source-refs.sh の 6.2 gate と対称。LLM が `{branch_strategy}` /
#  `{wiki_branch}` を literal substitute せずに helper を呼んだ場合の検出。
#  旧 inline block では `{wiki_branch}` 残留が git show の stderr 文言次第で
#  absent / io_error に揺れていた経路を fail-fast に統一する。)
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 6.0 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_6_0_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 6.0 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    exit 1
    ;;
esac

# branch_strategy を early に case 検証 (unknown は fail-fast — 旧 inline block と同じ文言)
case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 6.0)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# separate_branch では --wiki-branch が必須。空のまま進むと git show ":.rite/wiki/log.md" が
# ref ではなく git index (staging area) を読む別 semantics に陥る (wiki-lint-source-refs.sh と
# 同じ runtime enforcement)。
if [ "$branch_strategy" = "separate_branch" ] && [ -z "$wiki_branch" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です (空のため fail-fast)" >&2
  usage >&2
  exit 2
fi

# repo root へ移動 (separate_branch の git show / same_branch の cat はいずれも
# repo-relative path を前提とする)。
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

# ---- 集合構築本体 (inline block の faithful port) ---------------------------
# signal-specific trap (canonical 4 行パターン)。
# 詳細は commands/pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照。
log_err=""
awk_sort_err=""
_cleanup() {
  [ -n "${log_err:-}" ] && rm -f "$log_err"
  [ -n "${awk_sort_err:-}" ] && rm -f "$awk_sort_err"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# skipped_refs 空継続時の「影響」文言 helper (4 site の literal duplicate を集約)
_rite_log_read_impact_advice() {
  echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
}

# stderr 退避失敗 + tool 失敗の複合経路の helper (separate_branch / same_branch で tool 名のみ異なる)
_rite_log_read_sub_path_warning() {
  local tool_desc="$1" remedy_target="$2" rc="$3"
  echo "WARNING: .rite/wiki/log.md の ${tool_desc} に失敗し、かつ stderr 退避も失敗しました (rc=${rc}、原因区別不能のため io_error 扱い)" >&2
  _rite_log_read_impact_advice
  echo "  対処: /tmp の容量 / permission と ${remedy_target} を確認してください" >&2
}

log_err=$(mktemp /tmp/rite-wiki-lint-p60-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (log_err) の mktemp に失敗しました。log.md 読み出しの詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒れ、false positive note が常に表示される regression が起き得ます" >&2
  log_err=""
}

skipped_refs=""
log_content=""
# log_read_ok は 4 値 enum (unknown / true / absent / io_error)。
#   unknown: 初期値 (placeholder/strategy fail-fast 経路でのみ残る、後段未到達)
#   true:    log.md 読出成功
#   absent:  legitimate absence (fresh branch / ENOENT / blob not found) — skipped_refs="" は妥当
#   io_error: 真の IO error — false positive リスクあり、ステップ 9.1 完了レポートで note 表示
# canonical 定義: references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout
log_read_ok="unknown"

case "$branch_strategy" in
  separate_branch)
    # LC_ALL=C で locale 固定 — ja_JP.UTF-8 等で git の stderr メッセージが翻訳されると legitimate
    # absence 判別 regex (does not exist / No such file) と不一致になり io_error に誤分類される silent regression を防ぐ。
    if log_content=$(LC_ALL=C git show "${wiki_branch}:.rite/wiki/log.md" 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      # selective surface pattern: 成功時でも ambiguous ref hint 等の git stderr を surface する
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | neutralize_ctrl --keep-newline | sed 's/^/  WARNING(git hint): /' >&2
    else
      rc=$?
      # legitimate absence 判別 (4 pattern を OR):
      #   - "does not exist": blob not found (標準的な legitimate absence)
      #   - "path '...' exists on disk, but not in": git show の path 対 ref 不整合
      #   - "Not a valid object name": 古い git の revspec 不正メッセージ
      #   - "fatal: invalid object name '<ref>:<path>'": blob path 指定形式
      # 4 pattern いずれも match しない場合 (典型: blob path なしの "fatal: invalid object name 'wiki'") は
      # wiki_branch 自体の race 消失として io_error 扱いとする (ステップ 1.3 後の race 検出)。
      if [ -n "$log_err" ] && [ -s "$log_err" ] && \
         grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:\\.rite/wiki/log\\.md'" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の git show に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: wiki branch の integrity / 権限を確認してください" >&2
      else
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "git show" "wiki branch の integrity / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  same_branch)
    if log_content=$(LC_ALL=C cat .rite/wiki/log.md 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | neutralize_ctrl --keep-newline | sed 's/^/  WARNING(cat hint): /' >&2
    else
      rc=$?
      if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "No such file or directory|cannot open" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の cat に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: .rite/wiki/log.md の存在 / 権限を確認してください" >&2
      else
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "cat" ".rite/wiki/log.md の存在 / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
esac

# log.md から ingest:skip レコードを抽出 (field 3 厳密一致、field 4 prefix 正規化)
if [ -n "$log_content" ]; then
  set -o pipefail
  awk_sort_err=$(mktemp /tmp/rite-wiki-lint-p60-awk-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: awk/sort stderr 退避 tempfile の mktemp に失敗しました" >&2
    echo "  対処: /tmp の容量 / inode 枯渇 / read-only filesystem / permission を確認してください" >&2
    echo "  影響: pipeline 失敗時の詳細エラー情報 (awk syntax error / sort OOM 等) が失われます" >&2
    awk_sort_err=""
  }
  skipped_refs=$(printf '%s\n' "$log_content" \
    | awk -F'|' 'NF >= 4 {
        action=$3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", action)
        if (action == "ingest:skip") {
          target=$4
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
          sub(/^\.rite\/wiki\//, "", target)
          if (length(target) > 0) print target
        }
      }' 2>"${awk_sort_err:-/dev/null}" \
    | LC_ALL=C sort -u 2>>"${awk_sort_err:-/dev/null}")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: ステップ 6.0 の awk/sort pipeline が失敗しました (rc=$rc)" >&2
    [ -n "$awk_sort_err" ] && [ -s "$awk_sort_err" ] && head -3 "$awk_sort_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  対処: awk / sort バイナリと /tmp の容量を確認してください" >&2
    _rite_log_read_impact_advice
    skipped_refs=""
    # log_read_ok="true" のまま据え置くと ステップ 9.1 で false positive note が展開されず silent 表示
    # になる。awk/sort 失敗経路でも io_error に降格させ note 展開を発火させる
    # (canonical: references/bash-cross-boundary-state-transfer.md Pattern 3 の「後段 pipeline 失敗も同 enum の io_error 側に降格する」)。
    log_read_ok="io_error"
  fi
  set +o pipefail
fi

# 集合本体を marker block で stdout 出力 (ステップ 6.2 の (b) 分岐で LLM が会話コンテキストに保持する)。
# canonical: references/bash-cross-boundary-state-transfer.md#pattern-2-marker-delimited-multi-value-block
if [ -n "$skipped_refs" ]; then
  count=$(printf '%s\n' "$skipped_refs" | awk 'NF>0 {n++} END {print n+0}')
  echo "skipped_refs_count=$count"
  echo "---skipped_refs_begin---"
  printf '%s\n' "$skipped_refs"
  echo "---skipped_refs_end---"
else
  echo "skipped_refs_count=0"
  echo "---skipped_refs_begin---"
  echo "---skipped_refs_end---"
fi

# log_read_ok を stdout 出力 (LLM が ステップ 9.1 完了レポートで参照する契約)
echo "log_read_ok=$log_read_ok"
