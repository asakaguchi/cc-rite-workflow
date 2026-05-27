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

# Helper: create a sandbox with a single fixture markdown file at
# plugins/rite/commands/pr/fix.md and return its repo root path.
make_fixture_sandbox() {
  local body="$1"
  local d
  d=$(make_plain_sandbox --soft)
  (cd "$d" && git init -q && git -c user.email=t@test.local -c user.name=test commit -q --allow-empty -m init) >/dev/null
  mkdir -p "$d/plugins/rite/commands/pr"
  printf '%s' "$body" > "$d/plugins/rite/commands/pr/fix.md"
  echo "$d"
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
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null || true)
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
```
')
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null || true)
if printf '%s\n' "$out" | grep -Eq "reason '(trigger_exit_|commit_rc_)'"; then
  fail "TC-2: shell variable expansion still produces bogus identifier"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: shell variable expansion correctly skipped"
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
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null || true)
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
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null || true)
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
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null || true)
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
# stderr 経由で log() が出るため stderr を capture
err=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --show-extracted-reasons --repo-root "$d" 2>&1 >/dev/null || true)
if printf '%s\n' "$err" | grep -Eq "P2 extracted.*table_reasons=.*alpha_reason"; then
  pass "TC-6: table_reasons list emitted under --show-extracted-reasons"
else
  fail "TC-6: table_reasons list missing under --show-extracted-reasons"
  echo "--- stderr ---"; printf '%s\n' "$err"; echo "--- end ---"
fi
if printf '%s\n' "$err" | grep -Eq "P2 extracted.*emit_reasons=.*beta_reason"; then
  pass "TC-6: emit_reasons list emitted under --show-extracted-reasons"
else
  fail "TC-6: emit_reasons list missing under --show-extracted-reasons"
  echo "--- stderr ---"; printf '%s\n' "$err"; echo "--- end ---"
fi

# --- TC-7: --show-extracted-reasons silent without flag ---
echo ""
echo "=== TC-7: extracted reasons NOT printed without flag (default behavior) ==="
err=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>&1 >/dev/null || true)
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
