#!/bin/bash
# Tests for post-compact.sh (PostCompact hook)
# Usage: bash plugins/rite/hooks/tests/post-compact.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-compact.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Prerequisite check: jq is required
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

setup_test() {
  local test_cwd="$TEST_DIR/$1"
  mkdir -p "$test_cwd"
  # Create minimal state-path-resolve.sh mock
  mkdir -p "$test_cwd/.git"
  echo "$test_cwd"
}

echo "=== post-compact.sh tests ==="

# --- TC-001: active flow + recovering → stdout output + normal transition ---
echo "TC-001: Active flow + recovering → auto-recovery"
TC_DIR=$(setup_test "tc001")
jq -n '{active: true, issue_number: 42, phase: "phase5_implementation", next_action: "Continue coding", loop_count: 1, pr_number: 10, branch: "feat/issue-42-test"}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-03-14T12:00:00Z", active_issue: 42}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Auto-compact recovery"; then
  pass "stdout contains auto-recovery message"
else
  fail "stdout missing auto-recovery message: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Issue #42"; then
  pass "stdout contains issue number"
else
  fail "stdout missing issue number"
fi
COMPACT_VAL=$(jq -r '.compact_state' "$TC_DIR/.rite-compact-state" 2>/dev/null) || COMPACT_VAL=""
if [ "$COMPACT_VAL" = "normal" ]; then
  pass "compact_state transitioned to normal"
else
  fail "compact_state is '$COMPACT_VAL', expected 'normal'"
fi

# --- TC-002: manual compact → state re-injection only ---
echo "TC-002: Manual compact → no auto-continue instruction"
TC_DIR=$(setup_test "tc002")
jq -n '{active: true, issue_number: 42, phase: "phase5_review", next_action: "Review PR", loop_count: 0, pr_number: 5, branch: "feat/issue-42-test"}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-03-14T12:00:00Z", active_issue: 42}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "manual"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Compact recovery"; then
  pass "stdout contains recovery message for manual"
else
  fail "stdout missing recovery message: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Auto-compact recovery"; then
  fail "manual should not contain auto-compact recovery"
else
  pass "manual does not contain auto-compact recovery"
fi

# --- TC-003: no flow state → cleanup + no stdout ---
echo "TC-003: No flow state → cleanup, no output"
TC_DIR=$(setup_test "tc003")
jq -n '{compact_state: "recovering"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output"
else
  fail "unexpected stdout: $OUTPUT"
fi
if [ ! -f "$TC_DIR/.rite-compact-state" ]; then
  pass "compact state cleaned up"
else
  fail "compact state not cleaned up"
fi

# --- TC-004: active=false → cleanup + no stdout ---
echo "TC-004: Active=false → cleanup, no output"
TC_DIR=$(setup_test "tc004")
jq -n '{active: false, issue_number: 42}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "recovering"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output"
else
  fail "unexpected stdout: $OUTPUT"
fi
if [ ! -f "$TC_DIR/.rite-compact-state" ]; then
  pass "compact state cleaned up"
else
  fail "compact state not cleaned up"
fi

# --- TC-005: compact_state=normal → no action ---
echo "TC-005: compact_state=normal → no action"
TC_DIR=$(setup_test "tc005")
jq -n '{active: true, issue_number: 42}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "normal"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output for normal state"
else
  fail "unexpected stdout: $OUTPUT"
fi

# --- TC-680-A (Issue #680, AC-LOCAL-2): per-session active=true + recovering → recovery output ---
# Verifies post-compact reads & writes the per-session file (not legacy) when
# schema_version=2 + valid SID + per-session file exists, and that the
# `.active=true` precondition path still triggers recovery.
echo "TC-680-A (Issue #680, AC-LOCAL-2): per-session + recovering → auto-recovery from per-session file"
TC_DIR=$(setup_test "tc680a")
sid680a="aaaabbbb-cccc-dddd-eeee-ffffaaaa1111"
mkdir -p "$TC_DIR/.rite/sessions"
echo "$sid680a" > "$TC_DIR/.rite-session-id"
cat > "$TC_DIR/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
per_session_file="$TC_DIR/.rite/sessions/${sid680a}.flow-state"
jq -n '{active: true, issue_number: 680, phase: "phase5_review", next_action: "review", loop_count: 0, pr_number: 0, branch: "refactor/issue-680-test", session_id: "'"$sid680a"'"}' > "$per_session_file"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-04-30T12:00:00Z", active_issue: 680}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Auto-compact recovery" && echo "$OUTPUT" | grep -q "Issue #680"; then
  pass "TC-680-A: recovery output read from per-session file (.active=true preserved)"
else
  fail "TC-680-A: expected Auto-compact recovery for Issue #680 from per-session, got: $OUTPUT"
fi
# Counter-assertion: compact_state transitioned to normal
cs_state=$(jq -r '.compact_state' "$TC_DIR/.rite-compact-state" 2>/dev/null)
if [ "$cs_state" = "normal" ]; then
  pass "TC-680-A: compact_state transitioned to normal after per-session recovery"
else
  fail "TC-680-A: compact_state expected 'normal', got '$cs_state'"
fi

# --- TC-680-B (Issue #680): per-session active=false + recovering → cleanup ---
echo "TC-680-B (Issue #680): per-session active=false → cleanup (no recovery)"
TC_DIR=$(setup_test "tc680b")
sid680b="22222222-3333-4444-5555-666666666666"
mkdir -p "$TC_DIR/.rite/sessions"
echo "$sid680b" > "$TC_DIR/.rite-session-id"
cat > "$TC_DIR/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
jq -n '{active: false, issue_number: 681}' > "$TC_DIR/.rite/sessions/${sid680b}.flow-state"
jq -n '{compact_state: "recovering"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "TC-680-B: per-session active=false → no recovery output (silent exit)"
else
  fail "TC-680-B: expected silent exit on active=false, got: $OUTPUT"
fi
if [ ! -f "$TC_DIR/.rite-compact-state" ]; then
  pass "TC-680-B: compact_state cleaned up on per-session inactive flow"
else
  fail "TC-680-B: compact_state not cleaned up"
fi

echo ""

# --------------------------------------------------------------------------
# TC-749-STDERR-PASSTHROUGH (Issue #749, AC-1 / AC-LOCAL-1)
# --------------------------------------------------------------------------
echo "TC-749-STDERR-PASSTHROUGH: helper failure → ERROR pass-through + fallback WARNING"

HOOKS_REAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
sbx_749="$(mktemp -d "$TEST_DIR/sbx-hooks-XXXXXX")"
cp -a "$HOOKS_REAL_DIR/." "$sbx_749/"
cat > "$sbx_749/_resolve-flow-state-path.sh" <<'FAKE_RESOLVER_EOF'
#!/bin/bash
echo "ERROR: TC-749 simulated _resolve-flow-state-path failure" >&2
exit 1
FAKE_RESOLVER_EOF
chmod +x "$sbx_749/_resolve-flow-state-path.sh"

# post-compact.sh exits early when no flow_state — provide an active legacy file
# so the resolver path is exercised, the fallback FLOW_STATE points at it, and
# the hook continues to attempt recovery (which will exit silently when there
# is no .rite-compact-state). The point of this TC is the stderr pass-through,
# not the recovery output.
dir_749="$TEST_DIR/tc749-passthrough"
mkdir -p "$dir_749"
jq -n '{active: true, issue_number: 749, phase: "phase5_test", next_action: "test", loop_count: 0, pr_number: 0, branch: "refactor/issue-749-test"}' \
  > "$dir_749/.rite-flow-state"
# Seed compact_state so post-compact.sh actually exercises the recovery transition
# (instead of the early `! -f compact_state` exit path). This lets us assert the
# fallback path was loaded by observing the recovering→normal state transition.
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-04-01T00:00:00Z", active_issue: 749}' \
  > "$dir_749/.rite-compact-state"

stderr_file="$(mktemp "$TEST_DIR/stderr.749.XXXXXX")"
echo "{\"cwd\": \"$dir_749\", \"source\": \"auto\"}" \
  | bash "$sbx_749/post-compact.sh" >/dev/null 2>"$stderr_file" || true
stderr_749="$(cat "$stderr_file")"

if printf '%s' "$stderr_749" | grep -qF 'TC-749 simulated _resolve-flow-state-path failure'; then
  pass "ERROR line from helper passed through to caller stderr"
else
  fail "Expected ERROR pass-through; got stderr: $stderr_749"
fi
if printf '%s' "$stderr_749" | grep -qF 'flow-state path resolution failed, falling back to legacy'; then
  pass "Fallback WARNING emitted to stderr"
else
  fail "Expected fallback WARNING; got stderr: $stderr_749"
fi
# Positive evidence: assert the legacy fallback path was actually used by
# observing the compact_state transition. With compact_state="recovering"
# seeded above, post-compact.sh on the fallback FLOW_STATE should transition
# it to "normal". If the fallback path silently broke, post-compact.sh would
# either ENOENT or transition the wrong file, and compact_state would remain
# "recovering".
compact_state_after=$(jq -r '.compact_state' "$dir_749/.rite-compact-state" 2>/dev/null)
if [ "$compact_state_after" = "normal" ]; then
  pass "Legacy fallback path was loaded (compact_state transitioned recovering→normal)"
else
  fail "Expected compact_state=normal after recovery; got: $compact_state_after"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────
# Reconciliation block runtime coverage (PR != 0 path).
# The block at post-compact.sh lines 158-379 emits 6 distinct incident sentinels
# (state_root_inaccessible / state_root_toctou_race / pr_deleted_or_inaccessible
# / post_compact_gh_pr_view_failed / projects_status_in_review_missing /
# post_compact_reconciliation_failed) but none of TC-001..TC-749 set pr_number
# to a non-zero value, so the entire block is otherwise dark. Exercise it with
# a PATH-injected gh / projects-status-update.sh / workflow-incident-emit.sh
# mock so a misclassification refactor fails here instead of in production.
# ──────────────────────────────────────────────────────────────────────────

_setup_recon_env() {
  local label="$1" gh_behavior="$2" reconcile_result="${3:-updated}"
  local dir="$TEST_DIR/recon-$label"
  mkdir -p "$dir/.git" "$dir/bin"
  # flow-state with pr_number=42 → reconciliation block enters
  jq -n '{active: true, issue_number: 42, phase: "phase5_post_ready", next_action: "Ready", loop_count: 0, pr_number: 42, branch: "feat/issue-42-recon"}' \
    > "$dir/.rite-flow-state"
  jq -n '{compact_state: "recovering", compact_state_set_at: "2026-04-01T00:00:00Z", active_issue: 42}' \
    > "$dir/.rite-compact-state"
  # Minimal rite-config so awk projects.enabled detection picks up `true`
  cat > "$dir/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML

  case "$gh_behavior" in
    pr_view_404)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "could not resolve to a PullRequest with the number of 42" >&2; exit 1 ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo "Todo" ;;
  *) exit 0 ;;
esac
EOF
      ;;
    pr_view_403)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "HTTP 403: rate limit exceeded" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
      ;;
    repo_view_fail)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo "auth required" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
      ;;
    happy)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"In Review"}]}}]}}}}}' ;;
  *) exit 0 ;;
esac
EOF
      ;;
    mismatch_then_reconcile)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}}}}' ;;
  *) exit 0 ;;
esac
EOF
      ;;
  esac
  chmod +x "$dir/bin/gh"

  # Mock projects-status-update.sh — return failure when reconcile_result=failed,
  # otherwise return JSON the reconciliation block expects.
  cat > "$dir/bin/projects-status-update.sh" <<EOF
#!/bin/bash
echo '{"result":"$reconcile_result"}'
EOF
  chmod +x "$dir/bin/projects-status-update.sh"

  echo "$dir"
}

# TC-RECON-02: pr_deleted_or_inaccessible classification (false-positive guard)
echo "TC-RECON-02: gh pr view 'could not resolve PullRequest' → pr_deleted_or_inaccessible classification"
recon_dir=$(_setup_recon_env "pr-deleted" "pr_view_404")
recon_stderr="$(mktemp "$TEST_DIR/recon-pr-deleted-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'pr_deleted_or_inaccessible' "$recon_stderr"; then
  pass "pr_deleted_or_inaccessible root cause hint set (not gh_pr_view_failed)"
else
  fail "expected pr_deleted_or_inaccessible hint; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi
if grep -qE 'post_compact_gh_pr_view_failed' "$recon_stderr"; then
  fail "post_compact_gh_pr_view_failed wrongly emitted for closed-PR case"
else
  pass "post_compact_gh_pr_view_failed NOT emitted for closed-PR case"
fi

# TC-RECON-03: distinguish gh_pr_view_failed (HTTP 403) from pr_deleted
echo "TC-RECON-03: gh pr view 'HTTP 403 rate limit' → post_compact_gh_pr_view_failed classification"
recon_dir=$(_setup_recon_env "pr-403" "pr_view_403")
recon_stderr="$(mktemp "$TEST_DIR/recon-pr-403-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'post_compact_gh_pr_view_failed' "$recon_stderr"; then
  pass "post_compact_gh_pr_view_failed emitted for 403 case"
else
  fail "expected post_compact_gh_pr_view_failed; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi
if grep -qE 'pr_deleted_or_inaccessible' "$recon_stderr"; then
  fail "pr_deleted_or_inaccessible wrongly emitted for 403 case (classification leak)"
else
  pass "pr_deleted_or_inaccessible NOT emitted for 403 case (no classification leak)"
fi

# TC-RECON-04: mktemp degradation surfaces stderr_capture=disabled
echo "TC-RECON-04: mktemp failure tags stderr_capture=disabled in emitted incident"
recon_dir=$(_setup_recon_env "mktemp-fail" "pr_view_403")
# Shadow mktemp to fail only for the pr_view tempfile pattern
cat > "$recon_dir/bin/mktemp" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    /tmp/rite-pc-pr-err-*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$recon_dir/bin/mktemp"
recon_stderr="$(mktemp "$TEST_DIR/recon-mktemp-fail-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'mktemp failed for pr_view_err' "$recon_stderr"; then
  pass "WARNING fired for pr_view_err mktemp failure"
else
  fail "missing pr_view_err mktemp WARNING; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi
if grep -qE 'stderr_capture=disabled' "$recon_stderr"; then
  pass "stderr_capture=disabled tag propagated to emitted incident details"
else
  fail "stderr_capture=disabled tag missing from emitted incident; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi

# TC-RECON-05: happy path emits NO incident sentinel (negative control)
echo "TC-RECON-05: happy reconciliation path → no incident sentinel"
recon_dir=$(_setup_recon_env "happy" "happy" "updated")
recon_stderr="$(mktemp "$TEST_DIR/recon-happy-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'WORKFLOW_INCIDENT=1' "$recon_stderr"; then
  fail "happy path wrongly emitted WORKFLOW_INCIDENT (false positive): $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
else
  pass "happy path emits no WORKFLOW_INCIDENT (negative control)"
fi

# TC-RECON-06: reconcile failed → post_compact_reconciliation_failed hint
echo "TC-RECON-06: reconcile result=failed → post_compact_reconciliation_failed hint"
recon_dir=$(_setup_recon_env "recon-fail" "mismatch_then_reconcile" "failed")
recon_stderr="$(mktemp "$TEST_DIR/recon-failed-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'post_compact_reconciliation_failed' "$recon_stderr"; then
  pass "post_compact_reconciliation_failed emitted when reconcile returns failed"
else
  fail "expected post_compact_reconciliation_failed; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi

# TC-RECON-07: gh repo view failure → cascade emit guard
# Strict count: exactly 1 incident (the repo view failure itself). The
# subsequent graphql / reconcile path is guarded by `exit 0` to prevent
# double-emit; a relaxed `<= 2` threshold would let 0-emit silent drops pass.
echo "TC-RECON-07: gh repo view failure → exactly one repo failure incident"
recon_dir=$(_setup_recon_env "repo-fail" "repo_view_fail")
recon_stderr="$(mktemp "$TEST_DIR/recon-repo-fail-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
incident_count=$(grep -cE 'WORKFLOW_INCIDENT=1' "$recon_stderr" || echo 0)
if [ "$incident_count" -eq 1 ]; then
  pass "repo view failure emits exactly 1 incident sentinel (cascade guard functional)"
else
  fail "repo view failure emitted $incident_count incident sentinels (expected exactly 1)"
fi
if grep -qE 'root_cause_hint=post_compact_gh_repo_view_failed' "$recon_stderr"; then
  pass "TC-RECON-07 emitted incident is attributed to root_cause_hint=post_compact_gh_repo_view_failed"
else
  fail "TC-RECON-07 incident emitted but not attributed via canonical root_cause_hint field: $(head -c 500 "$recon_stderr")"
fi

# TC-CONFIG-PARSE: post-compact.sh が rite-config.yml の awk parse 失敗を silent skip ではなく
# incident emit に乗せる経路を保持していることを static に pin する。awk-gating コードが削除
# された場合や hint string が変わった場合に検出する。behavioral test は gh CLI shim 等が必要で
# 重いため、source grep で contract をピン留めする。
echo "TC-CONFIG-PARSE: awk parse failure routes to incident emit with config_parse_failed hint"
if grep -q 'post_compact_config_parse_failed' "$HOOK"; then
  pass "post-compact.sh contains 'config_parse_failed' root_cause_hint"
else
  fail "post-compact.sh missing 'config_parse_failed' root_cause_hint — awk parse failure may silently fall to 'projects disabled' classification"
fi
if grep -qE '(awk_pe_rc|awk_pn_rc)' "$HOOK"; then
  pass "post-compact.sh distinguishes awk rc (config parse failure vs Projects disabled)"
else
  fail "post-compact.sh missing awk rc capture — awk failure cannot be distinguished from projects.enabled=false"
fi

# TC-RECON-08: command substitution は pipeline ではないため `set -o pipefail` だけでは jq -n の
# 失敗を outer rc に伝播しない。`JQ_PAYLOAD=$(jq -n ...) || JQ_PAYLOAD_RC=$?` の rc capture と
# `post_compact_jq_payload_build_failed` hint emit が削除されると、ENV 不整合 / locale / OOM 起因の
# jq 失敗時に projects status sync が silent に degraded する経路ができる。static pin で回帰防御。
echo "TC-RECON-08: jq -n payload build failure handling is wired (rc capture + jq_payload_build_failed hint)"
if grep -q 'JQ_PAYLOAD_RC' "$HOOK"; then
  pass "post-compact.sh contains JQ_PAYLOAD_RC capture (jq -n failure detection)"
else
  fail "post-compact.sh missing JQ_PAYLOAD_RC capture — command substitution swallows jq -n exit code"
fi
if grep -q 'post_compact_jq_payload_build_failed' "$HOOK"; then
  pass "post-compact.sh contains post_compact_jq_payload_build_failed hint"
else
  fail "post-compact.sh missing post_compact_jq_payload_build_failed hint — jq payload failure cannot be triaged"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
