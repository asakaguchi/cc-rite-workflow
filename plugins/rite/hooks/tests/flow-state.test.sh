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
# Why: session-start auto path silences only stdout. If `migrated:` is gated on --verbose or
# moved to stdout, a real migration becomes silent and violates AC-8 (silent skip forbidden).
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
# Why: grep specificity に v[12]→v3 矢印と phase 変換 token を要求することで、emission format が
# `migrate done:` 等にリネームされた場合も regression を検出できる (format stability invariant)。
echo "$err" | grep -qE 'migrated:.*v[12]→v3.*[a-z_]+→[a-z_]+' \
  && pass "TC-8b-a: non-verbose migrate announces 'migrated:' on stderr with v→v3 + phase tokens" \
  || fail "TC-8b-a: non-verbose migrate format mismatch (expected 'migrated:.*v[12]→v3.*phase→phase'): '$err'"

# Why: v3-only file は migrate 対象外で出力を発生させてはならない。`skip (already v3)` は --verbose
# でのみ出力される invariant も同時に検証する (quiet session start での noise 抑制)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 8 --branch "b" --pr 1 --next "n")
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
if echo "$err" | grep -q "migrated:\|skip (already v3)"; then
  fail "TC-8b-b: non-verbose migrate of v3-only emitted output (should be silent): '$err'"
else
  pass "TC-8b-b: non-verbose migrate of v3-only stays silent"
fi

# Why: AC-8 文面は v1/v2 両方を対象とする。`_migrate_file` の `jq -r '.schema_version // 1'`
# fallback で v1 (schema_version 欠落) と v2 の code path は等価だが、両方を invariant 化することで
# 将来 fallback 削除や schema_version 必須化が起きても regression を即検出できる。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"phase":"cleanup_pre_ingest","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 )
echo "$err" | grep -qE 'migrated:.*v1→v3.*[a-z_]+→[a-z_]+' \
  && pass "TC-8b-c: non-verbose migrate of v1 (schema_version 欠落) announces 'migrated:' on stderr" \
  || fail "TC-8b-c: v1 schema 欠落 migrate did not emit expected 'migrated:.*v1→v3.*phase→phase' format: '$err'"

# Why: `cmd_migrate` は SESSION_DIR/*.flow-state を loop して `_migrate_file` を call するため、
# N 個の v2 file があれば N 行の `migrated:` が emit される。single-file test では loop 内の
# 重複処理や emission 抜けを検出できないため、multi-file の counter 一致を直接 assertion する。
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
# Why: 行頭 anchor `^  migrated:` で固定することで、将来 hook が `Already migrated:` 等の文言を
# 追加した場合の false match を防ぐ (TC-8b-e/g と同じ anchor 形式)。
migrated_count=$(echo "$err" | grep -c '^  migrated:' || true)
if [ "$migrated_count" = "2" ]; then
  pass "TC-8b-d: multi-file migrate emits 'migrated:' per file (count=2)"
else
  fail "TC-8b-d: expected 2 'migrated:' lines but got $migrated_count: '$err'"
fi

# Why: write IO 失敗時に false `migrated:` を emit すると AC-8 invariant が逆方向 (skip を migrated
# と誤報) で破られる。chmod 0555 で sessions dir を readonly にして mv 失敗経路を強制し、
# `migrated:` 行 0 件 + `Migration complete: 0 file` を assert することで、`_atomic_write` の rc
# 伝播が将来削除されても本テストが fail する (write-failure invariant の direct verification)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
# Why (DAC probe): root / fakeroot / CAP_DAC_OVERRIDE 環境では chmod 0555 が DAC override で
# 無効化され write-failure path を強制できない。`id -u` 判定では fakeroot / capability bound
# scenario を捕捉できないため、実機 write probe で write 強制可能性を検出する。silent false-pass
# (write が通る環境で test が pass する誤検出) を防ぐ。
# Why (probe を sandbox 近接に配置): TMPDIR が別 filesystem を指す環境でも probe と sandbox の DAC
# 挙動を一致させるため、probe を sandbox dir 配下に作成する。
# Why: mktemp 失敗時の stderr を一時的に capture することで、TMPDIR が別 fs を指す / inode 枯渇 /
# permission denied 等の root cause を fail message から確認可能にする (silent な原因隠蔽を防ぐ)。
_dac_probe_err=$(mktemp /tmp/rite-dac-probe-err-XXXXXX 2>/dev/null) || _dac_probe_err=""
if ! _dac_probe_parent=$(mktemp -d "$d/_dac_probe.XXXXXX" 2>"${_dac_probe_err:-/dev/null}"); then
  _dac_probe_diag=""
  [ -n "$_dac_probe_err" ] && [ -s "$_dac_probe_err" ] && _dac_probe_diag=" ($(head -1 "$_dac_probe_err"))"
  [ -n "$_dac_probe_err" ] && rm -f "$_dac_probe_err"
  # Why: probe 構築失敗時は silent skip ではなく fail にする。test 自体の構築不能は AC-8 invariant の
  # 検証不能を意味し、observability を確保するため明示的に fail にする。
  fail "TC-8b-e/g: mktemp -d failed for DAC probe parent under $d$_dac_probe_diag"
else
  [ -n "$_dac_probe_err" ] && rm -f "$_dac_probe_err"
  _dac_probe="$_dac_probe_parent/probe"
  mkdir -p "$_dac_probe"
  chmod 0555 "$_dac_probe"
  # Why: redirect-open 失敗時の "Permission denied" 1 行が test output に混入することを避けるため、
  # subshell 内で `>` の open 自体を実行する。shell の redirect-open 失敗 message は `2>` 再リダイレクト
  # の前に直接 stderr へ出力されるため、subshell 化で外側に漏らさない設計。
  if ( echo x > "$_dac_probe/_probe_file" ) 2>/dev/null; then
    chmod +w "$_dac_probe" 2>/dev/null || true
    rm -rf "$_dac_probe_parent"
    pass "TC-8b-e/g: skipped (chmod 0555 ineffective in this env — DAC override / root / fakeroot; write-failure invariant unverifiable)"
  else
    chmod +w "$_dac_probe" 2>/dev/null || true
    rm -rf "$_dac_probe_parent"
    # Why (trap save/restore): 将来 top-level cleanup trap が flow-state.test.sh に導入されても、
    # 本 TC の `trap -` で外側 trap を破壊しないよう既存 trap を保存し eval で復元する。
    # POSIX `trap -p` 出力は shell に reinput 可能な proper quoting 形式であり、既存 trap が
    # 空の場合は `eval ""` が no-op になる (defense-in-depth)。
    # Why (異常終了時の restore): hard-fail test や signal kill (INT/TERM/HUP) で sandbox dir
    # が readonly のまま残ると後続 test が clean state を得られないため trap で restore を保証する。
    _tc8beg_saved_trap=$(trap -p EXIT INT TERM HUP)
    _tc8beg_test_cleanup() { chmod +w "$d/.rite/sessions" 2>/dev/null || true; }
    trap _tc8beg_test_cleanup EXIT INT TERM HUP
    chmod 0555 "$d/.rite/sessions"
    combined=$( (cd "$d" && bash "$HOOK" migrate) 2>&1 )
    chmod +w "$d/.rite/sessions"
    trap - EXIT INT TERM HUP
    eval "$_tc8beg_saved_trap"
    # Why: 解除後の dead function/変数を unset し、後続 TC の shell scope (declare -f / スタック
    # トレース) にノイズが残らないようにする。
    unset -f _tc8beg_test_cleanup
    unset _tc8beg_saved_trap
    migrated_lines=$(echo "$combined" | grep -c '^  migrated:' || true)
    # Why: counter が inflate しない invariant の direct verification。`_atomic_write` 失敗時に
    # `_migrate_file` が rc=1 を返し counter が 0 のままであることを確認する。
    if [ "$migrated_lines" = "0" ] && echo "$combined" | grep -qE 'Migration complete: 0 file'; then
      pass "TC-8b-e/g: write-failure path emits no 'migrated:' and counter stays 0 (AC-8 negative regression + counter invariant)"
    else
      fail "TC-8b-e/g: write-failure path leaked output: migrated_lines=$migrated_lines; combined='$combined'"
    fi
  fi
fi
# Why: TC 内で導入した一時変数を後続 TC の shell scope に残さないため明示 unset する
# (`_tc8beg_test_cleanup` / `_tc8beg_saved_trap` の cleanup precedent と整合)。
unset _dac_probe_err _dac_probe_parent _dac_probe _dac_probe_diag 2>/dev/null || true

# Why: `--dry-run` preview は session-start.sh の stdout-only silence 経路で見える必要があるため
# stderr に出力されることを invariant 化する。stdout に戻る regression を即検出する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
err=$( (cd "$d" && bash "$HOOK" migrate --dry-run >/dev/null) 2>&1 )
if echo "$err" | grep -q 'would migrate:'; then
  pass "TC-8b-f: --dry-run preview goes to stderr"
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

# --- TC-13: AC-4 — CLAUDE_CODE_SESSION_ID env resolves session_id when .rite-session-id is absent ---
echo ""
echo "=== TC-13: AC-4 CLAUDE_CODE_SESSION_ID env-only resolution (Issue #1142) ==="
# Why: Issue #1142 root cause was that `_resolve_session_id` only honored
# CLAUDE_SESSION_ID, but Claude Code runtime sets CLAUDE_CODE_SESSION_ID. When
# `.rite-session-id` was absent, get/set silently degraded (empty + rc=0 / silent skip).
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1142 --branch "fix/issue-1142" --pr 0 --next "n")
# Remove .rite-session-id to force env-var path.
rm -f "$d/.rite-session-id"
got=$(cd "$d" && CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "EMPTY")
assert "TC-13.1: CLAUDE_CODE_SESSION_ID resolves get correctly" "plan" "$got"
(cd "$d" && CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" set --phase pr --next "after-fix" --if-exists)
got=$(cd "$d" && CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "EMPTY")
assert "TC-13.2: CLAUDE_CODE_SESSION_ID resolves set --if-exists correctly" "pr" "$got"
got=$(cd "$d" && CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field next_action --default "EMPTY")
assert "TC-13.3: --if-exists write was not silently skipped" "after-fix" "$got"

# --- TC-14: AC-4 backwards-compat — CLAUDE_SESSION_ID still works ---
echo ""
echo "=== TC-14: AC-4 backwards-compat CLAUDE_SESSION_ID still resolves ==="
# Why: keep the legacy env var name working so any out-of-tree tooling that
# already sets CLAUDE_SESSION_ID does not break.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase implement --issue 1142 --branch "b" --pr 0 --next "n")
rm -f "$d/.rite-session-id"
got=$(cd "$d" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "EMPTY")
assert "TC-14: legacy CLAUDE_SESSION_ID still resolves get" "implement" "$got"

# --- TC-15: AC-3 — cmd_get surfaces _resolve_session_id ERROR (no silencing) ---
echo ""
echo "=== TC-15: AC-3 cmd_get does not silence resolution ERROR ==="
# Why: Issue #1142 — cmd_get used `_resolve_session_id ... 2>/dev/null`, hiding the
# "ERROR: cannot resolve session_id" message. Now stderr must reach the operator.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 )
echo "$err" | grep -q "ERROR: cannot resolve session_id" \
  && pass "TC-15: cmd_get surfaces _resolve_session_id ERROR on stderr" \
  || fail "TC-15: cmd_get silenced resolution ERROR (regression of Issue #1142 fix): '$err'"

# --- TC-16: AC-3 — cmd_get emits WARNING for stale .rite-session-id drift ---
echo ""
echo "=== TC-16: AC-3 cmd_get WARNs on stale .rite-session-id drift ==="
# Why: When `.rite-session-id` resolves to a sid whose state file does not exist,
# the caller's "get value" intent silently degrades to default. Issue #1142 fix
# emits a WARNING to make the drift observable. Truly first-time sessions (no
# `.rite-session-id`) stay silent (graceful no-op).
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
echo "deadbeef-0000-0000-0000-000000000000" > "$d/.rite-session-id"
err=$( (cd "$d" && bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 )
echo "$err" | grep -q "WARNING: flow-state.sh cmd_get: state file not found" \
  && pass "TC-16.1: cmd_get WARNs on stale sid drift" \
  || fail "TC-16.1: cmd_get silent on stale sid drift: '$err'"
# Truly first-time (no .rite-session-id) must stay silent (graceful contract).
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
# The resolution-ERROR is expected here; WARNING about state-file-not-found must NOT
# fire because we never resolved a sid.
echo "$err" | grep -q "WARNING: flow-state.sh cmd_get: state file not found" \
  && fail "TC-16.2: cmd_get emitted state-file WARNING when sid was not resolved (regression)" \
  || pass "TC-16.2: cmd_get silent about state-file-not-found when sid resolution itself failed"

# --- TC-17: AC-2 + AC-3 — cmd_set --if-exists WARNs on stale .rite-session-id drift ---
echo ""
echo "=== TC-17: AC-2/AC-3 cmd_set --if-exists WARNs on stale sid; first-time silent ==="
# Why: Issue #1142 — `--if-exists` silently skipped when sid resolved to a file
# that did not exist (stale `.rite-session-id`). Caller's intent (update active
# session state) was violated without any signal. Fix emits WARNING only when
# `.rite-session-id` exists (caller expected a session), staying silent for the
# truly first-time case that wiki/ingest.md and issue/create.md rely on.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
echo "deadbeef-0000-0000-0000-000000000000" > "$d/.rite-session-id"
err=$( (cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists) 2>&1 )
echo "$err" | grep -q "WARNING: flow-state.sh cmd_set: --if-exists skipped" \
  && pass "TC-17.1: cmd_set --if-exists WARNs on stale sid drift" \
  || fail "TC-17.1: cmd_set --if-exists silent on stale sid drift: '$err'"
# First-time session (no .rite-session-id, no env): silent no-op (legitimate graceful path).
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
# Must succeed silently with rc=0 — the truly-first-time graceful contract.
combined=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists) 2>&1 || true )
# When session_id cannot be resolved at all, cmd_set returns rc=1 with ERROR (not
# silent). This is correct: --if-exists's silent-skip contract applies after sid
# resolution succeeds, not before. The WARNING about "--if-exists skipped" must
# NOT appear because we never reached that branch.
echo "$combined" | grep -q "WARNING: flow-state.sh cmd_set: --if-exists skipped" \
  && fail "TC-17.2: emitted --if-exists WARNING when sid resolution itself failed (regression)" \
  || pass "TC-17.2: silent about --if-exists skip when sid resolution failed (ERROR surfaces instead)"

if ! print_summary "$(basename "$0")" "flow-state.sh PR 2a refactor + Issue #1142 silent-failure fixes"; then
  exit 1
fi
