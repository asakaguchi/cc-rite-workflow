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
#   (`bash 4-site-symmetry.test.sh`) because it defines its own SCRIPT_DIR
#   before sourcing this file.
#
# Provided variables (initialized to 0 / empty array on source):
#   PASS, FAIL, FAILED_NAMES
#
# Provided functions:
#   _helpers_resolve_plugin_root <script_dir>
#   _helpers_resolve_repo_root   <script_dir>
#   pass <label>
#   fail <label>
#   assert <label> <expected> <actual>
#   assert_grep     <label> <file> <pattern>     # ERE, exits via fail() if not found
#   assert_not_grep <label> <file> <pattern>     # ERE, exits via fail() if found
#   print_summary [test_name] [drift_hint_text]  # returns 1 if FAIL > 0

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

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ $1"
}

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
# tests like 4-site-symmetry that point readers at canonical anchor docs.
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
