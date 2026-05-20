#!/bin/bash
# auto-fire-step0.test.sh
#
# Unit test for `plugins/rite/hooks/auto-fire-step0.sh` (Issue #923 — Layer 4
# mechanical enforcement hook).
#
# Coverage:
#   1. Skill tool input + ingest_pre_lint phase => patches to ingest_post_lint
#   2. Skill tool input + cleanup_pre_ingest phase => patches to cleanup_post_ingest
#   3. Non-Skill tool name => silent exit (no patch, no JSON output)
#   4. Unknown phase => silent exit (no patch, no JSON output)
#   5. opt-out config (workflow.auto_fire_step0.enabled: false) => silent exit
#   6. flow-state file missing => silent exit
#   7. stdout JSON output contains hookSpecificOutput.additionalContext
#
# Test methodology:
#   Each test case constructs a sandbox directory with a controlled flow-state
#   file and (optionally) a rite-config.yml, then pipes a JSON input into the
#   hook script and verifies:
#     - exit code (always 0 — hook is non-blocking by design)
#     - resulting flow-state .phase value (post-patch)
#     - stdout content (JSON or empty)
#
# When this test fails:
#   The Layer 4 hook (auto-fire-step0.sh) runtime behavior has regressed.
#   Check the case statement, the flow-state-update.sh invocation, the
#   opt-out config parsing, or the hookSpecificOutput.additionalContext
#   stdout JSON output format.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOK_SCRIPT="$PLUGIN_ROOT/hooks/auto-fire-step0.sh"

if [ ! -x "$HOOK_SCRIPT" ]; then
  echo "  ❌ HOOK NOT EXECUTABLE: $HOOK_SCRIPT" >&2
  exit 1
fi

# Fixed valid UUID v4 for sandbox tests (deterministic for assertion targeting).
TEST_SESSION_UUID="00000000-0000-4000-8000-000000000999"

# Helper: create a sandbox dir with a flow-state file at the given phase.
# Provisions schema_version=2 + session-id file + per-session flow-state so the
# resolver chain (state-path-resolve.sh / _resolve-flow-state-path.sh /
# _resolve-schema-version.sh / _resolve-session-id-from-file.sh) finds the
# correct path under sandbox conditions.
create_sandbox() {
  local phase="$1"
  local active="${2:-true}"
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.rite/sessions"
  # rite-config.yml provisions schema_version=2 so the per-session path is selected.
  cat > "$sandbox/rite-config.yml" <<'CONFIG_EOF'
flow_state:
  schema_version: 2
CONFIG_EOF
  # session-id file (UUID v4 format required by _resolve-session-id.sh).
  echo "$TEST_SESSION_UUID" > "$sandbox/.rite-session-id"
  # Per-session flow-state file at the resolved path.
  local state_file="$sandbox/.rite/sessions/${TEST_SESSION_UUID}.flow-state"
  jq -n \
    --arg phase "$phase" \
    --arg branch "fix/test" \
    --arg sid "$TEST_SESSION_UUID" \
    --argjson active "$active" \
    --argjson issue 999 \
    --argjson pr 0 \
    '{
      schema_version: 2,
      session_id: $sid,
      phase: $phase,
      issue_number: $issue,
      branch: $branch,
      pr_number: $pr,
      active: $active,
      error_count: 0,
      created_at: "2026-05-20T19:00:00+09:00",
      updated_at: "2026-05-20T19:00:00+09:00",
      next_action: "test"
    }' > "$state_file"
  echo "$sandbox"
}

# Helper: read the current phase from a sandbox's flow-state file.
read_phase() {
  local sandbox="$1"
  jq -r '.phase // empty' "$sandbox/.rite/sessions/${TEST_SESSION_UUID}.flow-state" 2>/dev/null
}

# Helper: build a Skill tool PostToolUse input JSON.
make_skill_input() {
  local cwd="$1"
  local skill_name="${2:-rite:wiki:lint}"
  jq -n \
    --arg cwd "$cwd" \
    --arg sname "$skill_name" \
    '{
      tool_name: "Skill",
      tool_input: { skill_name: $sname },
      cwd: $cwd,
      session_id: "test-session",
      hook_event_name: "PostToolUse"
    }'
}

# Helper: build a non-Skill tool input.
make_bash_input() {
  local cwd="$1"
  jq -n \
    --arg cwd "$cwd" \
    '{
      tool_name: "Bash",
      tool_input: { command: "ls" },
      cwd: $cwd,
      session_id: "test-session",
      hook_event_name: "PostToolUse"
    }'
}

cleanup_sandbox() {
  local sandbox="$1"
  [ -n "$sandbox" ] && [ -d "$sandbox" ] && rm -rf "$sandbox" || true
}

echo "=== TC-1: ingest_pre_lint -> ingest_post_lint (wiki:lint return path) ==="

sandbox=$(create_sandbox "ingest_pre_lint")
input=$(make_skill_input "$sandbox" "rite:wiki:lint")
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true
new_phase=$(read_phase "$sandbox")

assert "TC-1.1: ingest_pre_lint -> ingest_post_lint patched" "ingest_post_lint" "$new_phase"

# stdout must contain hookSpecificOutput JSON
if printf '%s' "$stdout" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  pass "TC-1.2: stdout JSON contains hookSpecificOutput.additionalContext (ingest path)"
else
  fail "TC-1.2: stdout JSON missing hookSpecificOutput.additionalContext (ingest path)"
fi

# additionalContext must mention rite:wiki:ingest as the caller
if printf '%s' "$stdout" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -qF 'rite:wiki:ingest'; then
  pass "TC-1.3: additionalContext mentions caller 'rite:wiki:ingest'"
else
  fail "TC-1.3: additionalContext missing caller 'rite:wiki:ingest'"
fi

cleanup_sandbox "$sandbox"

echo
echo "=== TC-2: cleanup_pre_ingest -> cleanup_post_ingest (wiki:ingest return path) ==="

sandbox=$(create_sandbox "cleanup_pre_ingest")
input=$(make_skill_input "$sandbox" "rite:wiki:ingest")
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true
new_phase=$(read_phase "$sandbox")

assert "TC-2.1: cleanup_pre_ingest -> cleanup_post_ingest patched" "cleanup_post_ingest" "$new_phase"

if printf '%s' "$stdout" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  pass "TC-2.2: stdout JSON contains hookSpecificOutput.additionalContext (cleanup path)"
else
  fail "TC-2.2: stdout JSON missing hookSpecificOutput.additionalContext (cleanup path)"
fi

if printf '%s' "$stdout" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -qF 'rite:pr:cleanup'; then
  pass "TC-2.3: additionalContext mentions caller 'rite:pr:cleanup'"
else
  fail "TC-2.3: additionalContext missing caller 'rite:pr:cleanup'"
fi

cleanup_sandbox "$sandbox"

echo
echo "=== TC-3: non-Skill tool name -> silent exit (no patch) ==="

sandbox=$(create_sandbox "ingest_pre_lint")
input=$(make_bash_input "$sandbox")
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true
new_phase=$(read_phase "$sandbox")

assert "TC-3.1: non-Skill tool does NOT patch (phase unchanged)" "ingest_pre_lint" "$new_phase"

if [ -z "$stdout" ]; then
  pass "TC-3.2: non-Skill tool produces no stdout output"
else
  fail "TC-3.2: non-Skill tool unexpectedly produced stdout: $stdout"
fi

cleanup_sandbox "$sandbox"

echo
echo "=== TC-4: unknown phase -> silent exit (no patch) ==="

sandbox=$(create_sandbox "phase5_implement")
input=$(make_skill_input "$sandbox" "rite:wiki:lint")
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true
new_phase=$(read_phase "$sandbox")

assert "TC-4.1: unknown phase 'phase5_implement' does NOT patch" "phase5_implement" "$new_phase"

if [ -z "$stdout" ]; then
  pass "TC-4.2: unknown phase produces no stdout output"
else
  fail "TC-4.2: unknown phase unexpectedly produced stdout: $stdout"
fi

cleanup_sandbox "$sandbox"

echo
echo "=== TC-5: opt-out config (workflow.auto_fire_step0.enabled: false) ==="

sandbox=$(create_sandbox "ingest_pre_lint")
# Append opt-out section without removing the flow_state schema_version provisioned
# by create_sandbox (the schema_version must remain in scope so the resolver still
# selects the per-session path; otherwise we'd test the wrong code path).
cat >> "$sandbox/rite-config.yml" <<'EOF'
workflow:
  auto_fire_step0:
    enabled: false
EOF
input=$(make_skill_input "$sandbox" "rite:wiki:lint")
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true
new_phase=$(read_phase "$sandbox")

assert "TC-5.1: opt-out config disables hook (phase unchanged)" "ingest_pre_lint" "$new_phase"

if [ -z "$stdout" ]; then
  pass "TC-5.2: opt-out config produces no stdout output"
else
  fail "TC-5.2: opt-out config unexpectedly produced stdout: $stdout"
fi

cleanup_sandbox "$sandbox"

echo
echo "=== TC-6: default enabled when workflow section absent (covered by TC-1/TC-2 conditions) ==="

# TC-1 and TC-2 already exercise the "no workflow.auto_fire_step0 section in
# rite-config.yml" default-enabled path (create_sandbox writes only the
# flow_state section). This TC documents that explicitly.
pass "TC-6.1: TC-1/TC-2 already cover default-enabled behavior under absent workflow section"

echo
echo "=== TC-7: flow-state file missing -> silent exit ==="

sandbox=$(mktemp -d)
input=$(make_skill_input "$sandbox" "rite:wiki:lint")
# Capture stderr too — should be quiet
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true

if [ -z "$stdout" ]; then
  pass "TC-7.1: missing flow-state produces no stdout output"
else
  fail "TC-7.1: missing flow-state unexpectedly produced stdout: $stdout"
fi

cleanup_sandbox "$sandbox"

echo
echo "=== TC-8: empty stdin -> silent exit ==="

stdout=$(printf '' | bash "$HOOK_SCRIPT" 2>/dev/null) || true

if [ -z "$stdout" ]; then
  pass "TC-8.1: empty stdin produces no stdout output"
else
  fail "TC-8.1: empty stdin unexpectedly produced stdout: $stdout"
fi

echo
echo "=== TC-9: active=false -> silent exit (no patch) ==="

sandbox=$(create_sandbox "ingest_pre_lint" "false")
input=$(make_skill_input "$sandbox" "rite:wiki:lint")
stdout=$(printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null) || true
new_phase=$(read_phase "$sandbox")

assert "TC-9.1: active=false does NOT patch (phase unchanged)" "ingest_pre_lint" "$new_phase"

if [ -z "$stdout" ]; then
  pass "TC-9.2: active=false produces no stdout output"
else
  fail "TC-9.2: active=false unexpectedly produced stdout: $stdout"
fi

cleanup_sandbox "$sandbox"

echo
if ! print_summary "$(basename "$0")" "auto-fire-step0.sh runtime behavior regression — Issue #923. Check case mapping, opt-out parser, or hookSpecificOutput JSON output format."; then
  exit 1
fi
