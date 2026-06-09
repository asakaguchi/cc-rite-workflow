#!/bin/bash
# Tests for Issue #1183: jq / コマンド stderr 診断スニペット emission site の
# control-char 中和の横展開 parity を静的に pin する。
#
# Purpose:
#   flow-state.sh (#1173/#1181) で導入された「診断スニペットは
#   neutralize_ctrl を経由して emit する」規約を、hooks/ 配下の全
#   `head -3` emission site に対称適用したことを保証する
#   (Wiki 経験則 Asymmetric Fix Transcription — 対称位置への伝播漏れ防止)。
#   sweep は `head -3` 限定ではなく `head -N` / `head -n N` (任意行数・両綴り)
#   を対象とする — literal パターン限定の sweep は数値違い (head -5) や
#   綴り違い (head -n 10) の同型イディオムを構造的に見逃すことが
#   実証されている (Asymmetric Fix Transcription の変種)。
#   将来 hook に新しい行指向 head 診断 site が中和なしで追加された
#   場合も TC-1 が検出する。
#
# Test cases:
#   TC-1: hooks/ 配下 (tests/ 除く) に neutralize_ctrl を経由しない
#         `head -N` 行指向 emission site が存在しない (コメント行は除外)
#   TC-2: neutralize_ctrl を call する全 hook ファイルが
#         control-char-neutralize.sh を source している
#         (定義元 control-char-neutralize.sh 自身は除外)
#
# Usage: bash plugins/rite/hooks/tests/diag-snippet-neutralize-parity.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOKS_DIR="$PLUGIN_ROOT/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "ERROR: $HOOKS_DIR not found" >&2
  exit 1
fi

echo "=== TC-1: head -N emission site は全て neutralize_ctrl を経由 ==="
# 除外: tests/ (fixture/assertion 内の出現)、コメント行、定義元 helper の usage コメント
# `head -[0-9]+` / `head -n [0-9]+` (行指向 snippet、両綴り) を対象とする。
# `head -c` (byte 指向 inline 埋め込み) は 1 行 WARNING への embed で行構造が異なる
# 別イディオムのため本 sweep の対象外。
# 注意: head -c site は現状中和未適用 (Issue #1183 の対象は行指向 head snippet のみ)。
# 横展開する場合は別 Issue で扱う。同様に、`>&2` が log() 等の関数内部に隠れて
# 同一行に現れない emission 経路も本 sweep の検出対象外 (別 Issue の横展開対象候補)
violations=$(grep -rnE 'head (-[0-9]+|-n +[0-9]+) ' "$HOOKS_DIR" --include='*.sh' \
  | grep '>&2' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v 'neutralize_ctrl' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  || true)
assert "TC-1: un-neutralized head -N emission sites" "" "$violations"
if [ -n "$violations" ]; then
  echo "  検出された未中和 site (head -N の直後に '| neutralize_ctrl --keep-newline' を挿入すること):"
  printf '%s\n' "$violations" | sed 's/^/    /'
fi

echo ""
echo "=== TC-2: neutralize_ctrl の caller は helper を source 済み ==="
# `neutralize_ctrl` / `contains_ctrl` を実行コードとして含むファイル一覧 (コメント行のみの言及は除外)
# 収集側も両関数対応にする — contains_ctrl のみを使う hook が将来追加された場合の検査漏れ防止
caller_files=$(grep -rlE 'neutralize_ctrl|contains_ctrl' "$HOOKS_DIR" --include='*.sh' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v '/control-char-neutralize.sh$' \
  || true)
checked=0
for f in $caller_files; do
  # コメント行を除いた実 call site があるファイルのみ検査 (収集側 grep -rlE と書式統一)
  if ! grep -vE '^[[:space:]]*#' "$f" | grep -qE 'neutralize_ctrl|contains_ctrl'; then
    continue
  fi
  checked=$((checked + 1))
  # source 行は `source "$SCRIPT_DIR/..."` と `source "$(dirname "${BASH_SOURCE[0]}")/..."`
  # の両形式 (path 内に入れ子クォートあり) を許容する
  assert_grep "TC-2: $(basename "$f") sources control-char-neutralize.sh" \
    "$f" 'source ".*control-char-neutralize\.sh"'
done
# sweep 自体が空回りしていないことを pin (rollout 対象は 24 ファイル以上)
if [ "$checked" -ge 24 ]; then
  pass "TC-2: sweep coverage ($checked caller files checked)"
else
  fail "TC-2: sweep coverage too small ($checked files — rollout 対象が grep から漏れている可能性)"
fi

if ! print_summary "$(basename "$0")" \
  "診断スニペット emission site を hook に追加するときは control-char-neutralize.sh を source し、head -N の直後に '| neutralize_ctrl --keep-newline' を挿入すること (Issue #1183)"; then
  exit 1
fi
