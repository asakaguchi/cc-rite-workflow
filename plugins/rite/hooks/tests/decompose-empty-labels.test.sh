#!/bin/bash
# decompose-empty-labels.test.sh
#
# Source-drift guard for the empty-labels_csv fix in decompose-issues.sh.
#
# 挙動の回帰検証（共有ラベルなしでも全 Sub-Issue が作成されるか）は、実スクリプトを gh
# stub で e2e 実行する scripts/tests/decompose-issues.test.sh の "Test 8" が担う。本ファイルは
# それを補完する安価なソースレベル check で、Sub ラベル生成の idiom が buggy な stdin パイプへ
# 逆戻りしないことを pin する。
#
# Bug class (silent boundary failure):
#   旧実装は `printf '%s' "$labels_csv" | jq -R 'split(",")|map(...)'` で Sub ラベルを
#   組み立てていた。`jq -R` は stdin を行単位で読むため、空 labels_csv では「出力なし +
#   exit 0」を返し sub_labels_json="" となる。`|| "[]"` ガードは jq が exit 0 で終わるため
#   発火せず、直後の `jq --argjson labels ""` が "invalid JSON" で落ちて全 Sub-Issue 作成が
#   失敗する。親は "epic," を前置して常に非空入力になるため成功し、共有ラベルを空にした分解
#   だけが子を全滅させる（親成功・子全滅という気付きにくい部分失敗）。
#
# 修正は labels_csv を `jq -cn --arg` で渡し stdin を経由しない。これにより "" は有効な
# `[]` 配列になる。本 guard はソースが --arg idiom を使い続け、Sub ラベルに stdin パイプの
# jq -R を再導入しないことを固定する（親行は非空入力保証のため jq -R を温存する — 下記参照）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/scripts/decompose-issues.sh"

# ソースが --arg idiom を使い、Sub ラベルに stdin パイプの jq -R を使わないことを pin する。
# 親ラベル行 (`"epic,${labels_csv}" | jq -R`) は非空入力が保証され温存されるため、
# anti-pattern は Sub 行に固有の `labels_csv" | jq -R`（labels_csv の直後が "）のみを禁ずる。
echo "=== source uses --arg idiom, not the stdin jq -R pipe for Sub labels ==="
assert_grep     "sub_labels_json は jq -cn --arg 経由"        "$SCRIPT" \
  'sub_labels_json=\$\(jq -cn --arg'
assert_not_grep "Sub ラベルに stdin パイプの jq -R が残存しない" "$SCRIPT" \
  'labels_csv" \| jq -R'

if ! print_summary "$(basename "$0")" \
  "drift: decompose-issues.sh の Sub ラベル生成が stdin パイプの jq -R に逆戻りした。空 labels_csv は jq -cn --arg 経由で [] にせよ（jq -R は空入力で空出力 + exit 0 となりガードをすり抜ける）。挙動の回帰検証は scripts/tests/decompose-issues.test.sh Test 8 が担う。"; then
  exit 1
fi
