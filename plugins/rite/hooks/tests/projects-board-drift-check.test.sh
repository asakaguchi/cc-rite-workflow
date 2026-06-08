#!/bin/bash
# Static + offline tests for Issue #1305: projects-board-drift-check.sh
#
# Verifies:
#   T-1: script exists and is executable
#   T-2: script syntax is valid (bash -n)
#   T-3: --help prints usage without error
#   T-4: --limit rejects non-numeric / zero (exit 2)
#   T-5: documented flags + detection logic present in source
#   T-6: config-aware no-op (projects disabled / rite-config absent) exits 0 with a
#        0-findings summary line — exercised offline, no gh required (AC-4)
#
# Usage: bash plugins/rite/hooks/tests/projects-board-drift-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DRIFT_SH="$REPO_ROOT/plugins/rite/hooks/scripts/projects-board-drift-check.sh"

PASS=0
FAIL=0
FAILURES=()

assert_file_contains() {
  local file="$1" pattern="$2" description="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1)); echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("$description (pattern: $pattern)"); echo "  ✗ $description" >&2
  fi
}

echo "=== T: projects-board-drift-check.sh (Issue #1305) ==="

echo ""
echo "[T-1] Script exists and is executable"
if [ ! -f "$DRIFT_SH" ]; then
  echo "ERROR: $DRIFT_SH not found" >&2
  exit 1
fi
if [ -x "$DRIFT_SH" ]; then
  PASS=$((PASS + 1)); echo "  ✓ projects-board-drift-check.sh is executable"
else
  FAIL=$((FAIL + 1)); FAILURES+=("script is not executable"); echo "  ✗ script is not executable" >&2
fi

echo ""
echo "[T-2] Script syntax is valid"
if bash -n "$DRIFT_SH" 2>/dev/null; then
  PASS=$((PASS + 1)); echo "  ✓ bash -n passes"
else
  FAIL=$((FAIL + 1)); FAILURES+=("bash -n failed"); echo "  ✗ bash -n failed" >&2
fi

echo ""
echo "[T-3] --help prints usage"
help_output=$(bash "$DRIFT_SH" --help 2>&1) || true
if printf '%s' "$help_output" | grep -q 'projects-board-drift-check.sh'; then
  PASS=$((PASS + 1)); echo "  ✓ --help prints usage including script name"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--help output missing script name"); echo "  ✗ --help output missing script name" >&2
fi

echo ""
echo "[T-4] --limit input validation (must exit exactly 2 = invocation error)"
# exit 2 = invocation error; exit 1 = "drift detected" (lint Phase 3.18). A bad --limit arg
# must exit exactly 2, never 1, or lint would misread a usage error as drift. Capture the exact
# code (not just non-zero). set +e around the capture so set -euo pipefail does not abort the
# harness on the script's intentional non-zero exit.
set +e; bash "$DRIFT_SH" --limit abc --quiet >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ --limit non-numeric exits 2"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--limit abc should exit 2 (got $rc)"); echo "  ✗ --limit abc should exit 2 (got $rc)" >&2
fi
set +e; bash "$DRIFT_SH" --limit 0 --quiet >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ --limit 0 exits 2"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--limit 0 should exit 2 (got $rc)"); echo "  ✗ --limit 0 should exit 2 (got $rc)" >&2
fi
# Bare trailing --limit (missing value) must exit 2 — directly guards the exit-code contract:
# without the value-presence gate, `shift 2` under set -e aborts with exit 1 (= drift warning).
set +e; bash "$DRIFT_SH" --limit >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ bare --limit (missing value) exits 2"
else
  FAIL=$((FAIL + 1)); FAILURES+=("bare --limit should exit 2 (got $rc)"); echo "  ✗ bare --limit should exit 2 (got $rc)" >&2
fi

echo ""
echo "[T-5] Documented flags + detection logic present in source"
assert_file_contains "$DRIFT_SH" '\-\-dry-run\)' "case clause handles --dry-run flag"
assert_file_contains "$DRIFT_SH" '\-\-reconcile\)' "case clause handles --reconcile flag"
assert_file_contains "$DRIFT_SH" '\-\-limit\)' "case clause handles --limit flag"
assert_file_contains "$DRIFT_SH" '\-\-quiet\)' "case clause handles --quiet flag"
assert_file_contains "$DRIFT_SH" 'Issue #1305' "header references Issue #1305"
# Detection: anchor asserts to the load-bearing jq predicates (with quotes), NOT to the header
# comments (which spell COMPLETED/Done without the jq quoting), so deleting the detection logic
# actually fails the suite. The quoted `stateReason == "COMPLETED"` predicate also pins the AC-2
# NOT_PLANNED exclusion: rewriting it to a wrong form (e.g. `!= "NOT_PLANNED"`) drops this literal.
assert_file_contains "$DRIFT_SH" 'stateReason == "COMPLETED"' "AC-2: includes only COMPLETED (NOT_PLANNED excluded)"
assert_file_contains "$DRIFT_SH" 'select.*\$st.*!= "Done"' "AC-1: drift when board Status != Done"
assert_file_contains "$DRIFT_SH" 'projectItems' "queries projectItems for board membership"
# AC-4: projects-enabled gate
assert_file_contains "$DRIFT_SH" 'PROJECTS_ENABLED' "gates on github.projects.enabled (AC-4)"
# Reconcile path reuses the shared helper (AC-3)
assert_file_contains "$DRIFT_SH" 'projects-status-update\.sh' "reconcile path reuses projects-status-update.sh (AC-3)"
# Summary line consumed by lint Phase 3.18
assert_file_contains "$DRIFT_SH" 'Total projects-board-drift findings:' "emits lint-consumable summary line"

echo ""
echo "[T-6] Config-aware no-op exits 0 with 0-findings summary (AC-4, offline)"
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
# projects disabled
mkdir -p "$tmpd/disabled"
cat > "$tmpd/disabled/rite-config.yml" <<'CFG'
github:
  projects:
    enabled: false
    project_number: 6
CFG
# set +e around the assignment so a script regression (non-zero exit) does not abort
# the harness at the command-substitution line under `set -euo pipefail` — otherwise the
# `[ "$noop_rc" -eq 0 ]` failure branch below becomes dead code and failure attribution is lost.
set +e; noop_out=$( (cd "$tmpd/disabled" && bash "$DRIFT_SH" --quiet) 2>/dev/null ); noop_rc=$?; set -e
if [ "$noop_rc" -eq 0 ] && printf '%s' "$noop_out" | grep -q '==> Total projects-board-drift findings: 0'; then
  PASS=$((PASS + 1)); echo "  ✓ projects disabled → exit 0, 0 findings"
else
  FAIL=$((FAIL + 1)); FAILURES+=("projects disabled no-op (rc=$noop_rc)"); echo "  ✗ projects disabled no-op (rc=$noop_rc)" >&2
fi
# rite-config absent (walks up to a .git boundary with no config)
mkdir -p "$tmpd/noconfig/.git"
set +e; noop2_out=$( (cd "$tmpd/noconfig" && bash "$DRIFT_SH" --quiet) 2>/dev/null ); noop2_rc=$?; set -e
if [ "$noop2_rc" -eq 0 ] && printf '%s' "$noop2_out" | grep -q '==> Total projects-board-drift findings: 0'; then
  PASS=$((PASS + 1)); echo "  ✓ rite-config absent → exit 0, 0 findings"
else
  FAIL=$((FAIL + 1)); FAILURES+=("rite-config absent no-op (rc=$noop2_rc)"); echo "  ✗ rite-config absent no-op (rc=$noop2_rc)" >&2
fi

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do echo "  - $msg"; done
  exit 1
fi
echo "All projects-board-drift-check checks passed."
