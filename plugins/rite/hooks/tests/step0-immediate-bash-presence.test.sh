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
#   主たる 4 cross-orchestrator grep target + 補完的な 2 caller HTML literal pin
#   = 計 6 site で以下を grep verify する。imperative keyword の適用範囲は site
#   (= layer) ごとに異なることに注意:
#
#   1. Step 0 Immediate Bash literal の section anchor + bash 行が存在
#      — orchestrator prose 層 2 site のみに適用 (TC-1.3 create.md / TC-2.3 cleanup.md)
#   2. positive imperative keyword: `MUST execute` / `VERY FIRST` / `BEFORE any text output`
#      — 全 6 site に適用 (TC-1.1 / TC-1.2 / TC-2.1 / TC-2.2 / TC-3.2 / TC-5.3)
#   3. 否定形重ねがけ: `DO NOT end the turn` / `DO NOT output any narrative`
#      — HTML comment 層 (caller HTML hint / continuation HTML literal) のみに適用 (TC-3.3 / TC-3.4 / TC-5.4)
#      — orchestrator prose 層 (create.md / cleanup.md prose) は positive imperative のみで否定形を持たない
#        (sub-skill-return-protocol.md Defense-in-depth layers table の Layer 1 row + Layer 3 row 共通の
#         imperative 強度設計 — Layer 1 prose は positive imperative のみ、Layer 3 HTML comment は positive
#         + 否定形両方を載せる site-by-site の phrasing 強度規定)
#
# 4 cross-orchestrator grep targets (主たる pin scope):
#   (a) commands/issue/create.md       — Mandatory After Interview Step 0 (positive imperative のみ)
#   (b) commands/issue/create.md       — Mandatory After Delegation pre-section prose (positive imperative のみ)
#   (c) commands/pr/cleanup.md         — Mandatory After Wiki Ingest Step 0 (positive imperative のみ)
#   (d) commands/wiki/ingest.md        — Phase 9.1 caller continuation HTML comment (positive + 否定形両方)
#
#   Note (粒度の使い分け): create.md は **2 セクション anchor** (Mandatory After Interview / Mandatory
#   After Delegation) として `×2` と数える上記 4 grep target だが、TC-4.1 の `count >= 3` は
#   `VERY FIRST` keyword の **occurrence count** (= 3 prose site: line 201/207/304) を pin する。
#   両者は粒度が異なる ("section anchor 数" vs "keyword occurrence 数") ことに注意。
#
# 2 supplementary caller HTML literal pins (補完 pin scope):
#   (e) commands/issue/create-interview.md caller HTML literal — TC-5.3/5.4 で 2 keyword pin
#       (byte equality は caller-html-literal-symmetry.test.sh が pin。本 test は imperative
#        keyword presence pin で「両ブロック同時 weak-phrasing 差し替え」regression を補完検出)
#
# Coverage matrix (test 間の責務分離):
#   - byte equality (両ブロック完全一致): caller-html-literal-symmetry.test.sh が pin
#     (前提: 両 caller HTML literal block は baseline で byte-equal という invariant を
#      保持する設計。symmetry test がこの invariant を pin している)
#   - asymmetric weakening (片ブロックのみ weak-phrasing): caller-html-literal-symmetry.test.sh の
#     byte equality assertion が catch する (上記 baseline byte-equal 前提により、片ブロック
#     差し替え時は左右が一致せず fail)
#   - cross-orchestrator imperative keyword presence (site 別 weakening): 本 test (TC-1〜TC-5) が pin
#   - 両ブロック同時 weak-phrasing (両者を同じ weak-phrasing に差し替え): 本 test の TC-5.3/5.4 が
#     caller HTML literal に canonical keyword 不在となるため catch する (補完 pin)
#
# 本 test と caller-html-literal-symmetry.test.sh は互いに直交した責務を持ち、合わせて
# create-interview.md caller HTML literal 周辺の regression 全パターンをカバーする
# (commands/issue/create-interview.md「責務分離 invariant」と整合)。
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
# INTERVIEW_MD も precondition guard に含めることで、TC-5.x の if-guard 経由 silent skip を排除する。
for f in "$CREATE_MD" "$CLEANUP_MD" "$INGEST_MD" "$INTERVIEW_MD"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

echo "=== TC-1: create.md Mandatory After Interview Step 0 ==="

# TC-1.1: VERY FIRST tool call keyword presence (Mandatory After Interview)
# uppercase 形式のみ pin する。canonical phrasing (sub-skill-return-protocol.md
# 「3 layer canonical signaling pattern」blockquote の共通 keyword) が uppercase で固定されているため、
# lowercase phrasing は drift の兆候として fail させる意図。
#
# alternation regex の現状と限界 (実情の disclaimer):
# 第 1 branch `\*\*VERY FIRST tool call\*\*` のみが create.md の現在の phrasing (line 209 Mandatory
# After Interview prose) と match する。第 2 branch `\*\*VERY FIRST tool call \(cognitive action\)\*\*`
# は **dead branch** で、create.md 内に同形式の literal は存在しない (Mandatory After Delegation prose
# line 306 は long bold `**MUST proceed to Self-check as your VERY FIRST cognitive action BEFORE ...
# narrative**` の中に "VERY FIRST cognitive action" を含む形式で、第 2 branch の syntactic shape とは
# 一致しない)。つまり Mandatory After Delegation prose の bold は本 TC-1.1 では直接 pin できておらず、
# TC-4.1 の `VERY FIRST` count >= 3 で間接 catch されている (line 209 の Interview prose 内で
# `**VERY FIRST tool call**` 1 回 + line 306 の Delegation prose 内で `VERY FIRST` 出現 2 回 = 計 3 回)。
# 第 2 branch は将来 phrasing を `**VERY FIRST tool call (cognitive action)**` 形式に統一した場合の
# forward compatibility 用に保持し、現状は dead branch として disclaim する (Issue #910 review F-03)。
assert_grep "TC-1.1: create.md に uppercase '**VERY FIRST tool call**' keyword が存在 (canonical phrasing pin、現状は第 1 branch のみ active)" \
  "$CREATE_MD" \
  '\*\*VERY FIRST tool call(\*\*| \(cognitive action\)\*\*)'

# TC-1.2: BEFORE any text output keyword presence
assert_grep "TC-1.2: create.md に 'BEFORE any text output' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output'

# TC-1.3: Step 0 bash literal が存在 (flow-state-update.sh patch --phase create_post_interview)
# Step 0 specific anchor + alternation を 2 つの assert_grep に分割して specificity を上げる設計。
#
# 設計意図 (3 assertion 組合せの直交カバレッジ):
#   - Step 0 完全削除の主たる検出は TC-1.1 (`**VERY FIRST tool call**` markdown bold pin) が
#     担う — Step 0 prose 限定で出現する markdown bold token のため
#   - TC-1.3a (`### Mandatory After Interview` Markdown level-3 heading) と TC-1.3b (`phase "create_post_interview"`)
#     は補完的 assertion: section anchor + bash literal 形式の存在保証として機能する
#     (TC-1.3b の `phase "create_post_interview"` パターンは Step 1 の同 phase 名 patch にも
#     hit するため、TC-1.3b 単独では Step 0 削除を確実に検出できない設計)
#   - 3 assertion を組合せることで、bold prose 削除 / section heading 削除 / bash literal
#     形式変更 の各 regression に対する直交カバレッジを実現
assert_grep "TC-1.3a: create.md に '### .*Mandatory After Interview' Markdown level-3 heading が存在 (Step 0 が属するセクション anchor、table row や prose mention で誤 match しない)" \
  "$CREATE_MD" \
  '^### .*Mandatory After Interview'

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

# TC-3.1〜TC-3.4: caller continuation HTML literal の各 keyword は **行頭 `<!-- continuation:` から始まる
# 独立行のみ** に対して pin する。anchor `^` を含めない場合、rationale prose 内で backtick で
# wrap された literal (例: ingest.md `Caller-side coupling` 段落) も match してしまい、
# 実 canonical literal 行を削除しても test が誤って pass する false-negative 経路が成立する。
# 行頭 `^<!-- continuation:` を強制することで「独立行として存在する HTML comment そのもの」を
# 直接 pin する。

# TC-3.1: caller continuation HTML literal に 'MUST execute' + 'Step 0 bash literal'
assert_grep "TC-3.1: ingest.md caller continuation HTML literal に 'MUST execute' + 'Step 0 bash literal' keyword 群" \
  "$INGEST_MD" \
  '^<!-- continuation:.*caller MUST execute its.*Step 0 bash literal'

# TC-3.2: caller continuation HTML literal 1 行内に 'VERY FIRST tool call BEFORE any text output'
assert_grep "TC-3.2: ingest.md caller continuation HTML literal 1 行内に 'VERY FIRST tool call BEFORE any text output' keyword" \
  "$INGEST_MD" \
  '^<!-- continuation:.*VERY FIRST tool call BEFORE any text output'

# TC-3.3 / TC-3.4: 否定形重ねがけ (DO NOT end the turn / DO NOT output any narrative text)
# 両 keyword が caller continuation HTML literal 同一行内に出現することを別個に pin。
assert_grep "TC-3.3: ingest.md caller continuation HTML literal 1 行内に 'DO NOT end the turn' keyword" \
  "$INGEST_MD" \
  '^<!-- continuation:.*DO NOT end the turn'
assert_grep "TC-3.4: ingest.md caller continuation HTML literal 1 行内に 'DO NOT output any narrative text' keyword" \
  "$INGEST_MD" \
  '^<!-- continuation:.*DO NOT output any narrative text'

echo
echo "=== TC-4: Cross-orchestrator imperative keyword count (per-file 最低数) ==="

# TC-4.x は per-file の minimum を pin する形で「各 site が imperative 強度を保持している」
# ことを構造的に検証する。file 横断合計の閾値だと 1 file の imperative 強度が完全消失しても
# 他 file で hit 数が増えれば pass する false-negative 経路があるため per-file 閾値を採用する。
# create.md の閾値を `>= 3` にしているのも、Mandatory After Delegation site のみ単独 weakening
# した場合の `>= 2` fallthrough を防ぐため。
#
# 期待値の根拠 (現在の実測):
#   - create.md   : >= 3  (Mandatory After Interview prose + Step 0 prose + Mandatory After Delegation prose)
#                  (注: Mandatory After Delegation prose の line は `**VERY FIRST tool call (cognitive action)**`
#                       形式で literal が異なる。Self-check 自体が cognitive 判定行為のため canonical bash
#                       literal 経路と分離している意図。grep -cF 'VERY FIRST' は parenthetical 付きでも
#                       count 加算される)
#   - cleanup.md  : >= 1  (Mandatory After Wiki Ingest)
#   - ingest.md   : >= 1  (Phase 9.1 continuation HTML comment line)
# いずれかが下回れば即 fail。site 単位での弱化を確実に検出する。

# `grep -c ... || echo 0` idiom (注: || は logical OR) は 0 match 時に "0\n0" (length 3) を返す
# (grep -c が exit 1 + stdout `0` を返した上に `|| echo 0` が追加で 0 を append するため)。
# 後続の `[ "$count" -ge N ]` が `[: 0\n0: integer expression expected` で stderr error を吐き
# fall-through する診断ノイズが発生する。`if cmd; then :; else N=0` 形式を採用し、grep の
# exit code を独立して捕捉して fallback も明示的に integer 0 にする。
# precondition guard (file 存在 hard error 経路) で file 存在は保証済みのため、
# grep 失敗の経路は実質 IO error のみ。
if count_create=$(grep -cF 'VERY FIRST' "$CREATE_MD" 2>/dev/null); then :; else count_create=0; fi
if count_cleanup=$(grep -cF 'VERY FIRST' "$CLEANUP_MD" 2>/dev/null); then :; else count_cleanup=0; fi
if count_ingest=$(grep -cF 'VERY FIRST' "$INGEST_MD" 2>/dev/null); then :; else count_ingest=0; fi

if [ "$count_create" -ge 3 ]; then
  pass "TC-4.1: create.md に 'VERY FIRST' keyword が 3 ヶ所以上 (実測=$count_create, 期待>=3)"
else
  fail "TC-4.1: create.md に 'VERY FIRST' keyword が 3 ヶ所未満 (実測=$count_create, 期待>=3 — Mandatory After Interview / Step 0 / Mandatory After Delegation の 3 prose site で必要)"
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

# INTERVIEW_MD は precondition guard ループ (本ファイル冒頭の file 存在 hard error)
# で存在保証済。本セクション内では if-guard を持たず、silent skip による regression 見逃しを排除する。

# TC-5.1: '自動継続します' (現状報告) が create-interview.md に残っていない
# (S2 で 「MUST continue」へ recast 済み)
assert_not_grep "TC-5.1: create-interview.md に旧 '⏭ 継続中:.*自動継続します' 文言が残っていない" \
  "$INTERVIEW_MD" \
  '⏭ 継続中:.*自動継続します'

# TC-5.2 — caller HTML literal 内の weak phrasing revert 検出。
# canonical phrasing は `MUST execute as VERY FIRST tool call BEFORE any text output` であり、
# `IMMEDIATELY run this as your next tool call` のような weak phrasing が caller HTML literal 内に
# 再出現すると imperative 強度が弱まる経路となるため、anti-pattern として明示的に block する。
assert_not_grep "TC-5.2: create-interview.md caller HTML literal に旧 'IMMEDIATELY run this as your next tool call' 文言が残っていない" \
  "$INTERVIEW_MD" \
  'IMMEDIATELY run this as your next tool call'

# TC-5.3 / TC-5.4 — caller HTML literal 内の **positive imperative keyword** pin。
# create-interview.md の 2 ブロック (skipped/completed) で caller HTML literal が **両ブロック同時に**
# weak-phrasing (例: `Please run as soon as possible: ...`) に差し替えられる regression を検出する。
#
# Coverage matrix details: see Purpose section at the top of this file.
#
# 注意: TC-5.3/5.4 は `grep -qE` で **少なくとも 1 行 match** すれば pass するため、片方の
# ブロックだけを weak-phrasing 化した asymmetric drift は本 TC では catch できない。これは設計通りで、
# asymmetric drift は caller-html-literal-symmetry.test.sh の byte equality assertion が catch する。
assert_grep "TC-5.3: create-interview.md caller HTML literal 1 行内に 'VERY FIRST tool call BEFORE any text output' keyword" \
  "$INTERVIEW_MD" \
  '^<!-- caller:.*VERY FIRST tool call BEFORE any text output'

assert_grep "TC-5.4: create-interview.md caller HTML literal 1 行内に 'DO NOT end the turn' keyword" \
  "$INTERVIEW_MD" \
  '^<!-- caller:.*DO NOT end the turn'

# TC-5.5: Layer 3b (sub-skill plain-text reminder) imperative 強度 pin。
# create-interview.md の `> ⏭ MUST continue (turn を閉じない):` plain-text reminder は CHANGELOG で
# 「load-bearing 設計の Layer 3b」と明記されているため、TC-5.1 (anti-pattern) だけでなく positive
# presence でも pin する。reverter が `継続中` (without `自動継続します` suffix) や別 weak-phrasing
# に reset した場合でも本 positive pin で確実に検出する。
# 行頭 anchor (`^> ⏭ MUST continue \(turn を閉じない\):`) を含めることで、rationale prose 内の
# backtick で wrap された literal で誤 match する false-negative 経路を遮断する。
assert_grep "TC-5.5: create-interview.md plain-text reminder blockquote 行に '⏭ MUST continue (turn を閉じない):' が存在 (Layer 3b imperative 強度 pin)" \
  "$INTERVIEW_MD" \
  '^> ⏭ MUST continue \(turn を閉じない\):'

DRIFT_HINT="\
This test pins imperative keyword presence (Issue #910 mitigation) across
4 cross-orchestrator grep targets (create.md ×2, cleanup.md, ingest.md) +
3 supplementary pin types in create-interview.md (5 assertions total):
  (e1) caller HTML literal positive pins (TC-5.3/5.4) — 2 keyword pin
  (e2) caller HTML literal anti-pattern revert (TC-5.1/5.2) — 旧文言 (継続中.../IMMEDIATELY) の再出現を block
  (e3) plain-text reminder Layer 3b (TC-5.5) — '⏭ MUST continue (turn を閉じない):' blockquote 行を pin
If you weakened the imperative strength (e.g., reverted MUST → IMMEDIATELY,
removed 'VERY FIRST', or restored '継続中' status reporting), restore the
original strength.

Reference: skills/rite-workflow/references/sub-skill-return-protocol.md
\"3 layer canonical signaling pattern\" blockquote.
"

if ! print_summary "step0-immediate-bash-presence.test" "$DRIFT_HINT"; then
  exit 1
fi
