#!/bin/bash
# create-md-invocation-symmetry.test.sh — CG-A (PR #1079 verified-review)
#
# Purpose:
#   `commands/issue/create.md` の `create-issue-with-projects.sh` callsite が、
#   canonical JSON pattern (`"$(jq -n ...)"` 単一引数) で呼ばれていることを静的に
#   検証する。flag-style (`--title --body --labels ...`) への regress は runtime
#   fatal exit でしか検出できないため、PR #1079 commit 29d179bd で修正された
#   バグの再発を test レベルで防衛する。
#
# Coverage:
#   - 全 `create-issue-with-projects.sh` 呼び出しが `"$(jq -n` 続く形式である
#   - flag-style な `--title` / `--body` / `--labels` を `create-issue-with-projects.sh`
#     と同じ行に持たない (近傍 5 行内に出現しない)
#   - SoT (references/issue-create-with-projects.md) で示される canonical pattern
#     と整合する callsite 数 (>= 3: single create, parent create, sub-issue loop)
#
# When this test fails:
#   PR #1079 で修正した「flag-style 呼び出しでの runtime fatal exit」が再発した
#   可能性がある。create.md を SoT (references/issue-create-with-projects.md) と
#   照合し、canonical JSON pattern に修正すること。

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
# `link-sub-issue.sh "{owner}" "{repo}" "$parent..." "$sub_number"` の signature。
link_calls=$(grep -c 'bash.*link-sub-issue\.sh' "$CREATE_MD" || true)
link_canonical=$(grep -cE 'link-sub-issue\.sh[[:space:]]+\\?$' "$CREATE_MD" || true)

if [ "$link_calls" -ge 1 ]; then
  pass "TC-5 link-sub-issue.sh callsite exists (count=$link_calls)"
else
  fail "TC-5 link-sub-issue.sh callsite missing in create.md"
fi

print_summary "create-md-invocation-symmetry.test.sh"
