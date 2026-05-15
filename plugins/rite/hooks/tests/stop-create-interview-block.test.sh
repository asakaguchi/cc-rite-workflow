#!/bin/bash
# Tests for hooks/stop-create-interview-block.sh — Stop event hook (#920).
#
# Primary AC coverage:
#   AC-4 (Issue #920) — implicit stop detection emits workflow_incident sentinel
# Back-stop behavior tests (not direct Issue AC mapping):
#   - gate-match → exit 2 + ACTION (TC-1, TC-9)
#   - gate-mismatch / recursion guard / non-Stop → exit 0 (TC-2..TC-6, TC-8)
#   - workflow_incident.enabled=false respected (TC-7 variant matrix)
# Note: Issue AC-1/AC-2/AC-5 are orchestrator-side e2e concerns, out of hook test scope.
# Note: AC-3 (structural invariants) covered by 4-site-symmetry.test.sh et al.
# Note: AC-6 (charter violation grep) covered separately.
#
# Usage: bash plugins/rite/hooks/tests/stop-create-interview-block.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../stop-create-interview-block.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: stop-create-interview-block.sh missing or not executable: $HOOK" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

cleanup_dirs=()
_stop_hook_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}
trap '_stop_hook_test_cleanup' EXIT
trap '_stop_hook_test_cleanup; exit 130' INT
trap '_stop_hook_test_cleanup; exit 143' TERM
trap '_stop_hook_test_cleanup; exit 129' HUP

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     needle: $needle"
    echo "     in:     $(printf '%s' "$haystack" | head -c 400)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  ❌ $name"
    echo "     unexpected needle present: $needle"
    echo "     in:     $(printf '%s' "$haystack" | head -c 400)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  else
    echo "  ✅ $name"
    PASS=$((PASS+1))
  fi
}

make_sandbox() {
  local d
  d=$(mktemp -d) || { echo "ERROR: make_sandbox: mktemp -d failed" >&2; exit 1; }
  (
    cd "$d"
    git init -q 2>/dev/null
    echo a > a && git add a 2>/dev/null
    git -c user.email=t@test.local -c user.name=test commit -q -m init 2>/dev/null
  ) || { echo "ERROR: make_sandbox: git init failed in $d" >&2; rm -rf "$d"; exit 1; }
  echo "$d"
}

write_flow_state() {
  local d="$1" phase="$2" active="$3" pr="$4"
  printf '%s' "{\"phase\":\"$phase\",\"active\":$active,\"pr_number\":$pr,\"issue_number\":920,\"session_id\":\"00000000-0000-0000-0000-000000000000\"}" \
    > "$d/.rite-flow-state"
}

# Stop event payload builder.
# Default stop_hook_active=false (initial Stop event).
build_stop_payload() {
  local cwd="$1" stop_hook_active="${2:-false}"
  jq -n --arg cwd "$cwd" --argjson sha "$stop_hook_active" \
    '{hook_event_name: "Stop", cwd: $cwd, transcript_path: "/tmp/x.jsonl", session_id: "test", stop_hook_active: $sha}'
}

# run_hook captures stdout/stderr/exit-code into STDOUT/STDERR/HOOK_RC globals.
# Returns 0 always (caller inspects HOOK_RC) — this keeps `set -e` semantics
# unaffected even when the hook exits with code 2 (block).
run_hook() {
  local d="$1" payload="$2"
  local err_file out_file
  err_file=$(mktemp); out_file=$(mktemp)
  HOOK_RC=0
  set +e
  printf '%s' "$payload" | bash "$HOOK" >"$out_file" 2>"$err_file"
  HOOK_RC=$?
  set -e
  STDOUT=$(cat "$out_file"); STDERR=$(cat "$err_file")
  rm -f "$err_file" "$out_file"
  return 0
}

# ---- TC-1: gate match → exit 2 + ACTION + workflow_incident sentinel ----
echo "TC-1: phase=create_post_interview + active=true + pr=0 → exit 2 + block"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_post_interview" "true" "0"
payload=$(build_stop_payload "$SBX" false)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-1.1: exit code 2 (block)" "2" "$rc"
assert_contains "TC-1.2: stderr contains ACTION header" "Issue #920" "$STDERR"
assert_contains "TC-1.3: stderr contains Step 0 patch literal" "flow-state-update.sh patch" "$STDERR"
assert_contains "TC-1.4: stderr contains --if-exists --preserve-error-count" "--if-exists --preserve-error-count" "$STDERR"
assert_contains "TC-1.5: workflow_incident sentinel emitted" "WORKFLOW_INCIDENT=1" "$STDERR"
assert_contains "TC-1.6: incident type is manual_fallback_adopted" "type=manual_fallback_adopted" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-2: phase mismatch (create_interview, not yet at post_interview) → allow ----
echo "TC-2: phase=create_interview → exit 0 (gate mismatch)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_interview" "true" "0"
payload=$(build_stop_payload "$SBX" false)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-2.1: exit code 0 (allow)" "0" "$rc"
assert_eq "TC-2.2: no stderr output" "" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-3: active=false → allow (terminal or paused workflow) ----
echo "TC-3: active=false → exit 0 (terminal/paused)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_post_interview" "false" "0"
payload=$(build_stop_payload "$SBX" false)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-3.1: exit code 0 (allow)" "0" "$rc"
assert_eq "TC-3.2: no stderr output" "" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-4: pr_number != 0 (Issue already created, gate mismatch) → allow ----
echo "TC-4: pr_number=123 → exit 0 (Issue already exists)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_post_interview" "true" "123"
payload=$(build_stop_payload "$SBX" false)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-4.1: exit code 0 (allow)" "0" "$rc"
assert_eq "TC-4.2: no stderr output" "" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-5: stop_hook_active=true (recursion guard) → allow ----
echo "TC-5: stop_hook_active=true → exit 0 (recursion guard)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_post_interview" "true" "0"
payload=$(build_stop_payload "$SBX" true)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-5.1: exit code 0 (recursion guard allow)" "0" "$rc"
assert_eq "TC-5.2: no stderr output" "" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-6: flow-state file absent → allow ----
echo "TC-6: flow-state file absent → exit 0 (no workflow active)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
# No write_flow_state call
payload=$(build_stop_payload "$SBX" false)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-6.1: exit code 0 (allow)" "0" "$rc"
assert_eq "TC-6.2: no stderr output" "" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-7: workflow_incident.enabled variant matrix → all opt-out forms block + skip sentinel ----
# Canonical SoT (workflow-incident-detection.md) accepts 6+ syntactic variants of falsy values
# (`false` / `no` / `0`, case-insensitive, with/without quotes, with trailing comment). The hook
# parser (stop-create-interview-block.sh:103-111) implements quote stripping + case-folding +
# case branch. This loop pins all variants so future parser refactors cannot silently degrade
# any form to default-on (cycle 4 LOW finding — Issue #979).
echo "TC-7: workflow_incident.enabled variant matrix (7 syntactic forms) → exit 2 + no sentinel"

TC7_VARIANTS=(
  "false"
  "FALSE"
  '"false"'
  "'false'"
  "no"
  "0"
  "false # trailing comment"
)

for variant in "${TC7_VARIANTS[@]}"; do
  echo "  variant: enabled: $variant"
  SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
  write_flow_state "$SBX" "create_post_interview" "true" "0"
  cat > "$SBX/rite-config.yml" <<YAML
workflow_incident:
  enabled: $variant
YAML
  payload=$(build_stop_payload "$SBX" false)
  run_hook "$SBX" "$payload"; rc=$HOOK_RC
  assert_eq "TC-7.1 [enabled: $variant]: exit code 2 (block respected)" "2" "$rc"
  assert_contains "TC-7.2 [enabled: $variant]: ACTION still shown" "Issue #920" "$STDERR"
  assert_not_contains "TC-7.3 [enabled: $variant]: workflow_incident sentinel NOT emitted (opt-out respected)" "WORKFLOW_INCIDENT=1" "$STDERR"
  rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")
done

# ---- TC-8: non-Stop event → allow (other hooks are out of scope) ----
echo "TC-8: hook_event_name=PreToolUse → exit 0 (scope check)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_post_interview" "true" "0"
payload=$(jq -n --arg cwd "$SBX" '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: "Bash"}')
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-8.1: exit code 0 (non-Stop allow)" "0" "$rc"
assert_eq "TC-8.2: no stderr output" "" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

# ---- TC-9: rite-config.yml exists but workflow_incident section absent → block + emit ----
# Regression guard for cycle 2 CRITICAL #1 (Issue #920 verified-review):
# canonical parser (sed | grep | sed | tr) under `set -euo pipefail` + `trap 'exit 0' ERR`
# requires `|| true` to absorb grep no-match (exit 1) → pipefail → ERR trap → silent exit 0.
# Default rite install ships rite-config.yml without `workflow_incident:` section, so this
# code path is the most common production scenario.
echo "TC-9: rite-config.yml without workflow_incident section → exit 2 + sentinel (regression guard)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_flow_state "$SBX" "create_post_interview" "true" "0"
cat > "$SBX/rite-config.yml" <<'YAML'
project:
  type: generic
github:
  projects:
    enabled: true
YAML
payload=$(build_stop_payload "$SBX" false)
run_hook "$SBX" "$payload"; rc=$HOOK_RC
assert_eq "TC-9.1: exit code 2 (block, not silently allowed)" "2" "$rc"
assert_contains "TC-9.2: ACTION shown" "Issue #920" "$STDERR"
assert_contains "TC-9.3: workflow_incident sentinel emitted (default-on respected)" "WORKFLOW_INCIDENT=1" "$STDERR"
rm -rf "$SBX"; cleanup_dirs=("${cleanup_dirs[@]/$SBX}")

echo ""
echo "================================="
echo "PASS: $PASS / FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
echo "All tests passed."
exit 0
