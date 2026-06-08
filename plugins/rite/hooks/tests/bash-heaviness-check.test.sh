#!/bin/bash
# Tests for bash-heaviness-check.sh (Issue #1197 — #1193 提案 c)
# Usage: bash plugins/rite/hooks/tests/bash-heaviness-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/bash-heaviness-check.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT INT TERM HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== bash-heaviness-check.sh tests (Issue #1197) ==="
echo ""

mkdir -p "$TEST_DIR/plugins/rite/commands/pr"
mkdir -p "$TEST_DIR/plugins/rite/commands/tests"
(cd "$TEST_DIR" && git init -q 2>/dev/null || true)

F="$TEST_DIR/plugins/rite/commands/fixture.md"
REL="plugins/rite/commands/fixture.md"
run() { bash "$TARGET" --repo-root "$TEST_DIR" --target "$1" 2>&1; }

# Helper: emit N plain echo lines (filler to cross the long-block threshold).
filler() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "echo \"line $i\""; done; }

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 2 (usage error)
# --------------------------------------------------------------------------
echo "TC-001: No arguments → exit 2"
rc=0; output=$(bash "$TARGET" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "no args → exit 2"; else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-002: non-existent --repo-root → exit 2
# --------------------------------------------------------------------------
echo "TC-002: non-existent repo-root → exit 2"
rc=0; output=$(bash "$TARGET" --all --repo-root "$TEST_DIR/nope" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "repo-root not a directory"; then
  pass "bad repo-root → exit 2"
else fail "expected rc=2 + message, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-003: clean short block (helper call, no signals) → exit 0, 0 findings
# --------------------------------------------------------------------------
echo "TC-003: clean short helper-call block → exit 0"
{
  echo '```bash'
  echo 'bash plugins/rite/hooks/local-wm-update.sh "$arg"'
  echo 'echo "done"'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0"; then
  pass "clean block not flagged → exit 0"
else fail "expected rc=0 + 0 findings, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-004: python-inline + long-block (2 signals) → exit 1
# --------------------------------------------------------------------------
echo "TC-004: python-inline + long-block → exit 1"
{
  echo '```bash'
  echo "python3 -c 'import sys; print(sys.argv)' a b"
  filler 26
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "python-inline" \
   && echo "$output" | grep -q "long-block"; then
  pass "python-inline + long-block flagged → exit 1"
else fail "expected rc=1 + both signals, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-005: nested-cmdsub + long-block (2 signals) → exit 1
# --------------------------------------------------------------------------
echo "TC-005: nested-cmdsub + long-block → exit 1"
{
  echo '```bash'
  echo 'msg=$(printf "%s" "$(head -1 file)")'
  filler 26
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "nested-cmdsub"; then
  pass "nested-cmdsub + long-block flagged → exit 1"
else fail "expected rc=1 + nested-cmdsub, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-006: multi-heredoc (2 heredocs) + long-block → exit 1
# --------------------------------------------------------------------------
echo "TC-006: multi-heredoc + long-block → exit 1"
{
  echo '```bash'
  echo "cat > a <<'EOF'"
  echo 'aaa'
  echo 'EOF'
  echo "cat > b <<'EOF'"
  echo 'bbb'
  echo 'EOF'
  filler 26
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "multi-heredoc(2)"; then
  pass "two heredocs flagged → exit 1"
else fail "expected rc=1 + multi-heredoc(2), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-007: long-block ONLY (single signal) → NOT flagged → exit 0
#         The min-2-signals rule must not flag a long but simple block.
# --------------------------------------------------------------------------
echo "TC-007: long-block alone (1 signal) → exit 0"
{
  echo '```bash'
  filler 40
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0"; then
  pass "single signal not flagged → exit 0"
else fail "expected rc=0 (1 signal), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-008: single heredoc, short block (single signal at most) → exit 0
# --------------------------------------------------------------------------
echo "TC-008: single short heredoc → exit 0"
{
  echo '```bash'
  echo "cat > a <<'EOF'"
  echo 'content'
  echo 'EOF'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ]; then pass "single heredoc not flagged → exit 0"
else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-009: drift-check-ignore marker exempts a heavy block → exit 0
# --------------------------------------------------------------------------
echo "TC-009: drift-check-ignore exempts heavy block → exit 0"
{
  echo '```bash'
  echo '# drift-check-ignore — intentional heavy example'
  echo "python3 -c 'print(1)'"
  filler 26
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ]; then pass "exempted block skipped → exit 0"
else fail "expected rc=0 (exempted), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-010: heredoc BODY data must not produce python/nested signals.
#         The body holds `$(a $(b))` and `python3 -c` text, but as literal
#         data it is skipped — only long-block remains (1 signal) → exit 0.
# --------------------------------------------------------------------------
echo "TC-010: heredoc body data not counted → exit 0"
{
  echo '```bash'
  echo "cat > tpl <<'EOF'"
  echo 'example: msg=$(printf "%s" "$(inner)")'
  echo "example: python3 -c 'print()'"
  filler 26
  echo 'EOF'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0"; then
  pass "heredoc body data ignored → exit 0"
else fail "expected rc=0 (body is data), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-011: python invoking a .py script (no -c, no heredoc) is NOT python-inline.
#         With only a long block it stays at 1 signal → exit 0.
# --------------------------------------------------------------------------
echo "TC-011: python script call (no -c) not python-inline → exit 0"
{
  echo '```bash'
  echo 'python3 plugins/rite/hooks/work-memory-parse.py "$file"'
  filler 30
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ]; then pass "script call not flagged as python-inline → exit 0"
else fail "expected rc=0 (no -c), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-012: three signals (python-inline + nested + long) → exit 1, score 3
# --------------------------------------------------------------------------
echo "TC-012: three signals → exit 1"
{
  echo '```bash'
  echo "python3 -c 'print(1)'"
  echo 'x=$(echo "$(date)")'
  filler 26
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "3 signals"; then
  pass "three signals reported → exit 1"
else fail "expected rc=1 + 3 signals, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-013: non-bash fenced block (e.g. ```text) is ignored → exit 0
# --------------------------------------------------------------------------
echo "TC-013: non-bash fence ignored → exit 0"
{
  echo '```text'
  echo "python3 -c 'print(1)'"
  echo 'y=$(a "$(b)")'
  filler 30
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0"; then
  pass "non-bash fence skipped → exit 0"
else fail "expected rc=0 (non-bash), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-014: --all excludes commands/**/tests/ fixtures
# --------------------------------------------------------------------------
echo "TC-014: --all excludes tests/"
{
  echo '```bash'
  echo "python3 -c 'print(1)'"
  filler 26
  echo '```'
} > "$TEST_DIR/plugins/rite/commands/tests/bad-fixture.md"
# Keep the top-level fixture clean so --all stays non-empty but finds nothing.
{
  echo '```bash'
  echo 'echo ok'
  echo '```'
} > "$F"
rc=0; output=$(bash "$TARGET" --all --repo-root "$TEST_DIR" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && ! echo "$output" | grep -q "bad-fixture.md"; then
  pass "tests/ fixtures excluded from --all → exit 0"
else fail "expected rc=0 with no tests/ finding, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-015: long-block boundary — body of exactly 24 lines (< threshold 25).
#         python-inline is the only other signal, so long-block alone decides
#         the outcome: 24 lines must NOT fire long-block → 1 signal → exit 0.
#         Pins the LINE_THRESHOLD off-by-one (a 25→24 regression would fire
#         long-block here, reaching 2 signals → exit 1, failing this TC).
# --------------------------------------------------------------------------
echo "TC-015: long-block boundary 24 lines (< 25) → exit 0"
{
  echo '```bash'
  echo "python3 -c 'print(1)'"   # body line 1 (python-inline)
  filler 23                       # body lines 2-24 → nlines = 24
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0" \
   && ! echo "$output" | grep -q "long-block"; then
  pass "24-line body below threshold → exit 0, no long-block"
else fail "expected rc=0 + no long-block (24 lines), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-016: long-block boundary — body of exactly 25 lines (== threshold 25).
#         python-inline + long-block → 2 signals → exit 1. Asserts the
#         labelled line count long-block(25) to pin both the `>=` boundary
#         (a >=25→>=26 regression would leave 25 lines at 1 signal → exit 0,
#         failing this TC) and the nlines counting logic.
# --------------------------------------------------------------------------
echo "TC-016: long-block boundary 25 lines (== 25) → exit 1"
{
  echo '```bash'
  echo "python3 -c 'print(1)'"   # body line 1 (python-inline)
  filler 24                       # body lines 2-25 → nlines = 25
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "long-block(25)"; then
  pass "25-line body at threshold → exit 1 + long-block(25)"
else fail "expected rc=1 + long-block(25), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-017: inline-gh-create-title — literal --title in a single short block must
#         flag ON ITS OWN (no second signal needed). Issue #1307.
# --------------------------------------------------------------------------
echo "TC-017: literal --title standalone → exit 1"
{
  echo '```bash'
  echo 'gh pr create --draft --base develop --title "feat(pr): 全角 (≠) コロン: 実装"'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "inline-gh-create-title"; then
  pass "literal --title flagged standalone → exit 1"
else fail "expected rc=1 + inline-gh-create-title, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-018: variable --title ("$var") is the sanctioned form → NOT flagged.
#         Pins that the refactored pr/create.md Phase 3.4 stays clean.
# --------------------------------------------------------------------------
echo "TC-018: variable --title → exit 0"
{
  echo '```bash'
  echo 'pr_title=$(cat title.txt)'
  echo 'gh pr create --draft --base develop --title "$pr_title" --body-file body.md'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0"; then
  pass "variable --title not flagged → exit 0"
else fail "expected rc=0 (variable title), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-019: `gh issue create` with a literal --title is flagged too (both
#         pr and issue create are covered). Also `--title=` equals form.
# --------------------------------------------------------------------------
echo "TC-019: gh issue create + --title= equals form → exit 1"
{
  echo '```bash'
  echo 'gh issue create --title="fix: bug" --body-file b.md'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "inline-gh-create-title"; then
  pass "gh issue create literal (equals form) flagged → exit 1"
else fail "expected rc=1 + inline-gh-create-title, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-020: a literal --title inside a heredoc BODY is data, not a real shell
#         line → NOT flagged. Mirrors the heredoc-body-as-data rule.
# --------------------------------------------------------------------------
echo "TC-020: literal --title in heredoc body → exit 0"
{
  echo '```bash'
  echo "cat > tpl <<'EOF'"
  echo 'gh pr create --title "example literal title"'
  echo 'EOF'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total bash-heaviness findings: 0"; then
  pass "heredoc-body literal title ignored → exit 0"
else fail "expected rc=0 (body is data), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-021: drift-check-ignore exempts inline-gh-create-title too (same exempt
#         path as the heaviness signals).
# --------------------------------------------------------------------------
echo "TC-021: drift-check-ignore exempts literal --title → exit 0"
{
  echo '```bash'
  echo '# drift-check-ignore — intentional inline title example'
  echo 'gh pr create --title "feat: documented example"'
  echo '```'
} > "$F"
rc=0; output=$(run "$REL") || rc=$?
if [ "$rc" -eq 0 ]; then pass "exempted inline title skipped → exit 0"
else fail "expected rc=0 (exempted), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "TOTAL: $((PASS + FAIL))"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
