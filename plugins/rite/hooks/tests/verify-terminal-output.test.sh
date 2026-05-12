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
# 4 signal trap で SIGINT/SIGTERM/SIGHUP
# 中断時にも `$TEST_DIR` (mktemp -d) が確実に削除されるよう拡張。姉妹テスト
# `and-logic-defense-chain.test.sh` (4 signal 対応済) と対称化する。
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

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
  # html_comment: create-register / create-decompose の sentinel 形式選択。
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

# Test 2: regression — bare sentinel form in register/decompose
# (I-10: create-interview default bare is canonical post-PR-2、
# 本テストの fail trigger は register/decompose の bare form のみ)
echo "Test 2: Regression — bare sentinel form (register/decompose only)"
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
# Rationale — Test 8 regex に `error` を含めない理由:
# verify-terminal-output.sh Check 3 の negative assertion regex (`^...<!-- [interview:(completed|skipped)] -->...$`)
# は `[interview:error]` を意図的に regex 対象外にしている。`[interview:error]` は parent-routing pattern
# と同時に新規導入された catastrophic halt sentinel で、historical HTML-comment form を持たない
# (= revert 経路自体が存在しない) ため、negative assertion に含める必要がない。AC-3 non-regression (raw string presence)
# 側では `[interview:(completed|skipped|error)]` の 3 alternation で error を含む点に注意。
#
# Orthogonality (pr-test-analyzer IMP-4): `[interview:error]` の sentinel raw presence は本テストでは
# Test 8 範囲外。`parent-routing-pattern-interim.test.sh` TC-7c (pre-check-routing.md 4 sentinel
# dispatcher grep target pin) が 3 sentinel literal (`[interview:completed]` / `[interview:skipped]`
# / `[interview:error]`) すべての存在を pin する。coverage 自体は split されているが既存。
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

# Test 9: M6 path — unexpected git error class (not 'not a git repository' / 'dubious ownership')
# verify-terminal-output.sh の else branch (exit 1) を pin する。
# 偽の git binary を PATH の先頭に置き、git rev-parse が `fatal: ...` 等の予期しない error を
# 返す経路で silent marketplace fallback に流れないことを runtime で検証する。
echo "Test 9: unexpected git error class should exit 1 (M6 path runtime verification)"
mkdir -p "$TEST_DIR/test9/bin"
cat > "$TEST_DIR/test9/bin/git" <<'FAKEGIT_EOF'
#!/bin/bash
echo "fatal: simulated unexpected git error (permission denied / corrupt index / binary missing)" >&2
exit 128
FAKEGIT_EOF
chmod +x "$TEST_DIR/test9/bin/git"
setup_plugin_tree "$TEST_DIR/test9" "true" "bare"
# I-13: fake git 起動を pre-flight assertion で検証する。
# CI 環境差 (PATH ordering の差 / chmod ビット消失 / shebang 解釈失敗) で fake git が起動せず
# real git に fallback して Test 9 が silent skip するリスクを排除する。
# 期待: fake git は stderr に "simulated unexpected git error" を含む fatal メッセージを emit する。
# pr-test-analyzer M-1: probe 側も append で統一する (bash 非標準パス環境で git binary が
# /usr/bin / /bin にない実環境を想定した defense-in-depth)
fake_git_probe=$(PATH="$TEST_DIR/test9/bin:$PATH" git rev-parse --show-toplevel 2>&1 || true)
if printf '%s' "$fake_git_probe" | grep -q 'simulated unexpected git error'; then
  :  # fake git 起動確認 OK
else
  # fake-git probe 失敗時に Test 9 を継続すると real git に fallback して
  # silent false-positive pass する経路があるため fail-fast する (precondition check の対称化、Phase 1.5 と同型)。
  echo "  ❌ Test 9 pre-flight: fake git binary が起動しない (probe output: $fake_git_probe)" >&2
  echo "  原因候補: PATH ordering / chmod ビット消失 / shebang 解釈失敗" >&2
  cleanup
  exit 1
fi
# PATH=... を bash 直前に置くことで bash プロセス自身に PATH を渡す
# (PATH=... cd ... は cd builtin にのみ PATH を設定する罠を回避)
# pr-test-analyzer M-1: PATH を **append** で組み立てる (非標準 bash パス環境 = macOS の
# /usr/local/bin/bash 等で `bash` 自体が見つからず Test 9/10 が起動しない経路を防ぐ。
# probe 側 line 339 は既に append、本 hook invocation 側を統一)。
if (cd "$TEST_DIR/test9" && PATH="$TEST_DIR/test9/bin:$PATH" bash "$HOOK" --quiet >/dev/null 2>&1); then
  fail "expected exit 1 when git rev-parse returns unexpected error class, got exit 0 (silent marketplace fallback regression)"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on unexpected git error class (M6 path: fail-fast on non-marketplace git failures)"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 10: M6 path — 'dubious ownership' fallback branch (positive case)
# safe.directory 違反シミュレーション。偽の git binary が `fatal: detected dubious ownership` を
# stderr に emit する場合、verify-terminal-output.sh は legitimate marketplace fallback として
# SCRIPT_DIR/.. に切り替え、Check 1-3 を実行する経路を pin する。
echo "Test 10: 'dubious ownership' should trigger marketplace fallback (positive case)"
mkdir -p "$TEST_DIR/test10/bin"
cat > "$TEST_DIR/test10/bin/git" <<'FAKEGIT_EOF'
#!/bin/bash
echo "fatal: detected dubious ownership in repository at '/some/path'" >&2
exit 128
FAKEGIT_EOF
chmod +x "$TEST_DIR/test10/bin/git"
setup_plugin_tree "$TEST_DIR/test10" "true" "bare"
# Test 7 と同様、HOOK 自体を test10 plugin tree 内にもコピーする必要があるが、
# HOOK は --repo-root なしで起動するため SCRIPT_DIR/.. fallback で test10 plugin tree を
# 正しく解決する必要がある。HOOK script 自体を fixture 内に置いて invoke する。
mkdir -p "$TEST_DIR/test10/hooks"
cp "$HOOK" "$TEST_DIR/test10/hooks/verify-terminal-output.sh"
# Test 7 と同様、fixture を plugins/rite ではなく test10 root 直下に置く (marketplace layout)
mv "$TEST_DIR/test10/plugins/rite/commands" "$TEST_DIR/test10/"
mv "$TEST_DIR/test10/plugins/rite/skills" "$TEST_DIR/test10/"
rm -rf "$TEST_DIR/test10/plugins"
# --quiet で stdout/stderr を捨てると、Check 1-3 が
# 実際に実行されたかを区別できない (silent path bug でも exit 0 になる経路がある)。
# stdout を capture して Check の実行痕跡 (`PASS:` または既知の output) を grep する。
# pr-test-analyzer M-1: PATH を append で組み立てる (Test 9 と同型化、bash 非標準パス環境対策)
test10_stdout=$(cd "$TEST_DIR/test10" && PATH="$TEST_DIR/test10/bin:$PATH" bash "$TEST_DIR/test10/hooks/verify-terminal-output.sh" 2>&1)
test10_rc=$?
if [ "$test10_rc" = "0" ] && printf '%s' "$test10_stdout" | grep -qE 'PASS|create-register|create-decompose'; then
  pass "exit 0 on 'dubious ownership' AND Check 1-3 executed (marketplace fallback path verified, MIN-5)"
elif [ "$test10_rc" = "0" ]; then
  fail "exit 0 on 'dubious ownership' but no evidence of Check 1-3 execution (silent path bug suspected)"
else
  rc=$test10_rc
  fail "expected exit 0 on 'dubious ownership' fallback, got $rc"
fi

# Test 11: trap install symmetry (IMP-3 対応)
# verify-terminal-output.sh の `_git_err` tempfile が EXIT/INT/TERM/HUP の全 signal で
# cleanup されることを script 静的解析で確認する (signal injection は CI 上での再現困難なため
# static pin で代替)。trap が片方の経路だけ silent 削除される regression を防ぐ。
echo "Test 11: trap install symmetry (EXIT + INT + TERM + HUP all installed)"
trap_count=0
for _sig in EXIT INT TERM HUP; do
  # comment 行を pre-filter で除外することで、
  # コメント内の "trap EXIT cleanup is installed below" 等のドキュメンテーション言及を
  # 誤検出して count を inflate する経路を防ぐ。
  if grep -v '^[[:space:]]*#' "$HOOK" | grep -qE "trap[[:space:]].*${_sig}([[:space:]]|$)"; then
    trap_count=$((trap_count + 1))
  fi
done
if [ "$trap_count" -ge 4 ]; then
  pass "verify-terminal-output.sh installs trap for EXIT + INT + TERM + HUP (count=$trap_count)"
else
  fail "verify-terminal-output.sh missing trap for one or more signals (count=$trap_count, expected >= 4)"
fi

# Test 12: legacy prose WARNING の `[VERIFY:WARNING]` sentinel prefix pin (M-3 対応)
# legacy prose 検出時に CI/downstream parser が grep-friendly に catch できるよう sentinel prefix
# が付与されている必要がある。silent revert で sentinel が消えると WARNING の機械検出経路が失われる。
echo "Test 12: legacy prose WARNING contains [VERIFY:WARNING] sentinel prefix (M-3)"
if grep -qF '[VERIFY:WARNING]' "$HOOK"; then
  pass "verify-terminal-output.sh emits [VERIFY:WARNING] sentinel for legacy prose detection"
else
  fail "verify-terminal-output.sh missing [VERIFY:WARNING] sentinel prefix (CI catch メカニズムが silent に消失)"
fi

# Test 13: --strict flag runtime promotion semantics (I-2 対応, verified-review Important)
# 旧 Test 12 は `[VERIFY:WARNING]` literal の static grep のみで、`--strict` flag の runtime
# promotion (default→WARNING / --strict→fail) は未検証だった。将来 `STRICT=0` hardcoded /
# promotion branch unreachable などの regression が起きても Test 12 は trivially pass する
# 構造的欠陥を埋める。Check 1 (create-register.md) と Check 2 (create-decompose.md) の両方で
# 対称に検証する (本 PR で Check 2 にも drift guard を追加したため)。
echo "Test 13: --strict flag runtime promotion (default WARNING vs --strict fail)"

# Test 13a: Check 1 (create-register.md) で legacy prose 含む fixture を生成
mkdir -p "$TEST_DIR/test13/plugins/rite/commands/issue" \
         "$TEST_DIR/test13/plugins/rite/skills/rite-workflow/references"
setup_plugin_tree "$TEST_DIR/test13" "true" "bare"
# legacy "absolute last line" prose を create-register.md に追記する (drift guard の trigger 条件)。
# regex `\[create:completed:\{[^}]+\}\][[:space:]]*MUST be the (absolute )?last line` に合わせて、
# 「[create:completed:{N}]」literal の直後に空白 + `MUST be the absolute last line` を配置する
# (backtick で囲まない素の literal — 実際の legacy prose 退化シナリオを正確に再現)
cat >> "$TEST_DIR/test13/plugins/rite/commands/issue/create-register.md" <<'EOF'

[create:completed:{N}] MUST be the absolute last line of Phase 3.4's output
EOF

# 13a-1: default (no --strict) → rc=0 かつ stderr に [VERIFY:WARNING] が出る
# set -euo pipefail 下で rc!=0 を許容するため if-else 形式で実行 (Test 9 と同型)
if test13a1_stderr=$(bash "$HOOK" --quiet --repo-root "$TEST_DIR/test13" 2>&1 >/dev/null); then
  test13a1_rc=0
else
  test13a1_rc=$?
fi
if [ "$test13a1_rc" = "0" ] && printf '%s' "$test13a1_stderr" | grep -qF '[VERIFY:WARNING]'; then
  pass "Test 13a-1: default mode で legacy prose を [VERIFY:WARNING] WARNING として emit、rc=0"
else
  fail "Test 13a-1: default mode で WARNING/rc=0 が期待通りでない (rc=$test13a1_rc, stderr=$test13a1_stderr)"
fi

# 13a-2: --strict → rc=1 (hard fail に promote)
if test13a2_stderr=$(bash "$HOOK" --quiet --strict --repo-root "$TEST_DIR/test13" 2>&1 >/dev/null); then
  test13a2_rc=0
else
  test13a2_rc=$?
fi
if [ "$test13a2_rc" = "1" ] && printf '%s' "$test13a2_stderr" | grep -qF 'FAIL'; then
  pass "Test 13a-2: --strict mode で legacy prose を hard fail に promote、rc=1"
else
  fail "Test 13a-2: --strict mode で rc=1+FAIL が期待通りでない (rc=$test13a2_rc, stderr=$test13a2_stderr)"
fi

# Test 13b: Check 2 (create-decompose.md) でも対称に runtime test
# 本 PR の verified-review Important 1 で Check 2 にも drift guard を追加したため、Check 1 と
# 同じ runtime promotion 動作を pin する (drift guard 非対称が再発した場合に catch する)。
rm -rf "$TEST_DIR/test13/plugins"
mkdir -p "$TEST_DIR/test13/plugins/rite/commands/issue" \
         "$TEST_DIR/test13/plugins/rite/skills/rite-workflow/references"
setup_plugin_tree "$TEST_DIR/test13" "true" "bare"
# legacy "absolute last line" prose を create-decompose.md に追記 (Test 13a と同じく素の literal で trigger)
cat >> "$TEST_DIR/test13/plugins/rite/commands/issue/create-decompose.md" <<'EOF'

[create:completed:{N}] MUST be the absolute last line of Phase 3.4's output
EOF

# 13b-1: default → rc=0 かつ stderr に [VERIFY:WARNING] が出る
if test13b1_stderr=$(bash "$HOOK" --quiet --repo-root "$TEST_DIR/test13" 2>&1 >/dev/null); then
  test13b1_rc=0
else
  test13b1_rc=$?
fi
if [ "$test13b1_rc" = "0" ] && printf '%s' "$test13b1_stderr" | grep -qF '[VERIFY:WARNING]'; then
  pass "Test 13b-1: Check 2 default mode で legacy prose を [VERIFY:WARNING] WARNING として emit、rc=0 (本 PR で対称化)"
else
  fail "Test 13b-1: Check 2 default mode で WARNING/rc=0 が期待通りでない (rc=$test13b1_rc, stderr=$test13b1_stderr)"
fi

# 13b-2: --strict → rc=1
if test13b2_stderr=$(bash "$HOOK" --quiet --strict --repo-root "$TEST_DIR/test13" 2>&1 >/dev/null); then
  test13b2_rc=0
else
  test13b2_rc=$?
fi
if [ "$test13b2_rc" = "1" ] && printf '%s' "$test13b2_stderr" | grep -qF 'FAIL'; then
  pass "Test 13b-2: Check 2 --strict mode で legacy prose を hard fail に promote、rc=1 (本 PR で対称化)"
else
  fail "Test 13b-2: Check 2 --strict mode で rc=1+FAIL が期待通りでない (rc=$test13b2_rc, stderr=$test13b2_stderr)"
fi

rm -rf "$TEST_DIR/test13/plugins"

# Summary
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
