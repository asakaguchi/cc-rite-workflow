#!/bin/bash
# create-md-invocation-symmetry.test.sh
#
# Every `create-issue-with-projects.sh` callsite in `commands/issue/create.md`
# must use the canonical JSON pattern (single `"$(jq -n ...)"` argument). The
# flag-style alternative (`--title --body --labels ...`) is not supported by
# the script and would only surface at runtime as a fatal exit when a user
# actually creates an Issue — too late to catch in review.
#
# Coverage:
#   - every `create-issue-with-projects.sh` call is followed by `"$(jq -n`
#   - no flag-style `--title` / `--body` / `--labels` appears within 5 lines
#     of a `create-issue-with-projects.sh` invocation
#   - the callsite count matches the SoT (`references/issue-create-with-projects.md`):
#     at least 3 sites (single create, parent create, sub-issue loop)
#
# When this test fails: a flag-style invocation has likely been introduced.
# Cross-reference `references/issue-create-with-projects.md` for the canonical
# JSON pattern and fix create.md to match.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CREATE_MD="$PLUGIN_ROOT/commands/issue/create.md"
SOT_MD="$PLUGIN_ROOT/references/issue-create-with-projects.md"

if [ ! -f "$CREATE_MD" ]; then
  echo "ERROR: $CREATE_MD not found" >&2
  exit 1
fi
if [ ! -f "$SOT_MD" ]; then
  echo "ERROR: $SOT_MD not found" >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# TC-1: callsite が canonical JSON pattern (`"$(jq -n`) で呼ばれている
# ──────────────────────────────────────────────────────────────────────
# `create-issue-with-projects.sh "$(jq -n` literal が存在することを assert。
canonical_count=$(grep -c 'create-issue-with-projects\.sh "\$(jq -n' "$CREATE_MD" || true)

if [ "$canonical_count" -ge 3 ]; then
  pass "TC-1 canonical JSON pattern callsite count >= 3 (actual=$canonical_count)"
else
  fail "TC-1 canonical JSON pattern callsite count < 3 (actual=$canonical_count). Expected >= 3 (single create, parent create, sub-issue loop)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-2: 全 `create-issue-with-projects.sh` 行が canonical pattern と一致
#       (flag-style が混ざっていない)
# ──────────────────────────────────────────────────────────────────────
total_invocations=$(grep -c 'bash.*create-issue-with-projects\.sh' "$CREATE_MD" || true)
# 説明的言及 (`create-issue-with-projects.sh に委譲`、`ERROR: create-issue-with-projects.sh failed` 等の
# 説明テキスト) は除外して、実 invocation 行のみを数える。`bash ...create-issue-with-projects.sh` パターン
# が実 invocation の signature。
non_canonical=$((total_invocations - canonical_count))

if [ "$non_canonical" -eq 0 ]; then
  pass "TC-2 all create-issue-with-projects.sh invocations use canonical JSON pattern (total=$total_invocations)"
else
  # 非 canonical 行を診断出力
  echo "  Non-canonical invocations:"
  grep -n 'bash.*create-issue-with-projects\.sh' "$CREATE_MD" \
    | grep -v 'create-issue-with-projects\.sh "\$(jq -n' \
    | sed 's/^/    /' >&2
  fail "TC-2 $non_canonical create-issue-with-projects.sh invocations are NOT canonical JSON pattern (total=$total_invocations)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-3: flag-style な `--title` flag が create-issue-with-projects.sh と近接していない
#       (近傍 5 行内に同居していたら fail)
# ──────────────────────────────────────────────────────────────────────
# 近傍検査: create-issue-with-projects.sh を含む行から 5 行以内に `--title` flag があれば
# flag-style 呼び出しの suspect として fail。canonical pattern では `--arg title` を使うため
# `--title` flag は出現しないはず。
suspect_blocks=$(awk '
  /create-issue-with-projects\.sh/ { trigger_line=NR; window_start=NR; window_end=NR+5 }
  trigger_line && NR >= window_start && NR <= window_end {
    if ($0 ~ /[[:space:]]--title[[:space:]]/) { print trigger_line ":" NR ":" $0 }
  }
' "$CREATE_MD" || true)

if [ -z "$suspect_blocks" ]; then
  pass "TC-3 no flag-style --title near create-issue-with-projects.sh callsites"
else
  echo "  Suspect flag-style proximity:"
  printf '%s\n' "$suspect_blocks" | sed 's/^/    /' >&2
  fail "TC-3 found flag-style --title near create-issue-with-projects.sh callsites (probable regression)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-4: SoT (references/issue-create-with-projects.md) との表面的一致
#       SoT が canonical JSON pattern を示していることを確認
# ──────────────────────────────────────────────────────────────────────
if grep -qE 'create-issue-with-projects\.sh "\$\(jq -n' "$SOT_MD"; then
  pass "TC-4 SoT (references/issue-create-with-projects.md) demonstrates canonical JSON pattern"
else
  fail "TC-4 SoT does NOT show canonical JSON pattern (SoT drift suspected)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-5: link-sub-issue.sh callsite が positional 4 args pattern を維持
# ──────────────────────────────────────────────────────────────────────
# Real callsites end the first line with `\` and pass the positional args on
# the next line. A docstring example (single line, inside prose) is allowed —
# the assertion below requires at least one canonical call but does not block
# additional documentation mentions.
link_actual_calls=$(grep -cE 'link-sub-issue\.sh[[:space:]]+\\?$' "$CREATE_MD" || true)
link_total_mentions=$(grep -c 'bash.*link-sub-issue\.sh' "$CREATE_MD" || true)

if [ "$link_total_mentions" -ge 1 ]; then
  pass "TC-5 link-sub-issue.sh mentioned in create.md (count=$link_total_mentions)"
else
  fail "TC-5 link-sub-issue.sh mention missing in create.md"
fi
if [ "$link_actual_calls" -ge 1 ]; then
  pass "TC-5b at least one link-sub-issue.sh callsite uses canonical line-continuation form (count=$link_actual_calls)"
else
  fail "TC-5b no canonical line-continuation form found (refactor to flag form?)"
fi

print_summary "create-md-invocation-symmetry.test.sh"
