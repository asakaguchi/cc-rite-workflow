#!/bin/bash
# start-md-sentinel-coverage.test.sh — CG-2 (PR #1079 verified-review)
#
# Purpose:
#   `commands/issue/start.md` の flat workflow が caller (例: /rite:sprint:execute、
#   /rite:resume) に対して emit する sentinel pattern の全集合が start.md 内に
#   最低 1 回登場することを grep で assert する。
#
#   PR #1079 で sub-skill chain が撤去された結果、sentinel pattern は start.md
#   単一ファイル + invoke 先 skill (lint / pr:create / pr:review / pr:fix / pr:ready) の
#   出力の組み合わせで構成される。start.md がドキュメントするはずの「戻り値パターン」が
#   静的に欠落すると、caller 側の grep pattern と silent drift する。
#
# Coverage areas:
#   1. lint sentinel: [lint:success|skipped|error|aborted] (新 [lint:aborted] 含む)
#   2. pr:create sentinel: [pr:created:N], [pr:create-failed]
#   3. pr:review sentinel: [review:mergeable], [review:fix-needed:N]
#   4. pr:fix sentinel: [fix:pushed], [fix:pushed-wm-stale], [fix:issues-created:N],
#                       [fix:replied-only], [fix:error]
#   5. pr:ready sentinel: [ready:completed], [ready:error]
#   6. WORKFLOW_INCIDENT inline emit pattern (literal format guard)
#
# When this test fails:
#   start.md のドキュメント部分から sentinel literal が消えた場合、(a) sentinel set
#   自体を縮退させた refactor なら本 test の expected_set を更新、(b) ドキュメント
#   漏れなら start.md を修正する。caller (sprint:execute / resume) の grep pattern と
#   drift する前に防衛する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
START_MD="$PLUGIN_ROOT/commands/issue/start.md"

assert_file_exists_or_fail "start.md exists" "$START_MD" || {
  print_summary "$(basename "$0")" "start.md missing — PR #1079 retired this file?"
  exit 1
}

assert_in_start() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$START_MD"; then
    pass "$label"
  else
    fail "$label (pattern not found: $pattern)"
  fi
}

echo "=== lint sentinel set ==="
assert_in_start "lint:success literal" '\[lint:success\]'
assert_in_start "lint:skipped literal" '\[lint:skipped\]'
assert_in_start "lint:error literal" '\[lint:error\]'
assert_in_start "lint:aborted literal (PR #1079 fix(issue/start) added)" '\[lint:aborted\]'

echo ""
echo "=== pr:create sentinel set ==="
assert_in_start "pr:created:N literal" '\[pr:created:'
assert_in_start "pr:create-failed literal" '\[pr:create-failed\]'

echo ""
echo "=== pr:review sentinel set ==="
assert_in_start "review:mergeable literal" '\[review:mergeable\]'
assert_in_start "review:fix-needed:N literal" '\[review:fix-needed:'

echo ""
echo "=== pr:fix sentinel set ==="
assert_in_start "fix:pushed literal" '\[fix:pushed\]'
assert_in_start "fix:pushed-wm-stale literal" '\[fix:pushed-wm-stale\]'
assert_in_start "fix:issues-created:N literal" '\[fix:issues-created:'
assert_in_start "fix:replied-only literal" '\[fix:replied-only\]'
assert_in_start "fix:error literal" '\[fix:error\]'

echo ""
echo "=== pr:ready sentinel set ==="
assert_in_start "ready:completed literal" '\[ready:completed\]'
assert_in_start "ready:error literal" '\[ready:error\]'

echo ""
echo "=== WORKFLOW_INCIDENT inline emit pattern ==="
# Inline emit (`echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=..."`) と
# helper invoke (`workflow-incident-emit.sh --type ...`) の両形式どちらかが
# 最低 1 回登場すること。これにより 5.4.4.1 検出経路と互換性のある
# emit 経路が start.md から消えていないことを保証する。
assert_in_start "WORKFLOW_INCIDENT emit (inline or helper)" '(\[CONTEXT\] WORKFLOW_INCIDENT=1; type=|workflow-incident-emit\.sh --type)'

echo ""
echo "=== Resume Dispatch ステップ 0 (H-2 fix) ==="
# H-2 で追加した Resume Dispatch ステップが start.md に存在することを assert。
# resume.md Phase 3.2 表が「start.md は冒頭で flow state を読む」と公言するため、
# state-read.sh への呼び出しが最低 1 回登場する必要がある。
assert_in_start "state-read.sh invocation (Resume Dispatch ステップ 0)" 'state-read\.sh --field phase'
assert_in_start "RESUME_DISPATCH context marker" 'RESUME_DISPATCH='

echo ""
echo "=== Multi-site lower bound (II-2 PR #1079 verified-review) ==="
# 同一 sentinel が複数 phase で emit される場合、wildcard 1-hit pass で
# silent deletion を見逃す問題に対する aggregated lower-bound assertion。
# start-md-charter.test.sh と同じ pattern を採用 (count_aggregated ≥ N)。

# WORKFLOW_INCIDENT emit は複数 phase (lint default / pr_create_failed / git push / projects_*) で
# 8+ 箇所登場するはず。1 箇所未満になったら多くの incident emit 経路が消えた signal。
wf_incident_count=$(grep -cE 'workflow-incident-emit\.sh' "$START_MD" || true)
if [ "$wf_incident_count" -ge 8 ]; then
  pass "WORKFLOW_INCIDENT emit lower bound (>=8, got $wf_incident_count)"
else
  fail "WORKFLOW_INCIDENT emit lower bound failed (expected >=8, got $wf_incident_count) — silent deletion risk"
fi

# projects_status_update_failed は 8.3 (skipped + failed arms) + 8.4 (skipped + failed arms) で 4+ 箇所
proj_status_count=$(grep -cE 'projects_status_update_failed' "$START_MD" || true)
if [ "$proj_status_count" -ge 2 ]; then
  pass "projects_status_update_failed lower bound (>=2, got $proj_status_count)"
else
  fail "projects_status_update_failed lower bound failed (expected >=2, got $proj_status_count)"
fi

# skill_load_failure は lint default / pr:create default / pr:review default / pr:fix default / pr:ready default
# の最低 5 site で emit されるはず (H-4 改修後)
skill_load_count=$(grep -cE 'skill_load_failure' "$START_MD" || true)
if [ "$skill_load_count" -ge 3 ]; then
  pass "skill_load_failure multi-site lower bound (>=3, got $skill_load_count)"
else
  fail "skill_load_failure multi-site lower bound failed (expected >=3, got $skill_load_count) — non-lint phase default handlers may have been removed"
fi

echo ""
echo "=== 9-phase Resume Dispatch routing table rows (II-5 PR #1079 verified-review) ==="
# Resume Dispatch table の各 phase 行が start.md に存在することを assert。
# 行ごとに `phase=<name>` が table 内に登場するはず。
for phase in init branch plan implement lint pr review fix completed; do
  if grep -qE "phase=$phase\b" "$START_MD"; then
    pass "Resume Dispatch row for phase=$phase exists"
  else
    fail "Resume Dispatch row for phase=$phase is missing (routing table drift)"
  fi
done

echo ""
if ! print_summary "$(basename "$0")" "start.md の sentinel set を変更した場合、caller (sprint:execute / resume) の grep pattern も同時に更新する責務がある。本 test の expected_set を縮退させる前に caller 側との符号を必ず確認すること。"; then
  exit 1
fi
