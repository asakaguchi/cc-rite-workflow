#!/bin/bash
# Tests for verify-terminal-output.sh (Issue #561 regression guard)
# Usage: bash plugins/rite/hooks/tests/verify-terminal-output.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../verify-terminal-output.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: create a minimal valid plugin tree at a given root
# Layout: {root}/commands/issue/create-{register,decompose,interview}.md
#         {root}/skills/rite-workflow/SKILL.md
#         {root}/skills/rite-workflow/references/workflow-identity.md
setup_plugin_tree() {
  local repo_root="$1"
  # create_completed_form: create-register / create-decompose の sentinel 形式 (HTML-comment or bare)。
  # PR #926 verified-review M16 対応で旧 `html_comment` boolean を後方互換のまま意味を明文化:
  #   "true"  → HTML-commented form (`<!-- [create:completed:{N}] -->`) — register/decompose 用、Test 1 happy path
  #   "false" → bare sentinel form (`[create:completed:{N}]`) — register/decompose 用、Test 2 regression case
  # create-interview は別途 `interview_form` で制御 (parent-routing pattern 後は独立)。
  local html_comment="${2:-true}"
  # PR-2 #920 以降 create-interview は bare bracket form (parent-routing pattern)。
  # "html" を渡すと旧 HTML-commented form を fixture に書き込み Test 8 negative assertion を検証する。
  local interview_form="${3:-bare}"
  # When invoked with --repo-root, the script looks under {repo_root}/plugins/rite/
  local root="$repo_root/plugins/rite"

  mkdir -p "$root/commands/issue" "$root/skills/rite-workflow/references"

  if [ "$html_comment" = "true" ]; then
    local sentinel_create='<!-- [create:completed:{N}] -->'
  else
    local sentinel_create='[create:completed:{N}]'
  fi

  # create-interview sentinel form は html_comment と独立。PR-2 #920 で bare bracket form に
  # 移行済 (parent-routing pattern) のため、デフォルトは bare。"html" を渡せば旧形式 (Test 8
  # negative assertion の positive case で利用)。
  # verify-terminal-output.sh Check 3 の negative assertion は **独立行** の HTML-commented sentinel のみを
  # 検出するため (false-positive 防止)、Test 8 では fixture を独立行で書き込む。
  if [ "$interview_form" = "html" ]; then
    local sentinel_interview_html_block=$'<!-- [interview:completed] -->\n<!-- [interview:skipped] -->'
    local sentinel_interview=""  # 旧形式は別途下で出力
  else
    local sentinel_interview='[interview:completed] / [interview:skipped]'
    local sentinel_interview_html_block=""
  fi

  cat > "$root/commands/issue/create-register.md" <<EOF
# create-register
Test fixture. Sentinel form: $sentinel_create
EOF
  cat > "$root/commands/issue/create-decompose.md" <<EOF
# create-decompose
Test fixture. Sentinel form: $sentinel_create
EOF
  if [ -n "$sentinel_interview_html_block" ]; then
    # HTML-commented form を独立行として書き込む (Test 8 negative assertion 検証用)
    cat > "$root/commands/issue/create-interview.md" <<EOF
# create-interview
Test fixture (HTML-commented form, intentional regression):
$sentinel_interview_html_block
EOF
  else
    cat > "$root/commands/issue/create-interview.md" <<EOF
# create-interview
Test fixture. Sentinel form: $sentinel_interview
EOF
  fi
  cat > "$root/skills/rite-workflow/SKILL.md" <<'EOF'
# rite-workflow SKILL
workflow は途中で止まらない
meaningful_terminal_output
EOF
  cat > "$root/skills/rite-workflow/references/workflow-identity.md" <<'EOF'
# workflow-identity
no_mid_workflow_stop
meaningful_terminal_output
EOF
}

# Test 1: happy path — HTML-commented sentinel in all 3 files
echo "Test 1: Happy path (all HTML-commented)"
setup_plugin_tree "$TEST_DIR/test1"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test1" >/dev/null 2>&1; then
  pass "exit 0 on valid HTML-commented sentinels"
else
  fail "expected exit 0, got $?"
fi

# Test 2: regression — bare sentinel form in all 3 files (should FAIL)
echo "Test 2: Regression — bare sentinel form"
setup_plugin_tree "$TEST_DIR/test2" "false"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test2" >/dev/null 2>&1; then
  fail "expected exit 1 on bare sentinel form, got exit 0"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on bare sentinel form"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 3: AC-3 non-regression — missing [create:completed:] string entirely
echo "Test 3: AC-3 regression — sentinel string missing"
setup_plugin_tree "$TEST_DIR/test3"
# Overwrite create-register.md with no sentinel at all
cat > "$TEST_DIR/test3/plugins/rite/commands/issue/create-register.md" <<'EOF'
# create-register
No sentinel whatsoever. Pure prose.
EOF
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test3" >/dev/null 2>&1; then
  fail "expected exit 1 when sentinel string is missing, got exit 0"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on missing sentinel string (AC-3 regression detection)"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 4: --help exits 0 (UNIX convention, Issue #582 F-08)
echo "Test 4: --help returns exit 0"
if bash "$HOOK" --help >/dev/null 2>&1; then
  pass "--help exits 0 (UNIX convention)"
else
  fail "--help should exit 0, got $?"
fi

# Test 5: unknown argument exits 2 (usage error)
echo "Test 5: Unknown argument returns exit 2"
if bash "$HOOK" --nonexistent-flag >/dev/null 2>&1; then
  fail "expected exit 2 on unknown flag, got exit 0"
else
  rc=$?
  if [ "$rc" = "2" ]; then
    pass "exit 2 on unknown flag (usage error)"
  else
    fail "expected exit 2, got $rc"
  fi
fi

# Test 6: --repo-root with missing directory exits 2
echo "Test 6: --repo-root with non-existent directory"
if bash "$HOOK" --repo-root "/nonexistent/path/xyz123" >/dev/null 2>&1; then
  fail "expected exit 2 on missing --repo-root path, got exit 0"
else
  rc=$?
  if [ "$rc" = "2" ]; then
    pass "exit 2 on missing --repo-root directory"
  else
    fail "expected exit 2, got $rc"
  fi
fi

# Test 7: marketplace layout — plugin root without {repo}/plugins/rite/ prefix
echo "Test 7: Marketplace layout (no plugins/rite/ prefix, Issue #582 F-05)"
# Marketplace layout: hooks/ sits directly under plugin_root (not under plugins/rite/)
# Simulate by copying hook to a nested location and invoking without --repo-root
# (triggers SCRIPT_DIR/.. fallback → plugin root = test7 directory itself)
mkdir -p "$TEST_DIR/test7/hooks" "$TEST_DIR/test7/commands/issue" "$TEST_DIR/test7/skills/rite-workflow/references"
cp "$HOOK" "$TEST_DIR/test7/hooks/verify-terminal-output.sh"
chmod +x "$TEST_DIR/test7/hooks/verify-terminal-output.sh"
# Write fixtures at plugin root (no plugins/rite/ prefix)
cat > "$TEST_DIR/test7/commands/issue/create-register.md" <<'EOF'
# register
<!-- [create:completed:{N}] -->
EOF
cat > "$TEST_DIR/test7/commands/issue/create-decompose.md" <<'EOF'
# decompose
<!-- [create:completed:{N}] -->
EOF
cat > "$TEST_DIR/test7/commands/issue/create-interview.md" <<'EOF'
# interview
[interview:completed] [interview:skipped]
EOF
cat > "$TEST_DIR/test7/skills/rite-workflow/SKILL.md" <<'EOF'
workflow は途中で止まらない
meaningful_terminal_output
EOF
cat > "$TEST_DIR/test7/skills/rite-workflow/references/workflow-identity.md" <<'EOF'
no_mid_workflow_stop
meaningful_terminal_output
EOF
# Invoke from inside test7 (non-git directory, so git rev-parse fails, forcing SCRIPT_DIR/.. fallback)
# Run in sub-shell so our own git detection doesn't leak cwd
# IMPORTANT: `if ...; then ... else ...` form to bypass `set -e` abort when subshell exits non-zero
# (Test 1-6 と同じ形式に揃えることで、回帰発生時も fail カウントが正しく記録される)
if (cd "$TEST_DIR/test7" && bash "$TEST_DIR/test7/hooks/verify-terminal-output.sh" --quiet >/dev/null 2>&1); then
  pass "marketplace layout passes when fixtures present at plugin root"
else
  rc=$?
  fail "expected exit 0 on marketplace layout with valid fixtures, got $rc"
fi

# Test 8: regression — HTML-commented [interview:*] form (parent-routing pattern violation)
# parent-routing pattern 移行で create-interview は bare bracket form に移行済。
# HTML-commented form が混入したら verify-terminal-output.sh Check 3 の negative assertion が exit 1 を返す必要がある。
#
# Rationale (PR #926 verified-review M15 対応 — Test 8 regex に `error` を含めない理由):
# verify-terminal-output.sh Check 3 の negative assertion regex (`^...<!-- [interview:(completed|skipped)] -->...$`)
# は `[interview:error]` を意図的に regex 対象外にしている。`[interview:error]` は parent-routing pattern
# と同時に新規導入された catastrophic halt sentinel で、historical HTML-comment form を持たない
# (= revert 経路自体が存在しない) ため、negative assertion に含める必要がない。AC-3 non-regression (raw string presence)
# 側では `[interview:(completed|skipped|error)]` の 3 alternation で error を含む点に注意。
echo "Test 8: Regression — HTML-commented [interview:*] form should fail"
setup_plugin_tree "$TEST_DIR/test8" "true" "html"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test8" >/dev/null 2>&1; then
  fail "expected exit 1 when create-interview.md uses HTML-commented [interview:*] form, got exit 0"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on HTML-commented [interview:*] (parent-routing pattern violation detected)"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 8b: false-positive prevention — inline HTML-comment in prose should NOT trigger
# rationale prose 内に inline HTML-comment 形式の sentinel literal が含まれていても、
# verify-terminal-output.sh Check 3 の line-anchored regex (^...$) は match してはならない。
echo "Test 8b: false-positive prevention — inline HTML-comment in rationale prose"
setup_plugin_tree "$TEST_DIR/test8b" "true" "bare"
# bare bracket form で正常 setup された create-interview.md に inline HTML-comment を含む rationale 行を追加
# 行頭/行末 anchor を持つ regex は inline 出現に match しないため、本 fixture では exit 0 を期待する
echo "Old form was <!-- [interview:completed] --> historically (inline mention in prose)." >> "$TEST_DIR/test8b/plugins/rite/commands/issue/create-interview.md"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test8b" >/dev/null 2>&1; then
  pass "exit 0 on inline HTML-comment in prose (line-anchored regex correctly avoids false positive)"
else
  rc=$?
  fail "expected exit 0 on inline HTML-comment in prose, got $rc (line-anchored regex broke)"
fi

# Test 8c: false-positive prevention — backtick-wrapped literal in rationale should NOT trigger
echo "Test 8c: false-positive prevention — backtick-wrapped literal in migration note"
setup_plugin_tree "$TEST_DIR/test8c" "true" "bare"
# Migration note 等で sentinel を backtick で quote するのは自然な編集 pattern。
# 行頭が "Migration note:" 等の prose で始まるため、line-anchored regex (^[[:space:]]*<!--) は match しない。
echo 'Migration note: `<!-- [interview:completed] -->` was the old form.' >> "$TEST_DIR/test8c/plugins/rite/commands/issue/create-interview.md"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test8c" >/dev/null 2>&1; then
  pass "exit 0 on backtick-wrapped HTML-comment literal in rationale prose"
else
  rc=$?
  fail "expected exit 0 on backtick-wrapped literal, got $rc (line-anchored regex broke)"
fi

# Test 8d: skipped form alternation coverage — HTML-commented [interview:skipped] alone should also fail
# Test 8 fixture では completed/skipped が連続行で書かれるため regex の (skipped) alternation 削除を catch できない。
# skipped のみ独立行で配置することで alternation 健全性を pin する。
echo "Test 8d: HTML-commented [interview:skipped] alone should fail (alternation coverage)"
setup_plugin_tree "$TEST_DIR/test8d" "true" "bare"
# bare form で setup した create-interview.md を skipped のみ HTML-comment 化に上書き
cat > "$TEST_DIR/test8d/plugins/rite/commands/issue/create-interview.md" <<'EOF'
# create-interview
Test fixture (skipped only HTML-commented):
[interview:completed]
<!-- [interview:skipped] -->
EOF
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test8d" >/dev/null 2>&1; then
  fail "expected exit 1 when [interview:skipped] alone is HTML-commented, got exit 0 (alternation regression)"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on standalone HTML-commented [interview:skipped] (alternation healthy)"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 8e: completed form alternation coverage — HTML-commented [interview:completed] alone should also fail
# Test 8d と対称。Test 8d (skipped alone) では regex の (completed) branch が削除されても通過してしまうため、
# completed のみ独立行で HTML-comment 化した fixture を配置し、(completed) alternation の健全性を pin する。
echo "Test 8e: HTML-commented [interview:completed] alone should fail (alternation symmetry with Test 8d)"
setup_plugin_tree "$TEST_DIR/test8e" "true" "bare"
cat > "$TEST_DIR/test8e/plugins/rite/commands/issue/create-interview.md" <<'EOF'
# create-interview
Test fixture (completed only HTML-commented):
<!-- [interview:completed] -->
[interview:skipped]
EOF
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test8e" >/dev/null 2>&1; then
  fail "expected exit 1 when [interview:completed] alone is HTML-commented, got exit 0 (alternation regression)"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on standalone HTML-commented [interview:completed] (alternation symmetry healthy)"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Summary
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
