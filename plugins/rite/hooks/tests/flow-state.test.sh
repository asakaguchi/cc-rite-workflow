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
assert "last_synced_phase preserved (PR #1089 H1: post-tool-wm-sync.sh runtime-only field)" "cleanup" "$(jq -r '.last_synced_phase // "null"' "$state_file")"
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

# --- TC-8b: AC-8 — a performed migration is announced on stderr WITHOUT --verbose ---
echo ""
echo "=== TC-8b: AC-8 non-verbose migrate emits 'migrated:' to stderr; v3-only stays silent ==="
# (a) A v2 file migrated without --verbose MUST still emit 'migrated:' on stderr so the
#     session-start auto path (session-start.sh silences only stdout, passes stderr
#     through) is non-silent. A regression that re-gates this line on --verbose would
#     make startup migration silent and violate AC-8.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
# F-05 対応: format stability invariant も grep specificity で固定する
# `migrated:.*v[12]→v3.*[a-z_]+→[a-z_]+` で v1/v2→v3 矢印と phase 変換 token も assert し、
# 将来 emission format が `migrate done:` 等へ rename される regression を即検出する
echo "$err" | grep -qE 'migrated:.*v[12]→v3.*[a-z_]+→[a-z_]+' \
  && pass "TC-8b-a: non-verbose migrate announces 'migrated:' on stderr with v→v3 + phase tokens (AC-8 + format stability)" \
  || fail "TC-8b-a: non-verbose migrate format mismatch (expected 'migrated:.*v[12]→v3.*phase→phase'): '$err'"

# (b) An already-v3 file migrated without --verbose MUST stay silent (no 'migrated:' and
#     no verbose-only 'skip (already v3)'), so quiet session starts produce no noise.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 8 --branch "b" --pr 1 --next "n")
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
if echo "$err" | grep -q "migrated:\|skip (already v3)"; then
  fail "TC-8b-b: non-verbose migrate of v3-only emitted output (should be silent): '$err'"
else
  pass "TC-8b-b: non-verbose migrate of v3-only stays silent"
fi

# (c) F-04 対応: AC-8 文面は「v1/v2 → v3」両方を対象とするため、v1 (schema_version 欠落) で
#     も同様の `migrated:` emit を assert する。_migrate_file の `jq -r '.schema_version // 1'`
#     fallback により code path は v2 と等価だが、invariant 表現として明示的に固定する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"phase":"cleanup_pre_ingest","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
echo "$err" | grep -qE 'migrated:.*v1→v3.*[a-z_]+→[a-z_]+' \
  && pass "TC-8b-c: non-verbose migrate of v1 (schema_version 欠落) announces 'migrated:' on stderr (AC-8 — v1 path)" \
  || fail "TC-8b-c: v1 schema 欠落 migrate did not emit expected 'migrated:.*v1→v3.*phase→phase' format: '$err'"

# (d) F-06 対応: cmd_migrate は $SESSION_DIR/*.flow-state を loop して各 file で _migrate_file を
#     呼ぶため、N 個の v2 file があれば N 行の `migrated:` が emit される。multi-file emission の
#     invariant を `grep -c` で固定する (single-file の TC-8b-a/c だけでは loop 内の重複処理を
#     検出できない)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
sid2="00000000-0000-0000-0000-000000000002"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
cat > "$d/.rite/sessions/${sid2}.flow-state" <<EOF
{"schema_version":2,"phase":"create_branch","session_id":"$sid2","issue_number":4,"branch":"b2","pr_number":0,"next_action":"y","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
migrated_count=$(echo "$err" | grep -c 'migrated:' || true)
if [ "$migrated_count" = "2" ]; then
  pass "TC-8b-d: multi-file migrate emits 'migrated:' per file (count=2)"
else
  fail "TC-8b-d: expected 2 'migrated:' lines but got $migrated_count: '$err'"
fi

# (e) F-05 対応: cycle 2 で閉塞した最大の経路 (write IO 失敗時の false 'migrated:' 抑止) に対する
#     negative regression test。`chmod 0555` で sessions dir を readonly にして mv が失敗する経路を
#     強制的に作り、`migrated:` 行が 0 件であり、かつ stdout に "Migration complete: 0 file" が出る
#     ことを assert する。これにより `_atomic_write` の `|| return 1` (L236) を将来誰かが削除しても
#     本テストが fail するため、AC-8 invariant の write-failure side が固定される。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
chmod 0555 "$d/.rite/sessions"
combined=$( (cd "$d" && bash "$HOOK" migrate) 2>&1 )
chmod +w "$d/.rite/sessions"
migrated_lines=$(echo "$combined" | grep -c '^  migrated:' || true)
# F-07 対応 (TC-8b-g 統合): Migration complete counter が 0 のままであることを直接 assert する。
# `_atomic_write` 失敗時に counter が inflate しない invariant の direct verification。
if [ "$migrated_lines" = "0" ] && echo "$combined" | grep -qE 'Migration complete: 0 file'; then
  pass "TC-8b-e/g: write-failure path emits no 'migrated:' and counter stays 0 (F-05/F-07 — AC-8 negative regression + counter invariant)"
else
  fail "TC-8b-e/g: write-failure path leaked output: migrated_lines=$migrated_lines; combined='$combined'"
fi

# (f) F-06 対応: cycle 2 で `--dry-run` preview の出力先が stdout → stderr に変更された
#     (_migrate_file L218 `echo "  would migrate: ..." >&2`)。stderr→stdout の出力先変更を test 上で
#     固定し、将来 stdout に戻る regression を即検出する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate --dry-run >/dev/null) 2>&1 )
if echo "$err" | grep -q 'would migrate:'; then
  pass "TC-8b-f: --dry-run preview goes to stderr (F-06 — stdout→stderr regression guard)"
else
  fail "TC-8b-f: --dry-run preview missing from stderr (regression — possibly moved back to stdout): '$err'"
fi

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

# --- TC-11: cmd_set preserves last_synced_phase across merge (PR #1089 H1 regression) ---
echo ""
echo "=== TC-11: cmd_set preserves last_synced_phase (post-tool-wm-sync.sh runtime field) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 11 --branch "b" --pr 0 --next "n")
state_file="$d/.rite/sessions/${sid}.flow-state"
# Simulate post-tool-wm-sync.sh writing last_synced_phase as a runtime-only field.
jq '.last_synced_phase = "plan"' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
# A subsequent cmd_set must NOT wipe last_synced_phase (else wm-sync diff guard would
# fire every hook invocation and spam GitHub API calls).
(cd "$d" && bash "$HOOK" set --phase implement --issue 11 --branch "b" --pr 0 --next "n2")
assert "TC-11: last_synced_phase preserved across cmd_set merge" "plan" "$(jq -r '.last_synced_phase // "null"' "$state_file")"
assert "TC-11: phase updated as expected" "implement" "$(jq -r .phase "$state_file")"

# --- TC-12: cmd_set on corrupt JSON emits WARNING (PR #1089 H3 regression) ---
echo ""
echo "=== TC-12: cmd_set on corrupt existing state emits WARNING (no silent overwrite) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
# Create a corrupt state file (invalid JSON) at the per-session path.
mkdir -p "$d/.rite/sessions"
state_file="$d/.rite/sessions/${sid}.flow-state"
printf '{this is not valid JSON' > "$state_file"
# cmd_set should succeed (defaults applied to merge) BUT emit a WARNING to stderr so
# operator can observe the silent-overwrite-into-zero-state situation.
(cd "$d" && bash "$HOOK" set --phase plan --issue 12 --branch "b" --pr 0 --next "n") 2> "$d/tc12.stderr"
if grep -q "WARNING: flow-state.sh cmd_set: existing state read failed" "$d/tc12.stderr"; then
  pass "TC-12: corrupt-JSON WARNING emitted"
else
  fail "TC-12: no WARNING for corrupt JSON (silent overwrite regression)"
fi
# Resulting file must be valid JSON (write proceeded with defaults).
if jq -e . "$state_file" >/dev/null 2>&1; then
  pass "TC-12: merged write produced valid JSON with defaults"
else
  fail "TC-12: merged write failed to produce valid JSON"
fi

if ! print_summary "$(basename "$0")" "flow-state.sh PR 2a refactor"; then
  exit 1
fi
