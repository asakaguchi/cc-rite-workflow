#!/bin/bash
# Tests for plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh
# (doc_file_patterns 2-file sync detection between review.md and
# reviewers/SKILL.md). Covers Issue #1746 acceptance criteria:
#   - TC-1: the real repository's current 2 files pass (no drift)
#   - TC-2: missing both files (--repo-root outside the plugin source tree,
#     e.g. marketplace/consumer install) → clean skip (rc=0, not applicable)
#   - TC-3: asymmetric absence (only review.md present, SKILL.md missing —
#     a partial checkout signal) → invocation error (rc=2), NOT the clean-skip
#     rc=0 path
#   - TC-4: asymmetric absence (only SKILL.md present, review.md missing) →
#     invocation error (rc=2), symmetric to TC-3
#   - TC-5: drift between the 2 files (a token added to one but not the
#     other) is detected with rc=1
#   - Arg contract: --all required (rc=2)
#
# Portability note: fixture mutations use `awk` via the
# read→transform→write→mv pattern instead of `sed -i`. BSD sed (macOS)
# requires a mandatory backup suffix for `-i`, so GNU-style `sed -i '<expr>'`
# aborts the suite on macOS under `set -e`. The awk pattern is identical on
# GNU and BSD and matches the `reviewer-registry-drift-check.test.sh`
# portability convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CHECKER="$PLUGIN_ROOT/hooks/scripts/doc-heavy-patterns-drift-check.sh"

if [ ! -f "$CHECKER" ]; then
  echo "ERROR: $CHECKER not found" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Helper: create a sandbox with a synchronized doc_file_patterns fixture
# (review.md `doc_file_patterns = [...]` block + reviewers/SKILL.md
# Technical Writer row, both carrying the same glob token set) and echo its
# repo root path.
make_doc_heavy_sandbox() {
  local d
  d=$(make_plain_sandbox --soft) || return 1
  mkdir -p "$d/plugins/rite/skills/review" "$d/plugins/rite/skills/reviewers"

  cat > "$d/plugins/rite/skills/review/SKILL.md" <<'EOF'
# review.md fixture

## Step 1.2.7

```
doc_file_patterns = [
 **/*.md (excluding commands/**/*.md, skills/**/*.md, agents/**/*.md),
 **/*.mdx (excluding commands/**/*.mdx, skills/**/*.mdx, agents/**/*.mdx),
 docs/**, documentation/**,
 **/README*, CHANGELOG*, CONTRIBUTING*,
 i18n/**/*.md, i18n/**/*.mdx (excluding plugins/rite/i18n/**),
 *.rst, *.adoc
]
```
EOF

  cat > "$d/plugins/rite/skills/reviewers/SKILL.md" <<'EOF'
# Reviewers fixture

| Reviewer | Agent | Activation |
|----------|-------|------------|
| Technical Writer | `tech-writer-reviewer.md` | `**/*.md` (excluding `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`), `**/*.mdx` (excluding `commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`), `docs/**`, `documentation/**`, `**/README*`, `CHANGELOG*`, `CONTRIBUTING*`, `*.rst`, `*.adoc`, `i18n/**/*.md`, `i18n/**/*.mdx` (excluding `plugins/rite/i18n/**`) |
EOF

  echo "$d"
}

# --- TC-1: real repository's current 2 files pass (no drift) ---
echo "=== TC-1: real repository's 2 files pass with rc=0 ==="
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$REPO_ROOT" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-1: real review.md / reviewers/SKILL.md report no drift"
else
  fail "TC-1: expected rc=0 on real repository, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-2: neither file exists (consumer/marketplace install) → rc=0 (not applicable) ---
echo ""
echo "=== TC-2: --repo-root without either file → rc=0 (not applicable) ==="
empty_dir=$(make_plain_sandbox)
cleanup_dirs+=("$empty_dir")
rc=0
out=$(bash "$CHECKER" --all --repo-root "$empty_dir" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-2: missing both review.md and reviewers/SKILL.md correctly no-ops with rc=0"
else
  fail "TC-2: expected rc=0, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "not applicable"; then
  pass "TC-2: not-applicable skip message present"
else
  fail "TC-2: expected 'not applicable' message in output"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-3: asymmetric absence (review.md present, SKILL.md missing) → rc=2 ---
echo ""
echo "=== TC-3: only review.md present (partial checkout) → rc=2 ==="
d=$(make_doc_heavy_sandbox)
cleanup_dirs+=("$d")
rm -f "$d/plugins/rite/skills/reviewers/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-3: asymmetric absence (SKILL.md missing) correctly fails with rc=2"
else
  fail "TC-3: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "not applicable"; then
  fail "TC-3: asymmetric absence incorrectly treated as clean skip (not applicable)"
else
  pass "TC-3: asymmetric absence not confused with the clean-skip path"
fi

# --- TC-4: asymmetric absence (SKILL.md present, review.md missing) → rc=2 ---
echo ""
echo "=== TC-4: only reviewers/SKILL.md present (partial checkout) → rc=2 ==="
d=$(make_doc_heavy_sandbox)
cleanup_dirs+=("$d")
rm -f "$d/plugins/rite/skills/review/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-4: asymmetric absence (review.md missing) correctly fails with rc=2"
else
  fail "TC-4: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-5: drift between the 2 files is detected ---
echo ""
echo "=== TC-5: token added to review.md only → rc=1 (drift detected) ==="
d=$(make_doc_heavy_sandbox)
cleanup_dirs+=("$d")
awk_inplace() {
  local file="$1"
  local prog="$2"
  local tmp="${file}.tmp"
  awk "$prog" "$file" > "$tmp"
  mv "$tmp" "$file"
}
awk_inplace "$d/plugins/rite/skills/review/SKILL.md" '
  /^ \*\.rst, \*\.adoc$/ { print; print " **/extra-drift-pattern/**,"; next }
  { print }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-5: drift detected with rc=1"
else
  fail "TC-5: expected rc=1, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "extra-drift-pattern"; then
  pass "TC-5: drift finding names the injected token"
else
  fail "TC-5: drift finding did not mention the injected token"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-6: --all required (arg contract) ---
echo ""
echo "=== TC-6: missing --all → rc=2 ==="
rc=0
out=$(bash "$CHECKER" --repo-root "$REPO_ROOT" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-6: --all contract enforced"
else
  fail "TC-6: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- Summary ---
echo ""
if ! print_summary "$(basename "$0")" "doc_file_patterns 2-file sync"; then
  exit 1
fi
