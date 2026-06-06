#!/bin/bash
# wiki-lint-skipped-refs.test.sh
#
# Tests for wiki-lint-skipped-refs.sh (wiki/lint.md ステップ 6.0 delegation
# target, Issue #1196 / #1193 MEDIUM #14). The helper builds the `skipped_refs`
# set from log.md `ingest:skip` records and emits a marker block + log_read_ok
# 4-value enum. Structure mirrors wiki-lint-source-refs.test.sh (6.2 counterpart).
#
# Coverage:
#   TC-1  same_branch 抽出 (field 3 厳密一致 / field 4 prefix 正規化 / sort -u)
#   TC-2  same_branch log.md 不在 (legitimate absence) → log_read_ok=absent, 空集合
#   TC-3  ingest:skip 0 件 → count=0 + 空 marker block + log_read_ok=true
#   TC-4  placeholder residue (--branch-strategy "{...}") → exit 1 + LINT_PHASE_6_0_PLACEHOLDER_RESIDUE marker
#   TC-5  placeholder residue (--wiki-branch "{...}") → exit 1
#   TC-6  unknown branch_strategy → exit 1 (旧 inline block と同文言)
#   TC-7  separate_branch 抽出 (git show)
#   TC-8  separate_branch log.md 不在 blob (legitimate absence) → log_read_ok=absent
#   TC-9  --branch-strategy 欠落 → exit 2 (invocation error)
#   TC-10 separate_branch + 空 --wiki-branch → exit 2 (invocation error)
#   TC-11 値なしフラグ末尾 → no-hang (timeout ガード)
#   TC-D  differential equivalence — 旧 inline block (参照実装) と stdout byte 一致
#
# NOT covered (environment-dependent): mktemp failure on read-only /tmp,
# awk/sort pipeline OOM。いずれも io_error 降格経路で reading により検証済み。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-skipped-refs.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# ingest:skip 2 件 (うち 1 件は .rite/wiki/ prefix 付き) + ingest:done 1 件 +
# 重複 skip 1 件 (sort -u 検証) を含む log.md フィクスチャ。
# table 列構成は templates/wiki/log-template.md の `| 日時 | アクション | 対象 | 詳細 |`
# (awk -F'|' で $3=アクション / $4=対象) に一致させる。
LOG_FIXTURE='# Wiki 活動ログ

| 日時 | アクション | 対象 | 詳細 |
|------|-----------|------|------|
| 2026-04-10T00:00:00Z | ingest:done | raw/reviews/20260410T000000Z.md | 経験則化 |
| 2026-04-11T00:00:00Z | ingest:skip | raw/fixes/20260411T000000Z.md | 価値なし |
| 2026-04-12T00:00:00Z | ingest:skip | .rite/wiki/raw/reviews/20260412T000000Z.md | 重複 |
| 2026-04-13T00:00:00Z | ingest:skip | raw/fixes/20260411T000000Z.md | 重複行 |
'

# same_branch sandbox: log.md を filesystem に置く (git repo は不要だが repo-root 解決のため init)
make_same_branch_sandbox() {
  local name="$1" with_log="$2"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo/.rite/wiki"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  if [ "$with_log" = "1" ]; then
    printf '%s' "$LOG_FIXTURE" > "$repo/.rite/wiki/log.md"
  fi
  echo "$repo"
}

# separate_branch sandbox: wiki ブランチに log.md をコミットする
make_separate_branch_sandbox() {
  local name="$1" with_log="$2"
  local repo="$TEST_DIR/$name"
  git init -q -b main "$repo"
  (
    cd "$repo" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    echo base > base.txt
    git add base.txt && git commit -qm "init"
    git checkout -q --orphan wiki
    git rm -qrf . 2>/dev/null || true
    if [ "$with_log" = "1" ]; then
      mkdir -p .rite/wiki
      printf '%s' "$LOG_FIXTURE" > .rite/wiki/log.md
      git add .rite/wiki/log.md && git commit -qm "wiki log"
    else
      git commit -q --allow-empty -m "empty wiki"
    fi
    git checkout -q main
  )
  echo "$repo"
}

run_helper() {
  local repo="$1"; shift
  local rc=0
  HELPER_STDOUT=$( (cd "$repo" && timeout 10 bash "$SCRIPT" --repo-root "$repo" "$@") 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

# --- 参照実装: 旧 wiki/lint.md ステップ 6.0 inline block の verbatim 再現 ---
# {branch_strategy} / {wiki_branch} は旧 block で LLM が literal substitute していた
# 契約のため、ここでは sed で同じ substitution を行ってから実行する。
REF_TEMPLATE="$TEST_DIR/reference-step60.sh.tmpl"
cat > "$REF_TEMPLATE" <<'REF_EOF'
# signal-specific trap (canonical 4 行パターン)。
# 詳細は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照。
log_err=""
awk_sort_err=""
_cleanup() {
  [ -n "${log_err:-}" ] && rm -f "$log_err"
  [ -n "${awk_sort_err:-}" ] && rm -f "$awk_sort_err"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# skipped_refs 空継続時の「影響」文言 helper (4 site の literal duplicate を集約)
_rite_log_read_impact_advice() {
  echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
}

# stderr 退避失敗 + tool 失敗の複合経路の helper (separate_branch / same_branch で tool 名のみ異なる)
_rite_log_read_sub_path_warning() {
  local tool_desc="$1" remedy_target="$2" rc="$3"
  echo "WARNING: .rite/wiki/log.md の ${tool_desc} に失敗し、かつ stderr 退避も失敗しました (rc=${rc}、原因区別不能のため io_error 扱い)" >&2
  _rite_log_read_impact_advice
  echo "  対処: /tmp の容量 / permission と ${remedy_target} を確認してください" >&2
}

log_err=$(mktemp /tmp/rite-wiki-lint-p60-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (log_err) の mktemp に失敗しました。log.md 読み出しの詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒れ、false positive note が常に表示される regression が起き得ます" >&2
  log_err=""
}

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

skipped_refs=""
log_content=""
log_read_ok="unknown"

# branch_strategy を case で検証 (5 site で同型の fail-fast)
case "$branch_strategy" in
  separate_branch)
    if log_content=$(LC_ALL=C git show "${wiki_branch}:.rite/wiki/log.md" 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  WARNING(git hint): /' >&2
    else
      rc=$?
      if [ -n "$log_err" ] && [ -s "$log_err" ] && \
         grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:\\.rite/wiki/log\\.md'" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の git show に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: wiki branch の integrity / 権限を確認してください" >&2
      else
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "git show" "wiki branch の integrity / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  same_branch)
    if log_content=$(LC_ALL=C cat .rite/wiki/log.md 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  WARNING(cat hint): /' >&2
    else
      rc=$?
      if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "No such file or directory|cannot open" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の cat に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: .rite/wiki/log.md の存在 / 権限を確認してください" >&2
      else
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "cat" ".rite/wiki/log.md の存在 / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 6.0)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# log.md から ingest:skip レコードを抽出 (field 3 厳密一致、field 4 prefix 正規化)
if [ -n "$log_content" ]; then
  set -o pipefail
  awk_sort_err=$(mktemp /tmp/rite-wiki-lint-p60-awk-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: awk/sort stderr 退避 tempfile の mktemp に失敗しました" >&2
    echo "  対処: /tmp の容量 / inode 枯渇 / read-only filesystem / permission を確認してください" >&2
    echo "  影響: pipeline 失敗時の詳細エラー情報 (awk syntax error / sort OOM 等) が失われます" >&2
    awk_sort_err=""
  }
  skipped_refs=$(printf '%s\n' "$log_content" \
    | awk -F'|' 'NF >= 4 {
        action=$3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", action)
        if (action == "ingest:skip") {
          target=$4
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
          sub(/^\.rite\/wiki\//, "", target)
          if (length(target) > 0) print target
        }
      }' 2>"${awk_sort_err:-/dev/null}" \
    | LC_ALL=C sort -u 2>>"${awk_sort_err:-/dev/null}")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: ステップ 6.0 の awk/sort pipeline が失敗しました (rc=$rc)" >&2
    [ -n "$awk_sort_err" ] && [ -s "$awk_sort_err" ] && head -3 "$awk_sort_err" | sed 's/^/  /' >&2
    echo "  対処: awk / sort バイナリと /tmp の容量を確認してください" >&2
    _rite_log_read_impact_advice
    skipped_refs=""
    log_read_ok="io_error"
  fi
  set +o pipefail
fi

# 集合本体を marker block で stdout 出力
if [ -n "$skipped_refs" ]; then
  count=$(printf '%s\n' "$skipped_refs" | awk 'NF>0 {n++} END {print n+0}')
  echo "skipped_refs_count=$count"
  echo "---skipped_refs_begin---"
  printf '%s\n' "$skipped_refs"
  echo "---skipped_refs_end---"
else
  echo "skipped_refs_count=0"
  echo "---skipped_refs_begin---"
  echo "---skipped_refs_end---"
fi

# log_read_ok を stdout 出力 (LLM が ステップ 9.1 完了レポートで参照する契約)
echo "log_read_ok=$log_read_ok"

# 明示的 tempfile rm + 変数 reset (trap と冗長だが defense-in-depth: 後続 block の同名 path re-mktemp 競合防止)
[ -n "$log_err" ] && rm -f "$log_err"; log_err=""
[ -n "$awk_sort_err" ] && rm -f "$awk_sort_err"; awk_sort_err=""
REF_EOF

run_reference() {
  local repo="$1" strategy="$2" wiki="$3"
  local script="$TEST_DIR/ref-rendered.sh"
  # 旧 block の LLM substitution 契約どおり、冒頭の代入行 2 行のみを置換する
  # (本文中の `${wiki_branch}` shell 参照を巻き込まないため行頭アンカーで限定)
  sed -e "s/^branch_strategy=\"{branch_strategy}\"/branch_strategy=\"$strategy\"/" \
      -e "s/^wiki_branch=\"{wiki_branch}\"/wiki_branch=\"$wiki\"/" "$REF_TEMPLATE" > "$script"
  local rc=0
  REF_STDOUT=$( (cd "$repo" && timeout 10 bash "$script") 2>"$TEST_DIR/ref_stderr" ) || rc=$?
  REF_RC=$rc
  REF_STDERR=$(cat "$TEST_DIR/ref_stderr")
  return 0
}

echo "=== wiki-lint-skipped-refs.sh tests ==="
echo ""

# === TC-1: same_branch 抽出 ===
echo "TC-1: same_branch 抽出 (厳密一致 / prefix 正規化 / sort -u)"
repo=$(make_same_branch_sandbox tc1 1)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
expected_block='skipped_refs_count=2
---skipped_refs_begin---
raw/fixes/20260411T000000Z.md
raw/reviews/20260412T000000Z.md
---skipped_refs_end---
log_read_ok=true'
if [ "$HELPER_RC" = "0" ] && [ "$HELPER_STDOUT" = "$expected_block" ]; then
  pass "count=2 / prefix 正規化 / 重複排除 / ingest:done 除外 / read_ok=true"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-2: same_branch log.md 不在 → absent ===
echo "TC-2: same_branch legitimate absence"
repo=$(make_same_branch_sandbox tc2 0)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^log_read_ok=absent$' <<<"$HELPER_STDOUT" && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT"; then
  pass "absent + 空集合 + exit 0"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-3: ingest:skip 0 件 → count=0 + read_ok=true ===
echo "TC-3: ingest:skip 0 件"
repo=$(make_same_branch_sandbox tc3 0)
printf '| 2026-04-10T00:00:00Z | s1 | ingest:done | raw/reviews/a.md |\n' > "$repo/.rite/wiki/log.md"
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT" && grep -q '^log_read_ok=true$' <<<"$HELPER_STDOUT"; then
  pass "count=0 + 空 marker block + read_ok=true"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-4: placeholder residue (branch_strategy) → exit 1 + sentinel ===
echo "TC-4: placeholder residue (branch_strategy)"
repo=$(make_same_branch_sandbox tc4 1)
run_helper "$repo" --branch-strategy "{branch_strategy}" --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && grep -q 'LINT_PHASE_6_0_PLACEHOLDER_RESIDUE=1' <<<"$HELPER_STDERR"; then
  pass "exit 1 + LINT_PHASE_6_0_PLACEHOLDER_RESIDUE sentinel"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-5: placeholder residue (wiki_branch) → exit 1 ===
echo "TC-5: placeholder residue (wiki_branch)"
repo=$(make_same_branch_sandbox tc5 1)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch "{wiki_branch}"
if [ "$HELPER_RC" = "1" ] && grep -q '{wiki_branch} placeholder が literal substitute されていません' <<<"$HELPER_STDERR"; then
  pass "exit 1 + wiki_branch residue error"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-6: unknown branch_strategy → exit 1 (旧 block と同文言) ===
echo "TC-6: unknown branch_strategy"
repo=$(make_same_branch_sandbox tc6 1)
run_helper "$repo" --branch-strategy bogus --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && grep -q "未知の branch_strategy 値を検出しました: 'bogus' (ステップ 6.0)" <<<"$HELPER_STDERR"; then
  pass "exit 1 + 旧 block 同文言"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-7: separate_branch 抽出 (git show) ===
echo "TC-7: separate_branch 抽出"
repo=$(make_separate_branch_sandbox tc7 1)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^skipped_refs_count=2$' <<<"$HELPER_STDOUT" && grep -q '^log_read_ok=true$' <<<"$HELPER_STDOUT"; then
  pass "git show 経由で count=2 + read_ok=true"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-8: separate_branch blob 不在 → absent ===
echo "TC-8: separate_branch legitimate absence"
repo=$(make_separate_branch_sandbox tc8 0)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^log_read_ok=absent$' <<<"$HELPER_STDOUT"; then
  pass "blob 不在 → absent"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT / stderr: $HELPER_STDERR"
fi

# === TC-9: --branch-strategy 欠落 → exit 2 ===
echo "TC-9: --branch-strategy 欠落"
repo=$(make_same_branch_sandbox tc9 1)
run_helper "$repo" --wiki-branch wiki
if [ "$HELPER_RC" = "2" ]; then
  pass "exit 2 (invocation error)"
else
  fail "unexpected rc=$HELPER_RC"
fi

# === TC-10: separate_branch + 空 --wiki-branch → exit 2 ===
echo "TC-10: separate_branch + 空 wiki-branch"
repo=$(make_same_branch_sandbox tc10 1)
run_helper "$repo" --branch-strategy separate_branch
if [ "$HELPER_RC" = "2" ] && grep -q -- '--wiki-branch が必須です' <<<"$HELPER_STDERR"; then
  pass "exit 2 + git index 読取 semantics 回避"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-11: 値なしフラグ末尾 → no-hang ===
echo "TC-11: 値なしフラグ末尾 no-hang"
repo=$(make_same_branch_sandbox tc11 1)
run_helper "$repo" --branch-strategy same_branch --wiki-branch
if [ "$HELPER_RC" != "124" ]; then
  pass "no hang (rc=$HELPER_RC)"
else
  fail "hang detected (timeout)"
fi

# === TC-D: differential equivalence — 旧 inline block と stdout/stderr/rc 一致 ===
echo "TC-D: differential equivalence vs original inline block"
# シナリオ: <label> <sandbox-kind> <with_log> <strategy> <wiki>
run_differential() {
  local label="$1" kind="$2" with_log="$3" strategy="$4" wiki="$5"
  local repo_ref repo_new
  if [ "$kind" = "same" ]; then
    repo_ref=$(make_same_branch_sandbox "ref-$label" "$with_log")
    repo_new=$(make_same_branch_sandbox "new-$label" "$with_log")
  else
    repo_ref=$(make_separate_branch_sandbox "ref-$label" "$with_log")
    repo_new=$(make_separate_branch_sandbox "new-$label" "$with_log")
  fi
  run_reference "$repo_ref" "$strategy" "$wiki"
  run_helper "$repo_new" --branch-strategy "$strategy" --wiki-branch "$wiki"
  if [ "$REF_RC" = "$HELPER_RC" ] && [ "$REF_STDOUT" = "$HELPER_STDOUT" ] && [ "$REF_STDERR" = "$HELPER_STDERR" ]; then
    pass "[$label] rc + stdout + stderr byte-identical (rc=$HELPER_RC)"
  else
    fail "[$label] diverged: ref(rc=$REF_RC) stdout='$REF_STDOUT' stderr='$REF_STDERR' / new(rc=$HELPER_RC) stdout='$HELPER_STDOUT' stderr='$HELPER_STDERR'"
  fi
}

run_differential "same-with-log"     same 1 same_branch wiki
run_differential "same-absent"       same 0 same_branch wiki
run_differential "separate-with-log" sep  1 separate_branch wiki
run_differential "separate-absent"   sep  0 separate_branch wiki
run_differential "unknown-strategy"  same 1 bogus_strategy wiki

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
