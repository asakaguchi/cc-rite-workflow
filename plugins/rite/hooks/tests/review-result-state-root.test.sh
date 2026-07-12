#!/bin/bash
# review-result-state-root.test.sh
#
# Pin the state-path-resolve based default of review-result-save.sh and the
# matching read side (review-source-resolve.sh Priority 2). A regression back
# to the cwd-relative default would silently split the save/read/delete paths
# between a session worktree and the main checkout (multi_session), making
# cleanup a no-op and cross-session fix reads miss the findings.
#
# The scripts resolve state-path-resolve.sh relative to their own location, so
# the sandbox mirrors the plugin layout (hooks/ + scripts/) inside a real git
# repo with a linked worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.."
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  # linked worktree を先に外さないと rm -rf 後の git 参照が残る
  git -C "$TEST_DIR/repo" worktree remove --force "$TEST_DIR/repo/.rite/worktrees/issue-99" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- sandbox: git repo + plugin layout + linked worktree ---
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
mkdir -p "$REPO/hooks" "$REPO/scripts"
cp "$HOOKS_DIR/review-result-save.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/state-path-resolve.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/control-char-neutralize.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/../scripts/review-source-resolve.sh" "$REPO/scripts/"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
git -C "$REPO" worktree add -q "$REPO/.rite/worktrees/issue-99" -b test-branch main

# commit_sha は sandbox repo の HEAD に一致させる (Priority 2 は commit_sha 不一致を
# stale と判定し Priority 3 へ routing するため、不一致だと TC-2 が読取経路を検証できない)
REPO_HEAD=$(git -C "$REPO" rev-parse HEAD)
json_body() {
  cat <<JSON
{
  "schema_version": "1.1.0",
  "pr_number": 99,
  "timestamp": "__RITE_TS_PLACEHOLDER_7f3a9b2c__",
  "commit_sha": "$REPO_HEAD",
  "overall_assessment": "mergeable",
  "findings": []
}
JSON
}

echo "=== review-result state-root tests ==="
echo ""

# ─── TC-1 (AC-1): worktree 内保存が main checkout の state ルートに載る ───
echo "TC-1: save from linked worktree lands under main checkout root"
content1="$TEST_DIR/body1.json"
json_body > "$content1"
( cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content1" ) 2>/dev/null
main_hits=$({ find "$REPO/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
wt_hits=$({ find "$REPO/.rite/worktrees/issue-99/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$main_hits" -eq 1 ] && [ "$wt_hits" -eq 0 ]; then
  pass "TC-1: JSON saved at main root (main=$main_hits, worktree=$wt_hits)"
else
  fail "TC-1: expected main=1/worktree=0, got main=$main_hits worktree=$wt_hits"
fi
echo ""

# ─── TC-2 (AC-2): worktree cwd からの読取が main root の JSON を拾う ───
echo "TC-2: review-source-resolve Priority 2 reads main-root JSON from worktree cwd"
out2=$(cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/scripts/review-source-resolve.sh" \
    --pr-number 99 --review-file-path "__RITE_UNSET__" \
    --conversation-decision none --p1-scan-turns 0 --p1-scan-found false 2>&1) || true
if printf '%s' "$out2" | grep -q 'REVIEW_SOURCE=local_file' && \
   printf '%s' "$out2" | grep -q "review_source_path=$REPO/.rite/review-results/99-"; then
  pass "TC-2: Priority 2 resolved to main-root local file"
else
  fail "TC-2: expected local_file at main root. out: $(printf '%s' "$out2" | grep REVIEW_SOURCE | head -2)"
fi
echo ""

# ─── TC-3 (AC-4): --results-dir 明示指定は state-root 既定を上書きする ───
echo "TC-3: explicit --results-dir overrides the state-root default"
content3="$TEST_DIR/body3.json"
json_body > "$content3"
explicit_dir="$TEST_DIR/explicit-results"
( cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content3" \
    --results-dir "$explicit_dir" ) 2>/dev/null
explicit_hits=$({ find "$explicit_dir" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$explicit_hits" -eq 1 ]; then
  pass "TC-3: JSON saved to explicit dir"
else
  fail "TC-3: expected 1 file in $explicit_dir, got $explicit_hits"
fi
echo ""

# ─── TC-4 (AC-5): 単一 checkout (main root cwd) では従来と同じパスに保存 ───
echo "TC-4: single-checkout save path is unchanged (repo root)"
content4="$TEST_DIR/body4.json"
json_body > "$content4"
rm -f "$REPO/.rite/review-results"/99-*.json
( cd "$REPO" && bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content4" ) 2>/dev/null
root_hits=$({ find "$REPO/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$root_hits" -eq 1 ]; then
  pass "TC-4: JSON saved at repo root as before"
else
  fail "TC-4: expected 1 file at repo root, got $root_hits"
fi
echo ""

# ─── TC-5: state-path-resolve 解決失敗時は cwd 相対へフォールバック ───
echo "TC-5: falls back to cwd-relative dir when resolver is unavailable"
nogit_dir="$TEST_DIR/nogit"
mkdir -p "$nogit_dir/hooks"
cp "$HOOKS_DIR/review-result-save.sh" "$nogit_dir/hooks/"
cp "$HOOKS_DIR/control-char-neutralize.sh" "$nogit_dir/hooks/"
# state-path-resolve.sh を意図的に置かない (解決失敗経路)
content5="$TEST_DIR/body5.json"
json_body > "$content5"
out5=$( cd "$nogit_dir" && bash "$nogit_dir/hooks/review-result-save.sh" --pr 99 --content-file "$content5" 2>&1 ) || true
cwd_hits=$({ find "$nogit_dir/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$cwd_hits" -eq 1 ] && printf '%s' "$out5" | grep -q 'state-path-resolve.sh の解決に失敗'; then
  pass "TC-5: cwd fallback + WARNING emitted"
else
  fail "TC-5: expected cwd save + WARNING. hits=$cwd_hits warning=$(printf '%s' "$out5" | grep -c '解決に失敗' || true)"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
