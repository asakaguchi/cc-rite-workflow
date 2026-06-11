#!/usr/bin/env bash
# Smoke + validation tests for doc-heavy-patterns-drift-check.sh
#
# Requires bash 4.4+ for safe expansion of empty arrays under `set -u`.
#
# Portability note: this test uses `awk` for in-place edits (via the
# read→transform→write→mv pattern) instead of `sed -i`. BSD sed (macOS)
# requires a mandatory backup suffix for `-i`, so `sed -i '<regex>'` syntax
# that works on GNU sed fails with "extra characters at the end of d command"
# on macOS. The `awk` pattern is identical on GNU and BSD and matches the
# sibling `test-bang-backtick-check.sh` portability convention.
#
# The drift-check is a 2-file invariant (review.md doc_file_patterns block ↔
# SKILL.md Technical Writer row) after the per-reviewer skill files were
# consolidated into the named-subagent definitions. tech-writer.md no longer
# exists as a separate Activation source.
#
# Validates (numbered per in-file `--- Test N: ---` sections):
#   1. --help exits 0
#   2. No --all exits 2 (invocation error)
#   3. Unknown argument exits 2
#   4. Repo-wide --all is clean on the real 2 files (AC: no false positives)
#   5. Drift by removal — tokens removed from review.md are reported as
#      "only in SKILL.md" and NOT as "only in review.md" (direction-symmetry)
#   6. Drift by addition — token added to review.md is reported as
#      "only in review.md" and NOT as "only in SKILL.md"
#   7. Missing-file fixture: --repo-root pointing to a tree without the
#      required files exits 2 with a clear diagnostic
#   8. Broken-section fixture: empty doc_file_patterns block trips the
#      "expected >= 10" guard and exits 2

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "FAIL: bash 4.4+ required (detected ${BASH_VERSION})" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected=$expected actual=$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected output to contain: $needle" >&2
    echo "  actual: $haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Assert that `needle` appears under the `header` section of `haystack`,
# where a "section" is the lines strictly between the header line and the
# next `[doc-heavy-patterns-drift]` block header (or end of output). Pins
# label/token pairing so a swapped section label cannot silently pass.
assert_contains_near() {
  local desc="$1" header="$2" needle="$3" _window_unused="$4" haystack="$5"
  local slice
  slice=$(printf '%s\n' "$haystack" | awk -v h="$header" '
    index($0, h) > 0 { in_sec = 1; next }
    in_sec && /^\[doc-heavy-patterns-drift\]/ { in_sec = 0 }
    in_sec { print }
  ')
  if printf '%s' "$slice" | grep -qF -- "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected '$needle' inside '$header' section" >&2
    echo "  slice: $slice" >&2
    FAIL=$((FAIL + 1))
  fi
}

TMPDIRS=()
cleanup() {
  local d
  for d in "${TMPDIRS[@]}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Build a minimal repo-root layout containing the 2 required files, copied
# from the real source tree. Callers own the temp directory — they `mktemp
# -d` in the parent shell (so the TMPDIRS array actually receives the path
# and the EXIT trap can clean it up), then pass the directory as `$1`.
build_fake_tree_at() {
  local dest="$1"
  mkdir -p \
    "$dest/plugins/rite/skills/reviewers" \
    "$dest/plugins/rite/commands/pr"
  cp "$REPO_ROOT/plugins/rite/skills/reviewers/SKILL.md" \
     "$dest/plugins/rite/skills/reviewers/SKILL.md"
  cp "$REPO_ROOT/plugins/rite/commands/pr/review.md" \
     "$dest/plugins/rite/commands/pr/review.md"
}

# Tests allocate fake trees with the following 3-line pattern (all in the
# parent shell so the TMPDIRS mutation and `exit 2` on failure both affect
# the caller, not a subshell):
#
#   FAKE=$(mktemp -d) || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
#   TMPDIRS+=("$FAKE")
#   build_fake_tree_at "$FAKE"

# Delete the `*.rst, *.adoc` line from review.md's doc_file_patterns block.
# Uses awk (GNU/BSD-portable) rather than `sed -i`. Matches the line by its
# trimmed content so leading indentation is tolerated.
remove_rst_adoc_line() {
  local file="$1"
  local tmp="${file}.tmp"
  awk '{ t=$0; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == "*.rst, *.adoc") next; print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Append an extra glob token (`**/*.bogus,`) as a new line right after the
# `doc_file_patterns = [` opener in review.md. Also uses awk for portability.
append_bogus_pattern() {
  local file="$1"
  local tmp="${file}.tmp"
  awk '
    { print }
    /^doc_file_patterns = \[/ { print "  **/*.bogus," }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Blank out the entire doc_file_patterns body (drop every line between
# `doc_file_patterns = [` and the closing `]`, exclusive). Used by Test 8
# (broken-section guard).
blank_doc_patterns_body() {
  local file="$1"
  local tmp="${file}.tmp"
  awk '
    /^doc_file_patterns = \[/ { print; in_sec = 1; next }
    in_sec && /^\]/ { in_sec = 0 }
    !in_sec { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# --- Test 1: --help exits 0 --------------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: no --all exits 2 ------------------------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no --all exits 2" "2" "$rc"

# --- Test 3: unknown argument exits 2 ---------------------------------------
"$SCRIPT" --all --bogus >/dev/null 2>&1
rc=$?
assert "unknown argument exits 2" "2" "$rc"

# --- Test 4: repo-wide --all is clean (dogfood AC) ---------------------------
"$SCRIPT" --all --quiet --repo-root "$REPO_ROOT" >/dev/null 2>&1
rc=$?
assert "repo-wide --all exits 0 on real 2 files (no false positives)" "0" "$rc"

# --- Test 5: drift by removal ------------------------------------------------
# Delete the `*.rst, *.adoc` line from review.md inside a fake tree. The
# removed tokens remain in SKILL.md, so they should be reported as
# "only in SKILL.md" and NOT as "only in review.md" (direction-symmetry).
FAKE_REMOVED=$(mktemp -d) || { echo "FAIL: Test 5 mktemp -d failed" >&2; exit 2; }
TMPDIRS+=("$FAKE_REMOVED")
build_fake_tree_at "$FAKE_REMOVED"
REVIEW_FIXTURE="$FAKE_REMOVED/plugins/rite/commands/pr/review.md"
remove_rst_adoc_line "$REVIEW_FIXTURE"

# Sanity check: the line must be gone from the fixture.
if grep -qE '^[[:space:]]*\*\.rst, \*\.adoc[[:space:]]*$' "$REVIEW_FIXTURE"; then
  echo "FAIL: Test 5 fixture injection did not remove the target line" >&2
  echo "  file: $REVIEW_FIXTURE" >&2
  FAIL=$((FAIL + 1))
fi

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_REMOVED" 2>&1)
rc=$?
assert "drift-by-removal fixture exits 1" "1" "$rc"
assert_contains "drift-by-removal reports *.rst as missing from review.md" \
  "*.rst" "$out"
assert_contains "drift-by-removal reports *.adoc as missing from review.md" \
  "*.adoc" "$out"
assert_contains "drift-by-removal names SKILL.md as the source of the extra token" \
  "only in SKILL.md" "$out"

# Bleed-check: review.md must NEVER be reported as a source of an extra token
# when drift is injected by removing from review.md.
review_source_hits=$(printf '%s' "$out" | grep -c "only in review.md" || true)
assert "drift-by-removal does NOT falsely report review.md as source" "0" "$review_source_hits"

# Header-token locality: the removed tokens must appear under the correct
# section header (not elsewhere in the output).
assert_contains_near \
  "drift-by-removal pins *.rst under 'only in SKILL.md' header" \
  "only in SKILL.md" \
  "*.rst" \
  5 \
  "$out"
assert_contains_near \
  "drift-by-removal pins *.adoc under 'only in SKILL.md' header" \
  "only in SKILL.md" \
  "*.adoc" \
  5 \
  "$out"

# --- Test 6: drift by addition ----------------------------------------------
# Insert an extra glob token into review.md's doc_file_patterns block. The
# new token should be reported as "only in review.md" AND NOT as
# "only in SKILL.md" (direction-symmetry).
FAKE_ADDED=$(mktemp -d) || { echo "FAIL: Test 6 mktemp -d failed" >&2; exit 2; }
TMPDIRS+=("$FAKE_ADDED")
build_fake_tree_at "$FAKE_ADDED"
REVIEW_FIXTURE="$FAKE_ADDED/plugins/rite/commands/pr/review.md"
append_bogus_pattern "$REVIEW_FIXTURE"

if ! grep -qF -- '**/*.bogus' "$REVIEW_FIXTURE"; then
  echo "FAIL: Test 6 fixture injection did not insert **/*.bogus" >&2
  echo "  file: $REVIEW_FIXTURE" >&2
  FAIL=$((FAIL + 1))
fi

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_ADDED" 2>&1)
rc=$?
assert "drift-by-addition fixture exits 1" "1" "$rc"
assert_contains "drift-by-addition reports **/*.bogus only in review.md" \
  "**/*.bogus" "$out"
assert_contains "drift-by-addition names review.md as the source of the extra token" \
  "only in review.md" "$out"

# Bleed-check: SKILL.md must NEVER be reported as a source when the drift
# comes from review.md only.
skill_source_hits=$(printf '%s' "$out" | grep -c "only in SKILL.md Technical Writer row" || true)
assert "drift-by-addition does NOT falsely report SKILL.md as source" "0" "$skill_source_hits"

# Header-token locality for drift-by-addition.
assert_contains_near \
  "drift-by-addition pins **/*.bogus under 'only in review.md' header" \
  "only in review.md" \
  "**/*.bogus" \
  5 \
  "$out"

# --- Test 7: missing-file fixture -------------------------------------------
# A fake repo root with none of the required files should exit 2 with a
# clear diagnostic.
FAKE_MISSING=$(mktemp -d) || {
  echo "FAIL: Test 7 mktemp -d failed" >&2
  exit 2
}
TMPDIRS+=("$FAKE_MISSING")
mkdir -p "$FAKE_MISSING/plugins/rite"
out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_MISSING" 2>&1)
rc=$?
assert "missing-file fixture exits 2" "2" "$rc"
assert_contains "missing-file fixture names a required file" \
  "review.md" "$out"

# --- Test 8: broken-section guard --------------------------------------------
# Blank out review.md's doc_file_patterns body. The extractor should find zero
# tokens, fall through the >= 10 guard, and exit 2 with a diagnostic rather
# than falsely reporting drift.
FAKE_BROKEN=$(mktemp -d) || { echo "FAIL: Test 8 mktemp -d failed" >&2; exit 2; }
TMPDIRS+=("$FAKE_BROKEN")
build_fake_tree_at "$FAKE_BROKEN"
blank_doc_patterns_body "$FAKE_BROKEN/plugins/rite/commands/pr/review.md"

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_BROKEN" 2>&1)
rc=$?
assert "broken-section fixture exits 2 (guard trips)" "2" "$rc"
assert_contains "broken-section fixture names review.md in the error" \
  "review.md" "$out"

# --- Summary -----------------------------------------------------------------
echo ""
echo "==> PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
