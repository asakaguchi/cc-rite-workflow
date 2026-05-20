#!/bin/bash
# Static tests for Issue #1003 AC-4: workflow_incident sentinel emit on
# projects-status-update.sh failed / skipped_not_in_project (silent skip 禁止).
#
# Verifies:
#   T-4a: workflow-incident-emit.sh accepts the new types
#   T-4b: workflow-incident-emit.sh rejects an unknown type
#   T-4c: ready.md, start-finalize.md, callsites.md, start.md, post-compact.sh all
#         contain the canonical emit bash literals
#   T-4d: emitted sentinel format matches Phase 5.4.4.1 grep pattern
#
# Usage: bash plugins/rite/hooks/tests/projects-status-incident-emit.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WIE_SH="$REPO_ROOT/plugins/rite/hooks/workflow-incident-emit.sh"
READY_MD="$REPO_ROOT/plugins/rite/commands/pr/ready.md"
FINALIZE_MD="$REPO_ROOT/plugins/rite/commands/issue/start-finalize.md"
START_MD="$REPO_ROOT/plugins/rite/commands/issue/start.md"
CALLSITES_MD="$REPO_ROOT/plugins/rite/commands/issue/references/projects-status-update-callsites.md"
POST_COMPACT_SH="$REPO_ROOT/plugins/rite/hooks/post-compact.sh"

PASS=0
FAIL=0
FAILURES=()

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (file: $(basename "$file"), pattern: $pattern)")
    echo "  ✗ $description" >&2
  fi
}

assert_cmd() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (cmd: $*)")
    echo "  ✗ $description" >&2
  fi
}

echo "=== T-04: Projects Status incident emit guards (Issue #1003 AC-4) ==="

# Prerequisite: all files exist
for f in "$WIE_SH" "$READY_MD" "$FINALIZE_MD" "$START_MD" "$CALLSITES_MD" "$POST_COMPACT_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

echo ""
echo "[T-04a] workflow-incident-emit.sh accepts new types"
assert_cmd "Accepts --type projects_status_update_failed" \
  bash "$WIE_SH" --type projects_status_update_failed --details "test" --pr-number 0
assert_cmd "Accepts --type projects_status_in_review_missing" \
  bash "$WIE_SH" --type projects_status_in_review_missing --details "test" --pr-number 0

echo ""
echo "[T-04b] workflow-incident-emit.sh rejects unknown type"
if bash "$WIE_SH" --type bogus_invalid_type --details "test" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  FAILURES+=("workflow-incident-emit.sh should reject bogus type")
  echo "  ✗ workflow-incident-emit.sh should reject bogus type" >&2
else
  PASS=$((PASS + 1))
  echo "  ✓ workflow-incident-emit.sh rejects bogus type"
fi

echo ""
echo "[T-04c] Canonical emit literals are present in caller files"
assert_file_contains "$READY_MD" 'workflow-incident-emit\.sh.*projects_status_update_failed' \
  "ready.md Phase 4.2 contains projects_status_update_failed emit"
assert_file_contains "$READY_MD" 'silent skip 禁止' \
  "ready.md documents the silent-skip-禁止 contract"

assert_file_contains "$FINALIZE_MD" 'projects_status_update_failed' \
  "start-finalize.md Phase 5.5.1 contains projects_status_update_failed type"
assert_file_contains "$FINALIZE_MD" 'workflow-incident-emit\.sh' \
  "start-finalize.md contains workflow-incident-emit.sh invocation"
assert_file_contains "$FINALIZE_MD" 'projects_status_in_review_missing' \
  "start-finalize.md Workflow Termination contains projects_status_in_review_missing"

assert_file_contains "$START_MD" 'projects_status_in_review_missing' \
  "start.md Mandatory After 5.5-Termination contains projects_status_in_review_missing"

assert_file_contains "$CALLSITES_MD" 'workflow-incident-emit' \
  "callsites.md Common contract names workflow-incident-emit"
assert_file_contains "$CALLSITES_MD" 'Issue #1003 AC-4' \
  "callsites.md Common contract references Issue #1003 AC-4"

assert_file_contains "$POST_COMPACT_SH" 'projects_status_in_review_missing' \
  "post-compact.sh emits projects_status_in_review_missing on reconcile failure"

echo ""
echo "[T-04d] Sentinel output format matches Phase 5.4.4.1 grep"
# Capture actual sentinel and verify format
sentinel=$(bash "$WIE_SH" --type projects_status_update_failed --details "test_detail" --pr-number 42 2>/dev/null)
if printf '%s' "$sentinel" | grep -qE '^\[CONTEXT\] WORKFLOW_INCIDENT=1; type=projects_status_update_failed; details=test_detail; iteration_id=42-[0-9]+'; then
  PASS=$((PASS + 1))
  echo "  ✓ Emitted sentinel matches Phase 5.4.4.1 grep pattern"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("Sentinel format mismatch: $sentinel")
  echo "  ✗ Sentinel format mismatch: $sentinel" >&2
fi

# Verify root_cause_hint variant
sentinel_with_hint=$(bash "$WIE_SH" --type projects_status_in_review_missing --details "test" --root-cause-hint "hint_x" --pr-number 1 2>/dev/null)
if printf '%s' "$sentinel_with_hint" | grep -qE 'root_cause_hint=hint_x;'; then
  PASS=$((PASS + 1))
  echo "  ✓ root_cause_hint variant emitted correctly"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("root_cause_hint variant: $sentinel_with_hint")
  echo "  ✗ root_cause_hint variant: $sentinel_with_hint" >&2
fi

echo ""
echo "[T-04e] start-finalize.md & ready.md case logical completeness (cycle 10 F-01 / F-07 / Issue #1009)"
# Regression guard for cycle 9 CRITICAL bug: start-finalize.md case "$status_result" was missing
# `updated)` arm, causing success path (status_result=updated) to fall-through to failed|*) catchall
# and emit false-positive projects_status_update_failed sentinel.
#
# Issue #1009: previous patterns 'updated\)' / 'skipped_not_in_project\)' / 'failed\|\*\)' matched
# docstring occurrences (e.g., `(status_result=updated)`) as false-positives — pattern hit 4 sites in
# start-finalize.md (3 docstring + 1 actual case arm), so deleting the actual case arm would still
# leave the test passing via docstring matches. Anchor patterns at blockquote-prefix + whitespace
# (`^>[[:space:]]+`) to pin **case arms only** (case arms live inside `> ` blockquote bash blocks
# in both files). Cross-file coverage: assert symmetric 3-arm structure in **both** start-finalize.md
# (Phase 5.5.1) and ready.md (Phase 4.2 minimal skeleton) per Wiki cross-file-cross-site-coverage
# canonical (PR #1066). Mutation-verified: deleting any case arm now fails the corresponding assert
# (was silent-pass before this fix).
assert_file_contains "$FINALIZE_MD" '^>[[:space:]]+updated\)' \
  "start-finalize.md Phase 5.5.1 case arm: updated) (anchored, cycle 10 F-01 / Issue #1009 regression guard)"
assert_file_contains "$FINALIZE_MD" '^>[[:space:]]+skipped_not_in_project\)' \
  "start-finalize.md Phase 5.5.1 case arm: skipped_not_in_project) (anchored)"
assert_file_contains "$FINALIZE_MD" '^>[[:space:]]+failed\|\*\)' \
  "start-finalize.md Phase 5.5.1 case arm: failed|*) catchall (anchored)"
assert_file_contains "$READY_MD" '^>[[:space:]]+updated\)' \
  "ready.md Phase 4.2 case arm: updated) (anchored, Issue #1009 cross-file symmetric coverage)"
assert_file_contains "$READY_MD" '^>[[:space:]]+skipped_not_in_project\)' \
  "ready.md Phase 4.2 case arm: skipped_not_in_project) (anchored)"
assert_file_contains "$READY_MD" '^>[[:space:]]+failed\|\*\)' \
  "ready.md Phase 4.2 case arm: failed|*) catchall (anchored)"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
echo "All projects-status incident emit checks passed."
