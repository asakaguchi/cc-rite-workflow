#!/bin/bash
# anchor-reachability.test.sh — PR H (#905)
#
# Purpose:
#   `plugins/rite/commands/issue/start*.md` 内の全ての relative Markdown link
#   `[text](./<path>[#section])` が指し示すファイルが実在することを `test -e` で検証する。
#
#   sub-skill 分割や reference 移動の refactor で「link 先のファイルが移動 / 削除されて
#   dangling reference が発生する」regression を防ぐ。
#
# Detection algorithm:
#   1. start*.md から `[text](./<path>)` 形式の link をすべて抽出
#   2. パス部から section anchor (`#...`) を除去
#   3. 各 path を start*.md と同じディレクトリ起点で `test -e` 確認
#   4. 1 件でも missing なら fail (dangling reference 一覧を表示)
#
# Scope:
#   - 対象: relative path link `[...](./...)` のみ (絶対 URL や `../...` は対象外)
#   - section anchor (`#xxx`) 内の anchor 存在チェックは scope 外 (別 test 候補)
#
# When this test fails:
#   dangling reference が検出された場合、(a) ファイル移動先に link を更新、または
#   (b) link 自体を削除、いずれかで reachability を回復。Do NOT relax this test —
#   broken reference は document の信頼性を破壊する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
START_DIR="$PLUGIN_ROOT/commands/issue"

START_FILES=(
  "$START_DIR/start.md"
  "$START_DIR/start-execute.md"
  "$START_DIR/start-publish.md"
  "$START_DIR/start-finalize.md"
)

echo "=== anchor extraction ==="

# 全 start*.md から `[text](./<path>)` 形式の link を抽出
# `set -euo pipefail` 配下では grep の 0 マッチ (exit 1) が pipeline abort を起こすため、
# 各 grep に `|| true` を付与して pipefail abort を防ぐ (F-12 finding 対応)。
all_refs=()
for f in "${START_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
  mapfile -t refs < <({ grep -hoE '\[[^]]+\]\(\./[^)]+\)' "$f" || true; } | { grep -oE '\([^)]+\)' || true; } | sed 's/[()]//g' | sort -u)
  for r in "${refs[@]}"; do
    [ -z "$r" ] && continue
    all_refs+=("$r")
  done
done

# 重複排除
mapfile -t unique_refs < <(printf '%s\n' "${all_refs[@]}" | sort -u)
ref_count="${#unique_refs[@]}"
echo "  unique relative refs in start*.md: $ref_count"

if [ "$ref_count" -ge 1 ]; then
  pass "start*.md には >= 1 件の relative reference が存在 (count=$ref_count)"
else
  fail "start*.md に relative reference が検出されない (extraction 失敗?)"
  exit 1
fi

echo
echo "=== anchor reachability check (test -e) ==="

missing_count=0
missing_refs=()
for ref in "${unique_refs[@]}"; do
  # section anchor (#xxx) を除去
  path_only="${ref%%#*}"
  full_path="$START_DIR/$path_only"
  if [ -e "$full_path" ]; then
    pass "reachable: $ref"
  else
    missing_count=$((missing_count + 1))
    missing_refs+=("$ref")
    fail "DANGLING: $ref (resolved to $full_path, but does not exist)"
  fi
done

echo
if [ "$missing_count" -eq 0 ]; then
  pass "全 $ref_count 件の reference が reachable"
else
  echo "  対処: $missing_count 件の dangling reference を修正してください"
  echo "    - link を正しい path に更新する"
  echo "    - reference 自体を削除する"
fi

# === Summary ===
if ! print_summary "$(basename "$0")" \
  "dangling reference 検出時は link 更新 or 削除で reachability 回復。Do NOT relax this test."; then
  exit 1
fi
exit 0
