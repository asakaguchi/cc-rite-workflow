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
#   make_sandbox       [--branch <name>] [--soft]   # git-init+commit sandbox, echoes path
#   make_plain_sandbox                              # bare mktemp -d sandbox, echoes path

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

# make_sandbox — git-init + initial-commit sandbox (Issue #990).
#
# Consolidates the inline `make_sandbox()` definitions previously duplicated in
# stop-create-interview-block.test.sh, state-read.test.sh, work-memory-update.test.sh
# (with `--branch` for the `fix/issue-687-test` branch parsing test) and
# notification.test.sh TC-016 (with `--soft` for the setup-failure-skip path).
#
# Options:
#   --branch <name>  git init -b <name>; fall back to plain `git init` if -b is
#                    unsupported (older git pre-2.28).
#   --soft           Return non-zero on git-init/commit failure (caller decides
#                    whether to `skip` or treat as test failure). Default behavior
#                    is hard-fail (echo ERROR + exit 1) — used by tests where a
#                    broken sandbox indicates an infrastructure problem that must
#                    halt the run.
#
# Output:
#   stdout : sandbox path (one line) on success.
#   stderr : ERROR line(s) on failure, plus up to 5 lines of git's own stderr
#            to aid CI debugging when git config issues break sandbox setup.
#
# Exit code semantics:
#   exit 1   — hard-fail (default): mktemp -d or git init/commit failure halts the run.
#   return 1 — soft-fail (--soft):  same failures, but caller decides skip vs. test failure.
#   return 2 — option parse error:  unknown option or --branch without a non-empty argument.
#
# Caller patterns (the helper does NOT push to cleanup_dirs — callers do):
#   SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
#   SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
#   if ! SBX=$(make_sandbox --soft); then skip "TC-N (sandbox setup failed)"; fi
#
# Note: $(make_sandbox) runs in a command substitution subshell — any cleanup_dirs
# push performed inside a wrapper that is itself called via $(...) stays local to
# that subshell and is lost in the parent. Callers MUST push to cleanup_dirs from
# the parent shell (the assignment line, not inside the wrapper).
make_sandbox() {
  local branch_arg=""
  local soft_fail=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          echo "ERROR: make_sandbox: --branch requires a non-empty argument" >&2
          return 2
        fi
        branch_arg="$2"
        shift 2
        ;;
      --soft)
        soft_fail=1
        shift
        ;;
      *)
        echo "ERROR: make_sandbox: unknown option '$1'" >&2
        return 2
        ;;
    esac
  done

  local d sandbox_err
  d=$(mktemp -d) || {
    echo "ERROR: make_sandbox: mktemp -d failed" >&2
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  }
  sandbox_err=$(mktemp /tmp/rite-sandbox-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: make_sandbox: mktemp /tmp/rite-sandbox-err-XXXXXX failed; diagnostic capture disabled (git stderr will not be surfaced on failure)" >&2
    sandbox_err="/dev/null"
  }

  if ! (
    cd "$d" || exit 1
    if [ -n "$branch_arg" ]; then
      # Pre-2.28 git lacks `-b`; fall back to plain init + checkout to ensure
      # the requested branch name is the active HEAD regardless of git version.
      if ! git init -q -b "$branch_arg" 2>"$sandbox_err"; then
        git init -q 2>>"$sandbox_err" || exit 1
        git checkout -q -b "$branch_arg" 2>>"$sandbox_err" || exit 1
      fi
    else
      git init -q 2>"$sandbox_err"
    fi
    echo a > a && git add a 2>>"$sandbox_err"
    git -c user.email=t@test.local -c user.name=test commit -q -m init 2>>"$sandbox_err"
  ); then
    echo "ERROR: make_sandbox: git init/commit failed in $d" >&2
    [ "$sandbox_err" != "/dev/null" ] && [ -s "$sandbox_err" ] && head -5 "$sandbox_err" | sed 's/^/  /' >&2
    rm -rf "$d"
    [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  fi
  [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
  echo "$d"
}

# make_plain_sandbox — bare `mktemp -d` sandbox (no git init), echoes path.
#
# Consolidates the no-git sandbox helpers previously duplicated in
# _validate-helpers.test.sh and _resolve-session-id-from-file.test.sh.
# The helper does NOT push to cleanup_dirs — callers do — to match the
# `make_sandbox` convention (single uniform caller pattern across tests).
#
# Options:
#   --soft  Return non-zero on mktemp failure (caller decides whether to `skip`
#           or treat as test failure). Default behavior is hard-fail (echo ERROR
#           + exit 1). Mirrors `make_sandbox` for API symmetry.
#
# Output:
#   stdout : sandbox path (one line) on success.
#   stderr : ERROR line on mktemp failure.
#
# Exit code semantics:
#   exit 1   — hard-fail (default): mktemp -d failure halts the run.
#   return 1 — soft-fail (--soft):  same failure, but caller decides skip vs. test failure.
#   return 2 — option parse error:  unknown option.
#
# Caller pattern:
#   sbx=$(make_plain_sandbox); cleanup_dirs+=("$sbx")
#   if ! sbx=$(make_plain_sandbox --soft); then skip "TC-N (sandbox setup failed)"; fi
make_plain_sandbox() {
  local soft_fail=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --soft)
        soft_fail=1
        shift
        ;;
      *)
        echo "ERROR: make_plain_sandbox: unknown option '$1'" >&2
        return 2
        ;;
    esac
  done

  local d
  d=$(mktemp -d) || {
    echo "ERROR: make_plain_sandbox: mktemp -d failed" >&2
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  }
  echo "$d"
}

# Print summary block and return non-zero when any assertion failed.
# When FAILED_NAMES is non-empty, lists them so callers don't need to duplicate
# the "Failed assertions:" loop in every test file.
# drift_hint_text (optional) is echoed verbatim after the failure list — used by
# tests like 4-site-symmetry that point readers at canonical anchor docs.
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
