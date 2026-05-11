#!/bin/bash
# parent-routing-pattern-interim.test.sh
#
# Interim invariant test for the parent-routing pattern migration
# (Issue #920 / PR #926 PR-2, ADR docs/designs/parent-routing-unification.md).
#
# Purpose:
#   PR-2 で削除された 4 件の invariant test
#   (4-site-symmetry / caller-html-literal-symmetry /
#    create-interview-responsibility-separation / step0-immediate-bash-presence)
#   が pin していた canonical sites のうち、本 PR で site 自体が消滅したものを
#   除いた **残存 canonical sites** を interim coverage として pin する。
#
#   代替の `parent-routing-pattern-uniformity.test.sh` は PR-7 で導入予定だが、
#   PR-2 〜 PR-7 (推定数週間〜数ヶ月) の coverage gap 期間中に
#   cleanup.md / ingest.md / lint.md 上の imperative phrasing 弱体化や
#   create-interview.md Pre-flight 削除を catch する手段が必要。
#
# Pinned invariants (4 categories):
#   TC-1: create-interview.md Pre-flight + Return Output re-patch の存在
#     (`flow-state-update.sh patch ... --phase "create_post_interview"` を 2 回以上)
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
# `grep -c ... || echo 0` idiom の落とし穴を回避するため if/else 形式を採用。
if interview_patch_count=$(grep -cE 'flow-state-update\.sh patch' "$INTERVIEW_MD" 2>/dev/null); then :; else interview_patch_count=0; fi
if [ "$interview_patch_count" -ge 2 ]; then
  pass "TC-1: create-interview.md に 'flow-state-update.sh patch' が 2 回以上 (実測=$interview_patch_count, Pre-flight + Return Output re-patch)"
else
  fail "TC-1: create-interview.md の 'flow-state-update.sh patch' 出現回数が 2 未満 (実測=$interview_patch_count, 期待>=2 — Pre-flight または Return Output re-patch が削除された可能性)"
fi

# create_post_interview phase が patch arg として現れることを pin
assert_grep "TC-1b: create-interview.md に '--phase \"create_post_interview\"' が存在" \
  "$INTERVIEW_MD" \
  'phase[[:space:]]+"create_post_interview"'

echo
echo "=== TC-2: create-interview.md parent-routing pattern compliance ==="

# bare bracket form sentinel が result pattern bullet list として存在
assert_grep "TC-2a: create-interview.md に bare bracket '[interview:completed]' bullet" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview completed\*\*: `\[interview:completed\]`'
assert_grep "TC-2b: create-interview.md に bare bracket '[interview:skipped]' bullet" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview skipped\*\*'

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

DRIFT_HINT="\
parent-routing pattern interim invariant が崩れています。
本 test は PR-2 〜 PR-7 の coverage gap 期間中の defense layer として機能します。
ADR: docs/designs/parent-routing-unification.md
PR-7 で parent-routing-pattern-uniformity.test.sh に統合 / 退役予定。"

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: parent-routing pattern interim invariant verified"
exit 0
