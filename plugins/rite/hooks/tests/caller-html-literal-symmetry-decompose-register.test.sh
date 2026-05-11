#!/bin/bash
# caller-html-literal-symmetry-decompose-register.test.sh
#
# ⚠️ DELETION CHECKLIST (削除忘れ防止):
#   本テストは parent-routing-unification ADR (docs/designs/parent-routing-unification.md) PR-5 で
#   create-decompose.md / create-register.md からも caller HTML literal が撤去されるタイミングで
#   **テストファイル全体を削除する** こと。PR-5 マージ時のチェックリスト:
#     1. plugins/rite/hooks/tests/caller-html-literal-symmetry-decompose-register.test.sh を削除
#     2. plugins/rite/hooks/tests/run-tests.sh (テストランナーが個別 list する形式に変わった場合は同等の場所) から該当行を削除
#     3. plugins/rite/skills/rite-workflow/references/sub-skill-return-protocol.md
#        "廃止済 invariant test" list (line 94 付近) に本ファイル名を追記
#   PR-5 完了後に本ファイルが残ると、対象ファイル削除後に file-not-found exit 1 を出すが
#   CI が個別 stderr を見ない場合 silent fail する経路があるため必ず削除する。
#   (旧 item 4 「_test-helpers.sh の例示コメント削除」は本 PR で _test-helpers.sh が既に
#    parent-routing-pattern-interim.test.sh を例示するよう更新済のため不要、pr-test-analyzer MIN-1 対応)
#
# Tests for caller HTML inline literal symmetry across the
# Phase 3.4 Terminal Completion sections of create-decompose.md
# and create-register.md.
#
# Issue #855 — extension of the caller-html-literal-symmetry test
# from PR #850 (which guards 2 example blocks within a single file,
# create-interview.md) to cross-file symmetry between two terminal
# sub-skills that share the same Phase 3.4 deactivation contract.
#
# Purpose:
#   Both /rite:issue:create-decompose and /rite:issue:create-register
#   are terminal sub-skills that emit a single `<!-- caller: ... -->`
#   HTML inline comment ahead of their Phase 3.4 Terminal Completion
#   block. The contract that comment encodes is identical between the
#   two files except for one allowed semantic-difference token
#   (` on the Normal path`) that exists in create-decompose.md only —
#   create-decompose.md has a Delegation path branch, create-register.md
#   does not.
#
#   Beyond the caller comment, the Phase 3.4 deactivation `bash` literal
#   itself is byte-identical between the two files. The two are managed
#   as a co-evolving pair (create-decompose.md Phase 3.4 even states
#   "Same policy as create-register.md Phase 3.4." referencing its
#   sibling create-register.md).
#
#   This test verifies:
#     1. Each file has exactly 1 occurrence of `<!-- caller:`.
#     2. Each caller literal contains all 5 required semantic elements
#        (Phase 3.4 deactivation contract, completion message marker,
#        sentinel grep policy, Mandatory After Delegation reference,
#        DO NOT stop directive).
#     3. The caller literals are byte-equal after stripping the single
#        allowed difference (` on the Normal path`) from the
#        create-decompose.md side. Any other byte-level divergence
#        is treated as drift.
#     4. The Phase 3.4 deactivation `bash` literal block is byte-equal
#        across both files (no semantic difference is allowed there —
#        the deactivation is identical by contract).
#
# When this test fails:
#   The two files have drifted, typically because someone updated one
#   block but missed the symmetric update in the other. Restore symmetry
#   by replicating the change across both files. Do NOT relax this test —
#   symmetry restoration is the correct fix.
#
# Historical note (ADR docs/designs/parent-routing-unification.md):
#   The prior `caller-html-literal-symmetry.test.sh` that guarded create-interview.md
#   was retired along with the Layer 3a HTML literal it pinned (create-interview
#   migrated to parent-routing pattern with bare bracket sentinel; caller HTML literal
#   no longer exists). This test (decompose-register) remains active until PR-7, when
#   the cumulative invariant tests are deleted and parent-routing-pattern-uniformity.test.sh
#   is introduced as the unified replacement. PR-5 migrates create-register.md and
#   create-decompose.md to parent-routing pattern, but this test is preserved through
#   PR-5 → PR-6 → PR-7 transition window per ADR §6.1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

DECOMPOSE="$REPO_ROOT/plugins/rite/commands/issue/create-decompose.md"
REGISTER="$REPO_ROOT/plugins/rite/commands/issue/create-register.md"

for f in "$DECOMPOSE" "$REGISTER"; do
  if [ ! -f "$f" ]; then
    # Output convention (Issue #853): Hard precondition (missing target file) → stderr
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

ALLOWED_DIFF=" on the Normal path"

echo "=== caller HTML inline literal occurrence count (per file) ==="
for label in decompose register; do
  case "$label" in
    decompose) target="$DECOMPOSE" ;;
    register)  target="$REGISTER" ;;
  esac
  count=$(grep -cF '<!-- caller:' "$target" 2>/dev/null || true)
  count=${count:-0}
  if [ "$count" -eq 1 ]; then
    pass "$label: expected 1 caller-comment line, found 1"
  else
    fail "$label: expected exactly 1 caller-comment line, found $count"
  fi
done

echo
echo "=== required-element presence within each caller literal ==="
REQUIRED_ELEMENTS=(
  "this sub-skill is terminal"
  "Phase 3.4 deactivates flow state"
  "[create:completed:{N}]"
  "Mandatory After Delegation section MUST run"
  "DO NOT stop"
)
for label in decompose register; do
  case "$label" in
    decompose) target="$DECOMPOSE" ;;
    register)  target="$REGISTER" ;;
  esac
  # Use mapfile + process substitution instead of `grep | head -1` to avoid
  # `set -o pipefail` aborting the script when grep finds 0 matches (exit 1).
  # The pipefail-induced abort would make the empty-string check below dead
  # code and prevent subsequent phases from running.
  mapfile -t _caller_lines < <(grep -F '<!-- caller:' "$target")
  caller_line="${_caller_lines[0]:-}"
  if [ -z "$caller_line" ]; then
    fail "$label: no caller-comment line extracted; cannot verify required elements"
    continue
  fi
  for needle in "${REQUIRED_ELEMENTS[@]}"; do
    if [[ "$caller_line" == *"$needle"* ]]; then
      pass "$label caller literal contains: $needle"
    else
      fail "$label caller literal missing required element: $needle"
    fi
  done
done

echo
echo "=== cross-file caller literal byte equality (allowed-diff stripped) ==="
mapfile -t _decompose_lines < <(grep -F '<!-- caller:' "$DECOMPOSE")
mapfile -t _register_lines < <(grep -F '<!-- caller:' "$REGISTER")
decompose_line="${_decompose_lines[0]:-}"
register_line="${_register_lines[0]:-}"
# Strip the single allowed semantic difference from the decompose side and
# compare. Use bash parameter expansion (no regex / sed) so the comparison
# is unambiguous — only the literal substring " on the Normal path" is
# removed; everything else must match byte-for-byte.
decompose_normalized="${decompose_line/${ALLOWED_DIFF}/}"
if [ "$decompose_normalized" = "$register_line" ]; then
  pass "caller HTML inline literals are byte-equal after stripping allowed diff '$ALLOWED_DIFF'"
else
  fail "caller HTML inline literals diverge between create-decompose.md and create-register.md beyond the allowed diff"
  # Output convention (Issue #853): failure detail context stays on stdout so it
  # appears adjacent to the fail() marker in a single result stream.
  echo "  --- decompose caller (raw) ---"
  echo "    $decompose_line"
  echo "  --- decompose caller (allowed-diff stripped) ---"
  echo "    $decompose_normalized"
  echo "  --- register caller (raw) ---"
  echo "    $register_line"
fi

echo
echo "=== Phase 3.4 deactivation bash literal byte equality ==="
# The Phase 3.4 deactivation block is a 4-line literal:
#   bash {plugin_root}/hooks/flow-state-update.sh patch \
#     --phase "create_completed" \
#     --next "none" --active false \
#     --if-exists
#
# Extract these 4 contiguous lines from each file by anchoring on the
# first line and capturing the next 3 lines. awk preserves trailing
# whitespace (relevant for backslash continuations). This is intentional —
# any whitespace drift is also drift worth flagging.
extract_deactivation_block() {
  local file="$1"
  awk '
    /flow-state-update\.sh patch \\$/ {
      print
      for (i=1; i<=3; i++) {
        if ((getline line) > 0) {
          print line
        }
      }
      exit
    }
  ' "$file"
}

decompose_block=$(extract_deactivation_block "$DECOMPOSE")
register_block=$(extract_deactivation_block "$REGISTER")

if [ -z "$decompose_block" ]; then
  fail "decompose: Phase 3.4 deactivation bash literal not found"
elif [ -z "$register_block" ]; then
  fail "register: Phase 3.4 deactivation bash literal not found"
elif [ "$decompose_block" = "$register_block" ]; then
  pass "Phase 3.4 deactivation bash literals are byte-identical across both files"
else
  fail "Phase 3.4 deactivation bash literals diverge between create-decompose.md and create-register.md"
  echo "  --- decompose deactivation block ---"
  printf '%s\n' "$decompose_block" | sed 's/^/    /'
  echo "  --- register deactivation block ---"
  printf '%s\n' "$register_block" | sed 's/^/    /'
fi

echo
echo "=== required-element presence within the deactivation block ==="
DEACT_ELEMENTS=(
  "bash {plugin_root}/hooks/flow-state-update.sh patch"
  '--phase "create_completed"'
  '--next "none" --active false'
  "--if-exists"
)
if [ -n "$decompose_block" ]; then
  for needle in "${DEACT_ELEMENTS[@]}"; do
    if [[ "$decompose_block" == *"$needle"* ]]; then
      pass "deactivation block contains: $needle"
    else
      fail "deactivation block missing required element: $needle"
    fi
  done
else
  fail "deactivation block extraction failed; cannot verify required elements"
fi

DRIFT_HINT='⚠️ caller HTML inline literal symmetry drift detected (decompose ↔ register).
   create-decompose.md (Phase 3.4 Terminal Completion — Normal path) and
   create-register.md (Phase 3.4 Terminal Completion) share a co-evolving
   contract. The two caller comments must be byte-equal after stripping
   the single allowed semantic difference " on the Normal path", and the
   Phase 3.4 deactivation bash literal must be byte-identical across both
   files. Restore symmetry by replicating the change across both files.
   Do NOT relax this test — symmetry restoration is the correct fix.'

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: caller HTML inline literal symmetry across create-decompose.md / create-register.md verified"
exit 0
