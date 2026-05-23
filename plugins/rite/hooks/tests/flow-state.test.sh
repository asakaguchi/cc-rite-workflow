#!/bin/bash
# Tests for plugins/rite/hooks/flow-state.sh (PR 2a refactor)
# Covers AC-2 (atomic write + flock), AC-3 (schema_version v2 → v3 migration)
# and the canonical subcommand contract (set/get/deactivate/migrate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOK="$PLUGIN_ROOT/hooks/flow-state.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: $HOOK not found or not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

# Helper: prepare a sandbox with .rite-session-id and STATE_ROOT detection
new_sandbox() {
  local d sid
  d=$(make_plain_sandbox --soft)
  (cd "$d" && git init -q && echo a > a && git add a && \
    git -c user.email=t@test.local -c user.name=test commit -q -m init) >/dev/null
  sid="$(uuidgen 2>/dev/null || echo "11111111-2222-3333-4444-555555555555")"
  echo "$sid" > "$d/.rite-session-id"
  echo "$d|$sid"
}

# --- TC-1: set creates v3 schema file ---
echo "=== TC-1: set creates v3 schema file with branch (not branch_name) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 42 --branch "feat/issue-42" \
  --pr 0 --next "test next")
state_file="$d/.rite/sessions/${sid}.flow-state"
assert_file_exists_or_fail "state file written" "$state_file" || true
assert "schema_version=3" "3" "$(jq -r .schema_version "$state_file")"
assert "phase=plan" "plan" "$(jq -r .phase "$state_file")"
assert "branch field name = branch" "feat/issue-42" "$(jq -r .branch "$state_file")"
assert "no branch_name field" "null" "$(jq -r '.branch_name // \"null\"' "$state_file" 2>/dev/null || echo 'null')"
assert "active=true default" "true" "$(jq -r .active "$state_file")"
assert "error_count=0" "0" "$(jq -r .error_count "$state_file")"

# --- TC-2: get reads field ---
echo ""
echo "=== TC-2: get reads field and respects --default ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase implement --issue 7 --branch "x" --pr 0 --next "n")
got=$(cd "$d" && bash "$HOOK" get --field phase)
assert "get phase returns implement" "implement" "$got"
got=$(cd "$d" && bash "$HOOK" get --field nonexistent --default "FALLBACK")
assert "get nonexistent returns default" "FALLBACK" "$got"
got=$(cd "$d" && bash "$HOOK" get --field issue_number)
assert "get issue_number returns 7" "7" "$got"

# --- TC-3: deactivate sets active=false ---
echo ""
echo "=== TC-3: deactivate sets active=false and preserves other fields ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase ready --issue 42 --branch "b" --pr 99 --next "ready")
(cd "$d" && bash "$HOOK" deactivate --next "completed")
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "active=false after deactivate" "false" "$(jq -r .active "$state_file")"
assert "phase preserved" "ready" "$(jq -r .phase "$state_file")"
assert "pr_number preserved" "99" "$(jq -r .pr_number "$state_file")"
assert "next_action updated" "completed" "$(jq -r .next_action "$state_file")"

# --- TC-4: --if-exists is no-op when file is missing ---
echo ""
echo "=== TC-4: --if-exists skips when file absent ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists)
if [ -f "$d/.rite/sessions/${sid}.flow-state" ]; then
  fail "TC-4: --if-exists created file even though file did not exist"
else
  pass "TC-4: --if-exists skipped correctly"
fi

# --- TC-5: --preserve-error-count keeps error_count ---
echo ""
echo "=== TC-5: --preserve-error-count keeps error_count across same-phase set ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n")
state_file="$d/.rite/sessions/${sid}.flow-state"
# Manually inject error_count=3 to simulate prior error tracking
jq '.error_count = 3' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n2" --preserve-error-count)
assert "error_count preserved" "3" "$(jq -r .error_count "$state_file")"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n3")
assert "error_count reset without flag" "0" "$(jq -r .error_count "$state_file")"

# --- TC-6: migrate v2 → v3 transforms phase enum and drops legacy fields ---
echo ""
echo "=== TC-6: migrate v2 → v3 reduces cleanup_*/ingest_*/create_* and drops legacy fields ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{
  "schema_version": 2,
  "active": true,
  "issue_number": 100,
  "branch_name": "old-branch",
  "phase": "cleanup_pre_ingest",
  "previous_phase": "cleanup",
  "pr_number": 5,
  "parent_issue_number": 0,
  "next_action": "old",
  "updated_at": "2026-05-22T00:00:00Z",
  "session_id": "${sid}",
  "last_synced_phase": "cleanup"
}
EOF
(cd "$d" && bash "$HOOK" migrate --verbose) >/dev/null 2>&1 || true
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "schema_version bumped to 3" "3" "$(jq -r .schema_version "$state_file")"
assert "cleanup_pre_ingest → cleanup" "cleanup" "$(jq -r .phase "$state_file")"
assert "branch_name → branch (rename)" "old-branch" "$(jq -r .branch "$state_file")"
assert "branch_name dropped" "null" "$(jq -r '.branch_name // "null"' "$state_file")"
assert "previous_phase dropped" "null" "$(jq -r '.previous_phase // "null"' "$state_file")"
assert "last_synced_phase dropped" "null" "$(jq -r '.last_synced_phase // "null"' "$state_file")"
assert "issue_number preserved" "100" "$(jq -r .issue_number "$state_file")"

# --- TC-7: migrate idempotent for already-v3 files ---
echo ""
echo "=== TC-7: migrate skips files already at v3 ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 7 --branch "b" --pr 1 --next "n")
state_file="$d/.rite/sessions/${sid}.flow-state"
before=$(jq -r .updated_at "$state_file")
sleep 1
out=$(cd "$d" && bash "$HOOK" migrate --verbose 2>&1)
after=$(jq -r .updated_at "$state_file")
assert "v3 file is skipped" "$before" "$after"
echo "$out" | grep -q "skip (already v3)" && pass "TC-7: skip message shown" || fail "TC-7: no skip message"

# --- TC-8: migrate maps various legacy phases correctly ---
echo ""
echo "=== TC-8: migrate phase reduction matrix (cleanup_*/ingest_*/create_*/implementing) ==="
# Note: `implementing` legacy phase maps to v3 `implement` (not `init`) because
# the v3 SoT enum keeps the `implement` value (`init branch plan implement lint
# pr review fix ...`). Only create_*/parent_progress_sync/unknown collapse into
# init.
for legacy_phase in cleanup_post_ingest cleanup_completed ingest_pre_lint ingest_post_lint ingest_completed create_interview create_completed implementing; do
  case "$legacy_phase" in
    cleanup_*) expected=cleanup ;;
    ingest_*) expected=ingest ;;
    implementing) expected=implement ;;
    create_*) expected=init ;;
  esac
  result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
  mkdir -p "$d/.rite/sessions"
  cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"$legacy_phase","session_id":"$sid","issue_number":0,"branch":"","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
  (cd "$d" && bash "$HOOK" migrate >/dev/null 2>&1) || true
  got=$(jq -r .phase "$d/.rite/sessions/${sid}.flow-state")
  assert "migrate $legacy_phase → $expected" "$expected" "$got"
done

# --- TC-9: phase enum validation warns but accepts unknown phase ---
echo ""
echo "=== TC-9: unknown phase warns but writes file (non-strict mode) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase unknown_phase --issue 1 --branch "b" --pr 0 --next "n") 2> "$d/stderr"
state_file="$d/.rite/sessions/${sid}.flow-state"
assert_file_exists_or_fail "state file written despite unknown phase" "$state_file" || true
grep -q "WARNING: unknown phase" "$d/stderr" && pass "TC-9: warning emitted" || fail "TC-9: no warning"

# --- TC-10: concurrent writes do not corrupt JSON (flock smoke test) ---
echo ""
echo "=== TC-10: concurrent set calls preserve JSON integrity ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(
  cd "$d"
  for i in 1 2 3 4 5; do
    bash "$HOOK" set --phase plan --issue "$i" --branch "b$i" --pr "$i" --next "n$i" &
  done
  wait
)
state_file="$d/.rite/sessions/${sid}.flow-state"
if jq -e . "$state_file" >/dev/null 2>&1; then
  pass "TC-10: JSON integrity preserved after 5 concurrent writes"
else
  fail "TC-10: JSON corrupted by concurrent writes"
fi

if ! print_summary "$(basename "$0")" "flow-state.sh PR 2a refactor"; then
  exit 1
fi
