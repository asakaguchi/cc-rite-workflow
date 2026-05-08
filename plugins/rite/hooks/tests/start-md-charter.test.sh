#!/bin/bash
# start-md-charter.test.sh — Simplification Charter assertions for start.md
#
# Issue #897 / PR A: 後続 PR (B-H) の slim 進捗を機械的に保護するドリフト検出ゲート。
#
# Run modes:
#   STRICT_CHARTER 未設定 (default): skip して exit 0 (CI red 化しない)
#   STRICT_CHARTER=1                : 全 assert 実行 (上限超過時は fail = ratchet)
#
# Assertions:
#   上限 (Charter 違反パターン上限):
#     - `Issue #[0-9]+` ≤ 1   metavariable `Issue #N` は数字でないため自動除外
#     - `cycle [0-9]+`  ≤ 1
#     - `🚨`            ≤ 5
#   下限 (現状値の保護):
#     - `AskUserQuestion` ≥ 30
#     - `Mandatory After` ≥ 30
#   対称性:
#     - `flow-state-update.sh create` 各呼び出しが
#       --phase / --issue / --branch / --pr / --next の 5 種すべてを含む
#
# Note (PR C 以降):
#   `MUST execute in the SAME response turn` ≥ 30 / `DO NOT stop` ≥ 30 の追加 assert は
#   PR C で 2 文 contract phrase が導入された後に別 PR で追加する。本 PR では実装しない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
START_MD="$PLUGIN_ROOT/commands/issue/start.md"

# Env gate: opt-in via STRICT_CHARTER=1
if [ "${STRICT_CHARTER:-}" != "1" ]; then
  echo "[start-md-charter] skip (STRICT_CHARTER not set; opt-in only)"
  exit 0
fi

if [ ! -f "$START_MD" ]; then
  echo "ERROR: start.md not found at $START_MD" >&2
  exit 1
fi

echo "=== start-md-charter (STRICT_CHARTER=1) ==="
echo "target: $START_MD"
echo ""

# === 上限 assert: Charter 違反パターン上限 ===
echo "--- Upper bounds (Charter limits) ---"

# `grep -oE 'Issue #[0-9]+'` は数字限定のため `Issue #N` placeholder は自動除外される
issue_count=$(grep -oE 'Issue #[0-9]+' "$START_MD" | wc -l | tr -d ' ')
if [ "$issue_count" -le 1 ]; then
  pass "Upper: \`Issue #[0-9]+\` count <= 1 (actual=$issue_count)"
else
  fail "Upper: \`Issue #[0-9]+\` count <= 1 (actual=$issue_count, expected <=1)"
fi

cycle_count=$(grep -oE 'cycle [0-9]+' "$START_MD" | wc -l | tr -d ' ')
if [ "$cycle_count" -le 1 ]; then
  pass "Upper: \`cycle [0-9]+\` count <= 1 (actual=$cycle_count)"
else
  fail "Upper: \`cycle [0-9]+\` count <= 1 (actual=$cycle_count, expected <=1)"
fi

bell_count=$(grep -c '🚨' "$START_MD" || true)
if [ "$bell_count" -le 5 ]; then
  pass "Upper: \`🚨\` count <= 5 (actual=$bell_count)"
else
  fail "Upper: \`🚨\` count <= 5 (actual=$bell_count, expected <=5)"
fi

# === 下限 assert: 現状値の保護 ===
echo ""
echo "--- Lower bounds (current-state protection) ---"

ask_count=$(grep -c 'AskUserQuestion' "$START_MD" || true)
if [ "$ask_count" -ge 30 ]; then
  pass "Lower: \`AskUserQuestion\` count >= 30 (actual=$ask_count)"
else
  fail "Lower: \`AskUserQuestion\` count >= 30 (actual=$ask_count, expected >=30)"
fi

# `Mandatory After` (markdown heading 内) または `🚨 After ` (review/fix の after section) を集計
mandatory_count=$(grep -cE 'Mandatory After|🚨 After ' "$START_MD" || true)
if [ "$mandatory_count" -ge 30 ]; then
  pass "Lower: \`Mandatory After\` count >= 30 (actual=$mandatory_count)"
else
  fail "Lower: \`Mandatory After\` count >= 30 (actual=$mandatory_count, expected >=30)"
fi

# === 対称性 assert: flow-state-update.sh create の 5 引数 ===
echo ""
echo "--- Symmetry (flow-state-update.sh create 5-arg invariant) ---"

# bash code block 内 (```bash ... ```) の `flow-state-update.sh create` 呼び出しのみ対象。
# markdown 散文 (table cell / prose mention) の言及は対象外。
total=0
asymmetric=0
while IFS= read -r line_no; do
  [ -z "$line_no" ] && continue
  total=$((total + 1))
  end=$((line_no + 7))
  block=$(sed -n "${line_no},${end}p" "$START_MD")
  missing=""
  for flag in '--phase' '--issue' '--branch' '--pr' '--next'; do
    if ! printf '%s\n' "$block" | grep -qE -- "${flag}([[:space:]]|$)"; then
      missing="${missing} ${flag}"
    fi
  done
  if [ -n "$missing" ]; then
    asymmetric=$((asymmetric + 1))
    echo "  ⚠️ asymmetric (line ${line_no}, missing:${missing})"
  fi
done < <(awk '
  /^```bash/ { in_block=1; next }
  /^```$/    { in_block=0; next }
  in_block && /flow-state-update\.sh create/ { print NR }
' "$START_MD")

if [ "$asymmetric" -eq 0 ]; then
  pass "Symmetry: all ${total} \`flow-state-update.sh create\` invocations have 5 args (--phase/--issue/--branch/--pr/--next)"
else
  fail "Symmetry: ${asymmetric}/${total} invocations missing required args"
fi

# === Summary ===
if ! print_summary "start-md-charter" \
  "後続 PR (B-H) の slim 進捗で上限超過パターンを削減してください。STRICT_CHARTER=1 での fail は ratchet として設計されています。"; then
  exit 1
fi
