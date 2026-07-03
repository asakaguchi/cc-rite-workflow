#!/bin/bash
# Tests for plugins/rite/hooks/scripts/reviewer-registry-drift-check.sh
# (reviewer registry 3-way sync detection). Covers Issue #1711 acceptance
# criteria:
#   - T-01 (AC-1): adding a dummy reviewer agent file WITHOUT updating the
#     SKILL.md tables is detected as drift (single-check FAIL)
#   - T-03 (AC-1): a deliberate partial update (one table only) is detected
#   - T-05 (AC-2): the real repository's current registry passes (no drift)
#   - Invariant I3: slug/Agent cell mismatch is detected
#   - Guard: heading change → undersized extraction → invocation error (rc=2)
#   - Arg contract: --all required (rc=2 without it)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CHECKER="$PLUGIN_ROOT/hooks/scripts/reviewer-registry-drift-check.sh"

if [ ! -f "$CHECKER" ]; then
  echo "ERROR: $CHECKER not found" >&2
  exit 1
fi

# sibling _test-helpers.sh consumers (distributed-fix-drift-check.test.sh 等)
# と同型の sandbox cleanup pattern。
cleanup_dirs=()
cleanup() {
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM HUP

# 12 種のダミー reviewer slug（checker の >= 10 抽出ガードを満たす数）
FIXTURE_SLUGS=(alpha bravo charlie delta echo-x foxtrot golf hotel india juliett kilo lima)

# Helper: create a sandbox holding a synchronized reviewer registry fixture
# (12 agent files + reviewers/SKILL.md with both tables in sync) and echo its
# repo root path. Callers push the path onto cleanup_dirs and then mutate the
# fixture to create the drift under test.
make_registry_sandbox() {
  local d
  d=$(make_plain_sandbox --soft)
  mkdir -p "$d/plugins/rite/agents" "$d/plugins/rite/skills/reviewers"

  local slug
  for slug in "${FIXTURE_SLUGS[@]}"; do
    printf '# %s reviewer fixture\n' "$slug" > "$d/plugins/rite/agents/${slug}-reviewer.md"
  done
  # 共有 principles ファイルは registry 対象外であることも fixture で表現する
  printf '# shared principles fixture\n' > "$d/plugins/rite/agents/_reviewer-base.md"

  {
    printf '# Reviewer Skills fixture\n\n'
    printf '## Available Reviewers\n\n'
    printf '| Reviewer | Agent | File Patterns (Primary) |\n'
    printf '|----------|-------|-------------------------|\n'
    for slug in "${FIXTURE_SLUGS[@]}"; do
      printf '| %s Expert | `%s-reviewer.md` | `**/%s/**` |\n' "$slug" "$slug" "$slug"
    done
    printf '\n## Reviewer Type Identifiers\n\n'
    printf '| reviewer_type | 日本語表示名 | Agent |\n'
    printf '|---------------|-------------|-------|\n'
    for slug in "${FIXTURE_SLUGS[@]}"; do
      printf '| %s | %s 専門家 | `%s-reviewer.md` |\n' "$slug" "$slug" "$slug"
    done
    printf '\n## Trailing Section\n\nProse mentioning `unrelated-reviewer.md` outside tables must not count.\n'
  } > "$d/plugins/rite/skills/reviewers/SKILL.md"

  echo "$d"
}

# --- TC-1: real repository registry is in sync (T-05 / AC-2) ---
echo "=== TC-1: real repository registry passes with rc=0 ==="
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$REPO_ROOT" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-1: real registry (13 reviewers) reports no drift"
else
  fail "TC-1: expected rc=0 on real repository, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-2: synchronized fixture passes (baseline for mutation cases) ---
echo ""
echo "=== TC-2: synchronized fixture registry → rc=0 ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-2: synchronized fixture reports no drift"
else
  fail "TC-2: expected rc=0 on synchronized fixture, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "unrelated-reviewer.md"; then
  fail "TC-2: prose outside tables leaked into the comparison"
else
  pass "TC-2: prose outside tables correctly ignored"
fi

# --- TC-3: dummy agent file added without table updates → drift (T-01) ---
echo ""
echo "=== TC-3: agent file added, tables not updated → rc=1 (I1) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
printf '# dummy\n' > "$d/plugins/rite/agents/dummy-reviewer.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-3: drift detected with rc=1"
else
  fail "TC-3: expected rc=1, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "dummy-reviewer.md"; then
  pass "TC-3: finding names the missing reviewer"
else
  fail "TC-3: dummy-reviewer.md missing from findings"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-4: Available Reviewers row added alone → drift (T-03, I2) ---
echo ""
echo "=== TC-4: Available Reviewers updated, Type Identifiers not → rc=1 (I2) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
# Available Reviewers 表にだけ新 reviewer 行を足す（表末尾ではなく既存行の直後に
# 挿入し、セクション境界に依存しない位置で drift を作る）
sed -i '/^| alpha Expert |/a | zulu Expert | `zulu-reviewer.md` | `**/zulu/**` |' \
  "$d/plugins/rite/skills/reviewers/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-4: partial table update detected with rc=1"
else
  fail "TC-4: expected rc=1, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "zulu-reviewer.md"; then
  pass "TC-4: finding names the half-registered reviewer"
else
  fail "TC-4: zulu-reviewer.md missing from findings"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-5: Type Identifiers row removed alone → drift (I1 reverse) ---
echo ""
echo "=== TC-5: Type Identifiers row missing for an existing agent → rc=1 ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
sed -i '/^| bravo | bravo 専門家 |/d' "$d/plugins/rite/skills/reviewers/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "bravo-reviewer.md"; then
  pass "TC-5: missing Type Identifiers row detected (agents側 + Available側から双方向で浮く)"
else
  fail "TC-5: expected rc=1 with bravo-reviewer.md finding, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-6: slug/Agent cell mismatch → drift (I3) ---
echo ""
echo "=== TC-6: Type Identifiers slug does not match Agent cell → rc=1 (I3) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
# charlie 行の Agent セルだけ delta に差し替える（集合としては両方存在するため
# I1/I2 では検出されず、I3 の行内整合チェックのみが検出できる drift）
sed -i 's/^| charlie | charlie 専門家 | `charlie-reviewer.md` |$/| charlie | charlie 専門家 | `delta-reviewer.md` |/' \
  "$d/plugins/rite/skills/reviewers/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "slug charlie expects charlie-reviewer.md"; then
  pass "TC-6: slug/Agent mismatch detected via I3 row check"
else
  fail "TC-6: expected rc=1 with slug mismatch finding, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-7: heading change → undersized extraction → invocation error ---
echo ""
echo "=== TC-7: renamed section heading → rc=2 (extraction guard) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
sed -i 's/^## Reviewer Type Identifiers$/## Renamed Identifiers/' \
  "$d/plugins/rite/skills/reviewers/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-7: heading drift fails fast as invocation error (not a huge diff report)"
else
  fail "TC-7: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-8: --all is required ---
echo ""
echo "=== TC-8: missing --all → rc=2 ==="
rc=0
bash "$CHECKER" --repo-root "$REPO_ROOT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-8: --all contract enforced"
else
  fail "TC-8: expected rc=2 without --all, got rc=$rc"
fi

# --- Summary ---
echo ""
if ! print_summary "$(basename "$0")" "reviewer registry 3-way sync"; then
  exit 1
fi
