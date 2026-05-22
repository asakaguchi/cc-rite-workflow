#!/bin/bash
# start-md-sentinel-coverage.test.sh
#
# Every sentinel pattern that `commands/issue/start.md` emits to its callers
# (/rite:sprint:execute, /rite:resume, etc.) must appear at least once inside
# start.md itself. The sentinel set lives across start.md plus the sub-skills
# it invokes (lint / pr:create / pr:review / pr:fix / pr:ready); if start.md's
# documented "return patterns" silently lose a literal, caller-side grep
# patterns drift out of sync and detection breaks without an obvious failure.
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
  print_summary "$(basename "$0")" "start.md missing — was the file retired or renamed?"
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
assert_in_start "lint:aborted literal" '\[lint:aborted\]'

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
echo "=== WORKFLOW_INCIDENT emit patterns ==="
# inline emit (`echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=..."`) と helper invoke
# (`workflow-incident-emit.sh --type ...`) を OR で 1 つの assert にすると、片方が
# 完全に消えても残った形式で PASS する fragility (3-method OR alternation 問題と同型)
# が出る。両形式が最低 1 回ずつ登場することを独立 assertion で pin する。
inline_wf_count=$(grep -cE '\[CONTEXT\] WORKFLOW_INCIDENT=1; type=' "$START_MD" || true)
if [ "$inline_wf_count" -ge 1 ]; then
  pass "WORKFLOW_INCIDENT inline emit present (>=1, got $inline_wf_count)"
else
  fail "WORKFLOW_INCIDENT inline emit missing — context grep 検出経路の inline form が start.md から消滅"
fi
helper_wf_count=$(grep -cE 'workflow-incident-emit\.sh --type' "$START_MD" || true)
if [ "$helper_wf_count" -ge 1 ]; then
  pass "WORKFLOW_INCIDENT helper invoke present (>=1, got $helper_wf_count)"
else
  fail "WORKFLOW_INCIDENT helper invoke missing — workflow-incident-emit.sh への delegate が start.md から消滅"
fi

echo ""
echo "=== Resume Dispatch ステップ 0 (H-2 fix) ==="
# H-2 で追加した Resume Dispatch ステップが start.md に存在することを assert。
# resume.md Phase 3.2 表が「start.md は冒頭で flow state を読む」と公言するため、
# state-read.sh への呼び出しが最低 1 回登場する必要がある。
assert_in_start "state-read.sh invocation (Resume Dispatch ステップ 0)" 'state-read\.sh --field phase'
assert_in_start "RESUME_DISPATCH context marker" 'RESUME_DISPATCH='

echo ""
echo "=== Multi-site lower bound ==="
# A wildcard 1-hit grep would let silent deletions through when the same sentinel
# is emitted from multiple phases. Aggregated lower-bound counts (count >= N)
# catch the case where most emit sites disappear but one literal remains.
# WORKFLOW_INCIDENT spans lint / pr_create_failed / git push / projects_* phases —
# at least 8 occurrences are expected.
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
echo "=== 11-phase Resume Dispatch routing table rows ==="
# `phase=ready` / `phase=ready_error` 行が削除されると pr/ready.md の Ready
# 後続 routing が start.md 側で silent regression する。resume.md の 11 phase
# 仕様 (FLAT_PHASES) と一致する全行を必須化する。
for phase in init branch plan implement lint pr review fix ready ready_error completed; do
  if grep -qE "phase=$phase\b" "$START_MD"; then
    pass "Resume Dispatch row for phase=$phase exists"
  else
    fail "Resume Dispatch row for phase=$phase is missing (routing table drift)"
  fi
done

echo ""
echo "=== 5-arg symmetry for flow-state-update.sh create ==="
# Every `flow-state-update.sh create` invocation across start.md + create.md must
# include all 5 args: --phase / --issue / --branch / --pr / --next. Argument drift
# breaks phase routing and resume; CI must catch the divergence early.
CREATE_MD="$PLUGIN_ROOT/commands/issue/create.md"
for f in "$START_MD" "$CREATE_MD"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

# awk で `flow-state-update.sh create` を含む multi-line invocation を抽出 (連続行 + 末尾の `\`)。
# 抽出した塊ごとに 5 種類の flag が登場するか検査する。
check_symmetry_5arg() {
  local file="$1"
  local fname; fname="$(basename "$file")"
  # bash fenced code block (` ```bash ... ``` `) 内に限定して `flow-state-update.sh create` invocation を抽出する。
  # markdown 表内のテキスト (例: 表セルでの言及) を誤検出しないため、in_bash フラグを使う。
  # multi-line bash invocation (行末 `\` で継続) は 1 record として concat する。
  awk '
    /^```bash$/ { in_bash=1; next }
    /^```$/    { in_bash=0; next }
    in_bash && /flow-state-update\.sh create/ {
      block = $0
      while (match(block, /\\$/)) {
        if ((getline next_line) <= 0) break
        block = block " " next_line
      }
      print block
      print "---END---"
    }
  ' "$file" | awk -v fname="$fname" -v pass_token="✅" -v fail_token="❌" '
    BEGIN { block_count=0; ok=0 }
    /^---END---$/ {
      block_count++
      missing = ""
      if (block !~ /--phase[[:space:]]/)  missing = missing " --phase"
      if (block !~ /--issue[[:space:]]/)  missing = missing " --issue"
      if (block !~ /--branch[[:space:]]/) missing = missing " --branch"
      if (block !~ /--pr[[:space:]]/)     missing = missing " --pr"
      if (block !~ /--next[[:space:]]/)   missing = missing " --next"
      if (missing != "") {
        printf "  %s 5-arg symmetry violation in %s block #%d (missing:%s)\n  block: %s\n", fail_token, fname, block_count, missing, block
        ok = 1
      }
      block = ""
      next
    }
    { block = (block == "" ? $0 : block " " $0) }
    END {
      if (block_count == 0) {
        printf "  (no flow-state-update.sh create invocations in %s — skipping)\n", fname
      } else if (ok == 0) {
        printf "  %s %s: all %d flow-state-update.sh create invocations carry --phase/--issue/--branch/--pr/--next\n", pass_token, fname, block_count
      }
      exit ok
    }
  '
}

if check_symmetry_5arg "$START_MD"; then
  pass "5-arg symmetry: start.md flow-state-update.sh create invocations"
else
  fail "5-arg symmetry: start.md has invocations missing required flags (see awk output above)"
fi

if check_symmetry_5arg "$CREATE_MD"; then
  pass "5-arg symmetry: create.md flow-state-update.sh create invocations"
else
  fail "5-arg symmetry: create.md has invocations missing required flags (see awk output above)"
fi

echo ""
if ! print_summary "$(basename "$0")" "start.md の sentinel set を変更した場合、caller (sprint:execute / resume) の grep pattern も同時に更新する責務がある。本 test の expected_set を縮退させる前に caller 側との符号を必ず確認すること。"; then
  exit 1
fi
