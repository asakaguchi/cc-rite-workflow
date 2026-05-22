#!/bin/bash
# phase-transition-whitelist.test.sh
#
# Source `phase-transition-whitelist.sh` directly and pin its decision logic
# (rite_phase_transition_allowed / rite_phase_is_known / rite_phase_expected_next).
# Companion to `asymmetric-whitelist.test.sh`: that one detects symmetry drift
# between orchestrator markdown and the whitelist via static grep; this one
# guards against typos, missing phase additions, and over-broad terminal-accept
# forward-compat rules.
#
# Coverage areas:
#   1. Happy path: canonical transitions through the 9 flat-workflow phases
#   2. Negative path: phase skips and invalid transitions are blocked
#   3. Legacy forward-compat: unknown prev phases are accepted (fail-open)
#   4. Terminal accept: completed / cleanup_completed / ingest_completed
#   5. rite_phase_is_known: known phase name predicate
#   6. Cleanup / Ingest lifecycle: existing create_* / cleanup_* / ingest_* rings
#
# When this test fails: update both the assertion and the whitelist together.
# Intentional logic changes should land as paired diffs; unintentional ones
# mean the implementation regressed and should be reverted.

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
# Terminal acceptance is restricted to the canonical predecessor set
# (lint/pr/review/fix → completed; cleanup_pre/post_ingest → cleanup_completed;
# ingest_pre/post_lint → ingest_completed). Phase-skip patterns such as
# init → completed are blocked (TC-103); canonical patterns such as
# pr → completed are allowed (TC-104).

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

# Legacy phase prefixes from earlier sub-skill chains must still reach terminal
# `completed`. Without these assertions, removing the case-glob in
# phase-transition-whitelist.sh would silently break `/rite:resume` for users with
# in-flight pre-flat state files.
assert_allowed "TC-62 legacy 'phase5_post_review' → completed (terminal forward-compat)" "phase5_post_review" "completed"
assert_allowed "TC-63 legacy 'phase3_lint' → completed (terminal forward-compat)" "phase3_lint" "completed"
assert_allowed "TC-64 legacy 'create_in_review' → completed (terminal forward-compat)" "create_in_review" "completed"
assert_allowed "TC-65 legacy 'start_branch_setup' → completed (terminal forward-compat)" "start_branch_setup" "completed"

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

# Terminal accept is restricted to canonical predecessors; init → completed
# must be blocked (return 1) and emit an ERROR rather than silently passing.
debug_out2=$(RITE_DEBUG=1 bash -c "
  set -e
  source '$WHITELIST_SH'
  rite_phase_transition_allowed 'init' 'completed' 2>&1 >/dev/null || true
") || true
case "$debug_out2" in
  *terminal-accept\ rejected*|*phase-transition*) pass "TC-101 RITE_DEBUG=1 emits ERROR for non-canonical init → completed" ;;
  *) fail "TC-101 RITE_DEBUG=1 should emit terminal-accept rejected ERROR for init → completed (got: $debug_out2)" ;;
esac

# Canonical lint → completed should NOT warn (clean accept path)
debug_out3=$(RITE_DEBUG=1 bash -c "
  set -e
  source '$WHITELIST_SH'
  rite_phase_transition_allowed 'lint' 'completed' 2>&1 >/dev/null
") || true
case "$debug_out3" in
  *terminal-accept*|*ERROR*) fail "TC-102 canonical lint → completed should NOT emit any warning (got: $debug_out3)" ;;
  *) pass "TC-102 canonical lint → completed is silent under RITE_DEBUG=1" ;;
esac

# TC-103 — H-3 strictification: init → completed must be blocked (return 1)
if RITE_DEBUG=0 bash -c "source '$WHITELIST_SH'; rite_phase_transition_allowed 'init' 'completed'" 2>/dev/null; then
  fail "TC-103 init → completed should be blocked (H-3 canonical predecessor 縮退)"
else
  pass "TC-103 init → completed is blocked (H-3 canonical predecessor 縮退)"
fi

# TC-104 — H-3: pr → completed must be allowed (canonical)
if RITE_DEBUG=0 bash -c "source '$WHITELIST_SH'; rite_phase_transition_allowed 'pr' 'completed'" 2>/dev/null; then
  pass "TC-104 pr → completed is allowed (canonical predecessor)"
else
  fail "TC-104 pr → completed should be allowed (canonical predecessor)"
fi

echo ""
echo "=== Phase 11: _rite_load_whitelist_overrides coverage ==="
# Test the override loader by creating a temporary rite-config.yml with inline / block list forms.
override_tmpdir=$(mktemp -d)
trap 'rm -rf "$override_tmpdir"' EXIT

# TC-200 — inline list form
mkdir -p "$override_tmpdir/inline-list"
cat > "$override_tmpdir/inline-list/rite-config.yml" <<'YAML'
hooks:
  stop_guard:
    phase_transitions:
      custom_phase_x: [foo, bar]
YAML
override_out=$(RITE_CONFIG="$override_tmpdir/inline-list/rite-config.yml" bash -c "
  set -e
  source '$WHITELIST_SH'
  declare -p _RITE_PHASE_TRANSITIONS 2>/dev/null | tr -d '\n'
" 2>&1) || true
case "$override_out" in
  *'[custom_phase_x]="foo bar"'*|*'[custom_phase_x]="foo bar "'*) pass "TC-200 inline list form merged into _RITE_PHASE_TRANSITIONS" ;;
  # A fall-through `pass` would let "loader didn't crash" silently regress the
  # merge semantics. Fail loudly so the assertion has real teeth.
  *) fail "TC-200 expected '[custom_phase_x]=\"foo bar\"' in override output but loader produced: ${override_out:0:200}" ;;
esac

# TC-201 — block list form
mkdir -p "$override_tmpdir/block-list"
cat > "$override_tmpdir/block-list/rite-config.yml" <<'YAML'
hooks:
  stop_guard:
    phase_transitions:
      custom_phase_y:
        - alpha
        - beta
YAML
# TC-201 — block list form. Inspect _RITE_PHASE_TRANSITIONS after sourcing so a
# silently-skipped block-list parser fails the test instead of passing on "OK".
override_out=$(RITE_CONFIG="$override_tmpdir/block-list/rite-config.yml" bash -c "
  set -e
  source '$WHITELIST_SH'
  declare -p _RITE_PHASE_TRANSITIONS | tr -d '\n'
" 2>&1) || true
case "$override_out" in
  *'[custom_phase_y]="alpha beta"'*) pass "TC-201 block list parser merged custom_phase_y → 'alpha beta'" ;;
  *) fail "TC-201 block list parser did NOT merge custom_phase_y: $override_out" ;;
esac

# TC-202 — comment lines tolerated. Same inspection approach: confirm the
# parsed value made it into the array, not just that sourcing didn't crash.
mkdir -p "$override_tmpdir/with-comments"
cat > "$override_tmpdir/with-comments/rite-config.yml" <<'YAML'
hooks:
  stop_guard:
    phase_transitions:
      # comment line
      custom_phase_z: [a]  # inline comment
YAML
override_out=$(RITE_CONFIG="$override_tmpdir/with-comments/rite-config.yml" bash -c "
  set -e
  source '$WHITELIST_SH'
  declare -p _RITE_PHASE_TRANSITIONS | tr -d '\n'
" 2>&1) || true
case "$override_out" in
  *'[custom_phase_z]="a"'*) pass "TC-202 commented YAML loader merged custom_phase_z → 'a'" ;;
  *) fail "TC-202 commented YAML loader did NOT merge custom_phase_z: $override_out" ;;
esac

echo ""
echo "=== Phase 12: Additional transition coverage ==="
# 既存 TC は happy path 中心。fix → pr / lint → review / non-init terminal block の 3 種を補完する。

# TC-300 — fix → pr (fix 後に review を経ずに PR 直行できる canonical 経路)
assert_allowed "TC-300 fix → pr (fix サイクル後の re-PR)" "fix" "pr"

# TC-301 — lint → review (lint skip 経路で review に直行できる alternate canonical)
assert_allowed "TC-301 lint → review (lint skip ルート)" "lint" "review"

# TC-302 — plan → completed must be blocked (H-3 canonical predecessor 縮退、init 以外も同じ block)
if RITE_DEBUG=0 bash -c "source '$WHITELIST_SH'; rite_phase_transition_allowed 'plan' 'completed'" 2>/dev/null; then
  fail "TC-302 plan → completed should be blocked (non-canonical predecessor)"
else
  pass "TC-302 plan → completed is blocked (non-canonical predecessor)"
fi

# TC-303 — branch → completed must be blocked (同上)
if RITE_DEBUG=0 bash -c "source '$WHITELIST_SH'; rite_phase_transition_allowed 'branch' 'completed'" 2>/dev/null; then
  fail "TC-303 branch → completed should be blocked (non-canonical predecessor)"
else
  pass "TC-303 branch → completed is blocked (non-canonical predecessor)"
fi

# TC-304 — implement → completed must be blocked (同上、lint / pr / review / fix のみが canonical)
if RITE_DEBUG=0 bash -c "source '$WHITELIST_SH'; rite_phase_transition_allowed 'implement' 'completed'" 2>/dev/null; then
  fail "TC-304 implement → completed should be blocked (non-canonical predecessor)"
else
  pass "TC-304 implement → completed is blocked (non-canonical predecessor)"
fi

echo ""
echo "=== Phase 13: bash < 4.2 fail-open simulation ==="
# macOS ships bash 3.2 by default; the production script's BASH_VERSINFO guard
# at line 39 short-circuits the associative-array load with a WARNING and
# `return 0`. None of the tests above exercise this branch — a future refactor
# that switches `return 0` to `exit 1` would silently break macOS callers
# (`source phase-transition-whitelist.sh 2>/dev/null || true` would abort the
# caller process instead of falling through), and a removed WARNING would make
# the silent disable indistinguishable from "validation passing".
#
# Approach: copy the script into a sandbox and rewrite the `BASH_VERSINFO`
# guard to `if true` so the fail-open branch fires unconditionally. Source the
# rewritten copy and assert (a) WARNING text on stderr, (b) graceful return
# (the caller's `echo` after `source` still runs), (c) function undefined
# afterward.
sandbox_bash32=$(mktemp -d 2>/dev/null) || sandbox_bash32=""
if [ -n "$sandbox_bash32" ]; then
  sandbox_script="$sandbox_bash32/phase-transition-whitelist.sh"
  # Replace the `if ((BASH_VERSINFO...))` line with `if true;` so the rest of
  # the production behaviour (WARNING + return 0) runs unmodified.
  sed -E 's|^if \(\(BASH_VERSINFO.*\)\); then$|if true; then|' "$WHITELIST_SH" > "$sandbox_script"

  # TC-BASH32-01: WARNING text is on stderr
  bash32_out=$(bash -c "source '$sandbox_script'; echo POST_SOURCE_REACHED" 2>"$sandbox_bash32/stderr") || true
  bash32_stderr=$(cat "$sandbox_bash32/stderr")
  if printf '%s' "$bash32_stderr" | grep -qE 'phase-transition-whitelist disabled.*requires bash >= 4\.2'; then
    pass "TC-BASH32-01 WARNING text emitted on bash<4.2 fail-open path"
  else
    fail "TC-BASH32-01 WARNING text missing — silent disable regression: $bash32_stderr"
  fi

  # TC-BASH32-02: graceful return (caller's POST_SOURCE_REACHED still runs)
  if printf '%s' "$bash32_out" | grep -qF 'POST_SOURCE_REACHED'; then
    pass "TC-BASH32-02 graceful return 0 — caller continues after source"
  else
    fail "TC-BASH32-02 fail-open path aborted caller (return changed to exit?): out='$bash32_out' stderr='$bash32_stderr'"
  fi

  # TC-BASH32-03: rite_phase_transition_allowed is undefined after fail-open
  type_check=$(bash -c "source '$sandbox_script' 2>/dev/null; type rite_phase_transition_allowed >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED") || true
  if [ "$type_check" = "UNDEFINED" ]; then
    pass "TC-BASH32-03 rite_phase_transition_allowed undefined after fail-open (callers must fall through)"
  else
    fail "TC-BASH32-03 function unexpectedly defined after fail-open: $type_check"
  fi

  rm -rf "$sandbox_bash32"
else
  fail "TC-BASH32 sandbox mktemp -d failed; cannot exercise fail-open"
fi

echo ""
if ! print_summary "$(basename "$0")" "phase-transition-whitelist.sh の transition decision logic に変更を加えた場合、本 test を同時に更新すること"; then
  exit 1
fi
