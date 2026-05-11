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
# Pinned invariants (6 categories):
#   TC-1: create-interview.md Pre-flight + Return Output re-patch の存在
#     (`flow-state-update.sh patch ... --phase "create_post_interview"` を 2 回以上)
#   TC-1c: cold-start 二段書き込み (create→patch) sequence の pin
#     (`flow-state-update.sh create --phase "create_interview"` AND `--phase "create_post_interview"` の併存)
#   TC-2: create-interview.md は bare bracket form sentinel を含み、HTML-comment form
#         の sentinel を含まない (parent-routing pattern compliance)
#   TC-3: cleanup.md Mandatory After Wiki Ingest Step 0 の imperative keyword
#         (`VERY FIRST tool call` / `BEFORE any text output`) の存在
#         (PR-4 で parent-routing pattern に移行予定までの interim guard)
#   TC-4: ingest.md Mandatory After Auto-Lint Step 0 の imperative keyword
#         (`VERY FIRST tool call` / `BEFORE any text output`) の存在
#         (PR-3 で移行予定までの interim guard)
#   TC-5: lint.md Phase 9.2 三点セット blockquote の `> ⏭ MUST continue (turn を閉じない):`
#         imperative recast (Issue #917) の存在 (PR-3 で移行予定までの interim guard)
#   TC-6: 全 incident-emit 経路で workflow-incident-emit.sh と retained flag が co-located
#         (parent-routing pattern で新設された 8 retained flag が helper call と co-located であることを pin)
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
# `>= 3` で厳格化し、いずれか 1 site の silent removal も catch する (II-2 対応)。
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

# TC-1c: cold-start 二段書き込み (create→patch) sequence の pin (CG-2 対応)。
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
assert_grep "TC-2b: create-interview.md に bare bracket '[interview:skipped]' bullet (TC-2a と parallel に sentinel value も pin、II-1 対応)" \
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

echo
echo "=== TC-3: cleanup.md Mandatory After Wiki Ingest Step 0 imperative keyword ==="

# `VERY FIRST tool call` Markdown bold (Step 0 prose canonical phrasing pin)
assert_grep "TC-3a: cleanup.md に '**VERY FIRST tool call**' Markdown bold が存在" \
  "$CLEANUP_MD" \
  '\*\*VERY FIRST tool call\*\*'
assert_grep "TC-3b: cleanup.md に 'BEFORE any text output' keyword が存在" \
  "$CLEANUP_MD" \
  'BEFORE any text output'

echo
echo "=== TC-4: ingest.md Mandatory After Auto-Lint Step 0 imperative keyword ==="

assert_grep "TC-4a: ingest.md に '**VERY FIRST tool call**' Markdown bold が存在" \
  "$INGEST_MD" \
  '\*\*VERY FIRST tool call\*\*'
assert_grep "TC-4b: ingest.md に 'BEFORE any text output' keyword が存在" \
  "$INGEST_MD" \
  'BEFORE any text output'

echo
echo "=== TC-5: lint.md Phase 9.2 Layer 3b imperative recast (Issue #917) ==="

# `> ⏭ MUST continue (turn を閉じない):` blockquote の存在 (line-start anchor、echo / raw blockquote 両 form 受け入れ)
assert_grep "TC-5a: lint.md に Layer 3b imperative '⏭ MUST continue (turn を閉じない):' blockquote が存在" \
  "$LINT_MD" \
  '^[[:space:]]*(echo ")?> ⏭ MUST continue \(turn を閉じない\):'

# 旧 `⏭ 継続中:` 現状報告 phrasing が残っていないこと (Issue #917 で recast 済)
assert_not_grep "TC-5b: lint.md に旧 '⏭ 継続中:' 現状報告 phrasing が残っていない" \
  "$LINT_MD" \
  '⏭ 継続中:'

echo
echo "=== TC-6: workflow-incident-emit.sh が全 retained flag emit 経路と co-located ==="

# CG-1 対応: parent-routing pattern で新設された 8 retained flag (CREATE_INTERVIEW_PRE_WRITE_PATCH_FAILED /
# CREATE_INTERVIEW_PRE_WRITE_CREATE_FAILED / CREATE_DELEGATION_PRE_WRITE_PATCH_FAILED /
# CREATE_DELEGATION_PRE_WRITE_CREATE_FAILED / PREFLIGHT_PATCH_FAILED / PREFLIGHT_CREATE_FAILED /
# PREFLIGHT_CREATE_THEN_PATCH_FAILED / INTERVIEW_RETURN_PATCH_FAILED) ごとに、
# (a) `[CONTEXT] FLAG=1` echo と (b) `workflow-incident-emit.sh` invocation が同一ファイル内に併存することを pin。
# 真の co-location (近接行範囲) の検証は line-by-line analysis が必要だが、本 interim test では
# ファイル単位の co-existence pin で十分 (silent removal regression を catch する)。
CREATE_MD="$REPO_ROOT/plugins/rite/commands/issue/create.md"

if interview_emit_count=$(grep -cE 'workflow-incident-emit\.sh' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_emit_count=0; fi
if [ "$interview_emit_count" -ge 4 ]; then
  pass "TC-6a: create-interview.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$interview_emit_count, Pre-flight 3 site + Return Output 1 site)"
else
  fail "TC-6a: create-interview.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$interview_emit_count, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

if create_emit_count=$(grep -cE 'workflow-incident-emit\.sh' "$CREATE_MD" 2>/dev/null); then :; else create_emit_count=0; fi
if [ "$create_emit_count" -ge 4 ]; then
  pass "TC-6b: create.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$create_emit_count, Phase 1 Pre-write 2 site + Phase 3 Pre-write 2 site)"
else
  fail "TC-6b: create.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$create_emit_count, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

# fallback WARNING pattern: helper 失敗時に silent fall-through しないことを pin
if interview_warn_count=$(grep -cE 'WARNING: workflow-incident-emit\.sh failed' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_warn_count=0; fi
if [ "$interview_warn_count" -ge 4 ]; then
  pass "TC-6c: create-interview.md に 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回以上 (実測=$interview_warn_count, F-1 silent failure 防御 pattern)"
else
  fail "TC-6c: create-interview.md の 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回未満 (実測=$interview_warn_count, 期待>=4 — `2>/dev/null || true` silent failure pattern に reverted した可能性)"
fi

if create_warn_count=$(grep -cE 'WARNING: workflow-incident-emit\.sh failed' "$CREATE_MD" 2>/dev/null); then :; else create_warn_count=0; fi
if [ "$create_warn_count" -ge 4 ]; then
  pass "TC-6d: create.md に 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回以上 (実測=$create_warn_count, F-1 silent failure 防御 pattern)"
else
  fail "TC-6d: create.md の 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回未満 (実測=$create_warn_count, 期待>=4 — `2>/dev/null || true` silent failure pattern に reverted した可能性)"
fi

# anti-pattern revert detection: `2>/dev/null || true` が workflow-incident-emit.sh と co-located で残っていないこと
if grep -B1 -A1 'workflow-incident-emit\.sh' "$INTERVIEW_MD" | grep -qE '2>/dev/null \|\| true'; then
  fail "TC-6e: create-interview.md で workflow-incident-emit.sh 呼び出し近傍に '2>/dev/null || true' silent failure pattern が残存 (F-1 anti-pattern revert)"
else
  pass "TC-6e: create-interview.md で workflow-incident-emit.sh と '2>/dev/null || true' の co-location なし (F-1 silent failure 防御維持)"
fi

if grep -B1 -A1 'workflow-incident-emit\.sh' "$CREATE_MD" | grep -qE '2>/dev/null \|\| true'; then
  fail "TC-6f: create.md で workflow-incident-emit.sh 呼び出し近傍に '2>/dev/null || true' silent failure pattern が残存 (F-1 anti-pattern revert)"
else
  pass "TC-6f: create.md で workflow-incident-emit.sh と '2>/dev/null || true' の co-location なし (F-1 silent failure 防御維持)"
fi

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
