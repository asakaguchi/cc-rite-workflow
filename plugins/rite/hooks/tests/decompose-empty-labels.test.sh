#!/bin/bash
# decompose-empty-labels.test.sh
#
# Regression test: decompose-issues.sh は共有ラベルなし（labels_csv が空）でも
# Sub-Issue のラベル配列を crash せずに生成しなければならない。
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
# `[]` 配列になり、非空 CSV も従来同等に動く。本テストは挙動（idiom 出力）とソース
# （anti-pattern 不在）の両面で退行を防ぐ。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/scripts/decompose-issues.sh"

# === TC-1: ラベル生成 idiom が空 / 空白 / 通常 CSV で crash しない ===
# スクリプトが採用した idiom (jq -cn --arg) を同一フィルタで境界入力に対して実行し、
# 空入力でも有効な JSON 配列が得られることを確認する。
echo "=== TC-1: labels-building idiom is crash-free across boundary inputs ==="
labels_jq() {
  jq -cn --arg csv "$1" '$csv | split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))'
}
assert "TC-1a 空 CSV → []"                  "[]"               "$(labels_jq "")"
assert "TC-1b 末尾カンマ → 空要素除去"        '["chore"]'        "$(labels_jq "chore,")"
assert "TC-1c 単一ラベル"                    '["chore"]'        "$(labels_jq "chore")"
assert "TC-1d トリム + 空要素除去"           '["chore","docs"]' "$(labels_jq " chore , docs ,")"

# === TC-2: ソースが --arg idiom を使い、Sub ラベルに stdin パイプの jq -R を使わない ===
# 親ラベル行 (`"epic,${labels_csv}" | jq -R`) は非空入力が保証され温存されるため、
# anti-pattern は Sub 行に固有の `labels_csv" | jq -R`（labels_csv の直後が "）のみを禁ずる。
echo "=== TC-2: source uses --arg idiom, not the stdin jq -R pipe for Sub labels ==="
assert_grep     "TC-2a sub_labels_json は jq -cn --arg 経由"        "$SCRIPT" \
  'sub_labels_json=\$\(jq -cn --arg'
assert_not_grep "TC-2b Sub ラベルに stdin パイプの jq -R が残存しない" "$SCRIPT" \
  'labels_csv" \| jq -R'

if ! print_summary "$(basename "$0")" \
  "drift: decompose-issues.sh の Sub ラベル生成が空 labels_csv で crash する退行。空 CSV は jq -cn --arg 経由で [] にせよ（jq -R は空入力で空出力 + exit 0 となりガードをすり抜ける）。"; then
  exit 1
fi
