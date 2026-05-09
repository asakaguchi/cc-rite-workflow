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
# 注: `set -euo pipefail` 配下では grep 0 マッチ (exit 1) で pipeline 全体が abort するため、
# `{ grep ... || true; }` で 0 マッチを exit 0 に正規化する (ratchet ideal 達成時の silent abort 防止)
issue_count=$({ grep -oE 'Issue #[0-9]+' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$issue_count" -le 1 ]; then
  pass "Upper: \`Issue #[0-9]+\` count <= 1 (actual=$issue_count)"
else
  fail "Upper: \`Issue #[0-9]+\` count <= 1 (actual=$issue_count, expected <=1)"
fi

cycle_count=$({ grep -oE 'cycle [0-9]+' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$cycle_count" -le 1 ]; then
  pass "Upper: \`cycle [0-9]+\` count <= 1 (actual=$cycle_count)"
else
  fail "Upper: \`cycle [0-9]+\` count <= 1 (actual=$cycle_count, expected <=1)"
fi

bell_count=$({ grep -oE '🚨' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$bell_count" -le 5 ]; then
  pass "Upper: \`🚨\` count <= 5 (actual=$bell_count)"
else
  fail "Upper: \`🚨\` count <= 5 (actual=$bell_count, expected <=5)"
fi

# === 下限 assert: 現状値の保護 ===
echo ""
echo "--- Lower bounds (current-state protection) ---"

# 上限 assert と単位を揃えるため `grep -oE | wc -l` (occurrence 単位) に統一する。
# `grep -c` (line 単位) では 1 行に複数出現する phrase を 1 とカウントしてしまい、後続 PR で
# 1 行集約 slim を行った際に行数 30 を満たしつつ実出現が 30 未満になる ratchet 漏れリスクがある。
# 注: 0 マッチ時の pipefail abort 回避は `{ ... || true; }` で実装 (上限 assert と同パターン)。
ask_count=$({ grep -oE 'AskUserQuestion' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$ask_count" -ge 30 ]; then
  pass "Lower: \`AskUserQuestion\` count >= 30 (actual=$ask_count)"
else
  fail "Lower: \`AskUserQuestion\` count >= 30 (actual=$ask_count, expected >=30)"
fi

# heading-anchor 限定: 行頭の `#+ … 🚨 (Mandatory After|After <Word>)` のみを集計する。
# 現状の構造:
#   - h3: `### 🚨 Mandatory After N.N` 14 件
#   - h4: `#### N.N.N 🚨 (After Review|After Fix|Mandatory After …)` 3 件
#   - 合計: 17 件 (実測値、本 assert の閾値根拠)
# 散文 mention (`**🚨 Immediate after …**`) や table cell の参照 (`| 🚨 After Review |`) は除外する。
# 旧 regex (`Mandatory After|🚨 After `) は occurrence 単位で heading 17 件 + prose mention 等 34 件 = 51 件
# となり、後続 slim PR が prose mention を削減すると heading 数が無傷でも閾値割れする false-positive
# ratchet を生んだ。本 assert は heading 自体の削除のみを catch する真正な構造保護として機能する。
# `After ` 側を `After [A-Za-z]` (単語境界) として `Mandatory After` 側との trailing-space 非対称性を解消し、
# 将来 `### 🚨 After-Review` (hyphen) など想定外の heading 命名が混入した場合の取りこぼしも防ぐ。
mandatory_count=$({ grep -oE '^#+ .*🚨 (Mandatory After|After [A-Za-z])' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$mandatory_count" -ge 17 ]; then
  pass "Lower: \`Mandatory After\` heading-anchor count >= 17 (actual=$mandatory_count)"
else
  fail "Lower: \`Mandatory After\` heading-anchor count >= 17 (actual=$mandatory_count, expected >=17)"
fi

# === 対称性 assert: flow-state-update.sh create の 5 引数 ===
echo ""
echo "--- Symmetry (flow-state-update.sh create 5-arg invariant) ---"

# bash code block 内 (```bash ... ```) の `flow-state-update.sh create` 呼び出しのみ対象。
# markdown 散文 (table cell / prose mention) の言及は対象外。
# 各 create 呼び出しに対して、bash block 終端 ``` までを動的に block として抽出する
# (固定 +7 行 window では line continuation の長さに依存して block を取り損ねるリスクがある)。
# awk でファイル全体を 1 度走査し、各 block を `\0` 区切りで出力 → bash の read -d '' で受ける。
total=0
asymmetric=0
while IFS= read -r -d '' block; do
  [ -z "$block" ] && continue
  total=$((total + 1))
  first_line=$(printf '%s' "$block" | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)
  missing=""
  # 引数検出 regex は `--flag value` (space 区切り) 形式を前提とする。`--flag=value` 形式は
  # 現状 start.md では使われていないが、将来書式変更時はこの regex を拡張する必要がある。
  for flag in '--phase' '--issue' '--branch' '--pr' '--next'; do
    if ! printf '%s\n' "$block" | grep -qE -- "${flag}([[:space:]]|$)"; then
      missing="${missing} ${flag}"
    fi
  done
  if [ -n "$missing" ]; then
    asymmetric=$((asymmetric + 1))
    echo "  ⚠️ asymmetric (block starting: ${first_line}, missing:${missing})"
  fi
done < <(awk '
  /^```bash/      { in_block=1; in_create=0; block=""; next }
  /^```$/         {
                    if (in_create) { printf "%s%c", block, 0 }
                    in_block=0; in_create=0; block=""; next
                  }
  in_block && /flow-state-update\.sh create/ {
                    # 同一 bash block 内に複数 create 呼び出しがある場合、前 block を先に flush
                    # してから新 block を開始する (multi-create-per-block blind spot 防止)
                    if (in_create) { printf "%s%c", block, 0 }
                    in_create=1
                    block=$0
                    next
                  }
  in_block && in_create { block = block "\n" $0 }
' "$START_MD")

if [ "$asymmetric" -eq 0 ]; then
  pass "Symmetry: all ${total} \`flow-state-update.sh create\` invocations have 5 args (--phase/--issue/--branch/--pr/--next)"
else
  fail "Symmetry: ${asymmetric}/${total} invocations missing required args"
fi

# === Summary ===
if ! print_summary "$(basename "$0")" \
  "後続 PR (B-H) の slim 進捗で上限超過パターンを削減してください。STRICT_CHARTER=1 での fail は ratchet として設計されています。"; then
  exit 1
fi
