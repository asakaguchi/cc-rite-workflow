#!/bin/bash
# error-count-runtime-reference.test.sh
#
# Pins the dead-code claim that `--preserve-error-count` was removed from
# `create-interview.md` because no runtime hook reads `.error_count` outside
# of `flow-state-update.sh` / `migrate-flow-state.sh` themselves (stop-guard.sh
# was retired in #675).
#
# Why this test exists:
#   `commands/issue/create-interview.md` の ADR §3.1 rationale で
#   `--preserve-error-count` 撤去の根拠を「production runtime に error_count
#   reader が存在しない (grep 結果 0 件)」としている。これは documentation
#   comment のみで保護されていないため、将来 `error_count` reader が再導入
#   された場合に同 phase self-patch (Pre-flight + Return Output) で `error_count`
#   が 0 にリセットされ silent な runtime gate defeat を引き起こす可能性が
#   ある。本 test で「reader 不在」の invariant を機械的に保護する。
#
# Scope:
#   - 検証対象 directory: `plugins/rite/hooks/`
#   - reader 判定: `.error_count` (jq field access **literal**) または `error_count`
#     (bash var / arg、`$error_count` / `${error_count}` 等の **string literal**) の
#     **読取** 出現。helper 自身 (`flow-state-update.sh` / `migrate-flow-state.sh`) と
#     本 test 自身は除外。
#   - **検出 limitation** (I-14 PR #926 verified-review): 本 test は string-based field
#     access (literal) のみを捕捉する。variable indirection (`local field="error_count";
#     jq ".$field"` / `eval "x=\$$varname"` 等) は対象外。現状の hooks/ にそのような
#     indirection は存在しないため実用的な制約だが、将来 indirection 経由の reader が
#     再導入された場合は本 test では catch できない。Scope 拡張時は本注記も更新すること。
#
# When this test fails:
#   いずれかの hook が `error_count` を runtime 参照するようになった。
#   `--preserve-error-count` の semantics が再び load-bearing になるため、
#   (a) `create-interview.md` の同 phase self-patch を `--preserve-error-count`
#   付きに戻す、または (b) 新規 reader 側で対応する設計を選ぶ必要がある。
#
# Reference:
#   - ADR `docs/designs/parent-routing-unification.md` §3.1
#   - `commands/issue/create-interview.md` Defense-in-Depth section の
#     `--preserve-error-count` 撤去 rationale

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

HOOKS_DIR="$REPO_ROOT/plugins/rite/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "  ❌ HOOKS DIR NOT FOUND: $HOOKS_DIR" >&2
  exit 1
fi

echo "=== TC-1: error_count runtime reader 不在の invariant ==="

# Allowlist (本テスト自身および error_count を保持・migrate する責務を持つ helper):
#   - flow-state-update.sh: error_count を保持する helper 自身 (writer / preserve 判定)
#   - migrate-flow-state.sh: legacy schema → 新 schema migration の filter
ALLOWLIST_REGEX='/(flow-state-update|migrate-flow-state)\.sh$'

# 検索範囲: hooks/ 配下の .sh ファイル (本 test 自身 = tests/ 配下は除外)
# 検索 pattern: `.error_count` (jq の field access) または bash variable
# としての `error_count` (`$error_count` / `${error_count}` / `error_count=`
# 等は除外し、明示的 reader を捕捉する想定)。
#
# 実装方針: 「`.error_count` 出現」と「`\$error_count` / `\${error_count` 出現」
# を別々に grep し、allowlist にマッチするファイルを除外する。
violations=""

# 検索範囲は production runtime scope のみ:
#   - tests/ 配下は test ファイルであり production runtime path ではないため除外
#   - flow-state-update.sh (hooks/) / migrate-flow-state.sh (hooks/scripts/) は
#     ALLOWLIST_REGEX で除外 (helper 自身)

# M-5 対応 (PR #926 verified-review): grep stderr を tempfile に退避して silent IO エラーを検出。
# 旧 `2>/dev/null` は grep -RIl が permission denied / broken symlink / IO error で読めないパスを
# silent skip させ、load-bearing test invariant (dead-code claim) の保護を silent に失う経路があった。
# stderr が空でなければ test を fail させて未保護領域を可視化する。
#
# 注: `set -euo pipefail` 下で grep rc=1 (no match) が script 早期 exit を引き起こすため、
# `set +e` で一時的に disable して exit code を取得する。grep rc=2 (IO error) は stderr 非空判定で
# 検出する (rc 1/2 を直接区別する必要がないため `|| true` ではなく明示的 set +e/set -e 形式)。
#
# I-2 PR #926 verified-review: mktemp 失敗時に fail-fast (旧 `|| _grep_err=""` 経路は
# silent `/dev/null` fallback で dead-code claim 保護の load-bearing 検出能力を完全無効化していた)。
# verify-terminal-output.sh:120-124 の H-1 canonical pattern と対称化。
if ! _grep_err=$(mktemp /tmp/rite-error-count-grep-err-XXXXXX); then
  echo "ERROR: mktemp failed for grep stderr capture — test invariant (silent IO error detection) is disabled" >&2
  echo "  hint: /tmp の inode 枯渇 / read-only filesystem / permission 拒否を確認してください" >&2
  exit 1
fi

# jq field access ('.error_count') の探索
set +e
if [ -n "$_grep_err" ]; then
  jq_field_hits=$(grep -RIlE '\.error_count' "$HOOKS_DIR" --include='*.sh' --exclude-dir='tests' 2>"$_grep_err")
else
  jq_field_hits=$(grep -RIlE '\.error_count' "$HOOKS_DIR" --include='*.sh' --exclude-dir='tests' 2>/dev/null)
fi
set -e
if [ -n "$_grep_err" ] && [ -s "$_grep_err" ]; then
  fail "TC-1: grep over $HOOKS_DIR emitted stderr (test cannot guarantee jq_field coverage — silent IO error)"
  head -5 "$_grep_err" | sed 's/^/  /' >&2
fi
if [ -n "$jq_field_hits" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if printf '%s\n' "$f" | grep -qE "$ALLOWLIST_REGEX"; then
      continue
    fi
    violations+="$f"$'\n'
  done <<< "$jq_field_hits"
fi

# bash variable expansion ('$error_count' / '${error_count') の探索
[ -n "$_grep_err" ] && : > "$_grep_err"  # truncate before reuse
set +e
if [ -n "$_grep_err" ]; then
  bash_var_hits=$(grep -RIlE '\$\{?error_count\b' "$HOOKS_DIR" --include='*.sh' --exclude-dir='tests' 2>"$_grep_err")
else
  bash_var_hits=$(grep -RIlE '\$\{?error_count\b' "$HOOKS_DIR" --include='*.sh' --exclude-dir='tests' 2>/dev/null)
fi
set -e
if [ -n "$_grep_err" ] && [ -s "$_grep_err" ]; then
  fail "TC-1: grep over $HOOKS_DIR emitted stderr (test cannot guarantee bash_var coverage — silent IO error)"
  head -5 "$_grep_err" | sed 's/^/  /' >&2
fi
if [ -n "$bash_var_hits" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if printf '%s\n' "$f" | grep -qE "$ALLOWLIST_REGEX"; then
      continue
    fi
    violations+="$f"$'\n'
  done <<< "$bash_var_hits"
fi
[ -n "$_grep_err" ] && rm -f "$_grep_err"

# 重複除去
violations=$(printf '%s' "$violations" | sort -u | sed '/^$/d')

if [ -z "$violations" ]; then
  pass "TC-1: hooks/ 配下 (helper 自身を除く) に error_count の runtime reader が存在しない"
else
  fail "TC-1: hooks/ 配下に error_count の runtime reader が検出されました — '--preserve-error-count' の dead-code claim が破られています"
  echo "  Detected files:" >&2
  printf '%s\n' "$violations" | sed 's/^/    - /' >&2
  echo "  対処: create-interview.md ADR §3.1 rationale の前提が崩れています。" >&2
  echo "    (a) 当該 site の同 phase self-patch を '--preserve-error-count' 付きに戻す、または" >&2
  echo "    (b) 新規 reader 側で error_count semantics を保護する設計を導入してください。" >&2
fi

DRIFT_HINT="\
error_count runtime reader invariant が崩れています。
本 test は create-interview.md ADR §3.1 で撤去された '--preserve-error-count' の
dead-code claim を機械的に保護します。Reader 再導入時は ADR rationale を更新する
必要があります。"

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: error_count is not referenced at runtime outside of flow-state-update.sh / migrate-flow-state.sh"
exit 0
