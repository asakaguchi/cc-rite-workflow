#!/bin/bash
# step0-immediate-bash-presence.test.sh
#
# Cross-orchestrator regression test for Issue #910 / #917 — orchestrator return-block
# 直後の implicit stop regression。
#
# Background:
#   stop-guard.sh 撤去 (#674/#675) 以降、prompt-side defense のみが残り、LLM の
#   turn-boundary heuristic 起因の implicit stop が `Sautéed for 7m 40s` 等として
#   実測されている。Issue #910 は caller-side Step 0 Immediate Bash literal の
#   imperative 強度を強化することで mitigation を図る対策。Issue #917 で 5 番目の
#   canonical site (commands/wiki/ingest.md Mandatory After Auto-Lint Step 0 prose)
#   を 4 site → 5 site 対称化に拡張。
#
# Purpose:
#   主たる 5 cross-orchestrator grep target + 補完的な 3 supplementary pin types
#   (caller HTML literal positive 2 + anti-pattern revert 2 + plain-text reminder 1
#   = 計 5 supplementary assertion) で以下を grep verify する。imperative keyword の
#   適用範囲は site (= layer) ごとに異なることに注意:
#
#   1. Step 0 Immediate Bash literal の section anchor + bash 行が存在
#      — orchestrator prose 層 3 site に適用 (TC-1.3 create.md / TC-2.3 cleanup.md / TC-3.5/3.6 ingest.md)
#   2. positive imperative keyword: `MUST execute` / `VERY FIRST` / `BEFORE any text output`
#      — 5 site で計 7 assertion (TC-1.1/1.2 = create.md, TC-2.1/2.2 = cleanup.md, TC-3.2 = ingest.md
#        continuation HTML literal, TC-3.7 = ingest.md Mandatory After Auto-Lint Step 0 prose,
#        TC-5.3 = create-interview.md)
#        (粒度: site 数 = 5、assertion 数 = 7 — protocol-doc L98 の granularity-mixing prohibition と整合)
#   3. 否定形重ねがけ: `DO NOT end the turn` / `DO NOT output any narrative`
#      — HTML comment 層のみに 2 site で計 3 assertion (TC-3.3/3.4 = ingest.md continuation HTML literal,
#        TC-5.4 = create-interview.md caller HTML literal)
#        (粒度: site 数 = 2、assertion 数 = 3 — 同上 granularity-mixing prohibition と整合)
#      — orchestrator prose 層 (create.md / cleanup.md / ingest.md Mandatory After Auto-Lint Step 0 prose)
#        は positive imperative のみで否定形を持たない (sub-skill-return-protocol.md Defense-in-depth
#        layers table の Layer 1 row + Layer 3 row 共通の imperative 強度設計 — Layer 1 prose は
#        positive imperative のみ、Layer 3 HTML comment は positive + 否定形両方を載せる site-by-site
#        の phrasing 強度規定)
#
# 5 cross-orchestrator grep targets (主たる pin scope、Issue #917 で 4 → 5 に拡張):
#   (a) commands/issue/create.md       — Mandatory After Interview Step 0 (positive imperative のみ)
#   (b) commands/issue/create.md       — Mandatory After Delegation pre-section prose (positive imperative のみ)
#   (c) commands/pr/cleanup.md         — Mandatory After Wiki Ingest Step 0 (positive imperative のみ)
#   (d) commands/wiki/ingest.md        — Phase 9.1 caller continuation HTML comment (positive + 否定形両方)
#   (e) commands/wiki/ingest.md        — Mandatory After Auto-Lint Step 0 prose (positive imperative のみ、
#                                        Issue #917 で追加。cleanup.md Step 0 と byte-equal 相当の二重 patch
#                                        構造で対称化、`Step 0: Immediate Bash Action` 名称 + Markdown bold
#                                        `**VERY FIRST tool call**` で TC-3.7 が直接 pin する)
#
#   Note (粒度の使い分け): create.md は **2 セクション anchor** (Mandatory After Interview / Mandatory
#   After Delegation) として `×2` と数える上記 4 grep target だが、TC-4.1 の `count >= 3` は
#   `VERY FIRST` keyword の **行カウント** (`grep -cF` の戻り値、= prose 3 site: Mandatory After Interview
#   prose / Step 0 prose / Mandatory After Delegation prose) を pin する。両者は粒度が異なる
#   ("section anchor 数" vs "keyword 出現行数") ことに注意。
#   注: `grep -cF` はマッチ行数を返すため、Mandatory After Delegation prose 行のように同一行に複数
#   occurrence がある場合でも count に 1 加算される。token 数 ("VERY FIRST" の出現回数) ではなく行数。
#   注 (cycle 8 CQ LOW 02 — line-number rot 回避): 本 test 内の prose reference は **構造名**
#   (Mandatory After Interview prose / Step 0 prose / Mandatory After Delegation prose) で行う。実
#   line number (例: 203/209/306) は create.md 上部に行追加があると即 silent rot するため意図的に
#   保持しない。drift 判定は構造名 anchor の存在 (`^### .*Mandatory After Interview` 等) と grep keyword の
#   `count >= N` で行う orthogonal 設計。
#
# 3 supplementary pin types (補完 pin scope、計 5 assertion):
#   Intentional ordering convention (cycle 8 test info 02): e1 → e2 → e3 で「positive pin → anti-pattern
#   revert → plain-text Layer 3b」の意味グループ順に並べる。本順序は TC-5 内の assertion 番号順序
#   (TC-5.1 → 5.5) とはずれており (TC-5.1/5.2=anti-pattern revert, TC-5.3/5.4=positive pin,
#   TC-5.5=plain-text reminder)、e1/e2/e3 は意味グループ順、TC-5.1〜5.5 は assertion 実行順 (anti-pattern
#   check を先に走らせて positive pin を後に置く設計) で各々独立に並べてある。混同しないこと。
#
#   (e1) commands/issue/create-interview.md caller HTML literal positive — TC-5.3/5.4 で 2 keyword pin
#        (byte equality は caller-html-literal-symmetry.test.sh が pin。本 test は imperative
#         keyword presence pin で「両ブロック同時 weak-phrasing 差し替え」regression を補完検出)
#   (e2) commands/issue/create-interview.md anti-pattern revert — 2 site に分解 (cycle 8 TW LOW 03):
#        (e2-a) plain-text reminder content — TC-5.1 で旧 `⏭ 継続中:.*自動継続します` 文言の再出現を block
#               (target = plain-text Markdown blockquote 行内容)
#        (e2-b) caller HTML literal content — TC-5.2 で旧 `IMMEDIATELY run this as your next tool call`
#               文言の再出現を block (target = caller HTML literal 1 行内文字列)
#   (e3) commands/issue/create-interview.md plain-text reminder Layer 3b — TC-5.5 で
#        `^> ⏭ MUST continue (turn を閉じない):` blockquote 行を pin (caller HTML literal とは別 site)
#
# Future enhancement notes (cycle 8 test reviewer info 01/03; cycle 9 LOW 03 で permanence rationale 明示):
#   - 本 inline notes は **proactive Issue 化を予定しない**。新たな implicit-stop regression が dogfooding
#     で観測された時点で reactive に Issue 化を判断する design (cycle 9 CQ LOW 03 への対応として明示)。
#   - TC-1.4 (cognitive-action 直接 weakening 独立 pin、test info 01): Mandatory After Delegation
#     pre-section prose の `**VERY FIRST cognitive action**` 単独 phrasing 弱化を直接 pin する独立
#     assertion の追加余地。現在は TC-4.1 count >= 3 で間接 catch されるのみ (cycle 7 F-07 推奨対応 (b))。
#     blocker ではないため reactive 判断 (regression 観測時に file)。
#   - TC-1.3b の Step 0 specific 拡張 (test info 03): 現状 `phase "create_post_interview"` は Step 0 と
#     Step 1 両方に match するため Step 0 単独削除を直接特定できない。TC-1.1 が確実に catch する
#     orthogonal 設計のため現状で sufficient。将来 Step 0 specific pin が必要 (例: TC-1.1 が誤って
#     pass する状況が発覚) なら `--phase "create_post_interview" --active true` の Step 0 引数組合せ
#     pattern を要求する形に拡張可能。blocker ではないため reactive 判断 (regression 観測時に file)。
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

# TC-1.1: VERY FIRST tool call keyword presence (Mandatory After Interview Step 0 prose)
# uppercase 形式のみ pin する。canonical phrasing (sub-skill-return-protocol.md
# 「3 layer canonical signaling pattern」blockquote の共通 keyword) が uppercase で固定されているため、
# lowercase phrasing は drift の兆候として fail させる意図。
#
# regex は `\*\*VERY FIRST tool call\*\*` のみ pin する (旧 alternation の第 2 branch
# `\*\*VERY FIRST tool call \(cognitive action\)\*\*` は dead code として削除済み、cycle 7 F-07 対応)。
# 削除理由: create.md の Mandatory After Delegation pre-section prose は long bold
# `**MUST proceed to Self-check as your VERY FIRST cognitive action BEFORE ... narrative**` 形式で、
# 第 2 branch の syntactic shape (`**VERY FIRST tool call (cognitive action)**`) には一致しないため
# 永続的に dead。
# TC-1.1 が pin する scope: Step 0 prose 内 `**VERY FIRST tool call**` Markdown bold (Mandatory After
# Delegation の rationale section にある backtick literal `**VERY FIRST tool call** = bash literal 実行` にも
# match するが、後者は説明文脈であり TC-1.1 の主目的は Step 0 prose 強度 pin)。Mandatory After Delegation
# prose の Markdown bold (`**...VERY FIRST cognitive action...**`) は本 TC-1.1 では直接 pin できず TC-4.1 の
# per-file count >= 3 で間接 catch される (cognitive action variant を直接 pin する独立 assertion は今後の
# 拡張で検討、cycle 7 F-07 推奨対応 (b)、cycle 8 test info 01 で再確認)。
assert_grep "TC-1.1: create.md に uppercase '**VERY FIRST tool call**' keyword が存在 (Step 0 prose canonical phrasing pin)" \
  "$CREATE_MD" \
  '\*\*VERY FIRST tool call\*\*'

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

# TC-3.5 / TC-3.6 / TC-3.7: ingest.md Mandatory After Auto-Lint Step 0 prose (Issue #917 — 5 番目の canonical site)
# Pre-#917 baseline では本 site は意図的に canonical phrasing 適用対象外として残置されていたが、
# PR #916 マージ直後の実機実行で Mandatory After Auto-Lint Step 0 が未発火で implicit stop する事象を
# 直接観測 (累積 27 回目)。Issue #917 D-01 で 5 site 対称化を判定し、本 TC で grep pin する。
#
# 設計意図 (3 assertion 組合せの直交カバレッジ):
#   - TC-3.5: '### .*Mandatory After Auto-Lint' Markdown level-3 heading anchor (section 削除を確実に検出)
#   - TC-3.6: 'phase "ingest_post_lint"' bash literal が 2 回出現 (Step 0 + Step 1 idempotent 二重 patch
#             構造を pin、Step 0 削除時 count が 1 に減って fail)
#   - TC-3.7: '**VERY FIRST tool call**' Markdown bold (Step 0 prose 限定で出現する canonical phrasing pin、
#             cleanup.md Step 0 prose と同型の imperative 強度を保証)

# TC-3.5: Mandatory After Auto-Lint section heading anchor
assert_grep "TC-3.5: ingest.md に '### .*Mandatory After Auto-Lint' Markdown level-3 heading が存在 (Step 0 が属するセクション anchor)" \
  "$INGEST_MD" \
  '^### .*Mandatory After Auto-Lint'

# TC-3.6: Step 0 + Step 1 二重 patch 構造の保証 (count >= 2)
# `grep -c ... || echo 0` idiom の落とし穴を回避するため、TC-4 と同じ
# `if cmd; then :; else N=0` 形式を採用 (該当 idiom の rationale は TC-4 セクション参照)。
if count_ingest_phase=$(grep -cE 'phase[[:space:]]+"ingest_post_lint"' "$INGEST_MD" 2>/dev/null); then :; else count_ingest_phase=0; fi
if [ "$count_ingest_phase" -ge 2 ]; then
  pass "TC-3.6: ingest.md Mandatory After Auto-Lint に 'phase \"ingest_post_lint\"' bash literal が 2 回以上 (実測=$count_ingest_phase, 期待>=2 — Step 0 + Step 1 idempotent 二重 patch 構造、cleanup.md Step 0/1 と byte-equal 相当の対称設計)"
else
  fail "TC-3.6: ingest.md Mandatory After Auto-Lint に 'phase \"ingest_post_lint\"' bash literal が 2 回未満 (実測=$count_ingest_phase, 期待>=2 — Step 0 が削除された可能性。Issue #917 で確立した cleanup.md Step 0/1 と byte-equal 相当の二重 patch 構造を維持すること)"
fi

# TC-3.7: Step 0 prose 内の canonical Markdown bold pin
# Mandatory After Auto-Lint Step 0 prose 限定で出現する `**VERY FIRST tool call**` (Markdown bold) を
# pin する。continuation HTML comment / Caller-side coupling rationale prose では bold なし `VERY FIRST tool call`
# 形式のため、bold 形式の存在で Mandatory After Auto-Lint Step 0 prose 強度を直接 pin できる
# (TC-3.2 の continuation HTML comment 内 `VERY FIRST tool call BEFORE any text output` とは
# 直交した assertion)。
assert_grep "TC-3.7: ingest.md に uppercase '**VERY FIRST tool call**' Markdown bold が存在 (Mandatory After Auto-Lint Step 0 prose canonical phrasing pin、Issue #917 で追加された 5th canonical site)" \
  "$INGEST_MD" \
  '\*\*VERY FIRST tool call\*\*'

echo
echo "=== TC-4: Cross-orchestrator imperative keyword count (per-file 最低数) ==="

# TC-4.x は per-file の minimum を pin する形で「各 site が imperative 強度を保持している」
# ことを構造的に検証する。file 横断合計の閾値だと 1 file の imperative 強度が完全消失しても
# 他 file で hit 数が増えれば pass する false-negative 経路があるため per-file 閾値を採用する。
# create.md の閾値を `>= 3` にしているのも、Mandatory After Delegation site のみ単独 weakening
# した場合の `>= 2` fallthrough を防ぐため。
#
# 期待値の根拠 (現在の実測、grep -cF はマッチ行数を返す):
#   - create.md   : >= 3  (Mandatory After Interview prose + Step 0 prose +
#                          Mandatory After Delegation prose / rationale prose の 3 prose site)
#                  (注: Mandatory After Delegation prose は `**VERY FIRST cognitive action**`
#                       形式 (`tool call` を含まない) を採用。Self-check 自体が cognitive 判定行為のため
#                       canonical bash literal 経路 (`**VERY FIRST tool call**`) と分離している意図。
#                       `grep -cF 'VERY FIRST'` は **行数** をカウントするため、Mandatory After Delegation
#                       prose の同一行に複数の `VERY FIRST` occurrence (`cognitive action` + canonical scheme
#                       rationale 内の `tool call`) があっても count に 1 のみ加算される。token 数ではなく行数。)
#                  (cycle 8 CQ LOW 02: 元々 `line 203 / line 209 / line 306` の line number 参照を
#                   持っていたが、create.md 上部に行追加があると即 silent rot するため意図的に構造名のみに
#                   変更。drift 判定は構造名 anchor の存在 (`^### .*Mandatory After Interview` 等)
#                   と grep keyword の `count >= N` で orthogonal に行う。)
#   - cleanup.md  : >= 1  (Mandatory After Wiki Ingest)
#   - ingest.md   : >= 2  (Mandatory After Auto-Lint Step 0 prose [Issue #917、5th canonical site] +
#                          Phase 9.1 caller continuation HTML comment、計 2 canonical site。
#                          rationale/description prose の `VERY FIRST` 言及 [line ~935 Caller-side coupling /
#                          line ~1158 Imperative 強度 rationale] は load-bearing でないため計数に含めない。)
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

if [ "$count_ingest" -ge 2 ]; then
  pass "TC-4.3: ingest.md に 'VERY FIRST' keyword が 2 ヶ所以上 (実測=$count_ingest, 期待>=2 — Mandatory After Auto-Lint Step 0 prose [Issue #917] + caller continuation HTML literal の 2 canonical site)"
else
  fail "TC-4.3: ingest.md に 'VERY FIRST' keyword が 2 ヶ所未満 (実測=$count_ingest, 期待>=2 — Issue #917 で 5th canonical site (Mandatory After Auto-Lint Step 0 prose) を追加。Step 0 prose の '**VERY FIRST tool call**' か Phase 9.1 continuation HTML comment の 'VERY FIRST tool call' が削除された可能性)"
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
This test pins imperative keyword presence (Issue #910 / #917 mitigation) across
5 cross-orchestrator grep targets (create.md ×2, cleanup.md, ingest.md ×2 —
continuation HTML comment + Mandatory After Auto-Lint Step 0 prose, Issue #917 で
4 → 5 に拡張) + 3 supplementary pin types in create-interview.md (5 assertions total):
  (e1) caller HTML literal positive pins (TC-5.3/5.4) — 2 keyword pin
  (e2) anti-pattern revert — 2 site に分解 (cycle 8 TW LOW 03):
       (e2-a) plain-text reminder content (TC-5.1) — 旧 '⏭ 継続中:.*自動継続します' 文言の再出現を block
       (e2-b) caller HTML literal content (TC-5.2) — 旧 'IMMEDIATELY run this as your next tool call' 文言の再出現を block
  (e3) plain-text reminder Layer 3b (TC-5.5) — '⏭ MUST continue (turn を閉じない):' blockquote 行を pin
If you weakened the imperative strength (e.g., reverted MUST → IMMEDIATELY,
removed 'VERY FIRST', restored '継続中' status reporting in lint.md Phase 9.2,
or removed Step 0 from ingest.md Mandatory After Auto-Lint), restore the
original strength.

Reference: skills/rite-workflow/references/sub-skill-return-protocol.md
\"3 layer canonical signaling pattern\" blockquote and \"Issue #910 / #917 imperative
strengthening coverage (Layer 1 + Layer 3, 5 site canonical)\" Scope note.
"

if ! print_summary "step0-immediate-bash-presence.test" "$DRIFT_HINT"; then
  exit 1
fi
