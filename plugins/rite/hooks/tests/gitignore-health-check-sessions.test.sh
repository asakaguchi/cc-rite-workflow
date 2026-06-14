#!/bin/bash
# Tests for gitignore-health-check.sh always-on .rite/sessions/ check.
#
# Verifies the non-blocking, ALWAYS-ON `.rite/sessions/` ignore check folded into
# gitignore-health-check.sh. Unlike the `.rite/worktrees/` check (gated on
# multi_session.enabled), per-session state files (.rite/sessions/{session_id}.flow-state)
# are written on every rite session, so this check is NOT gated:
#   - .rite/sessions/ NOT ignored                       → drift (exit 1)
#   - .rite/sessions/ ignored                            → healthy (exit 0)
#   - multi_session.enabled=false + sessions NOT ignored → still drift (NOT gated on multi_session)
#   - wiki.enabled=false + sessions NOT ignored          → still drift (runs BEFORE wiki early-exits)
#   - sessions check fires before the .rite/worktrees/ check (independent leak surface)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

GHC="$SCRIPT_DIR/../scripts/gitignore-health-check.sh"

cleanup_dirs=()
# `return 0` so an empty array (loop body `[ -n "" ]` → rc 1) does not become the
# script exit code via the EXIT trap (bash propagates the trap's last rc).
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# Build a sandbox repo with a given rite-config.yml + .gitignore, run the check,
# and publish the result via globals RUN_RC / RUN_OUT. Called WITHOUT command
# substitution so `cleanup_dirs+=` lands in the parent shell (a `$(run_case ...)`
# wrapper would lose the push in the subshell and leak sandboxes).
run_case() {
  local config="$1" gitignore="$2" d
  d=$(make_sandbox)
  cleanup_dirs+=("$d")
  printf '%s' "$config" > "$d/rite-config.yml"
  printf '%s' "$gitignore" > "$d/.gitignore"
  RUN_RC=0
  RUN_OUT=$(cd "$d" && bash "$GHC" --quiet 2>&1) || RUN_RC=$?
}

WIKI_OK=$'wiki:\n  enabled: true\n  branch_strategy: separate_branch\n'
WIKI_OFF=$'wiki:\n  enabled: false\n'
MS_ON=$'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n'
MS_OFF=$'multi_session:\n  enabled: false\n'
GI_WIKI=$'.rite/wiki/\n'
GI_WIKI_SESS=$'.rite/wiki/\n.rite/sessions/\n'

echo "=== TC-1: sessions NOT ignored (ms off) → drift (exit 1) ==="
run_case "${WIKI_OK}${MS_OFF}" "$GI_WIKI"
assert "TC-1 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (sessions)"*) pass "TC-1 sessions drift message emitted" ;;
  *) fail "TC-1 sessions drift message missing: $RUN_OUT" ;;
esac

echo "=== TC-2: sessions ignored (ms off) → healthy (exit 0) ==="
run_case "${WIKI_OK}${MS_OFF}" "$GI_WIKI_SESS"
assert "TC-2 exit 0" "0" "$RUN_RC"

echo "=== TC-3: ms enabled + worktrees ignored + sessions NOT ignored → sessions drift (exit 1) ==="
# Proves the sessions check is INDEPENDENT of the worktrees check: worktrees is healthy
# here (ignored), yet the missing sessions rule still drifts. This does NOT exercise
# ordering — both checks could run in either order and worktrees would still pass. The
# strict "sessions fires before worktrees" ordering is proven separately by TC-6.
run_case "${WIKI_OK}${MS_ON}" $'.rite/wiki/\n.rite/worktrees/\n'
assert "TC-3 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (sessions)"*) pass "TC-3 sessions drift (not worktrees) emitted" ;;
  *) fail "TC-3 sessions drift message missing: $RUN_OUT" ;;
esac

echo "=== TC-4: wiki disabled + sessions NOT ignored → still drift (exit 1) ==="
# Proves the check runs BEFORE the wiki early-exits (not gated on wiki.enabled).
run_case "${WIKI_OFF}${MS_OFF}" $'# no rules\n'
assert "TC-4 exit 1 (check not gated on wiki.enabled)" "1" "$RUN_RC"

echo "=== TC-5: wiki disabled + sessions ignored → healthy (exit 0) ==="
run_case "${WIKI_OFF}${MS_OFF}" $'.rite/sessions/\n'
assert "TC-5 exit 0" "0" "$RUN_RC"

echo "=== TC-6: ms enabled + BOTH sessions and worktrees NOT ignored → sessions fires first ==="
# Genuine ordering proof: when BOTH the sessions rule AND the worktrees rule are missing
# (and multi_session is enabled so the worktrees check is active), the script must emit
# the sessions drift — NOT the multi_session/worktrees drift — because the sessions block
# runs before, and exits at, the worktrees block. If a future change moves the sessions
# block after the worktrees block, this case would emit "(multi_session)" instead and fail.
run_case "${WIKI_OK}${MS_ON}" "$GI_WIKI"
assert "TC-6 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (sessions)"*) pass "TC-6 sessions drift fires before worktrees" ;;
  *) fail "TC-6 expected sessions drift first, got: $RUN_OUT" ;;
esac

print_summary "$(basename "$0")" \
  "Drift hint: gitignore-health-check.sh always-on .rite/sessions/ check — runs before the wiki early-exits and is NOT gated on multi_session.enabled."
