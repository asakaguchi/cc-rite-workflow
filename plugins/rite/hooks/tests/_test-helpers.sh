#!/bin/bash
# Common test helpers for plugins/rite/hooks/tests/*.test.sh (Issue #852)
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/_test-helpers.sh"
#   REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
#   # ...assertions using pass / fail / assert / assert_grep / assert_not_grep...
#   if ! print_summary "$(basename "$0")" "drift hint text"; then
#     exit 1
#   fi
#
# Why this file is named `_test-helpers.sh` (no `.test.sh` suffix):
#   `run-tests.sh` globs `*.test.sh`. A `_test-helpers.sh` filename is
#   intentionally excluded so this helper is sourced only when callers
#   `source` it explicitly. Each caller test still runs standalone
#   (`bash and-logic-defense-chain.test.sh`) because it defines its own
#   SCRIPT_DIR before sourcing this file.
#
# Output convention (Issue #853):
#   Scope: applies to tests that `source` this helper. Enumerate the current
#   set with:
#     grep -l 'source.*_test-helpers.sh' plugins/rite/hooks/tests/*.test.sh
#   Tests that define `pass()` / `fail()` inline (enumerate with the inverse
#   `grep -L 'source.*_test-helpers.sh' plugins/rite/hooks/tests/*.test.sh`)
#   are migration candidates but are NOT covered by this convention until
#   they switch to sourcing this file.
#
#   Tests sourcing this helper follow a single canonical convention so the
#   pass/fail stream and any supporting failure detail stay together for
#   readers and downstream tooling.
#
#   stdout (canonical for test-result stream):
#     - pass / fail / assert / assert_grep / assert_not_grep markers
#     - print_summary block (PASS/FAIL counts, Failed assertions list,
#       optional drift_hint_text)
#     - test phase headers (e.g., `echo "=== ... ==="`)
#     - failure detail context (expected/actual diffs, "--- block ---"
#       dumps that immediately follow a fail() line). Keep these on
#       stdout so the failure marker and its diff render in the same
#       stream — splitting them across stdout/stderr makes the diff
#       hard to correlate when callers redirect only one stream.
#
#   stderr (>&2 — reserved for environment errors only):
#     - Hard preconditions that prevent the test from running
#       (missing executable, mktemp/jq failure, malformed config).
#       These are NOT test failures; they are infrastructure problems
#       that callers may want to handle separately from PASS/FAIL.
#
#   The convention exists so downstream consumers (CI log parsers, grep
#   filters scanning for `❌` / `PASS:`) can rely on a single source stream
#   to capture the full test-result narrative without losing failure
#   detail context. `run-tests.sh` currently inherits the parent shell's
#   streams (no per-test split), so the rule is observable rather than
#   enforced — if the runner grows per-stream capture in the future,
#   tests honoring this convention will continue to work without change.
#
# Provided variables (initialized to 0 / empty array on source):
#   PASS, FAIL, FAILED_NAMES
#
# Provided functions:
#   _helpers_resolve_plugin_root <script_dir>
#   _helpers_resolve_repo_root   <script_dir>
#   pass <label>                                 # writes to stdout
#   fail <label>                                 # writes to stdout
#   assert <label> <expected> <actual>           # writes to stdout (via pass/fail)
#   assert_grep     <label> <file> <pattern>     # ERE, exits via fail() if not found
#   assert_not_grep <label> <file> <pattern>     # ERE, exits via fail() if found
#   print_summary [test_name] [drift_hint_text]  # writes to stdout, returns 1 if FAIL > 0

# Resolve PLUGIN_ROOT from the test's SCRIPT_DIR (tests/ is 2 levels below).
# plugins/rite/hooks/tests/<test>.sh -> plugins/rite (2 up)
_helpers_resolve_plugin_root() {
  local script_dir="${1:?script_dir required}"
  (cd "$script_dir/../.." && pwd)
}

# Resolve REPO_ROOT from the test's SCRIPT_DIR (tests/ is 4 levels below repo root).
# plugins/rite/hooks/tests/<test>.sh -> repo root (4 up)
_helpers_resolve_repo_root() {
  local script_dir="${1:?script_dir required}"
  (cd "$script_dir/../../../.." && pwd)
}

# Counters — declared here so callers can rely on them existing after `source`.
# Callers may reassign to 0 if re-running within a long-lived shell, but the
# normal pattern (run-tests.sh forks a fresh `bash` per test) makes that unnecessary.
PASS=0
FAIL=0
FAILED_NAMES=()

# Pass marker — writes to stdout (see "Output convention" in the file header).
pass() {
  PASS=$((PASS + 1))
  echo "  ✅ $1"
}

# Fail marker — writes to stdout (see "Output convention" in the file header).
# Any failure-detail context the caller emits afterwards (expected/actual,
# block dumps, etc.) MUST also go to stdout so it stays adjacent to this
# marker in the result stream.
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  echo "  ❌ $1"
}

# Generic equality assertion.
assert() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected='$expected' actual='$actual')"
  fi
}

# Pattern presence assertion (ERE via grep -E).
# File-existence check distinguishes "file missing" (grep exit 2) from "pattern absent" (grep exit 1).
assert_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return
  fi
  if grep -qE "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (pattern not found in $file: $pattern)"
  fi
}

# Pattern absence assertion (ERE via grep -E).
# File-existence check distinguishes "file missing" (grep exit 2) from "pattern absent" (grep exit 1).
assert_not_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return
  fi
  if grep -qE "$pattern" "$file"; then
    fail "$label (anti-pattern found in $file: $pattern)"
  else
    pass "$label"
  fi
}

# Print summary block and return non-zero when any assertion failed.
# When FAILED_NAMES is non-empty, lists them so callers don't need to duplicate
# the "Failed assertions:" loop in every test file.
# drift_hint_text (optional) is echoed verbatim after the failure list — used by
# tests that point readers at canonical anchor docs (e.g.
# caller-html-literal-symmetry-decompose-register.test.sh).
# Writes everything to stdout (see "Output convention" in the file header).
print_summary() {
  local test_name="${1:-summary}"
  local drift_hint="${2:-}"
  echo
  echo "─── $test_name summary ──────────────────────"
  echo "PASS: $PASS"
  echo "FAIL: $FAIL"
  if [ "$FAIL" -ne 0 ]; then
    if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
      echo "Failed assertions:"
      local n
      for n in "${FAILED_NAMES[@]}"; do
        echo "  - $n"
      done
    fi
    if [ -n "$drift_hint" ]; then
      echo
      printf '%s\n' "$drift_hint"
    fi
    return 1
  fi
  return 0
}
