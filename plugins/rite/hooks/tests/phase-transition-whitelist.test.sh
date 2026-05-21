#!/bin/bash
# phase-transition-whitelist.test.sh — CG-1 (PR #1079 verified-review)
#
# Purpose:
#   `phase-transition-whitelist.sh` の決定ロジック (rite_phase_transition_allowed /
#   rite_phase_is_known / rite_phase_expected_next) を直接 source して happy path
#   と negative path の挙動を pin する unit test。
#
#   `asymmetric-whitelist.test.sh` は静的 grep で orchestrator markdown との対称性
#   のみを検出する。本 test は transition logic の正確性 (typo / 新 phase 追加忘れ /
#   terminal accept の forward-compat 範囲) を assert することで、PR #1079 の flat
#   workflow 9 phase が将来 refactor でも壊れないようにする防衛線。
#
# Coverage areas:
#   1. Happy path: 新 flat workflow 9 phase の正規遷移
#   2. Negative path: phase skip / 不正遷移は block される
#   3. Legacy forward-compat: unknown prev は accept される (fail-open)
#   4. Terminal accept: completed / cleanup_completed / ingest_completed は accept
#   5. rite_phase_is_known: 既知 phase 名の判定
#   6. Cleanup / Ingest lifecycle: 既存の create_* / cleanup_* / ingest_* リング
#
# When this test fails:
#   whitelist 配列 (_RITE_PHASE_TRANSITIONS) を修正する場合、本 test も同時に更新する。
#   transition logic の意図的変更時は assert 行を実装に追従させ、意図せざる変更時は
#   実装側を巻き戻す。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
WHITELIST_SH="$PLUGIN_ROOT/hooks/phase-transition-whitelist.sh"

if [ ! -f "$WHITELIST_SH" ]; then
  echo "ERROR: $WHITELIST_SH not found" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$WHITELIST_SH"

# Helper: assert that rite_phase_transition_allowed returns 0 (allowed) for given prev/next
assert_allowed() {
  local label="$1" prev="$2" next="$3"
  if rite_phase_transition_allowed "$prev" "$next"; then
    pass "$label"
  else
    fail "$label (expected allowed, got blocked: '$prev' → '$next')"
  fi
}

# Helper: assert that rite_phase_transition_allowed returns non-0 (blocked) for given prev/next
assert_blocked() {
  local label="$1" prev="$2" next="$3"
  if rite_phase_transition_allowed "$prev" "$next"; then
    fail "$label (expected blocked, got allowed: '$prev' → '$next')"
  else
    pass "$label"
  fi
}

echo "=== Phase 1: Happy path (new flat workflow 9 phases) ==="
assert_allowed "TC-01 cold-start (empty → init)" "" "init"
assert_allowed "TC-02 init → branch" "init" "branch"
assert_allowed "TC-03 branch → plan" "branch" "plan"
assert_allowed "TC-04 plan → implement" "plan" "implement"
assert_allowed "TC-05 implement → lint" "implement" "lint"
assert_allowed "TC-06 lint → pr" "lint" "pr"
assert_allowed "TC-07 pr → review" "pr" "review"
assert_allowed "TC-08 review → fix" "review" "fix"
assert_allowed "TC-09 fix → review (loop)" "fix" "review"
assert_allowed "TC-10 review → pr (re-PR after review pass)" "review" "pr"

echo ""
echo "=== Phase 2: Terminal accept (forward-compat) ==="
assert_allowed "TC-20 lint → completed" "lint" "completed"
assert_allowed "TC-21 pr → completed" "pr" "completed"
assert_allowed "TC-22 review → completed" "review" "completed"
assert_allowed "TC-23 fix → completed" "fix" "completed"
assert_allowed "TC-24 cleanup_post_ingest → cleanup_completed" "cleanup_post_ingest" "cleanup_completed"
assert_allowed "TC-25 ingest_post_lint → ingest_completed" "ingest_post_lint" "ingest_completed"

echo ""
echo "=== Phase 3: Self-loop (same prev/next) ==="
assert_allowed "TC-30 lint → lint (re-invoke)" "lint" "lint"
assert_allowed "TC-31 implement → implement" "implement" "implement"

echo ""
echo "=== Phase 4: Negative path — phase skipping ==="
assert_blocked "TC-40 init → review (skips 4 phases)" "init" "review"
assert_blocked "TC-41 plan → completed via non-terminal target 'review'" "plan" "review"
# NOTE: init → completed / pr → completed 等の terminal accept は forward-compat で allow される。
# protocol violation の観測性は RITE_DEBUG=1 経由で確認する (TC-101 参照)。

echo ""
echo "=== Phase 5: rite_phase_is_known ==="
if rite_phase_is_known "init"; then
  pass "TC-50 init is known"
else
  fail "TC-50 init should be known"
fi
if rite_phase_is_known "lint"; then
  pass "TC-51 lint is known"
else
  fail "TC-51 lint should be known"
fi
if rite_phase_is_known "completed"; then
  pass "TC-52 completed is known"
else
  fail "TC-52 completed should be known"
fi
if rite_phase_is_known "phase5_post_review"; then
  fail "TC-53 phase5_post_review (legacy) should NOT be known in flat enum"
else
  pass "TC-53 phase5_post_review is unknown (legacy retired)"
fi
if rite_phase_is_known "totally_made_up_phase"; then
  fail "TC-54 typo phase should NOT be known"
else
  pass "TC-54 typo phase is unknown"
fi

echo ""
echo "=== Phase 6: Legacy forward-compat (unknown prev → accept) ==="
# Unknown prev phase (e.g. typo) currently accepts forward-compat. This is documented
# behavior — RITE_DEBUG=1 should log a WARNING (see SF-7 fix).
assert_allowed "TC-60 unknown prev 'typo_phase' → branch (forward-compat)" "typo_phase" "branch"
assert_allowed "TC-61 unknown prev 'phase5_legacy' → lint (legacy carry-over)" "phase5_legacy" "lint"

echo ""
echo "=== Phase 7: Cleanup lifecycle (PR cleanup helper) ==="
assert_allowed "TC-70 cleanup_pre_ingest → cleanup_post_ingest" "cleanup_pre_ingest" "cleanup_post_ingest"
assert_allowed "TC-71 cleanup_post_ingest → cleanup_completed" "cleanup_post_ingest" "cleanup_completed"

echo ""
echo "=== Phase 8: Ingest lifecycle (Wiki) ==="
assert_allowed "TC-80 ingest_pre_lint → ingest_post_lint" "ingest_pre_lint" "ingest_post_lint"
assert_allowed "TC-81 ingest_post_lint → ingest_completed" "ingest_post_lint" "ingest_completed"

echo ""
echo "=== Phase 9: rite_phase_expected_next (printf 'allowed' set) ==="
expected_init="$(rite_phase_expected_next "init")"
if [ -z "$expected_init" ]; then
  fail "TC-90 expected_next('init') should not be empty"
else
  pass "TC-90 expected_next('init') = '$expected_init' (non-empty)"
fi
expected_lint="$(rite_phase_expected_next "lint")"
case "$expected_lint" in
  *pr*) pass "TC-91 expected_next('lint') contains 'pr'" ;;
  *) fail "TC-91 expected_next('lint') = '$expected_lint' should contain 'pr'" ;;
esac

echo ""
echo "=== Phase 10: RITE_DEBUG=1 observability (SF-6 / SF-7) ==="
# Spawn a subshell with RITE_DEBUG=1 so the parent's variable doesn't leak.
debug_out=$(RITE_DEBUG=1 bash -c "
  set -e
  source '$WHITELIST_SH'
  rite_phase_transition_allowed 'typo_phase' 'branch' 2>&1 >/dev/null
") || true
case "$debug_out" in
  *unknown-prev-accept*) pass "TC-100 RITE_DEBUG=1 emits 'unknown-prev-accept' for typo prev" ;;
  *) fail "TC-100 RITE_DEBUG=1 should emit unknown-prev-accept warning (got: $debug_out)" ;;
esac

debug_out2=$(RITE_DEBUG=1 bash -c "
  set -e
  source '$WHITELIST_SH'
  rite_phase_transition_allowed 'init' 'completed' 2>&1 >/dev/null
") || true
case "$debug_out2" in
  *terminal-accept*) pass "TC-101 RITE_DEBUG=1 emits 'terminal-accept' WARN for non-canonical predecessor" ;;
  *) fail "TC-101 RITE_DEBUG=1 should emit terminal-accept warning for init → completed (got: $debug_out2)" ;;
esac

# Canonical lint → completed should NOT warn under RITE_DEBUG=1
debug_out3=$(RITE_DEBUG=1 bash -c "
  set -e
  source '$WHITELIST_SH'
  rite_phase_transition_allowed 'lint' 'completed' 2>&1 >/dev/null
") || true
case "$debug_out3" in
  *terminal-accept*) fail "TC-102 canonical lint → completed should NOT emit terminal-accept warning (got: $debug_out3)" ;;
  *) pass "TC-102 canonical lint → completed is silent under RITE_DEBUG=1" ;;
esac

echo ""
if ! print_summary "$(basename "$0")" "phase-transition-whitelist.sh の transition decision logic に変更を加えた場合、本 test を同時に更新すること"; then
  exit 1
fi
