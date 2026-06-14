#!/bin/bash
# Run all rite hook tests
# Usage: bash plugins/rite/hooks/tests/run-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Run the suite with a clean session-id env (Issue #1530). flow-state.sh now
# resolves session_id env-first (CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID) and
# only falls back to each sandbox's `.rite-session-id` file when env is absent.
# Most tests simulate a session by writing that file, so the dogfooding session's
# own ambient CLAUDE_CODE_SESSION_ID must not leak into the sandboxes (it would
# point every hook at a foreign per-session state file). Tests that exercise env
# resolution set the vars explicitly per-command, overriding this unset.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

TOTAL=0
PASSED=0
FAILED=0
FAILED_TESTS=()

for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$test_file" ] || continue
  test_name="$(basename "$test_file")"
  TOTAL=$((TOTAL + 1))
  echo "=== Running: $test_name ==="
  if bash "$test_file"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_TESTS+=("$test_name")
  fi
  echo ""
done

echo "==============================="
echo "Results: $PASSED/$TOTAL passed, $FAILED failed"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "All tests passed!"
