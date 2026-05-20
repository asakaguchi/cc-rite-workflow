#!/bin/bash
# cross-orchestrator-step0-symmetry.test.sh
#
# Cross-orchestrator regression test for Issue #923 — pins the symmetry
# contract for the mechanical enforcement layer (`auto-fire-step0.sh`,
# Layer 4) across the cleanup ↔ wiki:ingest / wiki:ingest ↔ wiki:lint
# 2 接続点.
#
# Background:
#   Wiki experiential knowledge `Declarative enforcement で LLM の
#   stop_reason: end_turn は抑制できない` confirms that prompt-side defense
#   (Layer 1 + Layer 3) cannot fully suppress implicit stop after sub-skill
#   return. Layer 4 mechanical enforcement (PostToolUse hook
#   `auto-fire-step0.sh`) provides a safety net.
#
# Coverage:
#   This test pins the structural existence of Layer 4 across all required
#   sites. It does NOT verify runtime behavior of the hook (that is
#   covered by `auto-fire-step0.test.sh`). It also does NOT replace the
#   existing `step0-immediate-bash-presence.test.sh` (which pins Layer 1
#   + Layer 3 imperative keyword presence).
#
# Pinned sites (2 connection points):
#   1. cleanup.md ↔ wiki:ingest connection
#      - cleanup.md Mandatory After Wiki Ingest must reference Layer 4 hook
#      - cleanup.md Step 0 prose must retain imperative keywords (Layer 1)
#   2. wiki:ingest.md ↔ wiki:lint connection
#      - wiki/ingest.md Mandatory After Auto-Lint must reference Layer 4 hook
#      - wiki/ingest.md Step 0 prose must retain imperative keywords (Layer 1)
#
# Required hook infrastructure:
#   - plugins/rite/hooks/auto-fire-step0.sh exists + executable
#   - plugins/rite/hooks/hooks.json contains PostToolUse Skill matcher entry
#   - auto-fire-step0.sh case statement covers both phase mappings
#   - sub-skill-return-protocol.md Defense-in-depth layers table contains
#     Layer 4 row
#
# When this test fails:
#   The Layer 4 contract (Issue #923) has been weakened. Either the hook
#   file has been removed, the hooks.json entry has been removed, the
#   caller mapping has lost a case arm, or the prompt-side prose has lost
#   its Layer 4 cross-reference. Each failure is a structural regression
#   in the mechanical enforcement layer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

CLEANUP_MD="$PLUGIN_ROOT/commands/pr/cleanup.md"
INGEST_MD="$PLUGIN_ROOT/commands/wiki/ingest.md"
LINT_MD="$PLUGIN_ROOT/commands/wiki/lint.md"
PROTOCOL_MD="$PLUGIN_ROOT/skills/rite-workflow/references/sub-skill-return-protocol.md"
HOOK_SCRIPT="$PLUGIN_ROOT/hooks/auto-fire-step0.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

# Hard precondition — missing target files are environment errors.
for f in "$CLEANUP_MD" "$INGEST_MD" "$LINT_MD" "$PROTOCOL_MD" "$HOOK_SCRIPT" "$HOOKS_JSON"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

echo "=== TC-1: auto-fire-step0.sh hook script existence + executability ==="

# TC-1.1: hook script exists (already verified by precondition guard above, but
# pin explicitly so future restructuring catches this assertion).
assert "TC-1.1: auto-fire-step0.sh exists" "exists" \
  "$([ -f "$HOOK_SCRIPT" ] && echo exists || echo missing)"

# TC-1.2: hook script is executable
assert "TC-1.2: auto-fire-step0.sh is executable" "executable" \
  "$([ -x "$HOOK_SCRIPT" ] && echo executable || echo not_executable)"

# TC-1.3: hook script has #!/bin/bash shebang
assert_grep "TC-1.3: auto-fire-step0.sh has bash shebang" \
  "$HOOK_SCRIPT" \
  '^#!/bin/bash'

echo
echo "=== TC-2: hook caller mapping case arms ==="

# TC-2.1: case arm for ingest_pre_lint (wiki:lint return -> ingest_post_lint)
assert_grep "TC-2.1: auto-fire-step0.sh has 'ingest_pre_lint)' case arm" \
  "$HOOK_SCRIPT" \
  '^[[:space:]]+ingest_pre_lint\)'

# TC-2.2: case arm for cleanup_pre_ingest (wiki:ingest return -> cleanup_post_ingest)
assert_grep "TC-2.2: auto-fire-step0.sh has 'cleanup_pre_ingest)' case arm" \
  "$HOOK_SCRIPT" \
  '^[[:space:]]+cleanup_pre_ingest\)'

# TC-2.3: post-phase mapping ingest_post_lint
assert_grep "TC-2.3: auto-fire-step0.sh maps to 'ingest_post_lint' post-phase" \
  "$HOOK_SCRIPT" \
  'POST_PHASE="ingest_post_lint"'

# TC-2.4: post-phase mapping cleanup_post_ingest
assert_grep "TC-2.4: auto-fire-step0.sh maps to 'cleanup_post_ingest' post-phase" \
  "$HOOK_SCRIPT" \
  'POST_PHASE="cleanup_post_ingest"'

# TC-2.5: flow-state-update.sh patch invocation with --if-exists + --preserve-error-count
# (idempotent with caller Mandatory After Step 0 / Step 1)
assert_grep "TC-2.5: auto-fire-step0.sh uses '--if-exists --preserve-error-count' (idempotent patch)" \
  "$HOOK_SCRIPT" \
  '\-\-if-exists --preserve-error-count'

# TC-2.6: hookSpecificOutput.additionalContext stdout JSON output
assert_grep "TC-2.6: auto-fire-step0.sh emits 'hookSpecificOutput' JSON via stdout" \
  "$HOOK_SCRIPT" \
  'hookSpecificOutput'

# TC-2.7: additionalContext field present
assert_grep "TC-2.7: auto-fire-step0.sh emits 'additionalContext' field" \
  "$HOOK_SCRIPT" \
  'additionalContext'

# TC-2.8: Skill matcher filter (tool_name case statement)
assert_grep "TC-2.8: auto-fire-step0.sh filters on 'Skill' tool_name" \
  "$HOOK_SCRIPT" \
  'Skill\|skill'

# TC-2.9: opt-out config check
assert_grep "TC-2.9: auto-fire-step0.sh checks 'auto_fire_step0' opt-out config" \
  "$HOOK_SCRIPT" \
  'auto_fire_step0'

echo
echo "=== TC-3: hooks.json PostToolUse Skill matcher registration ==="

# TC-3.1: hooks.json contains auto-fire-step0.sh command path
assert_grep "TC-3.1: hooks.json registers auto-fire-step0.sh as PostToolUse hook" \
  "$HOOKS_JSON" \
  'hooks/auto-fire-step0\.sh'

# TC-3.2: hooks.json registers Skill matcher (jq-validated structure)
# Use jq to extract the matcher field for the auto-fire-step0 entry.
matcher_value=$(jq -r '
  .hooks.PostToolUse[]
  | select(.hooks[]? | .command | test("auto-fire-step0"))
  | .matcher // empty
' "$HOOKS_JSON" 2>/dev/null)

assert "TC-3.2: hooks.json PostToolUse entry for auto-fire-step0.sh has matcher='Skill'" "Skill" "$matcher_value"

echo
echo "=== TC-4: cleanup.md ↔ wiki:ingest Layer 4 cross-reference ==="

# TC-4.1: cleanup.md Mandatory After Wiki Ingest references auto-fire-step0.sh
assert_grep "TC-4.1: cleanup.md references 'auto-fire-step0.sh' (Layer 4 hook)" \
  "$CLEANUP_MD" \
  'auto-fire-step0\.sh'

# TC-4.2: cleanup.md mentions Layer 4 as the layer label
assert_grep "TC-4.2: cleanup.md uses 'Layer 4' label (mechanical enforcement)" \
  "$CLEANUP_MD" \
  'Layer 4'

# TC-4.3: cleanup.md Step 0 imperative keyword retained (Layer 1 still canonical)
assert_grep "TC-4.3: cleanup.md retains 'VERY FIRST tool call' Step 0 keyword (Layer 1 canonical)" \
  "$CLEANUP_MD" \
  '\*\*VERY FIRST tool call\*\*'

# TC-4.4: cleanup.md retains cleanup_post_ingest Step 0 bash literal
assert_grep "TC-4.4: cleanup.md retains 'cleanup_post_ingest' Step 0 bash literal" \
  "$CLEANUP_MD" \
  'phase[[:space:]]+"cleanup_post_ingest"'

echo
echo "=== TC-5: wiki/ingest.md ↔ wiki:lint Layer 4 cross-reference ==="

# TC-5.1: wiki/ingest.md Mandatory After Auto-Lint references auto-fire-step0.sh
assert_grep "TC-5.1: wiki/ingest.md references 'auto-fire-step0.sh' (Layer 4 hook)" \
  "$INGEST_MD" \
  'auto-fire-step0\.sh'

# TC-5.2: wiki/ingest.md mentions Layer 4
assert_grep "TC-5.2: wiki/ingest.md uses 'Layer 4' label (mechanical enforcement)" \
  "$INGEST_MD" \
  'Layer 4'

# TC-5.3: wiki/ingest.md Step 0 imperative keyword retained (Layer 1 still canonical)
assert_grep "TC-5.3: wiki/ingest.md retains 'VERY FIRST tool call' Step 0 keyword (Layer 1 canonical)" \
  "$INGEST_MD" \
  '\*\*VERY FIRST tool call\*\*'

# TC-5.4: wiki/ingest.md retains ingest_post_lint Step 0 bash literal
assert_grep "TC-5.4: wiki/ingest.md retains 'ingest_post_lint' Step 0 bash literal" \
  "$INGEST_MD" \
  'phase[[:space:]]+"ingest_post_lint"'

echo
echo "=== TC-6: sub-skill-return-protocol.md Layer 4 row in table ==="

# TC-6.1: protocol doc references auto-fire-step0.sh
assert_grep "TC-6.1: sub-skill-return-protocol.md references 'auto-fire-step0.sh'" \
  "$PROTOCOL_MD" \
  'auto-fire-step0\.sh'

# TC-6.2: protocol doc has Layer 4 entry in Defense-in-depth layers table
# Match the table row pattern: `| 4. Mechanical enforcement` (table row format).
assert_grep "TC-6.2: sub-skill-return-protocol.md has 'Layer 4. Mechanical enforcement' table row" \
  "$PROTOCOL_MD" \
  '\| 4\. Mechanical enforcement'

# TC-6.3: protocol doc updates "two active layers" -> "three active layers"
assert_grep "TC-6.3: sub-skill-return-protocol.md states 'three active layers'" \
  "$PROTOCOL_MD" \
  'three active layers'

# TC-6.4: protocol doc preserves the declarative-limit rationale (Layer 4 rationale paragraph)
assert_grep "TC-6.4: sub-skill-return-protocol.md retains declarative-limit rationale" \
  "$PROTOCOL_MD" \
  'declarative limit'

echo
echo "=== TC-7: wiki/lint.md Phase 9.2 invariant preservation ==="

# TC-7.1: wiki/lint.md Phase 9.2 imperative keyword retained
# (invariant: imperative strength not weakened by Issue #923 changes)
assert_grep "TC-7.1: wiki/lint.md retains 'MUST continue' imperative blockquote (Layer 3b)" \
  "$LINT_MD" \
  'MUST continue'

# TC-7.2: wiki/lint.md Phase 9.2 lint:completed:auto sentinel preserved
assert_grep "TC-7.2: wiki/lint.md retains '[lint:completed:auto]' HTML sentinel" \
  "$LINT_MD" \
  '\[lint:completed:auto\]'

echo
if ! print_summary "$(basename "$0")" "Layer 4 mechanical enforcement (auto-fire-step0.sh) regression — Issue #923. Restore the missing site/file/case arm/cross-reference."; then
  exit 1
fi
