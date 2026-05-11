#!/bin/bash
# parent-routing-pattern-interim.test.sh
#
# ⚠️ DELETION CHECKLIST (削除忘れ防止):
#   本テストは parent-routing-unification ADR (docs/designs/parent-routing-unification.md) PR-7 で
#   `parent-routing-pattern-uniformity.test.sh` が新設されるタイミングで **本ファイル全体を削除する** こと。
#   PR-7 で各 sub-skill が parent-routing pattern canonical form に統一されるため、本 interim test の
#   pin 対象 (create-interview.md のみの interim 形態) は uniformity test の subset として吸収される。
#   PR-7 マージ時のチェックリスト:
#     1. plugins/rite/hooks/tests/parent-routing-pattern-interim.test.sh を削除
#     2. plugins/rite/hooks/tests/run-tests.sh (テストランナーが個別 list する形式に変わった場合は同等の場所) から該当行を削除
#     3. ADR §6.1 / sub-skill-return-protocol.md 廃止済 invariant test list に本ファイル名を追記
#     4. PR-7 統合計画 task list (ADR §6.1 PR-7 引き継ぎ箇所) の各 IMP-2 / IMP-3 / IMP-4 / IMP-5 / TQ-4 を確認
#
# Interim invariant test for the parent-routing pattern migration.
# 移行ロードマップ・統合計画は ADR docs/designs/parent-routing-unification.md 参照。
#
# Pinned invariants:
#   TC-1  create-interview.md Pre-flight + Return Output re-patch の存在 + cold-start 二段書き込み sequence
#   TC-2  create-interview.md は bare bracket sentinel のみ (HTML-comment form / caller HTML hint なし)
#   TC-3  cleanup.md Mandatory After Wiki Ingest Step 0 の imperative keyword + bash literal + anchor
#   TC-4  ingest.md Mandatory After Auto-Lint Step 0 + continuation HTML literal の imperative keyword 群
#   TC-5  lint.md Phase 9.2 三点セット blockquote の imperative recast を 3 canonical sites で pin
#   TC-6  workflow-incident-emit invocation count + WARNING fallback + 8 retained flag 名 + create.md prose
#   TC-7  caller-side [interview:error] halt rule presence (create.md / pre-check-routing.md)
#         + 4 sentinel literal の dispatcher grep target pin
#
# When this test fails: parent-routing pattern compliance または imperative keyword 強度の regression。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

INTERVIEW_MD="$REPO_ROOT/plugins/rite/commands/issue/create-interview.md"
CLEANUP_MD="$REPO_ROOT/plugins/rite/commands/pr/cleanup.md"
INGEST_MD="$REPO_ROOT/plugins/rite/commands/wiki/ingest.md"
LINT_MD="$REPO_ROOT/plugins/rite/commands/wiki/lint.md"

# Hard precondition — missing target files are an environment error, not a test failure.
for f in "$INTERVIEW_MD" "$CLEANUP_MD" "$INGEST_MD" "$LINT_MD"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

echo "=== TC-1: create-interview.md Pre-flight + Return Output re-patch の存在 ==="

# Pre-flight (head) と Return Output re-patch (tail) の 2 site で
# `flow-state-update.sh patch ... --phase "create_post_interview"` が出現することを pin。
# 実測 3 回 (Pre-flight if branch / Pre-flight cold-start elif / Return Output re-patch) のため
# `>= 3` で厳格化し、いずれか 1 site の silent removal も catch する。
# if/else 形式採用の意図: grep の rc=2 (IO エラー) と rc=1 (no match) を区別し、IO エラーを silent
# count=0 に倒さないこと (本テスト全体の defensive pattern との対称化)。
#
# Known limitation: hardcoded `>= 3` は将来の正当な refactor
# (例: Pre-flight 3 重 patch 化) で false positive を出さない代わりに、「期待回数が増えたのに気づかず
# >= N で甘く pass する」silent drift を許す。Pre-flight が scope conditional 内に移動した場合
# (Bug Fix/Chore skip path で skip される regression) も count 3 を維持するため検出不可。
# 将来 issue として：(a) `--phase "create_post_interview"` 別 count で directional check に分解する、
# (b) Pre-flight section heading の前提条件 prose ("interview scope に関係なく / scope=skip でも実行") を pin する
# などの defense-in-depth を追加することを検討。
#
# Known limitation 2: 各 grep の `2>/dev/null` 経路で
# ファイル不在 / permission denied などの IO エラーが silent に count=0 になりうる。L32-37 の
# precondition check で `INTERVIEW_MD` 等の存在を確認しているため通常 race は発生しないが、
# precondition check と各 TC の grep の間で TOCTOU race / mtime-based cleanup でファイルが
# 消える経路は理論上残る。PR-7 uniformity test で完全機械検証化する際は `grep ... | wc -l` への
# 切替か independent stderr capture で IO エラー検出を入れる。
if interview_patch_count=$(grep -cE 'flow-state-update\.sh patch' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_patch_count=0; fi
if [ "$interview_patch_count" -ge 3 ]; then
  pass "TC-1: create-interview.md に 'flow-state-update.sh patch' が 3 回以上 (実測=$interview_patch_count, Pre-flight if + Pre-flight cold-start elif + Return Output re-patch)"
else
  fail "TC-1: create-interview.md の 'flow-state-update.sh patch' 出現回数が 3 未満 (実測=$interview_patch_count, 期待>=3 — Pre-flight (if/elif) または Return Output re-patch のいずれかが削除された可能性)"
fi

# create_post_interview phase が patch arg として現れることを pin
assert_grep "TC-1b: create-interview.md に '--phase \"create_post_interview\"' が存在" \
  "$INTERVIEW_MD" \
  'phase[[:space:]]+"create_post_interview"'

# TC-1c: cold-start 二段書き込み (create→patch) sequence の pin。
# parent-routing pattern の load-bearing audit-trail fidelity 機能の regression を
# mechanical に検出する。単段 `create --phase create_post_interview` への退化が起きた場合、
# (a) `create --phase "create_interview"` が消失する OR (b) cold-start branch 自体が消失するため fail する。
# 注: bash backslash 続行 (`create \` の次行に `--phase ...`) のため `grep -A 1` で multiline match。
#
# Known limitation: `grep -A 1` 隣接 pin は **cold-start branch 内**
# であることを構造的に保証していない (`else` 節外に独立に `create --phase create_interview` が出現
# しても pass する)。完全保証には awk で `else` ブロック範囲を切り出してから検査するか、
# `grep -B 2 'create_interview"' | grep 'else'` の隣接を pin する必要があるが、保守コストが上がる
# ため現状の隣接 pin で許容。cold-start branch 全体の reorganization で sequence が崩れた silent revert
# は捕捉できないリスクあり。
if grep -A 1 'flow-state-update\.sh create' "$INTERVIEW_MD" | grep -qE '\-\-phase "create_interview"[^_]'; then
  pass "TC-1c-1: create-interview.md cold-start branch に 'create + --phase \"create_interview\"' の sequence が存在 (audit-trail fidelity)"
else
  fail "TC-1c-1: create-interview.md cold-start branch の 'create + --phase \"create_interview\"' sequence が消失 (単段 create --phase create_post_interview への退化、audit-trail fidelity 欠落)"
fi
# 二段書き込みの第 2 段 (create_post_interview への patch) は TC-1 で既に pin 済。

# TC-1d / TC-1e: per-section directional check
# TC-1 の `count >= 3` だけでは「Pre-flight if-branch を削除して Return Output re-patch を 2 重化」
# のような refactor mistake (count=3 維持) を catch できない silent drift を持つ。
# Pre-flight section と Return Output section の heading anchor をそれぞれ独立に pin することで、
# どちらの section が silent 削除されても fail する補完防御を追加する。
assert_grep "TC-1d: create-interview.md に Pre-flight section heading anchor が存在 (Pre-flight 削除の silent regression を catch)" \
  "$INTERVIEW_MD" \
  '^## 🚨 MANDATORY Pre-flight: Flow State Update'
assert_grep "TC-1e: create-interview.md に Defense-in-Depth (Return Output) section heading anchor が存在 (Return Output 削除の silent regression を catch)" \
  "$INTERVIEW_MD" \
  '^## Defense-in-Depth: Flow State Update \(Before Return\)'

echo
echo "=== TC-2: create-interview.md parent-routing pattern compliance ==="

# bare bracket form sentinel が result pattern bullet list として存在
assert_grep "TC-2a: create-interview.md に bare bracket '[interview:completed]' bullet" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview completed\*\*: `\[interview:completed\]`'
assert_grep "TC-2b: create-interview.md に bare bracket '[interview:skipped]' bullet (TC-2a と parallel に sentinel value も pin)" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview skipped\*\*.*: `\[interview:skipped\]`'

# TC-2e: catastrophic halt sentinel `[interview:error]` の bullet 存在を pin する。
# caller routing (create.md / pre-check-routing.md) が halt trigger として参照する load-bearing sentinel。
# silent revert で bullet が消えると catastrophic dual-failure 経路の halt が機能しなくなる。
assert_grep "TC-2e: create-interview.md に bare bracket '[interview:error]' bullet (catastrophic halt sentinel)" \
  "$INTERVIEW_MD" \
  '^- \*\*Halt with error\*\*.*: `\[interview:error\]`'

# TC-2e-1..TC-2e-4: halt 判定表 4 row の literal substring を独立に pin する。
# TC-2e は bullet 存在のみ、TC-6i は 4 retained flag echo のみで、表 row の AND 条件組合せが
# pin されていない silent regression を防ぐ (4 row のいずれかが silent 削除/組替された場合、
# Bug Fix/Chore preset の halt 判定が抜ける silent regression を直接 catch)。
assert_grep "TC-2e-1: create-interview.md halt 判定表 row 1 (PREFLIGHT_CREATE_FAILED 単独経路)" \
  "$INTERVIEW_MD" \
  '\| `PREFLIGHT_CREATE_FAILED=1` \|'
assert_grep "TC-2e-2: create-interview.md halt 判定表 row 2 (PREFLIGHT_PATCH_FAILED AND INTERVIEW_RETURN_PATCH_FAILED)" \
  "$INTERVIEW_MD" \
  '\| `PREFLIGHT_PATCH_FAILED=1` AND `INTERVIEW_RETURN_PATCH_FAILED=1` \|'
assert_grep "TC-2e-3: create-interview.md halt 判定表 row 3 (PREFLIGHT_CREATE_THEN_PATCH_FAILED AND INTERVIEW_RETURN_PATCH_FAILED)" \
  "$INTERVIEW_MD" \
  '\| `PREFLIGHT_CREATE_THEN_PATCH_FAILED=1` AND `INTERVIEW_RETURN_PATCH_FAILED=1` \|'
assert_grep "TC-2e-4: create-interview.md halt 判定表 row 4 (PREFLIGHT_CREATE_THEN_PATCH_FAILED AND skip path)" \
  "$INTERVIEW_MD" \
  '\| `PREFLIGHT_CREATE_THEN_PATCH_FAILED=1` AND skip path'

# TC-2f: Skip path での Defense-in-Depth re-patch 必須化 prose anchor の pin。
# Bug Fix / Chore preset (scope=skip) 経路で本 re-patch を省略すると
# PREFLIGHT_CREATE_THEN_PATCH_FAILED 単独経路で audit-trail が create_interview に停滞する
# silent regression を起こすため、prose anchor の silent weakening を mechanical に検出する。
assert_grep "TC-2f: create-interview.md に Skip path Defense-in-Depth 必須化 prose anchor が存在 (skip path / standard path / limited path / full path のいずれも実行する)" \
  "$INTERVIEW_MD" \
  'skip path / standard path / limited path / full path のいずれも実行する'

# TC-2g (negative): 旧 caller HTML literal 内で使われていた weak phrasing
# `IMMEDIATELY run this as your next tool call` が parent-routing 移行後の本ファイルに
# 書き戻されていないことを pin する (anti-pattern revert detection)。
assert_not_grep "TC-2g: create-interview.md に旧 'IMMEDIATELY run this as your next tool call' weak phrasing が残存しない (anti-pattern revert pin)" \
  "$INTERVIEW_MD" \
  'IMMEDIATELY run this as your next tool call'

# `--if-exists` flag の silent revert を catch する pin。
# parent-routing pattern で導入された file 不在時 silent skip guard (`flow-state-update.sh`
# の patch / increment mode 内 `IF_EXISTS && ! -f` 分岐) を defeat する revert (例: `--if-exists`
# を一括削除 / `--preserve-error-count` に書き換え) を検出する。実測 7 occurrences (CLI invocation 3 site +
# prose 言及 4 site)。最低 3 を要求して将来の正当な refactor (1 site のみ撤廃等) でも catch する。
if interview_if_exists_count=$(grep -cE '\-\-if-exists' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_if_exists_count=0; fi
if [ "$interview_if_exists_count" -ge 3 ]; then
  pass "TC-2h: create-interview.md に '--if-exists' flag が 3 個以上 (実測=$interview_if_exists_count, 同 phase self-patch の idempotent guard 維持)"
else
  fail "TC-2h: create-interview.md の '--if-exists' flag が 3 個未満 (実測=$interview_if_exists_count, 期待>=3 — Pre-flight patch 2 + Return Output 1 のいずれかが silent 削除された可能性、file 不在時 silent skip guard が defeat される)"
fi

# HTML-comment form sentinel が bash fenced block 外で出現しないこと
# (rationale prose や migration note 内で history 言及することはあるが、
#  bullet list の result pattern が HTML-comment 形式に戻ったら fail させる)
if grep -qE '^- \*\*Interview .*: `<!-- *\[interview:' "$INTERVIEW_MD"; then
  fail "TC-2c: create-interview.md の result pattern bullet が HTML-comment form に reverted (parent-routing pattern violation)"
else
  pass "TC-2c: create-interview.md result pattern bullet は bare bracket form (parent-routing pattern compliant)"
fi

# TC-2d (negative): caller HTML hint `<!-- caller: -->` literal の partial revert を検出する
# (parent-routing pattern では caller-side hint が不要のため、本 site では絶対に出現してはならない)
assert_not_grep "TC-2d: create-interview.md に caller HTML hint '<!-- caller:' literal が存在しない (parent-routing pattern compliant)" \
  "$INTERVIEW_MD" \
  '^<!-- caller:'

echo
echo "=== TC-3: cleanup.md Mandatory After Wiki Ingest Step 0 imperative keyword ==="

# `VERY FIRST tool call` Markdown bold (Step 0 prose canonical phrasing pin)
assert_grep "TC-3a: cleanup.md に '**VERY FIRST tool call**' Markdown bold が存在" \
  "$CLEANUP_MD" \
  '\*\*VERY FIRST tool call\*\*'
assert_grep "TC-3b: cleanup.md に 'BEFORE any text output' keyword が存在" \
  "$CLEANUP_MD" \
  'BEFORE any text output'

# Step 0 / Step 1 二重 patch design が silently 削除されると prose だけ残った half-migration
# regression を引き起こすため、bash literal の存在 + 個数で structure を pin する。
assert_grep "TC-3c: cleanup.md Step 0 bash literal 'phase \"cleanup_post_ingest\" --active' が存在" \
  "$CLEANUP_MD" \
  'phase[[:space:]]+"cleanup_post_ingest"[[:space:]]+--active'
if cleanup_post_ingest_count=$(grep -cE 'phase[[:space:]]+"cleanup_post_ingest"' "$CLEANUP_MD" 2>/dev/null); then :; else cleanup_post_ingest_count=0; fi
if [ "$cleanup_post_ingest_count" -ge 2 ]; then
  pass "TC-3d: cleanup.md に 'phase \"cleanup_post_ingest\"' bash literal が 2 回以上 (実測=$cleanup_post_ingest_count, Step 0 + Step 1 idempotent 二重 patch)"
else
  fail "TC-3d: cleanup.md の 'phase \"cleanup_post_ingest\"' bash literal が 2 未満 (実測=$cleanup_post_ingest_count, Step 0 or Step 1 が silently 削除された可能性)"
fi
assert_grep "TC-3e: cleanup.md の section anchor '### .*Mandatory After Wiki Ingest' が存在" \
  "$CLEANUP_MD" \
  '^### .*Mandatory After Wiki Ingest'

echo
echo "=== TC-4: ingest.md Mandatory After Auto-Lint Step 0 imperative keyword + continuation HTML literal ==="

assert_grep "TC-4a: ingest.md に '**VERY FIRST tool call**' Markdown bold が存在" \
  "$INGEST_MD" \
  '\*\*VERY FIRST tool call\*\*'
assert_grep "TC-4b: ingest.md に 'BEFORE any text output' keyword が存在" \
  "$INGEST_MD" \
  'BEFORE any text output'

# Step 0/1 二重 patch 構造の存在を pin (count >= 2 で idempotent re-patch 機構の silent 削除を検出)。
if ingest_post_lint_count=$(grep -cE 'phase[[:space:]]+"ingest_post_lint"' "$INGEST_MD" 2>/dev/null); then :; else ingest_post_lint_count=0; fi
if [ "$ingest_post_lint_count" -ge 2 ]; then
  pass "TC-4c: ingest.md に 'phase \"ingest_post_lint\"' bash literal が 2 回以上 (実測=$ingest_post_lint_count, Step 0 + Step 1 idempotent 二重 patch)"
else
  fail "TC-4c: ingest.md の 'phase \"ingest_post_lint\"' bash literal が 2 未満 (実測=$ingest_post_lint_count, 二重 patch 機構が silently 削除された可能性)"
fi
assert_grep "TC-4d: ingest.md の section anchor '🚨 Mandatory After Auto-Lint' が存在" \
  "$INGEST_MD" \
  '🚨 Mandatory After Auto-Lint'

# continuation HTML literal の 4 imperative keyword を line-anchored regex で pin する。
# load-bearing な負方向 imperative (`DO NOT end the turn` / `DO NOT output any narrative text`) の
# silent weakening を検出する。
assert_grep "TC-4e: ingest.md continuation HTML literal に 'MUST execute' + 'Step 0 bash literal' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*MUST execute.*Step 0 bash literal'
assert_grep "TC-4f: ingest.md continuation HTML literal に 'VERY FIRST tool call BEFORE any text output' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*VERY FIRST tool call BEFORE any text output'
assert_grep "TC-4g: ingest.md continuation HTML literal に 'DO NOT end the turn' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*DO NOT end the turn'
assert_grep "TC-4h: ingest.md continuation HTML literal に 'DO NOT output any narrative text' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*DO NOT output any narrative text'

echo
echo "=== TC-5: lint.md Phase 9.2 Layer 3b imperative recast ==="

# `> ⏭ MUST continue (turn を閉じない):` blockquote を 3 canonical sites で pin
# (Phase 1.1 echo / Phase 1.3 echo / Phase 9.2 raw blockquote)。
# 部分削除を検出するため count >= 3 で厳格化 (count >= 1 だと 1-2 sites 削除が silent pass する)。
if lint_must_continue_count=$(grep -cE '^[[:space:]]*(echo ")?> ⏭ MUST continue \(turn を閉じない\):' "$LINT_MD" 2>/dev/null); then :; else lint_must_continue_count=0; fi
if [ "$lint_must_continue_count" -ge 3 ]; then
  pass "TC-5a: lint.md に Layer 3b imperative '⏭ MUST continue (turn を閉じない):' blockquote が 3 回以上 (実測=$lint_must_continue_count, 3 canonical sites: Phase 1.1 echo + Phase 1.3 echo + Phase 9.2 raw blockquote)"
else
  fail "TC-5a: lint.md の '⏭ MUST continue (turn を閉じない):' blockquote が 3 未満 (実測=$lint_must_continue_count, 期待>=3 — 3 canonical sites のうち 1-2 sites が silently 削除された可能性)"
fi

# 旧 `⏭ 継続中:` 現状報告 phrasing が残っていないこと (命令形に recast 済)
assert_not_grep "TC-5b: lint.md に旧 '⏭ 継続中:' 現状報告 phrasing が残っていない" \
  "$LINT_MD" \
  '⏭ 継続中:'

echo
echo "=== TC-6: workflow-incident-emit.sh が全 retained flag emit 経路と co-located + create.md Mandatory After Delegation imperative ==="

# TC-6a/b: 8 retained flag の helper invocation が同一ファイル内に co-located であることを
# pin する。grep -cE は helper invocation の行数 (bash backslash 続行のため 1 invocation = 1 行) を
# 返すため、件数は invocation 件数と一致する。flag 名そのものの存在は TC-6i で個別に pin する。
CREATE_MD="$REPO_ROOT/plugins/rite/commands/issue/create.md"

# C-2 対応: hint message を実測値に更新。
# 旧 hint は `Pre-flight 3 site + Return Output 1 site` / `Phase 1 Pre-write 2 site + Phase 3 Pre-write 2 site` だったが、
# 実コード上では Pre-flight 5 site (state-path-resolve / _resolve / patch / cold-start create / create-then-patch) +
# Return Output 1 site = 6 invocations、Phase 1 Pre-write 4 site (state-path-resolve / _resolve / patch / create) +
# Phase 3 Pre-write 4 site = 8 invocations。
# threshold (>=4 / >=4) は H-3 で create.md に site が増えた将来の安全性を考慮して維持。
if interview_emit_count=$(grep -cE '^[[:space:]]*bash .*workflow-incident-emit\.sh' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_emit_count=0; fi
if [ "$interview_emit_count" -ge 4 ]; then
  pass "TC-6a: create-interview.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$interview_emit_count invocations, Pre-flight 5 site (state-path-resolve / _resolve-flow-state-path / patch-failed / create-failed / create-then-patch-failed) + Return Output 1 site)"
else
  fail "TC-6a: create-interview.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$interview_emit_count invocations, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

if create_emit_count=$(grep -cE '^[[:space:]]*bash .*workflow-incident-emit\.sh' "$CREATE_MD" 2>/dev/null); then :; else create_emit_count=0; fi
if [ "$create_emit_count" -ge 4 ]; then
  pass "TC-6b: create.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$create_emit_count invocations, Phase 1 Pre-write 4 site (state-path-resolve + _resolve-flow-state-path + patch + create) + Phase 3 Pre-write 4 site)"
else
  fail "TC-6b: create.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$create_emit_count invocations, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

# fallback WARNING pattern: helper 失敗時に silent fall-through しないことを pin
if interview_warn_count=$(grep -cE 'WARNING: workflow-incident-emit\.sh failed' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_warn_count=0; fi
if [ "$interview_warn_count" -ge 4 ]; then
  pass "TC-6c: create-interview.md に 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回以上 (実測=$interview_warn_count, silent failure 防御 pattern)"
else
  fail "TC-6c: create-interview.md の 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回未満 (実測=$interview_warn_count, 期待>=4 — \`2>/dev/null || true\` silent failure pattern に reverted した可能性)"
fi

if create_warn_count=$(grep -cE 'WARNING: workflow-incident-emit\.sh failed' "$CREATE_MD" 2>/dev/null); then :; else create_warn_count=0; fi
if [ "$create_warn_count" -ge 4 ]; then
  pass "TC-6d: create.md に 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回以上 (実測=$create_warn_count, silent failure 防御 pattern)"
else
  fail "TC-6d: create.md の 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回未満 (実測=$create_warn_count, 期待>=4 — \`2>/dev/null || true\` silent failure pattern に reverted した可能性)"
fi

# M-7 対応: silent failure pattern の variation を網羅的に検出。
# 旧実装は `2>/dev/null || true` 単独しか catch しなかったが、`|| :` / `|| return 0` /
# `|| { true; }` 等の equivalent silent fallback variation を全て検出するよう ERE alternation を拡張。
_silent_failure_pattern='2>/dev/null[[:space:]]*\|\|[[:space:]]*(true|:|return[[:space:]]+0|\{[[:space:]]*true[[:space:]]*;?[[:space:]]*\})'

# anti-pattern revert detection: silent failure variation が workflow-incident-emit.sh と co-located で残っていないこと
# grep -B1 -A1 では 5+ 行に渡る invocation block の
# 中間行に挿入された `2>/dev/null` を catch できないため、-A 8 に拡大して invocation block 全体
# (backslash 続行 5-7 行 + || echo WARNING フォールバック行) を範囲に含める。
# 加えて comment lines (先頭 `#`) を pre-filter で除外することで、explainer comment 内の
# 旧パターン例示 (`# 旧 mkdir ... 2>/dev/null || true`) を偽陽性として hit させない。
# pipefail 下の false-positive pass を防ぐため、最初の grep の結果を独立変数に capture してから後段 pipeline を実行する。
# 旧実装 `if grep -B1 -A8 ... | grep -v | grep -qE ...; then` は workflow-incident-emit invocation 全削除
# (catastrophic regression) で最初の grep が rc=1 → pipefail で pipeline rc=1 → if 条件 false → else 経路で
# `pass` が呼ばれる false-positive を起こす (Bash Reference Manual の pipefail 仕様、set -e は `if` 文脈で
# trigger しない仕様 — POSIX Shell)。TC-6a/b の count >= 4 で副次的 catch あるが、本 TC 単独で見ると壊れて
# いた。先頭 grep の rc を明示的に区別することで catastrophic regression を fail に倒す。
_invocation_block_interview=$(grep -B1 -A8 'workflow-incident-emit\.sh' "$INTERVIEW_MD" 2>/dev/null || true)
if [ -z "$_invocation_block_interview" ]; then
  fail "TC-6e prerequisite: create-interview.md から workflow-incident-emit.sh invocation block が見つからない (catastrophic regression — TC-6a を先に確認してください)"
elif printf '%s\n' "$_invocation_block_interview" | grep -v '^[[:space:]]*#' | grep -qE "$_silent_failure_pattern"; then
  fail "TC-6e: create-interview.md で workflow-incident-emit.sh invocation block 内に silent failure pattern (|| true / || : / || return 0 / || { true; } のいずれか) が残存 (anti-pattern revert)"
else
  pass "TC-6e: create-interview.md で workflow-incident-emit.sh と silent failure pattern の co-location なし (invocation block 全体 8 行範囲 + comment 除外、silent failure 防御維持)"
fi

_invocation_block_create=$(grep -B1 -A8 'workflow-incident-emit\.sh' "$CREATE_MD" 2>/dev/null || true)
if [ -z "$_invocation_block_create" ]; then
  fail "TC-6f prerequisite: create.md から workflow-incident-emit.sh invocation block が見つからない (catastrophic regression — TC-6b を先に確認してください)"
elif printf '%s\n' "$_invocation_block_create" | grep -v '^[[:space:]]*#' | grep -qE "$_silent_failure_pattern"; then
  fail "TC-6f: create.md で workflow-incident-emit.sh invocation block 内に silent failure pattern (|| true / || : / || return 0 / || { true; } のいずれか) が残存 (anti-pattern revert)"
else
  pass "TC-6f: create.md で workflow-incident-emit.sh と silent failure pattern の co-location なし (invocation block 全体 8 行範囲 + comment 除外、silent failure 防御維持)"
fi

# create.md Mandatory After Delegation の imperative phrasing を pin。
# 本 site は create.md に残る唯一の Layer 1 imperative defense で、load-bearing なフレーズ
# (`VERY FIRST cognitive action` / `BEFORE any text output or narrative`) の silent 弱体化を検出する。
assert_grep "TC-6g: create.md に Mandatory After Delegation の '**VERY FIRST cognitive action**' imperative bold が存在" \
  "$CREATE_MD" \
  '\*\*VERY FIRST cognitive action\*\*'
assert_grep "TC-6h: create.md に Mandatory After Delegation の 'BEFORE any text output or narrative' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output or narrative'

# TC-6h-2: TC-6g/h を **同一行** での句結合として再 pin する補強 (旧 step0-immediate-bash-presence.test.sh の
# TC-5.3/5.4 が per-site count >= 3 で保護していた imperative 強度の per-site weakening 検出を補完)。
# 旧テストは削除済 (PR-7 uniformity test で完全カバー予定) だが、PR-3..6 で create.md が誤って編集された
# 場合の partial weakening (例: `MUST proceed to Self-check as your VERY FIRST` だけが残り `BEFORE ...` が削除)
# を独立 grep (TC-6g + TC-6h の個別 grep) だけでは catch できない経路を補強する。
# 1 行内の前後関係 (`MUST proceed to Self-check` … `VERY FIRST cognitive action` … `BEFORE` … `narrative`) を
# 句結合で固定することで、片方の phrase が silent 弱化されたケースを catch する。
# Source: create.md L359 の load-bearing prose で実証されている canonical phrasing。
assert_grep "TC-6h-2: create.md Mandatory After Delegation prose に 'MUST proceed to Self-check' … 'VERY FIRST cognitive action' … 'BEFORE' … 'narrative' の句結合が同一行に存在 (partial weakening detection)" \
  "$CREATE_MD" \
  'MUST proceed to Self-check.*VERY FIRST cognitive action.*BEFORE.*narrative'

# TC-6j: Mandatory After Interview section の不在 pin
# parent-routing pattern 移行で create.md から `🚨 Mandatory After Interview` section を完全削除した。
# git revert / 別 Issue で section が古い phrasing で復活する catastrophic regression を mechanical に検出する。
# TC-6g/h は **存在** pin (Mandatory After Delegation の load-bearing phrasing 維持) なのに対し、
# 本 TC は **不在** pin で対称化する。両者の組合せで「Delegation のみ存続 / Interview は撤去」を保証。
# heading level は h2 / h3 / h4 のいずれでも catch (`^#+ ` で any heading level)。
# 別 heading level (`## ` / `#### `) での復活経路も silent pass させない。
if grep -qE '^#+ .*🚨.*Mandatory After Interview' "$CREATE_MD"; then
  fail "TC-6j: create.md に '🚨 Mandatory After Interview' section anchor が復活した (parent-routing pattern 移行の意図に反する catastrophic revert — git revert / 別 Issue で誤判断の可能性)"
else
  pass "TC-6j: create.md から '🚨 Mandatory After Interview' section anchor が削除されたまま維持 (parent-routing pattern 整合性、catastrophic revert なし)"
fi

# TC-6i: 8 種 retained flag 名の echo presence を個別に pin する。
# flag 名は ADR documented stable contract のため (rename / typo を確実に catch)、
# helper invocation count (TC-6a/b) だけでは検出できない経路を補完する。
# 対象 flag (4 + 4 = 8):
#   create-interview.md: PREFLIGHT_PATCH_FAILED / PREFLIGHT_CREATE_FAILED /
#                        PREFLIGHT_CREATE_THEN_PATCH_FAILED / INTERVIEW_RETURN_PATCH_FAILED
#   create.md:           CREATE_INTERVIEW_PRE_WRITE_PATCH_FAILED / CREATE_INTERVIEW_PRE_WRITE_CREATE_FAILED /
#                        CREATE_DELEGATION_PRE_WRITE_PATCH_FAILED / CREATE_DELEGATION_PRE_WRITE_CREATE_FAILED
for _flag in PREFLIGHT_PATCH_FAILED PREFLIGHT_CREATE_FAILED PREFLIGHT_CREATE_THEN_PATCH_FAILED INTERVIEW_RETURN_PATCH_FAILED; do
  if grep -qE "\\[CONTEXT\\] ${_flag}=1" "$INTERVIEW_MD"; then
    pass "TC-6i: create-interview.md に '[CONTEXT] ${_flag}=1' echo が存在 (catastrophic dual-failure 判定の load-bearing input)"
  else
    fail "TC-6i: create-interview.md に '[CONTEXT] ${_flag}=1' echo が見つからない (flag rename / typo / 削除の可能性 — catastrophic dual-failure 判定が silent break する)"
  fi
done
for _flag in CREATE_INTERVIEW_PRE_WRITE_PATCH_FAILED CREATE_INTERVIEW_PRE_WRITE_CREATE_FAILED CREATE_DELEGATION_PRE_WRITE_PATCH_FAILED CREATE_DELEGATION_PRE_WRITE_CREATE_FAILED; do
  if grep -qE "\\[CONTEXT\\] ${_flag}=1" "$CREATE_MD"; then
    pass "TC-6i: create.md に '[CONTEXT] ${_flag}=1' echo が存在 (caller-side incident emit の load-bearing input)"
  else
    fail "TC-6i: create.md に '[CONTEXT] ${_flag}=1' echo が見つからない (flag rename / typo / 削除の可能性)"
  fi
done

echo
echo "=== TC-7: caller-side [interview:error] halt rule presence ==="

# parent-routing pattern では `[interview:error]` は catastrophic Pre-flight failure を表す halt sentinel として
# create-interview.md / create.md / pre-check-routing.md の 3 site で routing/halt rule が宣言されている。
# silent partial-weakening (例: prose 削除 / phrasing 弱体化) を mechanical に検出する pin。
# 既存 TC-2e が create-interview.md の bullet 存在を pin 済のため、TC-7 では caller 側 (create.md /
# pre-check-routing.md) の halt rule prose 残存を pin する。

PRE_CHECK_ROUTING_MD="$REPO_ROOT/plugins/rite/commands/issue/references/pre-check-routing.md"

if [ ! -f "$PRE_CHECK_ROUTING_MD" ]; then
  fail "TC-7: pre-check-routing.md not found at $PRE_CHECK_ROUTING_MD"
else
  # create.md には Halt rule (Sub-skill Return Protocol section) と Phase 1 return branch
  # ('[interview:error]' return-branch bullet) の **2 箇所** で `[interview:error]` halt prose が存在する。
  # 旧 `grep -q` の 1 match pass は片方を silent 削除しても通過する false negative を持っていたため、
  # `grep -c` で count >= 2 に強化し独立 pin する (semantic anchor を使い line number drift surface を回避)。
  if interview_error_halt_count=$(grep -cE '\[interview:error\].*halt' "$CREATE_MD" 2>/dev/null); then :; else interview_error_halt_count=0; fi
  if [ "$interview_error_halt_count" -ge 2 ]; then
    pass "TC-7a: create.md に '[interview:error] ... halt' prose が 2 site 以上 (実測=$interview_error_halt_count, Halt rule + Phase 1 return branch の 2 site が load-bearing)"
  else
    fail "TC-7a: create.md の '[interview:error] ... halt' prose が 2 site 未満 (実測=$interview_error_halt_count, 期待>=2 — Halt rule (Sub-skill Return Protocol section) または Phase 1 return branch ('[interview:error]' return-branch bullet) のいずれかが削除された可能性)"
  fi

  # TC-7a-1: create.md halt rule の "manual intervention" / "Issue 未作成のまま停止" prose pin。
  # TC-7a の count >= 2 だけでは prose の semantic 弱化 (例: `halt` → `skip Phase 2 silently` への
  # 表現変更) を catch できないため、load-bearing phrase の存在を独立に pin する。両 phrase の
  # いずれかが silent 削除されると halt rule の意味が user-visible error 省略経路に倒れる。
  if grep -qE 'manual intervention' "$CREATE_MD" && grep -qE 'Issue 未作成のまま停止' "$CREATE_MD"; then
    pass "TC-7a-1: create.md halt rule に 'manual intervention' AND 'Issue 未作成のまま停止' prose が存在 (silent semantic weakening 防止)"
  else
    fail "TC-7a-1: create.md halt rule の 'manual intervention' または 'Issue 未作成のまま停止' prose が欠落 (halt rule の semantic 弱化リスク)"
  fi

  # pre-check-routing.md Item 0 dispatcher は `[interview:error]` matched 時の Phase 2 進入禁止経路を持つ。
  if grep -qE '\[interview:error\].*Phase 2' "$PRE_CHECK_ROUTING_MD"; then
    pass "TC-7b: pre-check-routing.md に '[interview:error] ... Phase 2' routing prose が存在 (Item 0 dispatcher の halt 経路の load-bearing pin)"
  else
    fail "TC-7b: pre-check-routing.md に '[interview:error] ... Phase 2' routing prose が見つからない (Item 0 dispatcher の halt 経路が silent に消失した可能性)"
  fi

  # 4 sentinel literal が pre-check-routing.md Item 0 で grep 対象として列挙されていることを pin
  # (grep -qF は fixed string match のため backslash escape は不要)
  for _sentinel in '[interview:skipped]' '[interview:completed]' '[interview:error]' '[create:completed:{N}]'; do
    if grep -qF "$_sentinel" "$PRE_CHECK_ROUTING_MD"; then
      pass "TC-7c: pre-check-routing.md に sentinel literal '$_sentinel' が enumerated (Item 0 dispatcher の grep target)"
    else
      fail "TC-7c: pre-check-routing.md に sentinel literal '$_sentinel' が見つからない (dispatcher grep target の silent 削除リスク)"
    fi
  done

  # TC-7d: Positional 制約 note の load-bearing prose pin。
  # dispatcher の runtime semantics ("fenced code block 内マッチを無視" + "直近 assistant turn 末尾優先")
  # が silent 削除されると、anti-pattern example (`[WRONG] <LLM output: "[interview:skipped]">`) が
  # dispatcher で誤発火し halt 経路ではなく continuation 経路に流れる silent semantic regression を起こす。
  if grep -qE 'fenced code block.*無視' "$PRE_CHECK_ROUTING_MD"; then
    pass "TC-7d: pre-check-routing.md に Positional 制約 note 'fenced code block 内マッチを無視' が存在 (dispatcher collision-safe matching の load-bearing prose pin)"
  else
    fail "TC-7d: pre-check-routing.md に Positional 制約 note 'fenced code block 内マッチを無視' が見つからない (anti-pattern example 誤発火リスク)"
  fi
fi

DRIFT_HINT="\
parent-routing pattern interim invariant が崩れています。
ADR: docs/designs/parent-routing-unification.md"

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: parent-routing pattern interim invariant verified"
exit 0
