#!/bin/bash
# Tests for plugins/rite/hooks/scripts/distributed-fix-drift-check.sh Pattern 2
# (reason-table drift detection). Covers Issue #1158 robustness fixes:
#   - Hyphenated reason values (no-pending) are not truncated to "no"
#   - Shell variable expansion (reason=foo_$var) is skipped instead of producing
#     bogus identifiers like "foo_"
#   - Static literals (reason=commit_rc_4) are preserved as true emits
#   - True positives (table-missing reasons) are still detected
#   - --show-extracted-reasons flag exposes the parsed reason lists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CHECKER="$PLUGIN_ROOT/hooks/scripts/distributed-fix-drift-check.sh"

if [ ! -x "$CHECKER" ]; then
  echo "ERROR: $CHECKER not found or not executable" >&2
  exit 1
fi

# sibling _test-helpers.sh consumers (_validate-helpers.test.sh /
# flow-state.test.sh) と同型の sandbox cleanup pattern。各 fixture sandbox の
# path を cleanup_dirs に push し、EXIT/INT/TERM/HUP で一括 rm -rf する。
cleanup_dirs=()
cleanup() {
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM HUP

# Helper: create a sandbox with a single fixture markdown file at
# plugins/rite/commands/pr/fix.md and return its repo root path.
# 各 caller は 戻り値の path を cleanup_dirs に push する責務を持つ。
make_fixture_sandbox() {
  local body="$1"
  local d
  d=$(make_plain_sandbox --soft)
  (cd "$d" && git init -q && git -c user.email=t@test.local -c user.name=test commit -q --allow-empty -m init) >/dev/null
  mkdir -p "$d/plugins/rite/commands/pr"
  printf '%s' "$body" > "$d/plugins/rite/commands/pr/fix.md"
  echo "$d"
}

# 各 TC で checker invocation 後に呼ぶ helper。
# drift 検出 (rc=1) と no drift (rc=0) は受理、それ以外 (rc=2: invocation error 等) は fail させる。
# 旧 `|| true` パターンは exit 2 を silent に空文字列に潰し、後段 grep no-match が false negative
# pass を生んでいた。本 helper で invocation error を明示分岐検出する。
assert_checker_rc() {
  local tc_label="$1"
  local rc="$2"
  case "$rc" in
    0|1) ;;
    *) fail "${tc_label}: unexpected checker invocation error (rc=${rc})" ;;
  esac
}

# --- TC-1: hyphenated reason value (no-pending) is preserved ---
echo "=== TC-1: reason=no-pending is extracted as 'no-pending', not 'no' ==="
d=$(make_fixture_sandbox '# Test

## reason table
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=no-pending"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC" "$rc"
if printf '%s\n' "$out" | grep -Fq "reason 'no-pending'"; then
  pass "TC-1: no-pending extracted as full hyphenated value"
else
  fail "TC-1: no-pending not recognized as drift"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Eq "reason 'no'( |\$)"; then
  fail "TC-1: spurious 'no' (truncated at hyphen) still emitted"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-1: no spurious truncated 'no' emitted"
fi

# --- TC-2: shell variable expansion is skipped ---
echo ""
echo "=== TC-2: reason=trigger_exit_\$var is skipped (truncation artifact) ==="
d=$(make_fixture_sandbox '# Test

## reason table
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
echo "[CONTEXT] Y=1; reason=commit_rc_$commit_rc"
echo "[CONTEXT] Z=1; reason=$reason"
echo "[CONTEXT] W=1; reason=hyphen-test-$some_var"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC" "$rc"
if printf '%s\n' "$out" | grep -Eq "reason '(trigger_exit_|commit_rc_)'"; then
  fail "TC-2: shell variable expansion still produces bogus identifier"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: shell variable expansion correctly skipped"
fi
# `-$` 形式 (例: reason=hyphen-test-$var) も同様に skip されることを確認
# (emit-side regex `[_-]$` の両側 alternation を test 化、片側除去 regression 防止)
if printf '%s\n' "$out" | grep -Eq "reason 'hyphen-test-'"; then
  fail "TC-2: hyphen suffix variant of shell variable expansion still produces bogus identifier"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: hyphen suffix variant correctly skipped"
fi

# --- TC-3: static literal with digit suffix is preserved ---
echo ""
echo "=== TC-3: reason=commit_rc_4 (static literal, digit suffix) is preserved ==="
d=$(make_fixture_sandbox '# Test

## reason table
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=commit_rc_4; exit_code=$wiki_commit_rc"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC" "$rc"
if printf '%s\n' "$out" | grep -Fq "reason 'commit_rc_4'"; then
  pass "TC-3: static literal commit_rc_4 still detected as drift candidate"
else
  fail "TC-3: static literal commit_rc_4 missing from output"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-4: true positive (table-missing reason) is still detected ---
echo ""
echo "=== TC-4: reason=mkdir_failed (table absent) is detected as true positive ==="
d=$(make_fixture_sandbox '# Test

## reason table
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=mkdir_failed"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC" "$rc"
if printf '%s\n' "$out" | grep -Fq "reason 'mkdir_failed' emitted but not in reason table"; then
  pass "TC-4: true positive mkdir_failed correctly flagged"
else
  fail "TC-4: true positive mkdir_failed missing from output"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-5: hyphenated reason in table is parseable too ---
echo ""
echo "=== TC-5: hyphenated reason in table cell is matched against emit ==="
d=$(make_fixture_sandbox '# Test

## reason table
| `no-pending` | wiki ingest has nothing to commit |

```bash
echo "[CONTEXT] X=1; reason=no-pending"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC" "$rc"
# Drift should be empty here: emit and table both contain `no-pending`.
if printf '%s\n' "$out" | grep -Eq "reason '(no-pending|no)'"; then
  fail "TC-5: hyphenated emit/table pair still produces drift (regex did not match table side)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-5: hyphenated emit/table pair correctly resolves with no drift"
fi

# --- TC-6: --show-extracted-reasons flag exposes parsed lists ---
echo ""
echo "=== TC-6: --show-extracted-reasons prints extracted reason lists ==="
d=$(make_fixture_sandbox '# Test

## reason table
| `alpha_reason` | spec |

```bash
echo "[CONTEXT] X=1; reason=beta_reason"
```
')
cleanup_dirs+=("$d")
# stderr 経由で log() が出るため stderr を capture
rc=0
err=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --show-extracted-reasons --repo-root "$d" 2>&1 >/dev/null) || rc=$?
assert_checker_rc "TC-6" "$rc"
# format prefix + word boundary を固定し、log 行 format 変更を assertion で検出する
# (`.*` wildcard だと alpha_reason / beta_reason の substring 含有のみで pass する緩い test だった)
if printf '%s\n' "$err" | grep -Eq '^[[:space:]]+\[P2 extracted\] .*: table_reasons=.*\balpha_reason\b'; then
  pass "TC-6: table_reasons list emitted under --show-extracted-reasons"
else
  fail "TC-6: table_reasons list missing under --show-extracted-reasons"
  echo "--- stderr ---"; printf '%s\n' "$err"; echo "--- end ---"
fi
if printf '%s\n' "$err" | grep -Eq '^[[:space:]]+\[P2 extracted\] .*: emit_reasons=.*\bbeta_reason\b'; then
  pass "TC-6: emit_reasons list emitted under --show-extracted-reasons"
else
  fail "TC-6: emit_reasons list missing under --show-extracted-reasons"
  echo "--- stderr ---"; printf '%s\n' "$err"; echo "--- end ---"
fi

# --- TC-7: --show-extracted-reasons silent without flag ---
echo ""
echo "=== TC-7: extracted reasons NOT printed without flag (default behavior) ==="
rc=0
err=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>&1 >/dev/null) || rc=$?
assert_checker_rc "TC-7" "$rc"
if printf '%s\n' "$err" | grep -q "P2 extracted"; then
  fail "TC-7: extracted lists leak when --show-extracted-reasons not specified"
  echo "--- stderr ---"; printf '%s\n' "$err"; echo "--- end ---"
else
  pass "TC-7: extracted lists correctly suppressed by default"
fi

# --- Summary ---
echo ""
if ! print_summary "$(basename "$0")" "Issue #1158 false positive regression"; then
  exit 1
fi
