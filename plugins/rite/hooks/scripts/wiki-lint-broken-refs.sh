#!/usr/bin/env bash
# wiki-lint-broken-refs.sh
#
# Detect broken cross-references for wiki/lint.md ステップ 7 (壊れた相互参照
# 検出). Read pages_list + raw_list from stdin (`---` separator, lint.md
# ステップ 2.2 stdout と同形式), extract Markdown links from each page body,
# resolve them page-dir 起点 (realpath -m -s, canonical:
# commands/wiki/references/broken-ref-resolution.md), and emit the broken set
# inside a marker block alongside a broken_refs_read_ok enum + [CONTEXT]
# sentinel.
#
# Why a helper:
#   The inline implementation in lint.md ステップ 7 was a per-page ×
#   per-link bash loop the LLM had to drive manually — the category with the
#   worst track record (218 件検出例のある broken_refs バグを「走らせたフリ」で
#   見逃し得る)。Delegating the whole category makes the count
#   machine-produced: the LLM only transcribes the emitted numbers
#   (same structural guarantee as wiki-lint-skipped-refs.sh /
#   wiki-lint-source-refs.sh for ステップ 6.0 / 6.2).
#
# Fence handling improvement over the inline implementation:
#   The old `sed -E '/^```/,/^```/d'` only removed fences starting at column 0.
#   This helper tracks fence open/close indent-agnostically with awk
#   (`/^[[:space:]]*```/`), so list-indented fences no longer leak their
#   contents into link extraction (旧 lint.md ステップ 7 リンク抽出の既知の限界の解消)。
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   stdin: pages_list 行 → "---" separator → raw_list 行 (lint.md ステップ 2.2
#          stdout の 3 部構成をそのまま substitute する。raw_list は raw/
#          参照リンクの突合にのみ使用)
#
# stdout contract (LLM holds these in conversation context; lint.md ステップ 7 の
# issues[] append と ステップ 9.1 完了レポートが参照する):
#   n_broken_refs={n}
#   ---broken_refs_begin---
#   {page}|{link}                          # 0..N lines
#   ---broken_refs_end---
#   broken_refs_read_ok={true|io_error}
#   [CONTEXT] WIKI_LINT_BROKEN_REFS={n}
#
# broken_refs_read_ok enum:
#   true      全ページ読出成功 (n_broken_refs は信頼可能)
#   io_error  1 件以上のページ読出に失敗 (該当ページのリンクは未検査のため
#             false negative を含む可能性あり — ステップ 9.1 で note 表示)
#
# Exit codes:
#   0  正常 (ページ読出失敗の io_error 降格含む — 非ブロッキング契約)
#   1  fail-fast (placeholder residue / unknown branch_strategy / realpath 不在)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: sibling helpers と同じく per-command rc 管理のため
# `set -e` は意図的に設定しない。

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-broken-refs.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR] < lists

stdin format: pages_list lines, a "---" separator line, then raw_list lines
(the verbatim 3-part stdout of lint.md ステップ 2.2).

Emits the broken-refs marker block + broken_refs_read_ok enum + [CONTEXT]
sentinel on stdout.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (incl. per-page read failures demoted to io_error)
  1  Fail-fast (placeholder residue / unknown branch_strategy / realpath unavailable)
  2  Invocation error
EOF
}

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
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 7 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_7_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 7 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    exit 1
    ;;
esac

case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 7)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

if [ "$branch_strategy" = "separate_branch" ] && [ -z "$wiki_branch" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です (空のため fail-fast)" >&2
  usage >&2
  exit 2
fi

# realpath -m -s は GNU coreutils 依存 (broken-ref-resolution.md 既知の限界)。
# 不在環境では全 link が silent broken 判定になるため fail-fast する。
if ! realpath -m -s -- / >/dev/null 2>&1; then
  echo "ERROR: GNU realpath (-m -s 対応) が利用できません。壊れた相互参照検出を実行できません" >&2
  echo "  対処: macOS/BSD 環境では coreutils のインストールを検討してください" >&2
  exit 1
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

# ---- stdin を pages_list / raw_list に分割 (ステップ 2.2 stdout の 3 部構成) --
stdin_all=$(cat)
pages_list=$(printf '%s\n' "$stdin_all" | awk '/^---$/{exit} {print}')
raw_list=$(printf '%s\n' "$stdin_all" | awk 'found{print} /^---$/{found=1}')

# 突合用の正規化 list (broken-ref-resolution.md L21-22 が要求する形式)
pages_list_normalized=$(printf '%s\n' "$pages_list" | sed -E 's|^\.rite/wiki/||' | grep -v '^$' || true)
raw_list_normalized=$(printf '%s\n' "$raw_list" | sed -E 's|^\.rite/wiki/||' | grep -v '^$' || true)

wiki_root=".rite/wiki"

# ---- 走査本体 (broken-ref-resolution.md canonical 実装の faithful port) -------
n_broken_refs=0
broken_lines=""
read_ok="true"

while IFS= read -r page_path; do
  [ -z "$page_path" ] && continue

  case "$branch_strategy" in
    separate_branch)
      page_content=$(git show "${wiki_branch}:$page_path" 2>/dev/null) || page_content=""
      ;;
    same_branch)
      page_content=$(cat "$page_path" 2>/dev/null) || page_content=""
      ;;
  esac
  if [ -z "$page_content" ]; then
    echo "WARNING: $page_path を読み出せません。リンク検査を skip します (false negative の可能性あり)" >&2
    read_ok="io_error"
    continue
  fi

  # リンク抽出順序 (旧 lint.md ステップ 7 リンク抽出と同じ骨格。1 と 2 は false positive 解消の改善):
  #   1. コードフェンス除去 — indent 不問で開閉をトグル追跡 (旧 sed 行頭限定の改善)
  #   2. インライン code span 除去 — `` `[desc](path)` `` のような説明文中の引用が
  #      リンク抽出に混入する false positive を除去 (実 Wiki ページで実測)
  #   3. 画像リンク除去 (fence 外でのみ意味を持つため 1 の後)
  #   4. 通常リンク `](...)` 抽出
  #   5. アンカー (#section) 除去
  set -o pipefail
  page_links=$(printf '%s' "$page_content" \
    | awk '/^[[:space:]]*```/{f=!f; next} !f' \
    | sed -E 's/`[^`]*`//g' \
    | sed -E 's/!\[[^]]*\]\([^)]*\)//g' \
    | { grep -oE '\]\([^)]+\)' || true; } \
    | sed -E 's/^\]\(//; s/\)$//' \
    | sed -E 's/#.*$//')
  set +o pipefail

  [ -z "$page_links" ] && continue

  page_dir=$(dirname "$page_path")

  while IFS= read -r link; do
    # 絶対パス / 外部 URL / 空文字列 (アンカーのみ含む) は対象外
    case "$link" in
      /*|http://*|https://*|"") continue ;;
    esac

    broken="false"
    resolved_abs=$(realpath -m -s -- "$page_dir/$link" 2>/dev/null) || resolved_abs=""
    if [ -z "$resolved_abs" ]; then
      broken="true"
    else
      resolved_path=$(realpath -m -s --relative-to="$wiki_root" -- "$resolved_abs" 2>/dev/null) || resolved_path=""
      if [ -z "$resolved_path" ]; then
        broken="true"
      else
        case "$resolved_path" in
          pages/*)
            printf '%s\n' "$pages_list_normalized" | grep -qxF -- "$resolved_path" || broken="true"
            ;;
          raw/*)
            printf '%s\n' "$raw_list_normalized" | grep -qxF -- "$resolved_path" || broken="true"
            ;;
          *)
            # wiki_root 直下 (index.md / log.md 等) や wiki_root 外への解決結果は
            # 検出対象外 (broken-ref-resolution.md の case `*)` 分岐と同じ)
            ;;
        esac
      fi
    fi

    if [ "$broken" = "true" ]; then
      n_broken_refs=$((n_broken_refs + 1))
      broken_lines="${broken_lines}${page_path}|${link}
"
    fi
  done <<< "$page_links"
done <<< "$pages_list"

echo "n_broken_refs=$n_broken_refs"
echo "---broken_refs_begin---"
[ -n "$broken_lines" ] && printf '%s' "$broken_lines"
echo "---broken_refs_end---"
echo "broken_refs_read_ok=$read_ok"
echo "[CONTEXT] WIKI_LINT_BROKEN_REFS=$n_broken_refs"
