#!/bin/bash
# create-md-invocation-symmetry.test.sh
#
# Every `create-issue-with-projects.sh` callsite must use the canonical JSON
# pattern (single `"$(jq -n ...)"` argument). The flag-style alternative
# (`--title --body --labels ...`) is not supported by the script and would only
# surface at runtime as a fatal exit when a user actually creates an Issue —
# too late to catch in review.
#
# Two-path architecture (PR #1205 / refs #1195 item #9):
#   - Single-Issue path  = `commands/issue/create.md` ステップ 4.3
#                          → 1 direct `create-issue-with-projects.sh "$(jq -n ...)"` callsite.
#                            (A single Issue has no children, so NO link-sub-issue.sh here.)
#   - Decompose path     = `scripts/decompose-issues.sh`
#                          → parent + sub-issue loop both call
#                            `bash "$CREATE_SCRIPT" "$(build_payload ...)"` (2 callsites),
#                            where build_payload is the canonical `jq -n` constructor,
#                            and links each child via `bash "$LINK_SCRIPT" ...` (positional args).
#
# The invocation-symmetry contract therefore holds across BOTH files combined:
#   - create-issue-with-projects.sh: 1 (create.md) + 2 (decompose-issues.sh) = 3 canonical sites
#   - link-sub-issue.sh: 1 canonical site (decompose-issues.sh), never in create.md anymore
# This test asserts each path independently and pins the combined total so a
# future re-inlining or silent removal in either file is caught.
#
# When this test fails: a flag-style invocation has likely been introduced, or
# a callsite was removed without moving the contract to the other path.
# Cross-reference `references/issue-create-with-projects.md` for the canonical
# JSON pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CREATE_MD="$PLUGIN_ROOT/commands/issue/create.md"
DECOMPOSE_SH="$PLUGIN_ROOT/scripts/decompose-issues.sh"
SOT_MD="$PLUGIN_ROOT/references/issue-create-with-projects.md"

for f in "$CREATE_MD" "$DECOMPOSE_SH" "$SOT_MD"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

# ──────────────────────────────────────────────────────────────────────
# TC-1: Single-Issue path (create.md ステップ 4.3) has exactly 1 canonical
#       create-issue-with-projects.sh callsite using `"$(jq -n` pattern.
# ──────────────────────────────────────────────────────────────────────
create_md_canonical=$(grep -c 'create-issue-with-projects\.sh "\$(jq -n' "$CREATE_MD" || true)
if [ "$create_md_canonical" -ge 1 ]; then
  pass "TC-1 Single-Issue path (create.md 4.3) has canonical JSON callsite (count=$create_md_canonical)"
else
  fail "TC-1 Single-Issue path (create.md 4.3) missing canonical 'create-issue-with-projects.sh \"\$(jq -n' callsite (count=$create_md_canonical)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-1b: Decompose path (decompose-issues.sh) routes both its create
#        invocations through the canonical `build_payload` (jq -n) constructor.
#        Parent + sub-issue loop = 2 callsites.
# ──────────────────────────────────────────────────────────────────────
decompose_canonical=$(grep -cE 'bash "\$CREATE_SCRIPT" "\$\(build_payload' "$DECOMPOSE_SH" || true)
if [ "$decompose_canonical" -ge 2 ]; then
  pass "TC-1b Decompose path (decompose-issues.sh) has both canonical build_payload callsites (count=$decompose_canonical)"
else
  fail "TC-1b Decompose path (decompose-issues.sh) canonical build_payload callsite count < 2 (actual=$decompose_canonical). Expected parent + sub-issue loop"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-1d: build_payload itself is the canonical `jq -n` constructor (the
#        decompose path's create JSON shape). Pins that the moved logic still
#        builds the JSON via jq -n rather than a hand-built/flag-style string.
# ──────────────────────────────────────────────────────────────────────
if grep -qE '^build_payload\(\) \{' "$DECOMPOSE_SH" && grep -qE '^[[:space:]]*jq -n' "$DECOMPOSE_SH"; then
  pass "TC-1d build_payload constructs the create JSON via jq -n (canonical)"
else
  fail "TC-1d build_payload missing or not built via jq -n in $DECOMPOSE_SH"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-1e: Combined invariant — total canonical create-issue callsites across
#        both paths is >= 3 (1 single + 2 decompose). Catches a silent removal
#        in either file without re-homing the contract.
# ──────────────────────────────────────────────────────────────────────
combined_canonical=$((create_md_canonical + decompose_canonical))
if [ "$combined_canonical" -ge 3 ]; then
  pass "TC-1e combined canonical create-issue callsite count >= 3 (create.md=$create_md_canonical + decompose=$decompose_canonical = $combined_canonical)"
else
  fail "TC-1e combined canonical create-issue callsite count < 3 (create.md=$create_md_canonical + decompose=$decompose_canonical = $combined_canonical). Expected single create + parent create + sub-issue loop"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-2: All actual `create-issue-with-projects.sh` invocations (the bash
#       callsite signature `bash .../create-issue-with-projects.sh` or via the
#       $CREATE_SCRIPT var) use the canonical pattern in BOTH files.
# ──────────────────────────────────────────────────────────────────────
# Single-Issue path: in create.md the only real invocation signature is the
# `bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n` line.
# A prose mention like `ERROR: create-issue-with-projects.sh failed` is NOT a
# `bash .../create-issue-with-projects.sh` callsite and is excluded by anchoring
# on `bash` followed by the script path.
create_md_invocations=$(grep -cE 'bash [^|]*create-issue-with-projects\.sh ' "$CREATE_MD" || true)
create_md_non_canonical=$((create_md_invocations - create_md_canonical))
if [ "$create_md_non_canonical" -eq 0 ]; then
  pass "TC-2 create.md: all create-issue-with-projects.sh invocations are canonical (total=$create_md_invocations)"
else
  echo "  Non-canonical invocations in create.md:"
  grep -nE 'bash [^|]*create-issue-with-projects\.sh ' "$CREATE_MD" \
    | grep -v 'create-issue-with-projects\.sh "\$(jq -n' \
    | sed 's/^/    /'
  fail "TC-2 create.md: $create_md_non_canonical create-issue-with-projects.sh invocation(s) NOT canonical (total=$create_md_invocations)"
fi

# Decompose path: every `bash "$CREATE_SCRIPT"` invocation must go through
# `"$(build_payload`. A flag-style invocation would NOT match the build_payload form.
decompose_invocations=$(grep -cE 'bash "\$CREATE_SCRIPT"' "$DECOMPOSE_SH" || true)
decompose_non_canonical=$((decompose_invocations - decompose_canonical))
if [ "$decompose_non_canonical" -eq 0 ]; then
  pass "TC-2b decompose-issues.sh: all \$CREATE_SCRIPT invocations route through build_payload (total=$decompose_invocations)"
else
  echo "  Non-canonical \$CREATE_SCRIPT invocations in decompose-issues.sh:"
  grep -nE 'bash "\$CREATE_SCRIPT"' "$DECOMPOSE_SH" \
    | grep -v 'bash "\$CREATE_SCRIPT" "\$(build_payload' \
    | sed 's/^/    /'
  fail "TC-2b decompose-issues.sh: $decompose_non_canonical \$CREATE_SCRIPT invocation(s) bypass build_payload (total=$decompose_invocations)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-3: flag-style `--title` flag is not adjacent to any
#       create-issue-with-projects.sh / $CREATE_SCRIPT callsite (within 5 lines).
#       canonical pattern uses `--arg title`, so a bare `--title` flag near a
#       callsite signals a regression in either path.
# ──────────────────────────────────────────────────────────────────────
check_no_flag_title_proximity() {
  local label="$1"
  local file="$2"
  local trigger_pat="$3"
  local suspects
  suspects=$(awk -v trig="$trigger_pat" '
    $0 ~ trig { trigger_line=NR; window_start=NR; window_end=NR+5 }
    trigger_line && NR >= window_start && NR <= window_end {
      if ($0 ~ /[[:space:]]--title[[:space:]]/) { print trigger_line ":" NR ":" $0 }
    }
  ' "$file" || true)
  if [ -z "$suspects" ]; then
    pass "$label"
  else
    echo "  Suspect flag-style proximity:"
    printf '%s\n' "$suspects" | sed 's/^/    /'
    fail "$label (probable flag-style regression)"
  fi
}
# awk regex (passed via -v) uses POSIX ERE: a literal dot is escaped as [.] and
# a literal `$` via [$] so awk does not emit "escape sequence treated as ..."
# warnings to stderr (which would otherwise pollute CI logs).
check_no_flag_title_proximity "TC-3 no flag-style --title near create.md create callsite" \
  "$CREATE_MD" 'create-issue-with-projects[.]sh'
check_no_flag_title_proximity "TC-3b no flag-style --title near decompose-issues.sh \$CREATE_SCRIPT callsite" \
  "$DECOMPOSE_SH" 'bash "[$]CREATE_SCRIPT"'

# ──────────────────────────────────────────────────────────────────────
# TC-4: SoT (references/issue-create-with-projects.md) demonstrates the
#       canonical JSON pattern.
# ──────────────────────────────────────────────────────────────────────
if grep -qE 'create-issue-with-projects\.sh "\$\(jq -n' "$SOT_MD"; then
  pass "TC-4 SoT (references/issue-create-with-projects.md) demonstrates canonical JSON pattern"
else
  fail "TC-4 SoT does NOT show canonical JSON pattern (SoT drift suspected)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-5: link-sub-issue.sh invocation now lives in the Decompose path
#       (decompose-issues.sh), called with positional args. A single Issue has
#       no children, so create.md must NOT invoke link-sub-issue.sh.
# ──────────────────────────────────────────────────────────────────────
# Canonical decompose callsite: `bash "$LINK_SCRIPT" \` (line-continuation form,
# args on the next line — the runtime shape). Documentation/prose mentions are
# allowed but the real invocation must exist.
link_canonical=$(grep -cE 'bash "\$LINK_SCRIPT"[[:space:]]*\\$' "$DECOMPOSE_SH" || true)
link_total=$(grep -cE 'bash "\$LINK_SCRIPT"' "$DECOMPOSE_SH" || true)
if [ "$link_canonical" -ge 1 ] && [ "$link_total" -ge "$link_canonical" ]; then
  pass "TC-5 decompose-issues.sh has $link_canonical canonical link-sub-issue.sh callsite(s), $link_total total"
else
  fail "TC-5 decompose-issues.sh link-sub-issue.sh integrity broken (canonical=$link_canonical, total=$link_total) — silent removal suspected"
fi

# TC-5b: the positional 4-arg contract is visible at the canonical callsite.
# link-sub-issue.sh takes <owner> <repo> <parent> <child>; assert the callsite
# passes "$owner" "$repo" "$parent_issue_number" "$sub_number" so an accidental
# switch to a flag/JSON form (which the script does not accept) is caught.
if grep -qE 'bash "\$LINK_SCRIPT"' "$DECOMPOSE_SH" \
   && grep -qE '"\$owner" "\$repo" "\$parent_issue_number" "\$sub_number"' "$DECOMPOSE_SH"; then
  pass "TC-5b link-sub-issue.sh canonical callsite passes positional 4 args (owner repo parent child)"
else
  fail "TC-5b link-sub-issue.sh positional 4-arg form not found at the decompose callsite"
fi

# TC-5c: create.md no longer runs link-sub-issue.sh in its create flow (the
# runtime invocation moved to decompose-issues.sh — TC-5/TC-5b). The ONLY
# remaining mention in create.md is the manual-recovery guidance line in the
# Decompose completion report (ステップ 5.6, shown when link_failures > 0):
#   - 復旧: `bash {plugin_root}/scripts/link-sub-issue.sh {owner} {repo} ...`
# That recovery hint is an intended fallback contract, not a runtime callsite, so
# we (a) require every link-sub-issue.sh mention in create.md to be that recovery
# line, and (b) pin the recovery line's presence so it cannot be silently dropped.
link_mentions_total=$(grep -cE 'link-sub-issue\.sh' "$CREATE_MD" || true)
link_recovery_mentions=$(grep -cE '復旧:.*scripts/link-sub-issue\.sh' "$CREATE_MD" || true)
if [ "$link_mentions_total" -eq "$link_recovery_mentions" ] && [ "$link_recovery_mentions" -ge 1 ]; then
  pass "TC-5c create.md's only link-sub-issue.sh mention is the manual-recovery guidance (recovery=$link_recovery_mentions, total=$link_mentions_total); no runtime callsite in the create flow"
else
  echo "  link-sub-issue.sh mentions in create.md:"
  grep -nE 'link-sub-issue\.sh' "$CREATE_MD" | sed 's/^/    /'
  fail "TC-5c create.md link-sub-issue.sh mentions are not solely the recovery guidance (recovery=$link_recovery_mentions, total=$link_mentions_total). A runtime callsite leaked back, or the recovery hint was dropped."
fi

# ──────────────────────────────────────────────────────────────────────
# TC-6: `[create:returned-to-caller:{N}]` HTML sentinel present in both
#       completion reports (Single Issue 4.4 / Decompose 5.6) of create.md.
# ──────────────────────────────────────────────────────────────────────
# Completion-report sentinels remain in create.md (the report templates were
# NOT moved to decompose-issues.sh — only the create/link logic was). Multiple
# SoT (SKILL.md / workflow-identity.md / SPEC.md) depend on this grep contract.
sentinel_count=$(grep -cE '<!-- \[create:returned-to-caller:\{(issue_number|parent_issue_number)\}\] -->' "$CREATE_MD" || true)
if [ "$sentinel_count" -ge 2 ]; then
  pass "TC-6 [create:returned-to-caller:{N}] HTML sentinel present in both paths (count=$sentinel_count)"
else
  fail "TC-6 [create:returned-to-caller:{N}] HTML sentinel missing or below 2 sites (count=$sentinel_count). Expected: Single Issue path (ステップ 4.4) + Decompose path (ステップ 5.6)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-7: active disambiguation marker `<!-- skill return signal: caller must continue next step -->`
#       emitted >= sentinel count, and each emit-site sentinel is immediately
#       preceded by it.
# ──────────────────────────────────────────────────────────────────────
emit_site_sentinel_count=$(grep -cE '^<!-- \[create:returned-to-caller:\{(issue_number|parent_issue_number)\}\] -->$' "$CREATE_MD" || true)
emit_site_disambiguator_count=$(grep -cE '^<!-- skill return signal: caller must continue next step -->$' "$CREATE_MD" || true)
if [ "$emit_site_disambiguator_count" -ge "$emit_site_sentinel_count" ]; then
  pass "TC-7a disambiguator marker (emit site only) count >= sentinel emit site count (disambiguator=$emit_site_disambiguator_count, sentinel=$emit_site_sentinel_count)"
else
  fail "TC-7a disambiguator marker (emit site only) count < sentinel emit site count (disambiguator=$emit_site_disambiguator_count, sentinel=$emit_site_sentinel_count). Each emit site sentinel must be preceded by '<!-- skill return signal: caller must continue next step -->'"
fi

adjacency_violations=$(awk '
  { lines[NR] = $0 }
  /^<!-- \[create:returned-to-caller:\{(issue_number|parent_issue_number)\}\] -->$/ {
    prev = lines[NR-1]
    if (prev !~ /^<!-- skill return signal: caller must continue next step -->$/) {
      print NR ":" $0 " (prev line " (NR-1) ": " prev ")"
    }
  }
' "$CREATE_MD" || true)
if [ -z "$adjacency_violations" ]; then
  pass "TC-7b each emit site sentinel is preceded by disambiguator marker on the immediately previous line"
else
  echo "  Adjacency violations:"
  printf '%s\n' "$adjacency_violations" | sed 's/^/    /'
  fail "TC-7b emit site sentinel without adjacent disambiguator marker found (silent marker strip suspected)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-8: create.md は flow-state ライフサイクルに関与しない (Issue #1184)
#       ステップ6 (flow-state completed 化) 削除の regression を pin する。
#       create.md に flow-state.sh set / --phase completed が再混入したら検出し、
#       「別の active な work フローの flow-state を誤って上書きする」回帰を防ぐ。
# ──────────────────────────────────────────────────────────────────────
flow_state_set_count=$(grep -cE 'flow-state\.sh set' "$CREATE_MD" || true)
phase_completed_count=$(grep -cE '\-\-phase completed' "$CREATE_MD" || true)
if [ "$flow_state_set_count" -eq 0 ] && [ "$phase_completed_count" -eq 0 ]; then
  pass "TC-8 create.md は flow-state を init/所有しない (flow-state.sh set=$flow_state_set_count, --phase completed=$phase_completed_count; Issue #1184)"
else
  fail "TC-8 create.md に flow-state 操作が再混入 (flow-state.sh set=$flow_state_set_count, --phase completed=$phase_completed_count). Issue #1184: issue:create は flow-state ライフサイクルに関与してはならない"
fi

print_summary "create-md-invocation-symmetry.test.sh"
