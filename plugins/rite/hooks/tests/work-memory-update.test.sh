#!/bin/bash
# Tests for hooks/work-memory-update.sh — caller-side AC-4 migration verification (PR #688).
#
# Covers Issue #687 acceptance criteria from caller perspective:
#   AC-4 — caller (work-memory-update.sh) integrates with flow-state.sh transparently:
#          (TC-1) schema_version=2 + per-session file present + legacy absent + WM_REQUIRE_FLOW_STATE=true
#                 → return 0 with WM updated (cycle 12 false negative regression guard)
#          (TC-2) schema_version=2 + both files absent + WM_REQUIRE_FLOW_STATE=true
#                 → return 1 (skip, no WM written)
#          (TC-3) WM_READ_FROM_FLOW_STATE=true + per-session file with pr_number=100/loop_count=3
#                 → generated WM frontmatter contains pr_number: 100 / loop_count: 3
#                 (cycle 10 stale residue regression guard)
#   AC-7 — regression test discoverable under hooks/tests/
#
# Removed (PR 2a refactor, v3 SoT):
#   (TC-4) schema_version=1 + legacy `.rite-flow-state` file present — the
#          legacy single-file path was retired in Phase E (commit bf5a2415);
#          v1/v2 files are now one-shot migrated to v3 per-session form by
#          flow-state.sh migrate at session-start, not handled inline by
#          work-memory-update.sh.
#
# Usage: bash plugins/rite/hooks/tests/work-memory-update.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/../work-memory-update.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: work-memory-update.sh missing: $HELPER" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not installed" >&2
  exit 1
fi

# Issue #990: source common helpers for make_sandbox.
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

cleanup_dirs=()
_wm_update_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0  # Form B (portability variant) → return 0 必須 (bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照)
}
trap '_wm_update_test_cleanup' EXIT
trap '_wm_update_test_cleanup; exit 130' INT
trap '_wm_update_test_cleanup; exit 143' TERM
trap '_wm_update_test_cleanup; exit 129' HUP

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

assert_contains() {
  local name="$1" expected_substring="$2" actual="$3"
  if [[ "$actual" == *"$expected_substring"* ]]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected substring: $expected_substring"
    echo "     actual:             $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# Issue #990: make_sandbox is now provided by _test-helpers.sh; callers below
# invoke `make_sandbox --branch fix/issue-687-test` to preserve the
# branch-based issue-number extraction path validated by TC-1.
# The fix/issue-687-test branch name is the SoT for EXPECTED_ISSUE_NUM=687
# below (any branch rename would require both call sites to sync).

write_config_v2() {
  cat > "$1/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
}

write_config_v1() {
  cat > "$1/rite-config.yml" <<EOF
flow_state:
  schema_version: 1
EOF
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

write_per_session() {
  mkdir -p "$1/.rite/sessions"
  printf '%s' "$3" > "$1/.rite/sessions/${2}.flow-state"
}

write_legacy() {
  printf '%s' "$2" > "$1/.rite-flow-state"
}

run_update() {
  local d="$1"
  shift
  # 残りの引数 (KEY=VALUE 形式) を env に渡し、その後 bash -c で関数を呼ぶ
  (cd "$d" && env WM_PLUGIN_ROOT="$PLUGIN_ROOT" "$@" bash -c \
    'source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh" && update_local_work_memory')
}

# --- TC-1: schema_version=2 + per-session present + legacy absent + WM_REQUIRE_FLOW_STATE=true ---
# cycle 12 fix の core invariant: WM_REQUIRE_FLOW_STATE check が legacy file 直接 [ -f ] check ではなく
# flow-state.sh 経由になったので per-session のみで skip しない
echo "TC-1: schema_v=2 + per-session present + legacy absent + WM_REQUIRE_FLOW_STATE=true → return 0 (cycle 12 false negative regression guard)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":42,"loop_count":2,"active":true}'
# legacy は意図的に作成しない (per-session only path)

# PR #688 cycle 16 fix (F-01 MEDIUM cross-validated 3 reviewers): TC-1.2 dead code 削除。
# work-memory-update.sh の update_local_work_memory 関数内の branch-based issue_number 抽出
# (`grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+'` chain) は数字のみ抽出するため、
# branch=fix/issue-687-test では生成 file 名は issue-687.md (not 687-test)。
# 旧実装は issue-687-test.md を期待する dead if 分岐を持ち、常に else 経路 (WM_ISSUE_NUMBER override)
# が実行されていた。これを branch-based extraction の直接 assert に修正する。
# branch-based extraction の直接検証 (cycle 12 false negative regression guard):
# `make_sandbox --branch fix/issue-687-test` が指定の branch を作るため、branch parsing が `687`
# を抽出して `.rite-work-memory/issue-687.md` を生成することを確認する。
#
# PR #688 followup F-06 LOW (branch-name coupling 軽減): make_sandbox 呼び出しで渡している
# `--branch fix/issue-687-test` 引数と本 TC の assertion で参照する issue 番号 (687) を local var
# で 1 か所に集約。Issue #990 cycle 3 F-01: make_sandbox は _test-helpers.sh の共通 helper に
# 集約されたため、コメントの「関数内」は誤り — call site の `--branch` 引数が SoT。
# branch 名を変更する場合は本 var と make_sandbox --branch 引数の両方を同期更新する。
EXPECTED_ISSUE_NUM=687  # make_sandbox --branch 引数 "fix/issue-687-test" (下記 call site 参照) から抽出される値 (branch 名を変更する場合は本 var と --branch 引数の両方を同期更新)
if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_REQUIRE_FLOW_STATE="true"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-1.1: return 0 (per-session resolved via flow-state.sh, branch parsing extracts ${EXPECTED_ISSUE_NUM})" "0" "$rc"
assert_eq "TC-1.2: WM file created via branch parsing (issue-${EXPECTED_ISSUE_NUM}.md)" "yes" \
  "$([ -f "$SBX/.rite-work-memory/issue-${EXPECTED_ISSUE_NUM}.md" ] && echo yes || echo no)"

# --- TC-2: schema_version=2 + both files absent + WM_REQUIRE_FLOW_STATE=true ---
echo "TC-2: schema_v=2 + per-session/legacy 両不在 + WM_REQUIRE_FLOW_STATE=true → return 1 (skip)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
write_session_id "$SBX" "22222222-2222-2222-2222-222222222222"
# per-session は作成しない、legacy も作成しない

if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_REQUIRE_FLOW_STATE="true" WM_ISSUE_NUMBER="687"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-2.1: return 1 (両 file 不在で skip)" "1" "$rc"
assert_eq "TC-2.2: WM file NOT created" "no" \
  "$([ -f "$SBX/.rite-work-memory/issue-687.md" ] && echo yes || echo no)"

# --- TC-3: WM_READ_FROM_FLOW_STATE=true + per-session has pr_number/loop_count ---
echo "TC-3: schema_v=2 + per-session pr_number=100 loop_count=3 + WM_READ_FROM_FLOW_STATE=true → frontmatter 反映 (cycle 10 stale residue regression guard)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":100,"loop_count":3,"active":true}'
# legacy には別の値を入れて per-session 優先を確認
write_legacy "$SBX" '{"phase":"stale","next_action":"stale","pr_number":999,"loop_count":99,"active":false}'

if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_READ_FROM_FLOW_STATE="true" WM_ISSUE_NUMBER="687"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-3.1: return 0" "0" "$rc"
WM_FILE="$SBX/.rite-work-memory/issue-687.md"
if [ -f "$WM_FILE" ]; then
  body=$(cat "$WM_FILE")
  assert_contains "TC-3.2: pr_number=100 (per-session 値、legacy 999 を override)" "pr_number: 100" "$body"
  assert_contains "TC-3.3: loop_count=3 (per-session 値、legacy 99 を override)" "loop_count: 3" "$body"
else
  echo "  ❌ TC-3.2/3.3: WM file not created at $WM_FILE"
  FAIL=$((FAIL+2))
  FAILED_NAMES+=("TC-3.2" "TC-3.3")
fi

# TC-4 removed (PR 2a refactor): schema_version=1 + legacy file path is no
# longer reachable. flow-state.sh always writes / reads per-session files at
# `.rite/sessions/<sid>.flow-state`; the legacy single-file form is gone.
# Backward compat for legacy state has migrated to flow-state.sh migrate
# (one-shot v1/v2 → v3 conversion at session-start), not to a parallel
# read path inside work-memory-update.sh.

echo
echo "─── work-memory-update.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All tests passed."
