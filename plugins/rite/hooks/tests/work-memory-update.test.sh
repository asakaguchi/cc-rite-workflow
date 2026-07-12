#!/bin/bash
# Tests for hooks/work-memory-update.sh — caller-side AC-4 migration verification.
#
# Covers the acceptance criteria from caller perspective:
#   AC-4 — caller (work-memory-update.sh) integrates with flow-state.sh transparently:
#          (TC-1) per-session file present + legacy absent + WM_REQUIRE_FLOW_STATE=true
#                 → return 0 with WM updated (cycle 12 false negative regression guard)
#          (TC-2) both files absent + WM_REQUIRE_FLOW_STATE=true
#                 → return 1 (skip, no WM written)
#          (TC-3) WM_READ_FROM_FLOW_STATE=true + per-session file with pr_number=100/loop_count=3
#                 → generated WM frontmatter contains pr_number: 100 / loop_count: 3
#                 (cycle 10 stale residue regression guard)
#   AC-7 — regression test discoverable under hooks/tests/
#
# Removed (PR 2a refactor, v3 SoT):
#   (TC-4) schema_version=1 + legacy `.rite-flow-state` file present — the
#          legacy single-file path was retired in Phase E (commit bf5a2415);
#          v1/v2 files are now one-shot migrated to v3 per-session form by
#          flow-state.sh migrate at session-start, not handled inline by
#          work-memory-update.sh.
#
# Usage: bash plugins/rite/hooks/tests/work-memory-update.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/../work-memory-update.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: work-memory-update.sh missing: $HELPER" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not installed" >&2
  exit 1
fi

# Source common helpers for make_sandbox.
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

cleanup_dirs=()
_wm_update_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0  # Form B (portability variant) → return 0 必須 (bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照)
}
trap '_wm_update_test_cleanup' EXIT
trap '_wm_update_test_cleanup; exit 130' INT
trap '_wm_update_test_cleanup; exit 143' TERM
trap '_wm_update_test_cleanup; exit 129' HUP

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
  local name="$1" expected_substring="$2" actual="$3"
  if [[ "$actual" == *"$expected_substring"* ]]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected substring: $expected_substring"
    echo "     actual:             $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# make_sandbox is now provided by _test-helpers.sh; callers below
# invoke `make_sandbox --branch fix/issue-687-test` to preserve the
# branch-based issue-number extraction path validated by TC-1.
# The fix/issue-687-test branch name is the SoT for EXPECTED_ISSUE_NUM=687
# below (any branch rename would require both call sites to sync).

# rite-config.yml sandbox marker. flow-state is always per-session (no
# `flow_state.schema_version` selection), so the fixture writes a
# neutral config rather than modeling the removed schema_version key.
write_config() {
  printf '# rite test sandbox config\n' > "$1/rite-config.yml"
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

write_per_session() {
  mkdir -p "$1/.rite/sessions"
  printf '%s' "$3" > "$1/.rite/sessions/${2}.flow-state"
}

write_legacy() {
  printf '%s' "$2" > "$1/.rite-flow-state"
}

run_update() {
  local d="$1"
  shift
  # 残りの引数 (KEY=VALUE 形式) を env に渡し、その後 bash -c で関数を呼ぶ
  (cd "$d" && env WM_PLUGIN_ROOT="$PLUGIN_ROOT" "$@" bash -c \
    'source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh" && update_local_work_memory')
}

# --- TC-1: per-session present + legacy absent + WM_REQUIRE_FLOW_STATE=true ---
# cycle 12 fix の core invariant: WM_REQUIRE_FLOW_STATE check が legacy file 直接 [ -f ] check ではなく
# flow-state.sh 経由になったので per-session のみで skip しない
echo "TC-1: per-session present + legacy absent + WM_REQUIRE_FLOW_STATE=true → return 0 (cycle 12 false negative regression guard)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":42,"loop_count":2,"active":true}'
# legacy は意図的に作成しない (per-session only path)

# Cycle 16 fix (F-01 MEDIUM cross-validated 3 reviewers): TC-1.2 dead code 削除。
# work-memory-update.sh の update_local_work_memory 関数内の branch-based issue_number 抽出
# (`grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+'` chain) は数字のみ抽出するため、
# branch=fix/issue-687-test では生成 file 名は issue-687.md (not 687-test)。
# issue-687-test.md を期待する if 分岐は数字のみ抽出する extraction chain と矛盾するため到達せず、
# 常に else 経路 (WM_ISSUE_NUMBER override) が実行される dead 分岐になる。本 TC は branch-based
# extraction の結果 (issue-687.md) を直接 assert し、その dead 分岐への退行を guard する。
# branch-based extraction の直接検証 (cycle 12 false negative regression guard):
# `make_sandbox --branch fix/issue-687-test` が指定の branch を作るため、branch parsing が `687`
# を抽出して `.rite-work-memory/issue-687.md` を生成することを確認する。
#
# F-06 LOW (branch-name coupling 軽減): make_sandbox 呼び出しで渡している
# `--branch fix/issue-687-test` 引数と本 TC の assertion で参照する issue 番号 (687) を local var
# で 1 か所に集約。cycle 3 F-01: make_sandbox は _test-helpers.sh の共通 helper に
# 集約されたため、コメントの「関数内」は誤り — call site の `--branch` 引数が SoT。
# branch 名を変更する場合は本 var と make_sandbox --branch 引数の両方を同期更新する。
EXPECTED_ISSUE_NUM=687  # make_sandbox --branch 引数 "fix/issue-687-test" (下記 call site 参照) から抽出される値 (branch 名を変更する場合は本 var と --branch 引数の両方を同期更新)
if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_REQUIRE_FLOW_STATE="true"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-1.1: return 0 (per-session resolved via flow-state.sh, branch parsing extracts ${EXPECTED_ISSUE_NUM})" "0" "$rc"
assert_eq "TC-1.2: WM file created via branch parsing (issue-${EXPECTED_ISSUE_NUM}.md)" "yes" \
  "$([ -f "$SBX/.rite-work-memory/issue-${EXPECTED_ISSUE_NUM}.md" ] && echo yes || echo no)"

# --- TC-2: both files absent + WM_REQUIRE_FLOW_STATE=true ---
echo "TC-2: per-session/legacy 両不在 + WM_REQUIRE_FLOW_STATE=true → return 1 (skip)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config "$SBX"
write_session_id "$SBX" "22222222-2222-2222-2222-222222222222"
# per-session は作成しない、legacy も作成しない

if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_REQUIRE_FLOW_STATE="true" WM_ISSUE_NUMBER="687"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-2.1: return 1 (両 file 不在で skip)" "1" "$rc"
assert_eq "TC-2.2: WM file NOT created" "no" \
  "$([ -f "$SBX/.rite-work-memory/issue-687.md" ] && echo yes || echo no)"

# --- TC-3: WM_READ_FROM_FLOW_STATE=true + per-session has pr_number/loop_count ---
echo "TC-3: per-session pr_number=100 loop_count=3 + WM_READ_FROM_FLOW_STATE=true → frontmatter 反映 (cycle 10 stale residue regression guard)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config "$SBX"
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":100,"loop_count":3,"active":true}'
# legacy には別の値を入れて per-session 優先を確認
write_legacy "$SBX" '{"phase":"stale","next_action":"stale","pr_number":999,"loop_count":99,"active":false}'

if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_READ_FROM_FLOW_STATE="true" WM_ISSUE_NUMBER="687"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-3.1: return 0" "0" "$rc"
WM_FILE="$SBX/.rite-work-memory/issue-687.md"
if [ -f "$WM_FILE" ]; then
  body=$(cat "$WM_FILE")
  assert_contains "TC-3.2: pr_number=100 (per-session 値、legacy 999 を override)" "pr_number: 100" "$body"
  assert_contains "TC-3.3: loop_count=3 (per-session 値、legacy 99 を override)" "loop_count: 3" "$body"
else
  echo "  ❌ TC-3.2/3.3: WM file not created at $WM_FILE"
  FAIL=$((FAIL+2))
  FAILED_NAMES+=("TC-3.2" "TC-3.3")
fi

# TC-4 removed (PR 2a refactor): schema_version=1 + legacy file path is no
# longer reachable. flow-state.sh always writes / reads per-session files at
# `.rite/sessions/<sid>.flow-state`; the legacy single-file form is gone.
# Backward compat for legacy state has migrated to flow-state.sh migrate
# (one-shot v1/v2 → v3 conversion at session-start), not to a parallel
# read path inside work-memory-update.sh.

# ─── TC-5: 蓄積セクション保持 (AC-3) ───────────────────────────────
# `## Detail` 以下に追記された蓄積セクション (「決定事項・メモ」等) がフェーズ遷移更新
# (WM_BODY_TEXT による body 再構築) 後も保持されることを検証する。stock の先頭
# Phase:/Branch: 行は最新値で再生成され、それ以外の蓄積内容が verbatim で残る契約。
echo "TC-5: 蓄積セクション保持 (フェーズ遷移更新で Detail 以下が消えない)"
SBX5=$(make_sandbox --branch fix/issue-687-test)
cleanup_dirs+=("$SBX5")
write_config "$SBX5"

# 1 回目の更新で WM ファイルを生成
run_update "$SBX5" \
  WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="impl" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="First body." WM_ISSUE_NUMBER="687" >/dev/null 2>&1 || true
WM_FILE5="$SBX5/.rite-work-memory/issue-687.md"
# 蓄積セクションを Detail 以下に追記 (pr-review 7.4.3 フォールバック相当の追記を模擬)
cat >> "$WM_FILE5" <<'ACCUM_EOF'

### 決定事項・メモ
- 2026-07-13: 重要な設計判断テスト行

### 計画逸脱ログ
- S2: 逸脱テスト行
ACCUM_EOF

# 2 回目の更新 (フェーズ遷移)
if run_update "$SBX5" \
  WM_SOURCE="ready" WM_PHASE="ready" WM_PHASE_DETAIL="Ready処理完了" \
  WM_NEXT_ACTION="merge" WM_BODY_TEXT="Second body." WM_ISSUE_NUMBER="687" >/dev/null 2>&1; then
  rc5=0
else
  rc5=$?
fi
assert_eq "TC-5.1: return 0" "0" "$rc5"
if [ -f "$WM_FILE5" ]; then
  body5=$(cat "$WM_FILE5")
  assert_contains "TC-5.2: 決定事項・メモ の追記が保持される" "重要な設計判断テスト行" "$body5"
  assert_contains "TC-5.3: 計画逸脱ログ の追記が保持される" "S2: 逸脱テスト行" "$body5"
  assert_contains "TC-5.4: サマリー領域は新 WM_BODY_TEXT に置換される" "Second body." "$body5"
  assert_contains "TC-5.5: stock Phase 行は最新 phase で再生成される" $'## Detail\nPhase: ready' "$body5"
  # stock Phase:/Branch: 行が重複していないこと (保持ロジックが stock 行を二重化しない)
  phase_line_count=$(printf '%s\n' "$body5" | grep -c '^Phase: ' || true)
  assert_eq "TC-5.6: Phase 行が 1 本のみ (stock 行の二重化なし)" "1" "$phase_line_count"
else
  echo "  ❌ TC-5.x: WM file not created at $WM_FILE5"
  FAIL=$((FAIL+5))
  FAILED_NAMES+=("TC-5.2" "TC-5.3" "TC-5.4" "TC-5.5" "TC-5.6")
fi

echo
echo "─── work-memory-update.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All tests passed."
