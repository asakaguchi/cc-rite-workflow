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
INTERVIEW_MD="$COMMANDS_DIR/issue/create-interview.md"

# Hard precondition — missing target file is an environment error, not a test failure.
# F-05: INTERVIEW_MD を precondition guard に組み込み、silent skip による regression 見逃しを防ぐ。
for f in "$CREATE_MD" "$CLEANUP_MD" "$INGEST_MD" "$INTERVIEW_MD"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

echo "=== TC-1: create.md Mandatory After Interview Step 0 ==="

# TC-1.1: VERY FIRST tool call keyword presence (Mandatory After Interview)
# F-08: 当初コメントは「両方を許容」と書かれていたが、ERE は大文字小文字を区別するため
# regex `\*\*VERY FIRST tool call\*\*` は uppercase 形式のみ pin する。これは canonical
# (sub-skill-return-protocol.md:84 の「3 site canonical signaling pattern」共通 keyword)
# が uppercase で固定されているため意図的: lowercase phrasing は drift の兆候として fail させる。
assert_grep "TC-1.1: create.md に uppercase '**VERY FIRST tool call**' keyword が存在 (canonical phrasing pin)" \
  "$CREATE_MD" \
  '\*\*VERY FIRST tool call\*\*'

# TC-1.2: BEFORE any text output keyword presence
assert_grep "TC-1.2: create.md に 'BEFORE any text output' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output'

# TC-1.3: Step 0 bash literal が存在 (flow-state-update.sh patch --phase create_post_interview)
# F-04, F-10 (LOW): Step 0 specific anchor + alternation を 2 つの assert_grep に分割して
# specificity を上げる。Mandatory After Interview header の存在も確認することで、
# Step 0 を完全削除し他の bash block (Phase 0.5 pre-flight 等) だけ残された
# regression を false negative させない設計。
assert_grep "TC-1.3a: create.md に 'Mandatory After Interview' header が存在 (Step 0 が属するセクション anchor)" \
  "$CREATE_MD" \
  'Mandatory After Interview'

assert_grep "TC-1.3b: create.md に Step 0 bash literal '--phase \"create_post_interview\"' が存在" \
  "$CREATE_MD" \
  'phase[[:space:]]+"create_post_interview"'

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

# F-02 (HIGH): TC-3.2/3.3/3.4 は **`<!-- continuation:` で始まる単一行内** に keyword が
# 出現することを pin する。当初実装は file 全体に対する grep だったため、rationale prose
# (ingest.md:1134 の「Imperative 強度の rationale」段落) にも keyword が含まれており、
# 万一 line 1131 の `<!-- continuation: ... -->` 自体が削除されても rationale prose を
# 残せば test が誤って pass する false-negative 経路が存在した。HTML comment 行頭 anchor を
# 含めることで「caller continuation HTML literal そのもの」を直接 pin する。

# TC-3.1: caller continuation HTML literal に 'MUST execute' + 'Step 0 bash literal'
assert_grep "TC-3.1: ingest.md caller continuation HTML literal に 'MUST execute' + 'Step 0 bash literal' keyword 群" \
  "$INGEST_MD" \
  '<!-- continuation:.*caller MUST execute its.*Step 0 bash literal'

# TC-3.2: caller continuation HTML literal 1 行内に 'VERY FIRST tool call BEFORE any text output'
assert_grep "TC-3.2: ingest.md caller continuation HTML literal 1 行内に 'VERY FIRST tool call BEFORE any text output' keyword" \
  "$INGEST_MD" \
  '<!-- continuation:.*VERY FIRST tool call BEFORE any text output'

# TC-3.3 / TC-3.4: 否定形重ねがけ (DO NOT end the turn / DO NOT output any narrative text)
# 両 keyword が caller continuation HTML literal 同一行内に出現することを別個に pin。
assert_grep "TC-3.3: ingest.md caller continuation HTML literal 1 行内に 'DO NOT end the turn' keyword" \
  "$INGEST_MD" \
  '<!-- continuation:.*DO NOT end the turn'
assert_grep "TC-3.4: ingest.md caller continuation HTML literal 1 行内に 'DO NOT output any narrative text' keyword" \
  "$INGEST_MD" \
  '<!-- continuation:.*DO NOT output any narrative text'

echo
echo "=== TC-4: Cross-orchestrator imperative keyword count (per-file 最低数) ==="

# F-03 (MEDIUM): TC-4.1 は当初 file 横断合計 `>=4` という緩い閾値だったため、
# 1 file の imperative 強度が完全消失しても他 file で hit 数が増えれば pass する
# false-negative 経路が存在した。per-file の minimum を pin する形に強化することで
# 「4 site それぞれが imperative 強度を保持している」ことを構造的に検証する。
# 期待値の根拠 (実装直後の実測):
#   - create.md   : >= 2  (Mandatory After Interview + Mandatory After Delegation)
#   - cleanup.md  : >= 1  (Mandatory After Wiki Ingest)
#   - ingest.md   : >= 1  (continuation HTML comment line)
# いずれかが下回れば即 fail。site 単位での弱化を確実に検出する。

count_create=$(grep -cF 'VERY FIRST' "$CREATE_MD" 2>/dev/null || echo 0)
count_cleanup=$(grep -cF 'VERY FIRST' "$CLEANUP_MD" 2>/dev/null || echo 0)
count_ingest=$(grep -cF 'VERY FIRST' "$INGEST_MD" 2>/dev/null || echo 0)

if [ "$count_create" -ge 2 ]; then
  pass "TC-4.1: create.md に 'VERY FIRST' keyword が 2 ヶ所以上 (実測=$count_create, 期待>=2)"
else
  fail "TC-4.1: create.md に 'VERY FIRST' keyword が 2 ヶ所未満 (実測=$count_create, 期待>=2 — Mandatory After Interview / Delegation 双方で必要)"
fi

if [ "$count_cleanup" -ge 1 ]; then
  pass "TC-4.2: cleanup.md に 'VERY FIRST' keyword が 1 ヶ所以上 (実測=$count_cleanup, 期待>=1)"
else
  fail "TC-4.2: cleanup.md に 'VERY FIRST' keyword が 1 ヶ所未満 (実測=$count_cleanup, 期待>=1 — Mandatory After Wiki Ingest で必要)"
fi

if [ "$count_ingest" -ge 1 ]; then
  pass "TC-4.3: ingest.md に 'VERY FIRST' keyword が 1 ヶ所以上 (実測=$count_ingest, 期待>=1)"
else
  fail "TC-4.3: ingest.md に 'VERY FIRST' keyword が 1 ヶ所未満 (実測=$count_ingest, 期待>=1 — caller continuation HTML literal で必要)"
fi

echo
echo "=== TC-5: Anti-pattern (旧文言の revert) 検出 ==="

# F-05: INTERVIEW_MD は precondition guard で存在保証済 (line 49-55)。if-guard を撤去し
#       silent skip による regression 見逃しを排除。

# TC-5.1: '自動継続します' (現状報告) が create-interview.md に残っていない
# (S2 で 「MUST continue」へ recast 済み)
assert_not_grep "TC-5.1: create-interview.md に旧 '⏭ 継続中:.*自動継続します' 文言が残っていない" \
  "$INTERVIEW_MD" \
  '⏭ 継続中:.*自動継続します'

# F-07: TC-5.2 — caller HTML literal 内の旧 phrasing revert 検出。
# Issue #910 mitigation の load-bearing 設計として `MUST execute as VERY FIRST tool call
# BEFORE any text output` への recast を採用した。`IMMEDIATELY run this as your next tool
# call` のような旧 caller HTML literal phrasing が caller HTML literal 内に再出現すると
# imperative 強度が弱まる経路となるため、anti-pattern として明示的に block する。
assert_not_grep "TC-5.2: create-interview.md caller HTML literal に旧 'IMMEDIATELY run this as your next tool call' 文言が残っていない" \
  "$INTERVIEW_MD" \
  'IMMEDIATELY run this as your next tool call'

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
