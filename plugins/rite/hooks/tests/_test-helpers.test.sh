#!/bin/bash
# Self-test for _test-helpers.sh (Issue #852)
#
# Each test case runs in a subshell that re-sources _test-helpers.sh,
# so we can observe how the helpers mutate the PASS / FAIL / FAILED_NAMES
# counters in isolation without polluting our own outer counters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS="$SCRIPT_DIR/_test-helpers.sh"

# Outer-test counters (use plain integers to avoid colliding with helper counters
# loaded inside subshells under test).
OUTER_PASS=0
OUTER_FAIL=0
OUTER_FAILED=()

outer_pass() { OUTER_PASS=$((OUTER_PASS + 1)); echo "  ✅ $1"; }
outer_fail() { OUTER_FAIL=$((OUTER_FAIL + 1)); OUTER_FAILED+=("$1"); echo "  ❌ $1"; }

if [ ! -f "$HELPERS" ]; then
  # Output convention (Issue #853): Hard precondition (missing executable) → stderr
  echo "FATAL: $HELPERS not found" >&2
  exit 1
fi

# === TC-1: path resolvers ===
echo "TC-1: _helpers_resolve_plugin_root / _helpers_resolve_repo_root"

expected_plugin_root=$(cd "$SCRIPT_DIR/../.." && pwd)
expected_repo_root=$(cd "$SCRIPT_DIR/../../../.." && pwd)

actual_plugin_root=$(bash -c "source '$HELPERS' && _helpers_resolve_plugin_root '$SCRIPT_DIR'")
if [ "$actual_plugin_root" = "$expected_plugin_root" ]; then
  outer_pass "TC-1.1: _helpers_resolve_plugin_root returns plugins/rite"
else
  outer_fail "TC-1.1: expected='$expected_plugin_root' actual='$actual_plugin_root'"
fi

actual_repo_root=$(bash -c "source '$HELPERS' && _helpers_resolve_repo_root '$SCRIPT_DIR'")
if [ "$actual_repo_root" = "$expected_repo_root" ]; then
  outer_pass "TC-1.2: _helpers_resolve_repo_root returns repo root"
else
  outer_fail "TC-1.2: expected='$expected_repo_root' actual='$actual_repo_root'"
fi

# === TC-2: pass / fail mutate counters ===
echo
echo "TC-2: pass / fail counter mutation"

# capture inner PASS / FAIL / FAILED_NAMES state in subshell
inner_state=$(bash -c "
  source '$HELPERS'
  pass 'sample-pass'   >/dev/null
  pass 'sample-pass-2' >/dev/null
  fail 'sample-fail'   >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
  echo \"FAILED_COUNT=\${#FAILED_NAMES[@]}\"
  echo \"FAILED_HEAD=\${FAILED_NAMES[0]:-}\"
")

inner_pass=$(echo "$inner_state" | grep '^PASS=' | cut -d= -f2)
inner_fail=$(echo "$inner_state" | grep '^FAIL=' | cut -d= -f2)
inner_failed_count=$(echo "$inner_state" | grep '^FAILED_COUNT=' | cut -d= -f2)
inner_failed_head=$(echo "$inner_state" | grep '^FAILED_HEAD=' | cut -d= -f2)

if [ "$inner_pass" = "2" ]; then
  outer_pass "TC-2.1: pass() increments PASS to 2"
else
  outer_fail "TC-2.1: expected PASS=2 got PASS=$inner_pass"
fi

if [ "$inner_fail" = "1" ]; then
  outer_pass "TC-2.2: fail() increments FAIL to 1"
else
  outer_fail "TC-2.2: expected FAIL=1 got FAIL=$inner_fail"
fi

if [ "$inner_failed_count" = "1" ] && [ "$inner_failed_head" = "sample-fail" ]; then
  outer_pass "TC-2.3: fail() appends label to FAILED_NAMES"
else
  outer_fail "TC-2.3: expected count=1 head='sample-fail' got count=$inner_failed_count head='$inner_failed_head'"
fi

# === TC-3: assert ===
echo
echo "TC-3: assert (equality)"

assert_state=$(bash -c "
  source '$HELPERS'
  assert 'eq-match'  'foo' 'foo' >/dev/null
  assert 'eq-mismatch' 'foo' 'bar' >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
")
ap=$(echo "$assert_state" | grep '^PASS=' | cut -d= -f2)
af=$(echo "$assert_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$ap" = "1" ] && [ "$af" = "1" ]; then
  outer_pass "TC-3.1: assert passes on equal, fails on unequal"
else
  outer_fail "TC-3.1: expected PASS=1 FAIL=1 got PASS=$ap FAIL=$af"
fi

# === TC-4: assert_grep / assert_not_grep ===
echo
echo "TC-4: assert_grep / assert_not_grep"

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
printf 'hello world\nfoo bar\n' > "$tmpfile"

grep_state=$(bash -c "
  source '$HELPERS'
  assert_grep     'present'   '$tmpfile' 'hello'   >/dev/null
  assert_grep     'absent'    '$tmpfile' 'missing' >/dev/null
  assert_not_grep 'absent-ok' '$tmpfile' 'missing' >/dev/null
  assert_not_grep 'present-bad' '$tmpfile' 'hello' >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
")
gp=$(echo "$grep_state" | grep '^PASS=' | cut -d= -f2)
gf=$(echo "$grep_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$gp" = "2" ] && [ "$gf" = "2" ]; then
  outer_pass "TC-4.1: assert_grep / assert_not_grep route correctly"
else
  outer_fail "TC-4.1: expected PASS=2 FAIL=2 got PASS=$gp FAIL=$gf"
fi

# TC-4.2 / TC-4.3: file-not-found path emits "file not found" diagnostic
missing_state=$(bash -c "
  source '$HELPERS'
  assert_grep     'missing-grep'     '/nonexistent/path/xyz' 'pattern' 2>&1
  assert_not_grep 'missing-not-grep' '/nonexistent/path/xyz' 'pattern' 2>&1
  echo \"FAIL=\$FAIL\"
")
mfail=$(echo "$missing_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$mfail" = "2" ]; then
  outer_pass "TC-4.2: file-not-found increments FAIL for both assert_grep and assert_not_grep"
else
  outer_fail "TC-4.2: expected FAIL=2 got FAIL=$mfail"
fi
if echo "$missing_state" | grep -q 'file not found'; then
  outer_pass "TC-4.3: file-not-found diagnostic message is emitted"
else
  outer_fail "TC-4.3: 'file not found' diagnostic missing in output"
fi

# === TC-5: print_summary return code ===
echo
echo "TC-5: print_summary return code"

# All-pass case → exit 0
if bash -c "source '$HELPERS'; pass 'x' >/dev/null; print_summary 'self-test' >/dev/null"; then
  outer_pass "TC-5.1: print_summary returns 0 when FAIL=0"
else
  outer_fail "TC-5.1: print_summary returned non-zero on all-pass"
fi

# Any-fail case → exit 1
if bash -c "source '$HELPERS'; fail 'x' >/dev/null; print_summary 'self-test' >/dev/null"; then
  outer_fail "TC-5.2: print_summary returned 0 on FAIL>0 (expected non-zero)"
else
  outer_pass "TC-5.2: print_summary returns non-zero when FAIL>0"
fi

# === TC-6: drift hint is echoed in summary ===
echo
echo "TC-6: print_summary drift hint propagation"

summary_output=$(bash -c "source '$HELPERS'; fail 'sample' >/dev/null; print_summary 'self-test' 'CUSTOM-DRIFT-HINT' || true")
if echo "$summary_output" | grep -q 'CUSTOM-DRIFT-HINT'; then
  outer_pass "TC-6.1: drift hint text appears in summary output"
else
  outer_fail "TC-6.1: drift hint not found in: $summary_output"
fi

# === TC-7: make_sandbox basic (Issue #990) ===
echo
echo "TC-7: make_sandbox default invocation → git-init + commit"

sbx_default=$(bash -c "source '$HELPERS'; make_sandbox")
if [ -d "$sbx_default" ] && [ -d "$sbx_default/.git" ]; then
  outer_pass "TC-7.1: make_sandbox returns an existing path with a .git directory"
else
  outer_fail "TC-7.1: make_sandbox path '$sbx_default' missing .git or directory"
fi

# Initial commit reachable via `git log` (any non-zero output proves commit landed).
log_output=$(cd "$sbx_default" 2>/dev/null && git log --oneline 2>/dev/null || true)
if [ -n "$log_output" ]; then
  outer_pass "TC-7.2: make_sandbox produced an initial commit (git log non-empty)"
else
  outer_fail "TC-7.2: make_sandbox did not produce an initial commit (git log empty)"
fi
rm -rf "$sbx_default"

# === TC-8: make_sandbox --branch ===
echo
echo "TC-8: make_sandbox --branch <name> → HEAD on requested branch"

sbx_branch=$(bash -c "source '$HELPERS'; make_sandbox --branch fix/issue-687-test")
head_branch=$(cd "$sbx_branch" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$head_branch" = "fix/issue-687-test" ]; then
  outer_pass "TC-8.1: HEAD is on the requested branch (fix/issue-687-test)"
else
  outer_fail "TC-8.1: expected HEAD on fix/issue-687-test, got '$head_branch'"
fi
rm -rf "$sbx_branch"

# F-08: TC-8.2 / TC-8.3 — option-parse error variants (return 2).
# Pins the explicit `if [ $# -lt 2 ] || [ -z "$2" ]` guard so a regression that
# changes `shift 2` to `shift` (and silently accepts `--branch` with no value)
# is caught.
# `|| rc=$?` 形式: set -e の下で非ゼロ exit が abort を起こさないよう短絡。
rc_empty=0
bash -c "source '$HELPERS'; make_sandbox --branch '' 2>/dev/null" || rc_empty=$?
if [ "$rc_empty" = "2" ]; then
  outer_pass "TC-8.2: --branch \"\" returns rc=2 (option parse error)"
else
  outer_fail "TC-8.2: expected rc=2 for --branch \"\", got rc=$rc_empty"
fi

rc_missing=0
bash -c "source '$HELPERS'; make_sandbox --branch 2>/dev/null" || rc_missing=$?
if [ "$rc_missing" = "2" ]; then
  outer_pass "TC-8.3: --branch with no argument returns rc=2 (option parse error)"
else
  outer_fail "TC-8.3: expected rc=2 for --branch with no argument, got rc=$rc_missing"
fi

# === TC-9: make_sandbox --soft ===
echo
echo "TC-9: make_sandbox --soft → success returns sandbox, failure returns rc=1 (no exit)"

# Success path: --soft must not change the success-side contract.
sbx_soft=$(bash -c "source '$HELPERS'; make_sandbox --soft")
if [ -d "$sbx_soft/.git" ]; then
  outer_pass "TC-9.1: make_sandbox --soft returns a working sandbox on success path"
else
  outer_fail "TC-9.1: make_sandbox --soft missing .git (path: '$sbx_soft')"
fi
rm -rf "$sbx_soft"

# TC-9.2 — failure path: --soft の存在意義 (infrastructure 失敗時に exit ではなく return 1) を pin。
# Cycle 2 F-05 修正: 旧コメントは「git 失敗時に return 1」と主張していたが、`mktemp` は GNU coreutils
# の外部コマンド (bash builtin ではない) のため、`PATH=/dev/null` 下では `mktemp -d` (helper line 216
# 相当) が先に失敗し soft-fail return が発火する。git init/commit 失敗の soft-fail branch (helper
# line 245 相当) は untested のまま。TC-9.3 で git 失敗 path を別途 pin する。
# `|| rc=$?` 形式: set -e の下で非ゼロ exit が abort を起こさないよう短絡。
rc_soft_fail=0
bash -c "source '$HELPERS'; PATH=/dev/null make_sandbox --soft 2>/dev/null" || rc_soft_fail=$?
if [ "$rc_soft_fail" = "1" ]; then
  outer_pass "TC-9.2: make_sandbox --soft returns rc=1 on mktemp failure (does NOT exit)"
else
  outer_fail "TC-9.2: expected rc=1 (soft-fail on mktemp failure), got rc=$rc_soft_fail"
fi

# Cycle 2 F-05: TC-9.3 — failure path: git unreachable but mktemp reachable。
# mktemp は本物を残し git のみ shim で無効化することで、helper の git init/commit 失敗 branch
# (subshell 内 `git init -q 2>"$sandbox_err"` 失敗 → 外側 if ! で soft-fail return) を実際に exercise する。
# Mutation で該当 branch の `return 1` を `exit 1` に書き換えると caller が `if !` で受けられず
# subshell ごと exit するため、本テストは「git failure → soft-fail return contract」を直接 pin する。
tc93_dir=$(mktemp -d)
trap "rm -rf '$tc93_dir'" EXIT  # one-shot best-effort (再 trap)
# real mktemp into shim PATH; only `git` is invalidated by creating a non-executable stub.
ln -sf "$(command -v mktemp)" "$tc93_dir/mktemp"
# git invalidator: an executable file that always exits non-zero so `git init` 失敗を再現する。
# PATH に shim dir を置くことで本物の git ($(command -v git)) より優先される。
cat > "$tc93_dir/git" <<'GIT_SHIM_EOF'
#!/bin/sh
echo "ERROR: git shim invoked (TC-9.3 force-failure)" >&2
exit 127
GIT_SHIM_EOF
chmod +x "$tc93_dir/git"
rc_git_fail=0
bash -c "source '$HELPERS'; PATH='$tc93_dir':/usr/bin:/bin make_sandbox --soft 2>/dev/null" || rc_git_fail=$?
if [ "$rc_git_fail" = "1" ]; then
  outer_pass "TC-9.3: make_sandbox --soft returns rc=1 on git failure (does NOT exit)"
else
  outer_fail "TC-9.3: expected rc=1 (soft-fail on git failure), got rc=$rc_git_fail"
fi
rm -rf "$tc93_dir"
trap 'rm -f "$tmpfile"' EXIT  # 既存 trap (line 111) を restore

# === TC-10: make_sandbox unknown option → return 2 ===
echo
echo "TC-10: make_sandbox unknown option → return 2 (option parse error)"

# F-06: rc=2 specific assertion. The previous test only verified non-zero exit,
# which would not catch a regression that changes `return 2` to `return 1` (the
# soft-fail code) or `exit 1` (hard-fail). Pin the specific contract.
# `|| rc=$?` 形式: set -e の下で非ゼロ exit が abort を起こさないよう短絡。
rc_bogus=0
bash -c "source '$HELPERS'; make_sandbox --bogus 2>/dev/null" || rc_bogus=$?
if [ "$rc_bogus" = "2" ]; then
  outer_pass "TC-10.1: make_sandbox --bogus returns rc=2 (option parse error)"
else
  outer_fail "TC-10.1: expected rc=2 for unknown option, got rc=$rc_bogus"
fi

# === TC-11: make_plain_sandbox ===
echo
echo "TC-11: make_plain_sandbox → bare mktemp -d (no .git)"

sbx_plain=$(bash -c "source '$HELPERS'; make_plain_sandbox")
if [ -d "$sbx_plain" ] && [ ! -e "$sbx_plain/.git" ]; then
  outer_pass "TC-11.1: make_plain_sandbox returns a bare directory without .git"
else
  outer_fail "TC-11.1: make_plain_sandbox unexpected layout at '$sbx_plain'"
fi
rm -rf "$sbx_plain"

# Cycle 2 F-03: TC-11.2 / TC-11.3 — API symmetry with make_sandbox.
# `make_plain_sandbox` exposes the same --soft / option-parse contract; pin both contracts here
# (parallels TC-9.2 / TC-10.1 for make_sandbox).
sbx_plain_soft=$(bash -c "source '$HELPERS'; make_plain_sandbox --soft")
if [ -d "$sbx_plain_soft" ] && [ ! -e "$sbx_plain_soft/.git" ]; then
  outer_pass "TC-11.2: make_plain_sandbox --soft returns a working sandbox on success path"
else
  outer_fail "TC-11.2: make_plain_sandbox --soft unexpected layout at '$sbx_plain_soft'"
fi
rm -rf "$sbx_plain_soft"

rc_plain_bogus=0
bash -c "source '$HELPERS'; make_plain_sandbox --bogus 2>/dev/null" || rc_plain_bogus=$?
if [ "$rc_plain_bogus" = "2" ]; then
  outer_pass "TC-11.3: make_plain_sandbox --bogus returns rc=2 (option parse error)"
else
  outer_fail "TC-11.3: expected rc=2 for unknown option, got rc=$rc_plain_bogus"
fi

# === Summary ===
echo
echo "─── $(basename "$0") summary ──────────────────────"
echo "PASS: $OUTER_PASS"
echo "FAIL: $OUTER_FAIL"

if [ "$OUTER_FAIL" -ne 0 ]; then
  echo "Failed assertions:"
  for n in "${OUTER_FAILED[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
