#!/bin/bash
# parent-routing-pattern-interim.test.sh
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

# TC-2e: catastrophic halt sentinel `[interview:error]` の bullet 存在を pin する。
# caller routing (create.md / pre-check-routing.md) が halt trigger として参照する load-bearing sentinel。
# silent revert で bullet が消えると catastrophic dual-failure 経路の halt が機能しなくなる。
assert_grep "TC-2e: create-interview.md に bare bracket '[interview:error]' bullet (catastrophic halt sentinel)" \
  "$INTERVIEW_MD" \
  '^- \*\*Halt with error\*\*.*: `\[interview:error\]`'

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

# create.md Mandatory After Delegation の imperative phrasing を pin。
# 本 site は create.md に残る唯一の Layer 1 imperative defense で、load-bearing なフレーズ
# (`VERY FIRST cognitive action` / `BEFORE any text output or narrative`) の silent 弱体化を検出する。
assert_grep "TC-6g: create.md に Mandatory After Delegation の '**VERY FIRST cognitive action**' imperative bold が存在" \
  "$CREATE_MD" \
  '\*\*VERY FIRST cognitive action\*\*'
assert_grep "TC-6h: create.md に Mandatory After Delegation の 'BEFORE any text output or narrative' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output or narrative'

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

DRIFT_HINT="\
parent-routing pattern interim invariant が崩れています。
ADR: docs/designs/parent-routing-unification.md"

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: parent-routing pattern interim invariant verified"
exit 0
