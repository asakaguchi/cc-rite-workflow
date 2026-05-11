#!/bin/bash
# parent-routing-pattern-interim.test.sh
#
# Interim invariant test for the parent-routing pattern migration
# (ADR docs/designs/parent-routing-unification.md).
#
# Purpose:
#   parent-routing pattern 移行で削除された 4 件の invariant test
#   (4-site-symmetry / caller-html-literal-symmetry /
#    create-interview-responsibility-separation / step0-immediate-bash-presence)
#   が pin していた canonical sites のうち、site 自体が消滅したものを
#   除いた **残存 canonical sites** を interim coverage として pin する。
#
#   代替の `parent-routing-pattern-uniformity.test.sh` は ADR 8 PR series の中継期 (PR-7 で導入予定)
#   までの coverage gap 期間中に、cleanup.md / ingest.md / lint.md 上の imperative phrasing 弱体化や
#   create-interview.md Pre-flight 削除を catch する手段が必要。
#
# Pinned invariants (6 top-level categories; TC-1c is a sub-pin of TC-1):
#   TC-1: create-interview.md Pre-flight + Return Output re-patch の存在
#     (`flow-state-update.sh patch ... --phase "create_post_interview"` を 3 回以上)
#     - TC-1c sub-pin: cold-start 二段書き込み (create→patch) sequence の pin
#       (`flow-state-update.sh create --phase "create_interview"` AND `--phase "create_post_interview"` の併存)
#   TC-2: create-interview.md は bare bracket form sentinel を含み、HTML-comment form
#         の sentinel および caller HTML hint (`<!-- caller: -->`) を含まない (parent-routing pattern compliance)
#   TC-3: cleanup.md Mandatory After Wiki Ingest Step 0 の imperative keyword
#         (`VERY FIRST tool call` / `BEFORE any text output`) + Step 0 bash literal
#         (`phase "cleanup_post_ingest"` >= 2) + section anchor の存在
#         (PR-4 で parent-routing pattern に移行予定までの interim guard)
#   TC-4: ingest.md Mandatory After Auto-Lint Step 0 の imperative keyword
#         (`VERY FIRST tool call` / `BEFORE any text output`) + Step 0/1 bash literal
#         (`phase "ingest_post_lint"` >= 2) + continuation HTML literal の 4 imperative keyword
#         (`MUST execute` / `VERY FIRST tool call BEFORE any text output` / `DO NOT end the turn` /
#          `DO NOT output any narrative text`) の存在
#         (PR-3 で移行予定までの interim guard)
#   TC-5: lint.md Phase 9.2 三点セット blockquote の `> ⏭ MUST continue (turn を閉じない):`
#         imperative recast (Issue #917) が 3 canonical sites (echo 形式 + raw blockquote) で存在
#         (PR-3 で移行予定までの interim guard、部分削除を検出するため count >= 3 で厳格化)
#   TC-6: 全 incident-emit 経路で workflow-incident-emit.sh と retained flag が co-located
#         (parent-routing pattern で新設された 8 retained flag が helper call と co-located であることを pin)
#         および create.md Mandatory After Delegation の `VERY FIRST cognitive action` imperative phrasing の存在
#
# When this test fails:
#   parent-routing pattern compliance または imperative keyword 強度が崩れた。
#   詳細は ADR docs/designs/parent-routing-unification.md を参照。
#   PR-7 で本 test は `parent-routing-pattern-uniformity.test.sh` に統合 / 退役予定。

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
# `grep -c ... || echo 0` idiom の落とし穴を回避するため if/else 形式を採用。
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
if grep -A 1 'flow-state-update\.sh create' "$INTERVIEW_MD" | grep -qE '\-\-phase "create_interview"[^_]'; then
  pass "TC-1c-1: create-interview.md cold-start branch に 'create + --phase \"create_interview\"' の sequence が存在 (audit-trail fidelity)"
else
  fail "TC-1c-1: create-interview.md cold-start branch の 'create + --phase \"create_interview\"' sequence が消失 (単段 create --phase create_post_interview への退化、audit-trail fidelity 欠落)"
fi
# 二段書き込みの第 2 段 (create_post_interview への patch) は TC-1 で既に pin 済。

echo
echo "=== TC-2: create-interview.md parent-routing pattern compliance ==="

# bare bracket form sentinel が result pattern bullet list として存在
assert_grep "TC-2a: create-interview.md に bare bracket '[interview:completed]' bullet" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview completed\*\*: `\[interview:completed\]`'
assert_grep "TC-2b: create-interview.md に bare bracket '[interview:skipped]' bullet (TC-2a と parallel に sentinel value も pin)" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview skipped\*\*.*: `\[interview:skipped\]`'

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

# 旧 step0-immediate-bash-presence.test.sh TC-2.3 が pin していた bash literal の存在を再構築。
# Step 0 / Step 1 二重 patch design が silently 削除されると prose だけ残った half-migration regression を
# 引き起こすため、bash literal の存在 + 個数で structure を pin する。
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

# 旧 step0-immediate-bash-presence.test.sh TC-3.6 が pin していた Step 0/1 二重 patch 構造を再構築。
# `phase "ingest_post_lint"` bash literal が >= 2 で出現することで、idempotent re-patch 機構が
# silent に削除された場合を検出する (Issue #917 で導入された 5 site canonical 対称化の保護)。
if ingest_post_lint_count=$(grep -cE 'phase[[:space:]]+"ingest_post_lint"' "$INGEST_MD" 2>/dev/null); then :; else ingest_post_lint_count=0; fi
if [ "$ingest_post_lint_count" -ge 2 ]; then
  pass "TC-4c: ingest.md に 'phase \"ingest_post_lint\"' bash literal が 2 回以上 (実測=$ingest_post_lint_count, Step 0 + Step 1 idempotent 二重 patch)"
else
  fail "TC-4c: ingest.md の 'phase \"ingest_post_lint\"' bash literal が 2 未満 (実測=$ingest_post_lint_count, Issue #917 の二重 patch 機構が silently 削除された可能性)"
fi
assert_grep "TC-4d: ingest.md の section anchor '🚨 Mandatory After Auto-Lint' が存在" \
  "$INGEST_MD" \
  '🚨 Mandatory After Auto-Lint'

# 旧 step0-immediate-bash-presence.test.sh TC-3.1-3.4 が pin していた continuation HTML literal の
# 4 imperative keyword を line-anchored regex で再構築。Issue #910 D-01 で実証された load-bearing な
# defense layer (`DO NOT end the turn` / `DO NOT output any narrative text` 等の負方向 imperative) の
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
echo "=== TC-5: lint.md Phase 9.2 Layer 3b imperative recast (Issue #917) ==="

# `> ⏭ MUST continue (turn を閉じない):` blockquote の存在 (line-start anchor、echo / raw blockquote 両 form 受け入れ)
# 旧 step0-immediate-bash-presence.test.sh TC-6.3 が pin していた 3 canonical sites
# (Phase 1.1 echo / Phase 1.3 echo / Phase 9.2 raw blockquote) のうち 1-2 sites が silently 削除されても
# count >= 1 では検出できなかった coverage gap を埋めるため、count >= 3 で厳格化する。
if lint_must_continue_count=$(grep -cE '^[[:space:]]*(echo ")?> ⏭ MUST continue \(turn を閉じない\):' "$LINT_MD" 2>/dev/null); then :; else lint_must_continue_count=0; fi
if [ "$lint_must_continue_count" -ge 3 ]; then
  pass "TC-5a: lint.md に Layer 3b imperative '⏭ MUST continue (turn を閉じない):' blockquote が 3 回以上 (実測=$lint_must_continue_count, 3 canonical sites: Phase 1.1 echo + Phase 1.3 echo + Phase 9.2 raw blockquote)"
else
  fail "TC-5a: lint.md の '⏭ MUST continue (turn を閉じない):' blockquote が 3 未満 (実測=$lint_must_continue_count, 期待>=3 — 3 canonical sites のうち 1-2 sites が silently 削除された可能性)"
fi

# 旧 `⏭ 継続中:` 現状報告 phrasing が残っていないこと (Issue #917 で recast 済)
assert_not_grep "TC-5b: lint.md に旧 '⏭ 継続中:' 現状報告 phrasing が残っていない" \
  "$LINT_MD" \
  '⏭ 継続中:'

echo
echo "=== TC-6: workflow-incident-emit.sh が全 retained flag emit 経路と co-located + create.md Mandatory After Delegation imperative ==="

# TC-6a/b: parent-routing pattern で新設された 8 retained flag (CREATE_INTERVIEW_PRE_WRITE_PATCH_FAILED /
# CREATE_INTERVIEW_PRE_WRITE_CREATE_FAILED / CREATE_DELEGATION_PRE_WRITE_PATCH_FAILED /
# CREATE_DELEGATION_PRE_WRITE_CREATE_FAILED / PREFLIGHT_PATCH_FAILED / PREFLIGHT_CREATE_FAILED /
# PREFLIGHT_CREATE_THEN_PATCH_FAILED / INTERVIEW_RETURN_PATCH_FAILED) の helper invocation が
# 同一ファイル内に co-located であることを pin する。grep -cE は helper invocation の
# 行数 (bash backslash 続行のため 1 invocation = 1 行) を返すため、件数は invocation 件数と一致する。
# 個別 flag 名の echo は本 test では検証しない (silent removal は invocation count で検出可能、
# かつ flag 名の細粒度 pin は test の保守コストに見合わない)。
CREATE_MD="$REPO_ROOT/plugins/rite/commands/issue/create.md"

if interview_emit_count=$(grep -cE '^[[:space:]]*bash .*workflow-incident-emit\.sh' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_emit_count=0; fi
if [ "$interview_emit_count" -ge 4 ]; then
  pass "TC-6a: create-interview.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$interview_emit_count invocations, Pre-flight 3 site + Return Output 1 site)"
else
  fail "TC-6a: create-interview.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$interview_emit_count invocations, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

if create_emit_count=$(grep -cE '^[[:space:]]*bash .*workflow-incident-emit\.sh' "$CREATE_MD" 2>/dev/null); then :; else create_emit_count=0; fi
if [ "$create_emit_count" -ge 4 ]; then
  pass "TC-6b: create.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$create_emit_count invocations, Phase 1 Pre-write 2 site + Phase 3 Pre-write 2 site)"
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

# anti-pattern revert detection: `2>/dev/null || true` が workflow-incident-emit.sh と co-located で残っていないこと
if grep -B1 -A1 'workflow-incident-emit\.sh' "$INTERVIEW_MD" | grep -qE '2>/dev/null \|\| true'; then
  fail "TC-6e: create-interview.md で workflow-incident-emit.sh 呼び出し近傍に '2>/dev/null || true' silent failure pattern が残存 (anti-pattern revert)"
else
  pass "TC-6e: create-interview.md で workflow-incident-emit.sh と '2>/dev/null || true' の co-location なし (silent failure 防御維持)"
fi

if grep -B1 -A1 'workflow-incident-emit\.sh' "$CREATE_MD" | grep -qE '2>/dev/null \|\| true'; then
  fail "TC-6f: create.md で workflow-incident-emit.sh 呼び出し近傍に '2>/dev/null || true' silent failure pattern が残存 (anti-pattern revert)"
else
  pass "TC-6f: create.md で workflow-incident-emit.sh と '2>/dev/null || true' の co-location なし (silent failure 防御維持)"
fi

# 旧 step0-immediate-bash-presence.test.sh TC-1.1 / TC-4.1 が pin していた create.md Mandatory After
# Delegation の imperative phrasing を再構築。Mandatory After Interview 廃止後、本 site は create.md に
# 残る唯一の Layer 1 imperative defense であり、Issue #910 D-01 で実証された load-bearing なフレーズ
# (`VERY FIRST cognitive action` / `BEFORE any text output or narrative`) が silently 弱体化された場合を
# 検出する。create.md:299 の prose を直接 pin する。
assert_grep "TC-6g: create.md に Mandatory After Delegation の '**VERY FIRST cognitive action**' imperative bold が存在" \
  "$CREATE_MD" \
  '\*\*VERY FIRST cognitive action\*\*'
assert_grep "TC-6h: create.md に Mandatory After Delegation の 'BEFORE any text output or narrative' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output or narrative'

DRIFT_HINT="\
parent-routing pattern interim invariant が崩れています。
本 test は ADR 8 PR series の中継期 (PR-7 までの coverage gap) の defense layer として機能します。
ADR: docs/designs/parent-routing-unification.md
PR-7 で parent-routing-pattern-uniformity.test.sh に統合 / 退役予定。"

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: parent-routing pattern interim invariant verified"
exit 0
