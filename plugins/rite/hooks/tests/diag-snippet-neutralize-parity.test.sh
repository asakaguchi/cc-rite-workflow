#!/bin/bash
# Tests for Issue #1183: jq / コマンド stderr 診断スニペット emission site の
# control-char 中和の横展開 parity を静的に pin する。
#
# Purpose:
#   flow-state.sh (#1173/#1181) で導入された「診断スニペットは
#   neutralize_ctrl を経由して emit する」規約を、hooks/ 配下の全
#   `head -3` emission site に対称適用したことを保証する
#   (Wiki 経験則 Asymmetric Fix Transcription — 対称位置への伝播漏れ防止)。
#   将来 hook に新しい `head -3 ... >&2` 診断 site が中和なしで追加された
#   場合も TC-1 が検出する。
#
# Test cases:
#   TC-1: hooks/ 配下 (tests/ 除く) に neutralize_ctrl を経由しない
#         `head -3` emission site が存在しない (コメント行は除外)
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

echo "=== TC-1: head -3 emission site は全て neutralize_ctrl を経由 ==="
# 除外: tests/ (fixture/assertion 内の出現)、コメント行、定義元 helper の usage コメント
violations=$(grep -rn 'head -3' "$HOOKS_DIR" --include='*.sh' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v 'neutralize_ctrl' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  || true)
assert "TC-1: un-neutralized head -3 emission sites" "" "$violations"
if [ -n "$violations" ]; then
  echo "  検出された未中和 site (head -3 の直後に '| neutralize_ctrl --keep-newline' を挿入すること):"
  printf '%s\n' "$violations" | sed 's/^/    /'
fi

echo ""
echo "=== TC-2: neutralize_ctrl の caller は helper を source 済み ==="
# `neutralize_ctrl` を実行コードとして含むファイル一覧 (コメント行のみの言及は除外)
caller_files=$(grep -rl 'neutralize_ctrl' "$HOOKS_DIR" --include='*.sh' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v '/control-char-neutralize.sh$' \
  || true)
checked=0
for f in $caller_files; do
  # コメント行を除いた実 call site があるファイルのみ検査
  if ! grep -vE '^[[:space:]]*#' "$f" | grep -q 'neutralize_ctrl\|contains_ctrl'; then
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
  "診断スニペット emission site を hook に追加するときは control-char-neutralize.sh を source し、head -3 の直後に '| neutralize_ctrl --keep-newline' を挿入すること (Issue #1183)"; then
  exit 1
fi
