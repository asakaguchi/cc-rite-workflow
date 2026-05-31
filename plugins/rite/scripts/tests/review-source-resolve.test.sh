#!/bin/bash
# Tests for review-source-resolve.sh
# Usage: bash plugins/rite/scripts/tests/review-source-resolve.test.sh
#
# Strategy: review-source-resolve.sh resolves the Hybrid Review Source Priority
# chain (extracted from commands/pr/fix.md ステップ 1.2.0, refs #1195 item #2).
# It has no gh dependency — only jq / git / find / mktemp — so tests are fully
# hermetic. We run the real script inside a throwaway git repo (so commit_sha
# stale detection has a real HEAD) and assert on:
#   - the final `[CONTEXT] REVIEW_SOURCE=...` marker (stderr, marker fidelity)
#   - the `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=...` markers on fatal paths
#   - exit codes (0 resolved incl. fallback / 1 fatal / 2 usage)
#   - the [fix:error] stdout 分離 invariant: the helper NEVER writes [fix:error]
#     to stdout (the caller owns that emit).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/review-source-resolve.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# --- sandbox: a throwaway git repo (real HEAD for stale detection) ---
SANDBOX="$TEST_DIR/repo"
mkdir -p "$SANDBOX"
(
  cd "$SANDBOX"
  git init -q
  git config user.email t@example.com
  git config user.name test
  git commit -q --allow-empty -m init
)

OUT=""; ERR=""; RC=0
run() {
  # run <args...> from inside SANDBOX, capturing stdout/stderr/rc separately.
  # set +e around the substitution: the helper exits non-zero on fatal paths and
  # that must NOT abort the test under `set -e`.
  OUT=""; ERR=""; RC=0
  set +e
  OUT=$(cd "$SANDBOX" && bash "$TARGET" "$@" 2>"$TEST_DIR/err")
  RC=$?
  set -e
  ERR=$(cat "$TEST_DIR/err")
}
assert_rc()        { [ "$RC" = "$1" ] && pass "$2 (rc=$RC)" || fail "$2 (rc=$RC, want $1)"; }
assert_err_has()   { printf '%s' "$ERR" | grep -qF "$1" && pass "$2" || fail "$2 — stderr missing: $1"; }
assert_stdout_empty() { [ -z "$OUT" ] && pass "$1 (stdout empty)" || fail "$1 — stdout NOT empty: [$OUT]"; }
assert_no_fixerror_stdout() { printf '%s' "$OUT" | grep -qF "[fix:error]" && fail "$1 — [fix:error] leaked to stdout" || pass "$1 ([fix:error] not on stdout)"; }

valid_json() {
  # $1 = path, $2 = overall_assessment (default fix-needed). No commit_sha => stale skip.
  local p="$1" oa="${2:-fix-needed}"
  cat > "$p" <<JSON
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"$oa","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
}

UNSET="__RITE_UNSET__"

# -----------------------------------------------------------------
echo "--- Test 1: input placeholder / usage fail-fast ---"
run --pr-number "{pr_number}" --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "pr_number 非数値 -> exit 1"
assert_err_has "reason=pr_number_placeholder_residue" "pr_number placeholder reason"
assert_no_fixerror_stdout "pr_number fatal"

run --pr-number 123 --review-file-path "{review_file_path_from_phase_1_0_1}" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "review_file_path placeholder -> exit 1"
assert_err_has "reason=review_file_path_placeholder_residue" "review_file_path placeholder reason"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision "{conversation_review_decision}" --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "conversation_decision unsubstituted -> exit 1"
assert_err_has "reason=priority1_decision_unset" "decision unset reason"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision bogus --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "conversation_decision invalid -> exit 1"
assert_err_has "reason=priority1_decision_invalid" "decision invalid reason"

RC=0; { (cd "$SANDBOX" && bash "$TARGET" --bogus x) >/dev/null 2>&1; } || RC=$?
[ "$RC" = 2 ] && pass "unknown arg -> exit 2" || fail "unknown arg -> exit 2 (rc=$RC)"

# -----------------------------------------------------------------
echo "--- Test 2: Priority 1 conversation receipt ---"
# p1_scan_turns の placeholder 残留 ({p1_scan_turns}) は helper が unset sentinel にマップする
run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns "{p1_scan_turns}" --p1-scan-found true
assert_rc 1 "use + receipt missing -> exit 1"
assert_err_has "reason=priority1_receipt_missing" "receipt missing reason"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns abc --p1-scan-found true
assert_rc 1 "use + receipt non-numeric -> exit 1"
assert_err_has "reason=priority1_receipt_invalid" "receipt invalid reason"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns 1 --p1-scan-found false
assert_rc 1 "use + found!=true -> exit 1"
assert_err_has "reason=priority1_receipt_inconsistent" "receipt inconsistent reason"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns 2 --p1-scan-found true
assert_rc 0 "use valid -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=conversation;" "conversation marker"

# -----------------------------------------------------------------
echo "--- Test 3: Priority 0 explicit file ---"
valid_json "$SANDBOX/explicit.json"
run --pr-number 123 --review-file-path "$SANDBOX/explicit.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit valid -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/explicit.json" "explicit_file marker + path"
assert_stdout_empty "explicit valid"

run --pr-number 123 --review-file-path "$SANDBOX/nope.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit missing -> exit 0 (fallback)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "fallback marker"
assert_err_has "reason=explicit_file_not_found" "explicit_file_not_found reason"

printf 'not json{' > "$SANDBOX/bad.json"
run --pr-number 123 --review-file-path "$SANDBOX/bad.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit invalid JSON -> fallback"
assert_err_has "reason=explicit_file_parse" "explicit_file_parse reason"

valid_json "$SANDBOX/mergeable.json" "mergeable"
run --pr-number 123 --review-file-path "$SANDBOX/mergeable.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit mergeable+open-blocker -> fallback"
assert_err_has "reason=mergeable_has_open_blockers" "cross-field invariant reason"

# -----------------------------------------------------------------
echo "--- Test 4: Priority 2 local file ---"
mkdir -p "$SANDBOX/.rite/review-results"
valid_json "$SANDBOX/.rite/review-results/123-20260101000000.json"
run --pr-number 123 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "local file valid -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file; review_source_path=.rite/review-results/123-20260101000000.json" "local_file marker + path"

# corrupt local file -> renamed + pr_comment routing
printf 'not json{' > "$SANDBOX/.rite/review-results/123-20260102000000.json"
run --pr-number 123 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "local corrupt -> pr_comment"
assert_err_has "reason=local_file_json_parse_failure" "corrupt parse reason"
if ls "$SANDBOX"/.rite/review-results/123-20260102000000.json.corrupt-* >/dev/null 2>&1; then
  pass "corrupt local file renamed to .corrupt-*"
else
  fail "corrupt local file NOT renamed"
fi

# -----------------------------------------------------------------
echo "--- Test 5: Priority 3 fall-through ---"
EMPTY="$TEST_DIR/emptyrepo"; mkdir -p "$EMPTY"
( cd "$EMPTY"; git init -q; git config user.email t@e.com; git config user.name t; git commit -q --allow-empty -m init )
set +e
OUT=$(cd "$EMPTY" && bash "$TARGET" --pr-number 999 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 3 --p1-scan-found false 2>"$TEST_DIR/err")
RC=$?
set -e
ERR=$(cat "$TEST_DIR/err")
assert_rc 0 "no source -> exit 0 (pr_comment)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=pr_comment;" "pr_comment marker"
assert_stdout_empty "pr_comment fall-through"
assert_no_fixerror_stdout "pr_comment path"

# -----------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
