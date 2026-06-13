#!/bin/bash
# Tests for plugins/rite/hooks/scripts/distributed-fix-drift-check.sh Pattern 2
# (reason-table drift detection). Covers robustness fixes:
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
# rc=2 を 0/1 と同列に扱う設計は禁止: invocation error が silent に空文字列へ潰されると、後段 grep の
# no-match が false negative pass を生み、checker 本体の degradation を test が検出できなくなる。
# 本 helper で rc=2 (invocation error) を明示分岐検出することで、意味論的 result (drift / no drift) と
# infrastructure error (binary 異常 / OOM / 引数異常) を構造的に区別する。
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
| reason | description |
|--------|-------------|
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=no-pending"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-1" "$rc"
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

# --- TC-2: shell variable expansion is skipped (emit-side + table-side) ---
echo ""
echo "=== TC-2: reason=trigger_exit_\$var is skipped (truncation artifact) ==="
# Mutation test design intent (table-side + emit-side regression guards):
# - table-side fixture row `| \`python_unexpected_exit_\` | placeholder |` (reason
#   column) は literal trailing `_` で終わる identifier 形式。column-aware awk が
#   reason 列から抽出した値に `[_-]$` filter を適用することを評価する。`$var` 形式の値は
#   awk identifier regex に match せず continue されるため、filter exercise 不可能
#   (false positive test) になる罠を避ける目的で literal trailing `_` を使う。
# - emit-side の独立 regression guard: `after == "$"` filter (二重防御) が同じ input
#   (`reason=trigger_exit_$var`) を skip するため、`[_-]$` filter のみが skip 責務を負う input
#   (`reason=trailing_underscore_; other=value`) を追加して独立性を保証する。
d=$(make_fixture_sandbox '# Test

## reason table
| reason | description |
|--------|-------------|
| `something_else` | spec |
| `python_unexpected_exit_` | placeholder |

```bash
echo "[CONTEXT] X=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
echo "[CONTEXT] Y=1; reason=commit_rc_$commit_rc"
echo "[CONTEXT] Z=1; reason=$reason"
echo "[CONTEXT] W=1; reason=hyphen-test-$some_var"
echo "[CONTEXT] V=1; reason=trailing_underscore_; other=value"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-2" "$rc"
# TC-2 fixture では `something_else` / `placeholder` (および `python_unexpected_exit_` を
# `[_-]$` filter で skip した後の table_reasons) は emit-side に対応エントリを持たないため、
# drift detected の rc=1 が決定的に返る設計。assert_checker_rc は rc=0/1 両方を受理する loose
# 設計 (他 TC との共通利用のため) だが、TC-2 については「無 drift を誤って rc=0 で返す regression」
# を catch するため厳格な rc=1 期待値 assertion を追加する。
if [ "$rc" -ne 1 ]; then
  fail "TC-2: expected drift detected (rc=1), got rc=$rc (table_reasons に対応する emit がない fixture)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: drift detected with rc=1 as expected"
fi
if printf '%s\n' "$out" | grep -Eq "reason '(trigger_exit_|commit_rc_)'"; then
  fail "TC-2: shell variable expansion still produces bogus identifier (emit-side)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: shell variable expansion correctly skipped (emit-side, after==\$)"
fi
# `-$` 形式 (例: reason=hyphen-test-$var) も同様に skip されることを確認
# (emit-side regex `[_-]$` の両側 alternation を test 化、片側除去 regression 防止)
if printf '%s\n' "$out" | grep -Eq "reason 'hyphen-test-'"; then
  fail "TC-2: hyphen suffix variant of shell variable expansion still produces bogus identifier"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: hyphen suffix variant correctly skipped"
fi
# emit-side `[_-]$` filter independent regression guard:
# `reason=trailing_underscore_; other=value` は val=`trailing_underscore_`, after=`;` (≠ `$`)。
# `after == "$"` filter は skip しないため、`[_-]$` filter のみが skip 責務を負う独立 input。
# script の emit-side `if (val ~ /[_-]$/) continue` を削除すると emit_reasons に
# `trailing_underscore_` が入り、table_reasons には存在しないため drift 「emit has X but table doesn't」が誤発火する。
if printf '%s\n' "$out" | grep -Fq "trailing_underscore_"; then
  fail "TC-2: emit-side [_-]\$ filter regression — trailing_underscore_ should be skipped (after=';', not '\$')"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: emit-side [_-]\$ filter correctly skips trailing_underscore_ (independent of after==\$)"
fi
# table-side `[_-]$` filter regression guard:
# fixture row `| \`python_unexpected_exit_\` | placeholder |` の table-side awk:
# - filter あり: `python_unexpected_exit_` matches identifier → `[_-]$` continue → `placeholder` 採用
# - filter 削除 mutation: `python_unexpected_exit_` matches → print + break → table_reasons 入り
# emit-side では `python_unexpected_exit_` を含む emit がないため、drift output に
# 「table 'python_unexpected_exit_' never emitted」が現れる → 本 assert が catch する。
if printf '%s\n' "$out" | grep -Fq "python_unexpected_exit_"; then
  fail "TC-2: table-side [_-]$ filter regression — python_unexpected_exit_ should be skipped from table_reasons"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-2: table-side [_-]$ filter correctly skips truncation-artifact reason"
fi

# --- TC-3: static literal with digit suffix is preserved ---
echo ""
echo "=== TC-3: reason=commit_rc_4 (static literal, digit suffix) is preserved ==="
d=$(make_fixture_sandbox '# Test

## reason table
| reason | description |
|--------|-------------|
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=commit_rc_4; exit_code=$wiki_commit_rc"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-3" "$rc"
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
| reason | description |
|--------|-------------|
| `something_else` | spec |

```bash
echo "[CONTEXT] X=1; reason=mkdir_failed"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-4" "$rc"
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
| reason | description |
|--------|-------------|
| `no-pending` | wiki ingest has nothing to commit |

```bash
echo "[CONTEXT] X=1; reason=no-pending"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-5" "$rc"
if [ "$rc" -ne 0 ]; then
  fail "TC-5: expected no drift (rc=0), got rc=$rc (table/emit が一致する fixture で drift 検出すべきでない)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-5: no drift confirmed with rc=0 as expected"
fi
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
| reason | description |
|--------|-------------|
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
# TC-6 fixture の $d 再利用を回避し独立 fixture を作成する。
# TC-6 削除や fixture 変更 (例: reason table を空にする) で TC-7 が誤った理由で pass する
# (Pattern 2 が table_reasons 空時に早期 return し SHOW_EXTRACTED_REASONS block に到達しない) のを防ぐ。
d=$(make_fixture_sandbox '# Test

## reason table
| reason | description |
|--------|-------------|
| `gamma_reason` | spec |

```bash
echo "[CONTEXT] X=1; reason=delta_reason"
```
')
cleanup_dirs+=("$d")
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

# --- TC-8: reason in 2nd column (| Flag | reason |) is recognized; a
#           non-reason table (no `reason` header) is NOT treated as a reason table ---
echo ""
echo "=== TC-8: column-aware reason table (2nd column) + non-reason table skip ==="
d=$(make_fixture_sandbox '# Test

## flag-to-reason table (reason in 2nd column)
| Flag | reason | description |
|------|--------|-------------|
| `SOME_FLAG` | `second_col_reason` | emitted via the 2nd column |

## reviewer-type table (NOT a reason table — no `reason` header)
| key | agent |
|-----|-------|
| `reviewer_type_x` | `some-agent` |

```bash
echo "[CONTEXT] SOME_FLAG=1; reason=second_col_reason"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-8" "$rc"
if [ "$rc" -eq 0 ]; then
  pass "TC-8: 2nd-column reason documented + non-reason table ignored → no drift"
else
  fail "TC-8: expected no drift (rc=0), got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Eq "reason '(second_col_reason|reviewer_type_x)'"; then
  fail "TC-8: 2nd-column reason or reviewer-type entry spuriously flagged"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-8: no spurious flag for 2nd-column reason / reviewer-type table"
fi

# --- TC-9: a reason documented only in an eval-table enumeration counts as
#           tracked (forward direction unions reason-table + enumeration) ---
echo ""
echo "=== TC-9: eval-table enumeration counts toward the documented set ==="
d=$(make_fixture_sandbox '# Test

## reason table
| reason | description |
|--------|-------------|
| `tabled_reason` | in the reason table |

Eval order: ( `enum_only_reason` / `tabled_reason` )

```bash
echo "[CONTEXT] X=1; reason=tabled_reason"
echo "[CONTEXT] Y=1; reason=enum_only_reason"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-9" "$rc"
if [ "$rc" -eq 0 ]; then
  pass "TC-9: enumeration-documented emit not flagged → no drift"
else
  fail "TC-9: expected no drift (rc=0), got rc=$rc (enum_only_reason should be documented via enumeration)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-10: emit-only file (no reason table AND no enumeration) is skipped ---
# Exercises the compound early-return guard `[ -z "$table_reasons" ] && [ -z "$enum_reasons" ]`.
# A file that emits reasons but documents them elsewhere (delegated helper) must
# NOT be flagged — Pattern-2 is out of scope without an in-file tracking structure.
# Without this case, deleting the second operand of the compound guard goes undetected.
echo ""
echo "=== TC-10: emit-only file (no reason table, no enumeration) → skipped, no drift ==="
d=$(make_fixture_sandbox '# Test

This file emits a reason but has no reason table and no eval-table enumeration.

```bash
echo "[CONTEXT] X=1; reason=orphan_reason"
```
')
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --target plugins/rite/commands/pr/fix.md --pattern 2 \
  --repo-root "$d" 2>/dev/null) || rc=$?
assert_checker_rc "TC-10" "$rc"
if [ "$rc" -eq 0 ]; then
  pass "TC-10: emit-only file skipped (compound guard both-empty) → no drift"
else
  fail "TC-10: expected no drift (rc=0), got rc=$rc (emit-only file must skip Pattern-2)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "orphan_reason"; then
  fail "TC-10: emit-only orphan_reason spuriously flagged (compound guard regression)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-10: no spurious flag for emit-only reason without tracking structure"
fi

# --- Summary ---
echo ""
if ! print_summary "$(basename "$0")" "false positive regression"; then
  exit 1
fi
