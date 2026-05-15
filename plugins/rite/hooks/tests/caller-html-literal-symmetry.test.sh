#!/bin/bash
# caller-html-literal-symmetry.test.sh
#
# Tests for caller HTML inline literal symmetry across the
# create-interview.md example output blocks.
#
# Issue #832 — split out from the 4-site-symmetry concern as a
# dedicated lint script (option B in the Issue's three-way decision).
# Background: PR #830 removed the prose that documented this 2-site
# symmetry; this test restores machine-verifiable drift detection.
#
# Purpose:
#   The /rite:issue:create-interview sub-skill emits a return block
#   ending in one of two HTML-commented sentinels:
#     <!-- [interview:skipped] -->   (XS / Bug Fix / Chore preset)
#     <!-- [interview:completed] --> (S / M / L / XL after deep-dive)
#
#   Both example blocks (Output format example sections in
#   create-interview.md) must contain an *identical*
#   `<!-- caller: ... -->` line that instructs the orchestrator to
#   run a Step 0 Immediate Bash Action. The bash literal embedded in
#   that comment must match across both examples so that an LLM
#   reading either example sees the same contract.
#
#   This test verifies:
#     1. There are exactly 2 occurrences of `<!-- caller:` in
#        create-interview.md (one per example block).
#     2. The 2 occurrences are byte-equal (full-line equality).
#     3. The literal contains all 6 required elements:
#          bash plugins/rite/hooks/flow-state-update.sh patch
#          --phase create_post_interview
#          --active true
#          --next 'Step 0 Immediate Bash Action fired ...'
#          --if-exists
#          --preserve-error-count
#
# When this test fails:
#   The 2 example blocks have drifted, typically because someone
#   updated one block but missed the symmetric update in the other.
#   Restore symmetry by replicating the change across both blocks.
#   Do NOT relax this test — symmetry restoration is the correct fix.
#
# Relationship with `4-site-symmetry.test.sh`:
#   That test guards CLI-arg PRESENCE (--phase / --active / --next /
#   --preserve-error-count) at file-level grep granularity for the 2
#   files commands/issue/create.md and commands/issue/create-interview.md.
#   This test is narrower and stricter: full-line byte equality of the
#   2 caller HTML inline literals within create-interview.md alone.
#   The two are complementary; neither subsumes the other.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

TARGET="$REPO_ROOT/plugins/rite/commands/issue/create-interview.md"

if [ ! -f "$TARGET" ]; then
  # Output convention (Issue #853): Hard precondition (missing target file) → stderr
  echo "  ❌ FILE NOT FOUND: $TARGET" >&2
  exit 1
fi

echo "=== caller HTML inline literal occurrence count ==="
caller_count=$(grep -cF '<!-- caller:' "$TARGET" 2>/dev/null || true)
caller_count=${caller_count:-0}
if [ "$caller_count" -eq 2 ]; then
  pass "expected 2 caller-comment lines, found 2"
else
  fail "expected exactly 2 caller-comment lines, found $caller_count"
fi

echo
echo "=== caller HTML inline literal byte equality ==="
mapfile -t caller_lines < <(grep -F '<!-- caller:' "$TARGET")
if [ "${#caller_lines[@]}" -ge 2 ]; then
  if [ "${caller_lines[0]}" = "${caller_lines[1]}" ]; then
    pass "caller HTML inline literals are byte-identical across the 2 example blocks"
  else
    fail "caller HTML inline literals diverge between [interview:skipped] and [interview:completed] example blocks"
    # Output convention (Issue #853): failure detail context stays on stdout so it
    # appears adjacent to the fail() marker above in a single result stream.
    # See _test-helpers.sh "Output convention" section.
    echo "  --- skipped block caller literal ---"
    echo "    ${caller_lines[0]}"
    echo "  --- completed block caller literal ---"
    echo "    ${caller_lines[1]}"
  fi
else
  fail "fewer than 2 caller-comment lines extracted; cannot compare"
fi

echo
echo "=== required-element presence within the caller literal ==="
REQUIRED_ELEMENTS=(
  "bash plugins/rite/hooks/flow-state-update.sh patch"
  "--phase create_post_interview"
  "--active true"
  "--next 'Step 0 Immediate Bash Action fired"
  "--if-exists"
  "--preserve-error-count"
)
if [ "${#caller_lines[@]}" -ge 1 ]; then
  for needle in "${REQUIRED_ELEMENTS[@]}"; do
    if [[ "${caller_lines[0]}" == *"$needle"* ]]; then
      pass "caller literal contains: $needle"
    else
      fail "caller literal missing required element: $needle"
    fi
  done
else
  fail "no caller-comment line extracted; cannot verify required elements"
fi

# === PR H (#905): start sub-skill 拡張 ===
# start-execute / start-publish / start-finalize 各 sub-skill は paired (completed/aborted)
# 2 caller HTML literal を持つ (create-interview.md とは異なり byte-equal ではなく
# semantic-paired)。両 literal は以下の structural element を共有しなければならない:
#   - 同一 `--phase <name>` (sub-skill 固有: phase5_post_execute / phase5_post_publish / completed)
#   - `--active <true|false>` (sub-skill 固有)
#   - `--if-exists`
#   - `--preserve-error-count`
#   - `bash plugins/rite/hooks/flow-state-update.sh patch`
# 異なる element:
#   - `--next 'message'` (completed/aborted で異なる narrative)
#   - bash command 後の human-readable 説明文
#
# When this test fails: 2 caller literal の structural element drift。restore symmetry
# by replicating shared elements across both example blocks; do NOT relax this test.

echo
echo "=== PR H (#905): start sub-skill paired caller HTML literal symmetry ==="

# sub-skill 別の expected shared elements (paired completed/aborted で共通)。
# 仕様: phase5_post_execute → start-execute、phase5_post_publish → start-publish、
#       completed → start-finalize (ともに `--active false` の terminal cleanup)。
START_SUB_SKILLS=(
  "start-execute.md|phase5_post_execute|true"
  "start-publish.md|phase5_post_publish|true"
  "start-finalize.md|completed|false"
)

for entry in "${START_SUB_SKILLS[@]}"; do
  IFS='|' read -r fname expected_phase expected_active <<<"$entry"
  target_file="$REPO_ROOT/plugins/rite/commands/issue/$fname"
  if [ ! -f "$target_file" ]; then
    fail "PR H: $fname not found at $target_file"
    continue
  fi

  echo
  echo "--- $fname ---"

  # 1. caller 行数: 各 sub-skill exactly 2 (paired completed/aborted)
  c_count=$(grep -cF '<!-- caller:' "$target_file" 2>/dev/null || true)
  c_count=${c_count:-0}
  if [ "$c_count" -eq 2 ]; then
    pass "$fname: caller-comment lines = 2 (paired completed/aborted)"
  else
    fail "$fname: expected exactly 2 caller-comment lines, found $c_count"
    continue
  fi

  # 2. 各 caller literal の shared structural element 確認
  mapfile -t lines < <(grep -F '<!-- caller:' "$target_file")
  shared_elements=(
    "bash plugins/rite/hooks/flow-state-update.sh patch"
    "--phase $expected_phase"
    "--active $expected_active"
    "--if-exists"
    "--preserve-error-count"
  )
  for line_idx in 0 1; do
    line_label="line $((line_idx + 1))"
    for needle in "${shared_elements[@]}"; do
      if [[ "${lines[$line_idx]}" == *"$needle"* ]]; then
        pass "$fname $line_label contains shared element: $needle"
      else
        fail "$fname $line_label missing shared element: $needle"
      fi
    done
  done

  # 3. 2 literal が paired distinction を持つこと: 行全体として byte-equal でない。
  # 注: start-execute / start-publish は `--next 'message'` 文字列が異なる。
  # start-finalize は `--next none` (terminal idempotent write) が両者で同一だが、
  # narrative ("completion handoff" vs "abort handoff") が異なる contract。
  # よって line 全体の byte-equality を否定することで paired distinction を validate する
  # (create-interview.md の byte-equal contract と対称的な inverse の関係)。
  if [ "${lines[0]}" != "${lines[1]}" ]; then
    pass "$fname: 2 caller literals are NOT byte-identical (paired completed/aborted distinction preserved)"
  else
    fail "$fname: 2 caller literals are byte-identical — paired completed/aborted distinction lost"
  fi
done

DRIFT_HINT='⚠️ caller HTML inline literal symmetry drift detected.
   create-interview.md: 2 example output blocks must be byte-identical.
   start-{execute,publish,finalize}.md: 2 paired caller literals must
   share structural elements (--phase / --active / --if-exists /
   --preserve-error-count / bash command) but differ in --next messages.
   Restore symmetry by replicating shared elements; do NOT relax this test.'

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: caller HTML inline literal symmetry verified"
exit 0
