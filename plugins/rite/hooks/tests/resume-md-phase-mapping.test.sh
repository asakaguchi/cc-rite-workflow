#!/bin/bash
# resume-md-phase-mapping.test.sh — CG-B (PR #1079 verified-review)
#
# Purpose:
#   `commands/resume.md` Phase 3.2 の phase → step mapping table が
#   `phase-transition-whitelist.sh` の `_RITE_PHASE_TRANSITIONS` と
#   `rite_phase_is_known` で実際に解決可能であることを静的に検証する。
#
#   resume.md は `/rite:resume` の routing SoT。typo (`phase5_fixx` 等)、
#   stale row、新規 phase の row 追加忘れは静かに `/rite:resume` を誤 step に
#   ジャンプさせる。本 test は以下の 3 不変条件を assert する:
#
#     (a) flat workflow 9 phase 行が `rite_phase_is_known` を通る
#     (b) `_RITE_PHASE_TRANSITIONS` に含まれる全 phase が resume.md に row を持つ
#     (c) legacy compat 行の target step 番号は 1-8 の範囲に収まる
#
# When this test fails:
#   - resume.md の Phase 3.2 表 / legacy compat 表 を修正
#   - 新 phase 追加時は (a)(b) が両立するよう resume.md と whitelist を同期更新

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
RESUME_MD="$PLUGIN_ROOT/commands/resume.md"
WHITELIST_SH="$PLUGIN_ROOT/hooks/phase-transition-whitelist.sh"

if [ ! -f "$RESUME_MD" ]; then
  echo "ERROR: $RESUME_MD not found" >&2
  exit 1
fi
if [ ! -f "$WHITELIST_SH" ]; then
  echo "ERROR: $WHITELIST_SH not found" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$WHITELIST_SH"

# 9 flat workflow phases per PR #1079 design.
# `completed` is terminal (no further forward transition) but must still be known.
FLAT_PHASES=(init branch plan implement lint pr review fix completed)

# ──────────────────────────────────────────────────────────────────────
# (a) Phase 3.2 主表に 9 phase 全てが row を持つ
# ──────────────────────────────────────────────────────────────────────
for phase in "${FLAT_PHASES[@]}"; do
  # 行頭 `| \`<phase>\` |` を緩く拾う (空白許容)
  if grep -qE "^\|[[:space:]]*\`${phase}\`[[:space:]]*\|" "$RESUME_MD"; then
    pass "TC-A1 resume.md has row for phase=${phase}"
  else
    fail "TC-A1 resume.md missing row for phase=${phase}"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# (b) 9 phase 全てが rite_phase_is_known を通る
# ──────────────────────────────────────────────────────────────────────
for phase in "${FLAT_PHASES[@]}"; do
  if rite_phase_is_known "$phase"; then
    pass "TC-B1 rite_phase_is_known('$phase') accepts"
  else
    fail "TC-B1 rite_phase_is_known('$phase') rejected (whitelist drift)"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# (c) legacy compat 行の target step 番号は 1-8 の範囲に収まる
# ──────────────────────────────────────────────────────────────────────
# 「Legacy phase 名 (pre-#1079) compatibility」セクション内の行から
# `Resume from ステップ N` を抽出して 1-8 の範囲を検証する。
in_legacy=0
invalid_steps=""
while IFS= read -r line; do
  if [[ "$line" == *"Legacy phase 名 (pre-#1079) compatibility"* ]]; then
    in_legacy=1
    continue
  fi
  if [ "$in_legacy" = "1" ]; then
    # 次の `####` heading で legacy セクション終了
    if [[ "$line" =~ ^#### ]]; then
      break
    fi
    # `Resume from ステップ X` 抽出
    if [[ "$line" =~ Resume\ from\ ステップ\ ([0-9]+) ]]; then
      step="${BASH_REMATCH[1]}"
      if [ "$step" -lt 1 ] || [ "$step" -gt 8 ]; then
        invalid_steps="${invalid_steps} ${step}(line:'$line')"
      fi
    fi
  fi
done < "$RESUME_MD"

if [ -z "$invalid_steps" ]; then
  pass "TC-C1 legacy compat rows target step 1-8"
else
  fail "TC-C1 legacy compat rows have out-of-range step refs:${invalid_steps}"
fi

# ──────────────────────────────────────────────────────────────────────
# (d) `_RITE_PHASE_TRANSITIONS` の primary key が resume.md でも参照されている
#     (`completed` / `init` / `branch` ...)。逆向きの drift guard。
# ──────────────────────────────────────────────────────────────────────
# 配列 keys を取得
declare -a TRANSITION_KEYS=("${!_RITE_PHASE_TRANSITIONS[@]}")
for key in "${TRANSITION_KEYS[@]}"; do
  # cleanup_* / ingest_* / create_* lifecycle は resume.md スコープ外なのでスキップ
  case "$key" in
    cleanup*|ingest*|create*) continue ;;
  esac
  if grep -qE "^\|[[:space:]]*\`${key}\`[[:space:]]*\|" "$RESUME_MD"; then
    pass "TC-D1 whitelist phase=${key} has row in resume.md"
  else
    fail "TC-D1 whitelist phase=${key} missing in resume.md (add row to Phase 3.2 table)"
  fi
done

print_summary "resume-md-phase-mapping.test.sh"
