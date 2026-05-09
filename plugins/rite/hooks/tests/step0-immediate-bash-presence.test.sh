#!/bin/bash
# step0-immediate-bash-presence.test.sh
#
# Cross-orchestrator regression test for Issue #910 — orchestrator return-block
# 直後の implicit stop regression。
#
# Background:
#   stop-guard.sh 撤去 (#674/#675) 以降、prompt-side defense のみが残り、LLM の
#   turn-boundary heuristic 起因の implicit stop が `Sautéed for 7m 40s` 等として
#   実測されている。Issue #910 は caller-side Step 0 Immediate Bash literal の
#   imperative 強度を強化することで mitigation を図る対策。
#
# Purpose:
#   4 site の caller / sub-skill output point で以下を grep verify する:
#     1. Step 0 Immediate Bash literal が存在 (bash command literal in backticks)
#     2. imperative keyword が存在: `MUST execute`, `VERY FIRST`, `BEFORE any text output`
#     3. 否定形重ねがけ: `DO NOT end the turn` / `DO NOT output any narrative`
#
# 4 sites (cross-orchestrator):
#   (a) commands/issue/create.md       — Mandatory After Interview Step 0
#   (b) commands/issue/create.md       — Mandatory After Delegation pre-section prose
#   (c) commands/pr/cleanup.md         — Mandatory After Wiki Ingest Step 0
#   (d) commands/wiki/ingest.md        — Step 1 caller continuation HTML comment
#
# Why presence + keyword (not byte equality):
#   byte equality は既存の caller-html-literal-symmetry.test.sh が
#   create-interview.md 内 2 site を pin する責務を持つ。本 test は
#   cross-orchestrator (4 site) で imperative keyword presence のみを担当する
#   (責務分離 — wiki/sub-skill-return-protocol.md「責務分離 invariant」と整合)。
#
# When this test fails:
#   imperative 強度が弱まった (`MUST` が `IMMEDIATELY` に diluted した、
#   `VERY FIRST` が `next` に置換された 等)。Issue #910 D-01 の経験的観測に
#   基づく mitigation を破壊しているため、強度を復元すること。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
COMMANDS_DIR="$PLUGIN_ROOT/commands"

CREATE_MD="$COMMANDS_DIR/issue/create.md"
CLEANUP_MD="$COMMANDS_DIR/pr/cleanup.md"
INGEST_MD="$COMMANDS_DIR/wiki/ingest.md"

# Hard precondition — missing target file is an environment error, not a test failure.
for f in "$CREATE_MD" "$CLEANUP_MD" "$INGEST_MD"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

echo "=== TC-1: create.md Mandatory After Interview Step 0 ==="

# TC-1.1: VERY FIRST tool call keyword presence (Mandatory After Interview)
# 「**very first tool call**」と「**VERY FIRST tool call**」の両方を許容する
# (cycle 1 review 対応: 表記揺れに対する戦略的緩和)
assert_grep "TC-1.1: create.md に 'VERY FIRST tool call' keyword が存在" \
  "$CREATE_MD" \
  '\*\*VERY FIRST tool call\*\*'

# TC-1.2: BEFORE any text output keyword presence
assert_grep "TC-1.2: create.md に 'BEFORE any text output' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output'

# TC-1.3: Step 0 bash literal が存在 (flow-state-update.sh patch --phase create_post_interview)
assert_grep "TC-1.3: create.md Step 0 bash literal (flow-state-update.sh patch --phase create_post_interview) が存在" \
  "$CREATE_MD" \
  'flow-state-update\.sh patch[[:space:]]*\\?[[:space:]]*$|--phase[[:space:]]+"create_post_interview"'

echo
echo "=== TC-2: cleanup.md Mandatory After Wiki Ingest Step 0 ==="

# TC-2.1: VERY FIRST tool call keyword (cleanup.md)
assert_grep "TC-2.1: cleanup.md に 'VERY FIRST tool call' keyword が存在" \
  "$CLEANUP_MD" \
  '\*\*VERY FIRST tool call\*\*'

# TC-2.2: BEFORE any text output keyword
assert_grep "TC-2.2: cleanup.md に 'BEFORE any text output' keyword が存在" \
  "$CLEANUP_MD" \
  'BEFORE any text output'

# TC-2.3: Step 0 bash literal (cleanup_post_ingest)
# Pattern intentionally avoids leading `--` (grep treats it as option terminator).
# Uses `phase` keyword (without leading dashes) followed by quoted phase value.
assert_grep "TC-2.3: cleanup.md Step 0 bash literal (phase \"cleanup_post_ingest\") が存在" \
  "$CLEANUP_MD" \
  'phase[[:space:]]+"cleanup_post_ingest"[[:space:]]+--active'

echo
echo "=== TC-3: ingest.md caller continuation HTML comment ==="

# TC-3.1: caller MUST execute its 🚨 Mandatory After ... Step 0 bash literal
assert_grep "TC-3.1: ingest.md caller continuation HTML に 'MUST execute' + 'Step 0 bash literal' keyword 群" \
  "$INGEST_MD" \
  'caller MUST execute its.*Step 0 bash literal'

# TC-3.2: VERY FIRST tool call BEFORE any text output
assert_grep "TC-3.2: ingest.md caller continuation HTML に 'VERY FIRST tool call BEFORE any text output' keyword" \
  "$INGEST_MD" \
  'VERY FIRST tool call BEFORE any text output'

# TC-3.3: 否定形重ねがけ (DO NOT end the turn / DO NOT output any narrative text)
assert_grep "TC-3.3: ingest.md caller continuation HTML に 'DO NOT end the turn' keyword" \
  "$INGEST_MD" \
  'DO NOT end the turn'
assert_grep "TC-3.4: ingest.md caller continuation HTML に 'DO NOT output any narrative text' keyword" \
  "$INGEST_MD" \
  'DO NOT output any narrative text'

echo
echo "=== TC-4: Cross-orchestrator imperative keyword count ==="

# TC-4.1: 4 site (create.md ×2 ヶ所 / cleanup.md / ingest.md) で 'VERY FIRST tool call' が
# 合計 4 ヶ所以上 grep hit する。create.md には Mandatory After Interview と Mandatory After
# Delegation の 2 ヶ所で言及される想定。
total_very_first=$(grep -cF 'VERY FIRST' "$CREATE_MD" "$CLEANUP_MD" "$INGEST_MD" 2>/dev/null \
  | awk -F: '{sum+=$2} END {print sum+0}')
if [ "$total_very_first" -ge 4 ]; then
  pass "TC-4.1: 'VERY FIRST' keyword が 3 file 横断で 4 ヶ所以上 grep hit (実測=$total_very_first)"
else
  fail "TC-4.1: 'VERY FIRST' keyword が 4 ヶ所未満 (実測=$total_very_first, 期待>=4)"
fi

echo
echo "=== TC-5: Anti-pattern (旧文言の revert) 検出 ==="

# TC-5.1: '自動継続します' (現状報告) が create-interview.md に残っていない
# (S2 で 「MUST continue」へ recast 済み)
INTERVIEW_MD="$COMMANDS_DIR/issue/create-interview.md"
if [ -f "$INTERVIEW_MD" ]; then
  assert_not_grep "TC-5.1: create-interview.md に旧 '⏭ 継続中:.*自動継続します' 文言が残っていない" \
    "$INTERVIEW_MD" \
    '⏭ 継続中:.*自動継続します'
fi

DRIFT_HINT="\
This test pins imperative keyword presence (Issue #910 mitigation) across 4
sites: create.md (×2), cleanup.md, ingest.md. If you weakened the imperative
strength (e.g., reverted MUST → IMMEDIATELY, removed 'VERY FIRST', or restored
'継続中' status reporting), restore the original strength.

Reference: skills/rite-workflow/references/sub-skill-return-protocol.md —
'prompt-side defense alone is insufficient' section.
"

if ! print_summary "step0-immediate-bash-presence.test" "$DRIFT_HINT"; then
  exit 1
fi
