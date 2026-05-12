#!/bin/bash
# Tests for 5-arg symmetry of `flow-state-update.sh create` invocations
# across the rite workflow (Issue #899 / parent #896).
#
# Purpose:
#   Every `flow-state-update.sh create` invocation in command markdown files
#   MUST include all 5 canonical arguments (--phase / --issue / --branch /
#   --pr / --next). Missing any one of them breaks the Pre-write + Mandatory
#   After contract documented in
#   `plugins/rite/commands/issue/references/flow-state-scaffolding.md`.
#
#   `start.md` symmetry is already verified by `start-md-charter.test.sh`'s
#   Symmetry assert (single-target). This test complements it by scanning
#   the **remaining caller files** so that drift in a sub-skill or sibling
#   command does not slip through.
#
# Scope:
#   - plugins/rite/commands/issue/implement.md      (Phase 5.1 sub-skill)
#   - plugins/rite/commands/issue/create.md         (Phase X.X handoff)
#   - plugins/rite/commands/issue/create-interview.md (Pre-flight)
#   - plugins/rite/commands/pr/cleanup.md           (Post-merge hand-off)
#
# Out of scope (documented elsewhere):
#   - `commands/issue/start.md` — covered by `start-md-charter.test.sh`
#   - `commands/issue/references/*.md` — documentation only (illustrative
#     literals must NOT be executed; the references explain the contract)
#   - `commands/resume.md` — references `flow-state-update.sh create` only in
#     prose (documentation of what the invoked command will do); contains no
#     executable bash block invoking create. Including it would yield a false-
#     positive NO_CREATE_BLOCK_FOUND fail.
#
# Detection logic:
#   For each SITE, find every bash code block (``` fence) containing
#   `flow-state-update.sh create` and assert that the block contains all
#   5 required `--<flag>` tokens. The block-aware extraction (vs naive
#   line grep) matches the canonical implementation in
#   `start-md-charter.test.sh::compute_symmetry_for()` so that line
#   continuations (`\`) and multi-line literals are handled identically.
#
# When this test fails:
#   The 5-arg contract has drifted in one of the caller files. Restore
#   the missing flag rather than relaxing the assert. The contract is
#   the runtime invariant — the test is its mirror.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

SITES=(
  "plugins/rite/commands/issue/implement.md"
  "plugins/rite/commands/issue/create.md"
  "plugins/rite/commands/issue/create-interview.md"
  "plugins/rite/commands/pr/cleanup.md"
)

REQUIRED_ARGS=(
  "--phase"
  "--issue"
  "--branch"
  "--pr"
  "--next"
)

# Extract bash blocks containing `flow-state-update.sh create` and emit one
# `null`-delimited record per block. Block-extraction semantics are
# **partially aligned** with `start-md-charter.test.sh::compute_symmetry_for()`,
# but the following 3 divergences are **intentional** and documented below.
# In the future, refactoring `compute_symmetry_for()` into `_test-helpers.sh`
# would let both tests share a single canonical implementation.
#
# Intentional divergences from `compute_symmetry_for()`:
#
#   1. Fence-open regex: `^[[:space:]]*```[[:space:]]*bash[[:space:]]*$` (strict, anchored)
#      vs `compute_symmetry_for`: `^[[:space:]]*```bash` (lenient, info-string accepting).
#      Intent: this test targets 4 specific caller files (implement.md /
#      create.md / create-interview.md / cleanup.md) which all use plain
#      ```bash without info-string suffixes. The strict form prevents false
#      positives if a future caller introduces ```bash {info-string} (which
#      may or may not warrant inclusion in symmetry check — re-evaluate at
#      that time). If info-string callers become common, relax to match.
#
#   2. Multi-`create`-per-block flush logic: `compute_symmetry_for()` emits
#      one record per `create` invocation (`if (in_create) printf ...`), but
#      this test concatenates all lines in a fence block into a single record.
#      Intent: SITES (4 caller files) currently have at most 1 `create` per
#      fence block. If a future caller writes 2 creates in one fence block,
#      this test would treat them as a single block (assertion still works:
#      `--phase` etc. would appear at least once). When per-`create` granularity
#      becomes necessary, port the flush logic from compute_symmetry_for.
#
#   3. Block content: this test stores stripped lines (post inline-comment-strip)
#      vs `compute_symmetry_for` stores original `$0`. Intent: stripped lines
#      simplify downstream `grep -qE` matching. The original-line preservation in
#      compute_symmetry_for is needed for diagnostic output (which this test
#      doesn't produce). When quoted `#` in --arg values appears in real callers
#      (none currently), revisit this decision.
#
# When refactoring: extract `compute_symmetry_for()` into `_test-helpers.sh` and
# parameterize the 3 divergences as function arguments. See Issue #899 / #896.
extract_create_blocks() {
  local target="$1"
  awk '
    /^[[:space:]]*```[[:space:]]*bash[[:space:]]*$/ { in_block=1; block=""; next }
    /^[[:space:]]*```[[:space:]]*$/ {
      if (in_block) {
        if (block ~ /flow-state-update\.sh create/) {
          printf "%s%c", block, 0
        }
        in_block=0; block=""
      }
      next
    }
    in_block {
      line=$0
      # strip whitespace-preceded inline shell comment (intentional divergence #3 above)
      sub(/[[:space:]]+#.*$/, "", line)
      # skip pure shell comment lines
      if (line ~ /^[[:space:]]*#/) next
      block = block line "\n"
    }
  ' "$target"
}

assert_block_has_arg() {
  local site="$1" arg="$2" block="$3" block_id="$4"
  if printf '%s\n' "$block" | grep -qE -- "${arg}([[:space:]]|$)"; then
    return 0
  fi
  fail "${site}|block#${block_id}|${arg} missing"
  return 1
}

# Note: pass/fail counts are tracked by the global FAIL/PASS counters in
# `_test-helpers.sh` via the `pass`/`fail` functions. `print_summary` consumes
# those globals — no local counter is needed in this driver.
total_blocks=0

for site in "${SITES[@]}"; do
  full_path="$REPO_ROOT/$site"
  if [ ! -f "$full_path" ]; then
    fail "${site}|FILE_NOT_FOUND"
    continue
  fi

  echo "=== ${site} ==="

  block_id=0
  any_block=0
  while IFS= read -r -d '' block; do
    [ -z "$block" ] && continue
    block_id=$((block_id + 1))
    any_block=1
    total_blocks=$((total_blocks + 1))
    block_failures=0
    for arg in "${REQUIRED_ARGS[@]}"; do
      if ! assert_block_has_arg "$site" "$arg" "$block" "$block_id"; then
        block_failures=$((block_failures + 1))
      fi
    done
    if [ "$block_failures" -eq 0 ]; then
      pass "${site}|block#${block_id} all 5 args present"
    fi
  done < <(extract_create_blocks "$full_path")

  if [ "$any_block" -eq 0 ]; then
    fail "${site}|NO_CREATE_BLOCK_FOUND (regression — caller previously contained flow-state-update.sh create)"
  fi
done

# Lower bound: at least one block must be found across all SITES. If every
# block disappears, the test silently passes which would mask a wholesale
# removal regression. This mirrors `start-md-charter.test.sh` Symmetry-bound
# assertion (Issue #908 finding 3).
if [ "$total_blocks" -ge 1 ]; then
  pass "lower-bound: total \`flow-state-update.sh create\` blocks across SITES = ${total_blocks} (>= 1)"
else
  fail "lower-bound: zero create blocks found across ${#SITES[@]} SITES (regression — all callers removed?)"
fi

DRIFT_HINT='⚠️ 5-arg flow-state-update.sh create symmetry drift detected.
   Locate the failing (site, block, arg) tuple above and restore the
   missing --phase / --issue / --branch / --pr / --next argument.
   The 5-arg contract is documented in
   plugins/rite/commands/issue/references/flow-state-scaffolding.md.
   Do NOT relax the test — restore the missing flag instead.'

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: 5-arg flow-state-update.sh create symmetry verified across ${#SITES[@]} sites (${total_blocks} blocks)"
exit 0
