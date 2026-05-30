#!/bin/bash
# wiki-lint-source-refs.test.sh
#
# Smoke tests for wiki-lint-source-refs.sh (wiki/lint.md ステップ 6.2 delegation
# target, Issue #1195 block #10). The helper builds the `all_source_refs` set
# from Wiki page frontmatter and emits a marker block + io_error 3-value enum.
#
# Coverage:
#   TC-1  same_branch 抽出 (canonical multi-line + legacy 単行、prefix 正規化、sort -u)
#   TC-2  same_branch 欠落ページ (legitimate absence) → read_ok=true, 空集合
#   TC-3  空 pages_list → 空 marker block, read_ok=true, errors=0
#   TC-4  placeholder residue (--branch-strategy "{...}") → exit 1 + LINT_PHASE_6_2_PLACEHOLDER_RESIDUE marker
#   TC-5  partial pollution (.rite/wiki/raw/ 行混入) → exit 1
#   TC-6  unknown branch_strategy → exit 1
#   TC-7  sources: 節あるが ref 0 件 → WARNING + read_ok=true (空集合)
#   TC-8  separate_branch 抽出 (git show)
#   TC-9  separate_branch io_error (存在しない wiki_branch ref) → read_ok=io_error
#   TC-10 --branch-strategy 欠落 → exit 2 (invocation error)
#
# NOT covered (environment-dependent): mktemp failure on read-only /tmp,
# sort/awk pipeline OOM. Both downgrade to io_error and are verified by reading.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-source-refs.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

cleanup_dirs=()
tmp_files=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
  for p in "${tmp_files[@]:-}"; do [ -n "$p" ] && rm -f "$p"; done
}
trap cleanup EXIT

mk_tmp() {
  local f
  f=$(mktemp /tmp/rite-wlsr-XXXXXX) || { echo "ERROR: mktemp failed" >&2; exit 1; }
  tmp_files+=("$f")
  printf '%s' "$f"
}

# canonical multi-line + legacy 単行の sources を持つページ群を sandbox に書く。
write_pages() {
  local root="$1"
  mkdir -p "$root/.rite/wiki/pages"
  # canonical multi-line 形式 + `.rite/wiki/` prefix 付き ref (正規化対象)
  cat > "$root/.rite/wiki/pages/p1.md" <<'EOF'
---
title: "Page 1"
sources:
  - type: "review"
    ref: ".rite/wiki/raw/reviews/20260410T000000Z.md"
  - type: "fix"
    ref: "raw/fixes/20260411T000000Z.md"
tags: ["x"]
---
body
EOF
  # legacy 単行形式 `- ref:`
  cat > "$root/.rite/wiki/pages/p2.md" <<'EOF'
---
title: "Page 2"
sources:
- ref: "raw/issues/20260412T000000Z.md"
---
EOF
}

# === TC-1: same_branch 抽出 (multi-line + legacy、prefix 正規化、sort -u) ===
echo "=== TC-1: same_branch 抽出 ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
write_pages "$sbx"
errf=$(mk_tmp); outf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" ".rite/wiki/pages/p2.md" \
  | bash "$SCRIPT" --branch-strategy same_branch --wiki-branch "" --repo-root "$sbx" >"$outf" 2>"$errf"
rc=$?
assert "TC-1 exit 0" "0" "$rc"
assert_grep     "TC-1 multi-line ref 抽出 (review)"  "$outf" '^raw/reviews/20260410T000000Z\.md$'
assert_grep     "TC-1 multi-line ref 抽出 (fix)"     "$outf" '^raw/fixes/20260411T000000Z\.md$'
assert_grep     "TC-1 legacy 単行 ref 抽出"          "$outf" '^raw/issues/20260412T000000Z\.md$'
assert_not_grep "TC-1 prefix 正規化 (.rite/wiki/ 残留なし)" "$outf" '\.rite/wiki/raw/'
assert_grep     "TC-1 marker begin"  "$outf" '^---all_source_refs_begin---$'
assert_grep     "TC-1 marker end"    "$outf" '^---all_source_refs_end---$'
assert_grep     "TC-1 read_ok=true"  "$outf" '^all_source_refs_read_ok=true$'
assert_grep     "TC-1 errors=0"      "$outf" '^all_source_refs_read_errors=0$'

# === TC-2: same_branch 欠落ページ (legitimate absence) → read_ok=true ===
echo "=== TC-2: same_branch legitimate absence ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
errf=$(mk_tmp); outf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/missing.md" \
  | bash "$SCRIPT" --branch-strategy same_branch --repo-root "$sbx" >"$outf" 2>"$errf"
rc=$?
assert "TC-2 exit 0" "0" "$rc"
assert_grep "TC-2 read_ok=true (absence は降格しない)" "$outf" '^all_source_refs_read_ok=true$'
assert_grep "TC-2 errors=0"                            "$outf" '^all_source_refs_read_errors=0$'

# === TC-3: 空 pages_list → 空 marker block, read_ok=true, errors=0 ===
echo "=== TC-3: 空 pages_list ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
errf=$(mk_tmp); outf=$(mk_tmp)
printf '' | bash "$SCRIPT" --branch-strategy same_branch --repo-root "$sbx" >"$outf" 2>"$errf"
rc=$?
assert "TC-3 exit 0" "0" "$rc"
assert_grep "TC-3 marker begin (0 件でも emit)" "$outf" '^---all_source_refs_begin---$'
assert_grep "TC-3 marker end (0 件でも emit)"   "$outf" '^---all_source_refs_end---$'
assert_grep "TC-3 read_ok=true"                 "$outf" '^all_source_refs_read_ok=true$'

# === TC-4: placeholder residue (branch_strategy) → exit 1 + marker ===
echo "=== TC-4: placeholder residue ==="
errf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" \
  | bash "$SCRIPT" --branch-strategy "{branch_strategy}" --wiki-branch "main" 2>"$errf" >/dev/null
rc=$?
assert "TC-4 exit 1 (fail-fast)" "1" "$rc"
assert_grep "TC-4 PLACEHOLDER_RESIDUE marker" "$errf" 'LINT_PHASE_6_2_PLACEHOLDER_RESIDUE=1'

# === TC-5: partial pollution (raw 行混入) → exit 1 ===
echo "=== TC-5: partial pollution ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
write_pages "$sbx"
errf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" ".rite/wiki/raw/reviews/x.md" \
  | bash "$SCRIPT" --branch-strategy same_branch --repo-root "$sbx" 2>"$errf" >/dev/null
rc=$?
assert "TC-5 exit 1 (fail-fast)" "1" "$rc"
assert_grep "TC-5 partial pollution エラー" "$errf" 'partial pollution 検出'

# === TC-6: unknown branch_strategy → exit 1 ===
echo "=== TC-6: unknown branch_strategy ==="
errf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" \
  | bash "$SCRIPT" --branch-strategy bogus 2>"$errf" >/dev/null
rc=$?
assert "TC-6 exit 1 (fail-fast)" "1" "$rc"
assert_grep "TC-6 unknown branch_strategy エラー" "$errf" '未知の branch_strategy'

# === TC-7: sources: 節あるが ref 0 件 → WARNING + read_ok=true ===
echo "=== TC-7: sources 節あるが ref 0 件 ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
mkdir -p "$sbx/.rite/wiki/pages"
cat > "$sbx/.rite/wiki/pages/empty-src.md" <<'EOF'
---
title: "Empty sources"
sources:
tags: ["x"]
---
EOF
errf=$(mk_tmp); outf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/empty-src.md" \
  | bash "$SCRIPT" --branch-strategy same_branch --repo-root "$sbx" >"$outf" 2>"$errf"
rc=$?
assert "TC-7 exit 0" "0" "$rc"
assert_grep "TC-7 read_ok=true (空集合は io_error ではない)" "$outf" '^all_source_refs_read_ok=true$'
assert_grep "TC-7 sources_section_empty WARNING" "$errf" 'ref が 1 件も抽出できませんでした'

# === TC-8: separate_branch 抽出 (git show) ===
echo "=== TC-8: separate_branch 抽出 ==="
sbx=$(make_sandbox --branch wikibranch); cleanup_dirs+=("$sbx")
write_pages "$sbx"
git -C "$sbx" add -A >/dev/null 2>&1
git -C "$sbx" -c user.email=t@test.local -c user.name=test commit -q -m pages >/dev/null 2>&1
errf=$(mk_tmp); outf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" ".rite/wiki/pages/p2.md" \
  | bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch wikibranch --repo-root "$sbx" >"$outf" 2>"$errf"
rc=$?
assert "TC-8 exit 0" "0" "$rc"
assert_grep "TC-8 git show で multi-line ref 抽出" "$outf" '^raw/reviews/20260410T000000Z\.md$'
assert_grep "TC-8 git show で legacy ref 抽出"     "$outf" '^raw/issues/20260412T000000Z\.md$'
assert_grep "TC-8 read_ok=true" "$outf" '^all_source_refs_read_ok=true$'

# === TC-9: separate_branch io_error (存在しない wiki_branch ref) ===
echo "=== TC-9: separate_branch io_error ==="
sbx=$(make_sandbox --branch wikibranch); cleanup_dirs+=("$sbx")
write_pages "$sbx"
git -C "$sbx" add -A >/dev/null 2>&1
git -C "$sbx" -c user.email=t@test.local -c user.name=test commit -q -m pages >/dev/null 2>&1
errf=$(mk_tmp); outf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" \
  | bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch nonexistent-ref-xyz --repo-root "$sbx" >"$outf" 2>"$errf"
rc=$?
assert "TC-9 exit 0 (非ブロッキング、io_error は stdout enum で表現)" "0" "$rc"
assert_grep "TC-9 read_ok=io_error" "$outf" '^all_source_refs_read_ok=io_error$'
if grep -qE '^all_source_refs_read_errors=0$' "$outf"; then
  fail "TC-9 errors>0 であるべき (io_error 降格)"
else
  pass "TC-9 errors>0 (io_error 降格)"
fi

# === TC-10: --branch-strategy 欠落 → exit 2 (invocation error) ===
echo "=== TC-10: --branch-strategy 欠落 ==="
errf=$(mk_tmp)
printf '%s\n' ".rite/wiki/pages/p1.md" | bash "$SCRIPT" 2>"$errf" >/dev/null
rc=$?
assert "TC-10 exit 2 (invocation error)" "2" "$rc"
assert_grep "TC-10 --branch-strategy 必須エラー" "$errf" 'branch-strategy は必須'

if ! print_summary "$(basename "$0")" \
  "drift: wiki-lint-source-refs.sh の挙動が変わった可能性。wiki/lint.md ステップ 6.2 委譲契約 (Issue #1195 #10) と marker block / io_error enum の出力契約を参照。"; then
  exit 1
fi
