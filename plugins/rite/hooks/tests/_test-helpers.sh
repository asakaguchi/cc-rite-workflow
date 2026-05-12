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
#
# silent-failure-hunter M-9: subshell `cd` 失敗時に caller's CWD が silent fallback として
# pwd で出力される経路を排除。set -e は subshell 内では発動するが、command substitution
# `$(_helpers_resolve_*)` の caller 側で rc が無視される invocation 形では「caller's CWD が
# REPO_ROOT として silent 採用」される。explicit fail-fast に変更。
_helpers_resolve_plugin_root() {
  local script_dir="${1:?script_dir required}"
  (cd "$script_dir/../.." 2>/dev/null && pwd) || {
    echo "ERROR: _helpers_resolve_plugin_root: cannot resolve plugin_root from $script_dir" >&2
    exit 1
  }
}

# Resolve REPO_ROOT from the test's SCRIPT_DIR (tests/ is 4 levels below repo root).
# plugins/rite/hooks/tests/<test>.sh -> repo root (4 up)
_helpers_resolve_repo_root() {
  local script_dir="${1:?script_dir required}"
  (cd "$script_dir/../../../.." 2>/dev/null && pwd) || {
    echo "ERROR: _helpers_resolve_repo_root: cannot resolve repo_root from $script_dir" >&2
    exit 1
  }
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
#
# 旧実装は
#   1. file-not-found を pattern-absent と同じ fail() に流入していた (環境エラーと test 失敗の混同)
#   2. grep stderr を取得せず、IO エラー (rc=2) を「pattern not found」(rc=1) と silent に融合させていた
#      (NFS hiccup / antivirus lock / permission flip 等が「regression detected」と誤報告される)
# 本修正で:
#   - file-not-found は label に [FILE_NOT_FOUND] sentinel を付加し、downstream parser が
#     環境問題と区別可能にする
#   - grep stderr を tempfile に退避し、rc==2 (IO error) を独立検出して [GREP_IO_ERROR] sentinel
#     付き fail として明示する (test 環境破綻を business-rule 失敗と区別する)
# Source: POSIX grep exit code spec (https://pubs.opengroup.org/onlinepubs/9699919799/utilities/grep.html)
#   0 = match found, 1 = no match, >=2 = IO/regex error
#
# IO error / mktemp 失敗時の doctrine asymmetry note (pr-test-analyzer IMP-6 対応):
#   - assert_grep / assert_not_grep: mktemp 失敗時は `fail "[MKTEMP_FAILED]"` で continue (test 全体は止めない)
#   - error-count-runtime-reference.test.sh / parent-routing-pattern-interim.test.sh の `_grep_count_safe`:
#     mktemp 失敗時は `exit 1` で fail-fast (test 全体を中止)
#   両者の方針は意図的に異なる: helpers は test 全体の安全網として連続実行を続け、_grep_count_safe は
#   load-bearing test invariant の保護を完全保証するため即時 abort する設計。混在を見て混乱しないこと。
assert_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$label [FILE_NOT_FOUND] (file not found: $file)"
    return
  fi
  # mktemp 失敗時は fail-fast (IMP-1 対応): 旧実装の silent fallback (`|| _ag_err=""`) は
  # /tmp 制限環境で GREP_IO_ERROR sentinel を silent 無効化する。
  # error-count-runtime-reference.test.sh の `_mktemp + fail-fast` canonical pattern と対称化 (行番号 drift 回避のため構造 anchor で参照)。
  local _ag_err
  if ! _ag_err=$(mktemp /tmp/rite-assert-grep-err-XXXXXX); then
    fail "$label [MKTEMP_FAILED] (mktemp failed for grep stderr capture — /tmp inode exhaustion / read-only fs / permission denied)"
    return
  fi
  # M-3 対応: assert_not_grep と同じ linear pattern で `local _grep_rc=$?` 同一行 declaration の
  # bash local pitfall を回避。`local _grep_rc=$?` は同一行なら captures するが、
  # 将来 refactor で分離すると `local` 自身の rc=0 が `$?` を上書きする (BashPitfalls)。
  local _grep_rc
  if grep -qE "$pattern" "$file" 2>"$_ag_err"; then
    _grep_rc=0
  else
    _grep_rc=$?
  fi
  if [ "$_grep_rc" -ge 2 ]; then
    local _io_detail=""
    if [ -s "$_ag_err" ]; then
      _io_detail=" ($(head -1 "$_ag_err"))"
    fi
    fail "$label [GREP_IO_ERROR rc=$_grep_rc] (grep IO/regex error in $file: $pattern)${_io_detail}"
  elif [ "$_grep_rc" = "0" ]; then
    pass "$label"
  else
    fail "$label (pattern not found in $file: $pattern)"
  fi
  rm -f "$_ag_err"
}

# Pattern absence assertion (ERE via grep -E).
# 同じ L-1 / L-4 対応を適用。
assert_not_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$label [FILE_NOT_FOUND] (file not found: $file)"
    return
  fi
  # mktemp 失敗時は fail-fast (IMP-1 対応、assert_grep と対称)。
  local _ang_err
  if ! _ang_err=$(mktemp /tmp/rite-assert-not-grep-err-XXXXXX); then
    fail "$label [MKTEMP_FAILED] (mktemp failed for grep stderr capture — /tmp inode exhaustion / read-only fs / permission denied)"
    return
  fi
  # `set -e` 下で grep rc=1 (no match) が関数 exit を発火する罠を回避するため、
  # `if grep; then` パターンで rc 捕捉を独立させる。
  local _grep_rc
  if grep -qE "$pattern" "$file" 2>"$_ang_err"; then
    _grep_rc=0
  else
    _grep_rc=$?
  fi
  if [ "$_grep_rc" -ge 2 ]; then
    local _io_detail=""
    if [ -s "$_ang_err" ]; then
      _io_detail=" ($(head -1 "$_ang_err"))"
    fi
    fail "$label [GREP_IO_ERROR rc=$_grep_rc] (grep IO/regex error in $file: $pattern)${_io_detail}"
  elif [ "$_grep_rc" = "0" ]; then
    fail "$label (anti-pattern found in $file: $pattern)"
  else
    pass "$label"
  fi
  rm -f "$_ang_err"
}

# Print summary block and return non-zero when any assertion failed.
# When FAILED_NAMES is non-empty, lists them so callers don't need to duplicate
# the "Failed assertions:" loop in every test file.
# drift_hint_text (optional) is echoed verbatim after the failure list — used by
# tests that point readers at canonical anchor docs (e.g.
# parent-routing-pattern-interim.test.sh).
# 例示は永続的に存在する `parent-routing-pattern-interim.test.sh` を使う
# (旧 `caller-html-literal-symmetry-decompose-register.test.sh` は ADR PR-5 で retire 予定のため例示から除外)。
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
