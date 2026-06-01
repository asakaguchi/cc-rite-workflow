#!/bin/bash
# settings-local-rite-hook-cleanup.test.sh
#
# Pin the behavioral contract of the settings.local.json rite-hook cleanup helper
# pair (Issue #1230). PR #1229 split the python-inline JSON edit from init.md into
# a `.py` transform + `.sh` wrapper; behavior equivalence was confirmed by hand at
# review time but had no automated guard. These cases lock the four regression
# points that two reviewers (code-quality + error-handling) flagged as revert-weak:
#
#   1. `.py` exit code branches: 0 = removed / 1 = no change / 2 = invalid JSON
#   2. `.py` selective removal of mixed rite/non-rite entries + event-key deletion
#   3. `.sh` token folding: python3 exit 1/2 both collapse to NO_RITE_HOOKS
#   4. `.sh` mv-failure path (guarded mv → NO_RITE_HOOKS), atomic write, trap cleanup
#
# The mv-failure case reuses the PATH-shimmed `mv` technique from the precedent
# test issue-comment-wm-sync.test.sh (a `bin/mv` that exits non-zero, prepended to
# PATH) so only `mv` fails while mktemp/python3/rm resolve normally — proving the
# wrapper's trap removes the temp file and leaves the original untouched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

PY="$PLUGIN_ROOT/hooks/scripts/settings-local-rite-hook-cleanup.py"
SH="$PLUGIN_ROOT/hooks/scripts/settings-local-rite-hook-cleanup.sh"

# Infrastructure preconditions (not test failures — see _test-helpers.sh header).
for tgt in "$PY" "$SH"; do
  if [ ! -f "$tgt" ]; then
    echo "ERROR: target helper not found: $tgt" >&2
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 unavailable — required by the helper under test" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TEST_DIR"' EXIT

# ─── local assertion helpers ────────────────────────────────────────────
# Per-case scratch directory (mktemp runs in a command-substitution subshell,
# so a shared counter would not persist — a unique mktemp template avoids one).
fresh() { mktemp -d "$TEST_DIR/case.XXXXXX"; }

assert_empty_file() {
  local label="$1" file="$2"
  if [ ! -s "$file" ]; then
    pass "$label"
  else
    fail "$label (expected empty stdout, got: $(head -c 120 "$file"))"
  fi
}

assert_valid_json() {
  local label="$1" file="$2"
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (output is not valid JSON)"
  fi
}

# Assert no leftover temp file (settings.local.json.XXXXXX) remains beside the
# target — proves the wrapper's `trap 'rm -f "$tmp"'` fired on every exit path.
assert_no_leftover_tmp() {
  local label="$1" settings="$2"
  local dir base matches
  dir="$(dirname "$settings")"
  base="$(basename "$settings")"
  matches=$(find "$dir" -maxdepth 1 -name "$base.*" 2>/dev/null)
  if [ -z "$matches" ]; then
    pass "$label"
  else
    fail "$label (leftover tmp: $matches)"
  fi
}

assert_unchanged() {
  local label="$1" file="$2" ref="$3"
  if cmp -s "$file" "$ref"; then
    pass "$label"
  else
    fail "$label (file was modified)"
  fi
}

# ─── .py exit code branches (P-1〜P-4) ───────────────────────────────────
echo "=== .py exit code 分岐 (P-1〜P-4) ==="

# P-1: a rite hook present → removed → exit 0, cleaned JSON on stdout.
out="$(fresh)/out.json"
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /opt/rite/hooks/session-start.sh"}]}]}}' \
  | python3 "$PY" > "$out" 2>/dev/null
rc=$?
assert "P-1: rite hook 削除 → exit 0" "0" "$rc"
assert_valid_json "P-1: cleaned JSON が stdout に出力される" "$out"

# P-2: no `hooks` section → no change → exit 1, nothing written.
out="$(fresh)/out.json"
printf '%s' '{"permissions":{"allow":[]}}' | python3 "$PY" > "$out" 2>/dev/null
rc=$?
assert "P-2: hooks セクションなし → exit 1" "1" "$rc"
assert_empty_file "P-2: stdout 空 (書き換えなし)" "$out"

# P-3: hooks present but no rite entries → no change → exit 1, nothing written.
out="$(fresh)/out.json"
printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/usr/local/bin/lint.sh"}]}]}}' \
  | python3 "$PY" > "$out" 2>/dev/null
rc=$?
assert "P-3: rite hook なし (変更なし) → exit 1" "1" "$rc"
assert_empty_file "P-3: stdout 空" "$out"

# P-4: stdin is not valid JSON → exit 2, nothing written.
out="$(fresh)/out.json"
printf '%s' '{not valid json,,,' | python3 "$PY" > "$out" 2>/dev/null
rc=$?
assert "P-4: 不正 JSON → exit 2" "2" "$rc"
assert_empty_file "P-4: stdout 空" "$out"

# ─── .py selective removal + event-key deletion (P-5 / P-6) ──────────────
echo ""
echo "=== .py 選択的除去 / event key 削除 (P-5 / P-6) ==="

# One fixture exercises both: PreToolUse mixes a rite entry with a non-rite entry
# (selective removal, key retained); SessionStart holds only a rite entry (whole
# event key dropped).
out="$(fresh)/out.json"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rite/hooks/pre-tool-bash-guard.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"/usr/bin/custom-guard.sh"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"bash plugins/rite/hooks/session-start.sh"}]}]}}' \
  | python3 "$PY" > "$out" 2>/dev/null
rc=$?
assert "P-5/6: 混在入力 → exit 0" "0" "$rc"
assert_valid_json "P-5/6: cleaned JSON valid" "$out"
assert_grep     "P-5: 非 rite entry (custom-guard) は保持" "$out" 'custom-guard'
assert_not_grep "P-5: rite entry (pre-tool-bash-guard) は除去" "$out" 'pre-tool-bash-guard'
assert_grep     "P-5: 混在 event key (PreToolUse) は残存" "$out" 'PreToolUse'
assert_not_grep "P-6: 全 rite event key (SessionStart) は削除" "$out" 'SessionStart'

# ─── .sh token folding + atomic write (S-1〜S-3) ─────────────────────────
echo ""
echo "=== .sh token 畳み込み / atomic write (S-1〜S-3) ==="

# S-1: happy path → CLEANED, file rewritten atomically, no leftover tmp.
d="$(fresh)"; f="$d/settings.local.json"
printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash /opt/rite/hooks/pre-tool-bash-guard.sh"}]},{"hooks":[{"type":"command","command":"/usr/bin/keepme.sh"}]}]}}' > "$f"
out=$(bash "$SH" "$f" 2>/dev/null); rc=$?
assert "S-1: happy path token = CLEANED" "CLEANED" "$out"
assert "S-1: exit 0" "0" "$rc"
assert_valid_json "S-1: 書き換え後ファイルは valid JSON" "$f"
assert_grep     "S-1: 非 rite hook 保持 (atomic write 完了)" "$f" 'keepme'
assert_not_grep "S-1: rite hook 除去" "$f" 'pre-tool-bash-guard'
assert_no_leftover_tmp "S-1: 残留 tmp なし" "$f"

# S-2: python3 exit 1 (no rite hooks) → NO_RITE_HOOKS, file byte-identical.
d="$(fresh)"; f="$d/settings.local.json"
printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/usr/local/bin/lint.sh"}]}]}}' > "$f"
cp "$f" "$d/ref"
out=$(bash "$SH" "$f" 2>/dev/null); rc=$?
assert "S-2: py exit 1 → NO_RITE_HOOKS" "NO_RITE_HOOKS" "$out"
assert "S-2: exit 0" "0" "$rc"
assert_unchanged "S-2: ファイル byte 不変" "$f" "$d/ref"
assert_no_leftover_tmp "S-2: 残留 tmp なし" "$f"

# S-3: python3 exit 2 (invalid JSON) → NO_RITE_HOOKS, file byte-identical.
d="$(fresh)"; f="$d/settings.local.json"
printf '%s' '{not valid json,,,' > "$f"
cp "$f" "$d/ref"
out=$(bash "$SH" "$f" 2>/dev/null); rc=$?
assert "S-3: py exit 2 (不正 JSON) → NO_RITE_HOOKS" "NO_RITE_HOOKS" "$out"
assert "S-3: exit 0" "0" "$rc"
assert_unchanged "S-3: ファイル byte 不変" "$f" "$d/ref"
assert_no_leftover_tmp "S-3: 残留 tmp なし" "$f"

# ─── .sh missing/absent file argument (S-4) ──────────────────────────────
echo ""
echo "=== .sh 引数欠落 / 不在ファイル (S-4) ==="

# S-4a: no argument → NO_RITE_HOOKS, exit 0.
out=$(bash "$SH" 2>/dev/null); rc=$?
assert "S-4a: 引数なし → NO_RITE_HOOKS" "NO_RITE_HOOKS" "$out"
assert "S-4a: exit 0" "0" "$rc"

# S-4b: nonexistent path → NO_RITE_HOOKS, exit 0.
d="$(fresh)"
out=$(bash "$SH" "$d/nope.json" 2>/dev/null); rc=$?
assert "S-4b: 不在ファイル → NO_RITE_HOOKS" "NO_RITE_HOOKS" "$out"
assert "S-4b: exit 0" "0" "$rc"

# ─── .sh mv failure path + trap cleanup (S-5) ────────────────────────────
echo ""
echo "=== .sh mv 失敗経路 (trap cleanup) (S-5) ==="

# A rite hook is present so python3 succeeds and the wrapper reaches the guarded
# `mv`. The PATH-shimmed mv fails (exit 1); only mv is shadowed, so mktemp/python3/
# rm still work — the wrapper folds to NO_RITE_HOOKS, the original survives, and
# trap removes the temp file.
d="$(fresh)"; f="$d/settings.local.json"
mkdir -p "$d/bin"
cat > "$d/bin/mv" <<'MV_SHIM'
#!/bin/bash
exit 1
MV_SHIM
chmod +x "$d/bin/mv"
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /opt/rite/hooks/session-start.sh"}]}]}}' > "$f"
cp "$f" "$d/ref"
out=$(PATH="$d/bin:$PATH" bash "$SH" "$f" 2>/dev/null); rc=$?
assert "S-5: mv 失敗 → NO_RITE_HOOKS (検査付き mv)" "NO_RITE_HOOKS" "$out"
assert "S-5: exit 0" "0" "$rc"
assert_unchanged "S-5: 原ファイル保持 (mv 失敗で未置換)" "$f" "$d/ref"
assert_no_leftover_tmp "S-5: trap cleanup で残留 tmp なし" "$f"

echo ""
if ! print_summary "$(basename "$0")" \
  "drift: settings-local-rite-hook-cleanup helper (#1230) の挙動契約が後退した可能性。.py の exit code (0=削除 / 1=変更なし / 2=不正JSON)、混在時の選択的除去・全 rite event の key 削除、.sh の token 畳み込み (py exit 1/2 → NO_RITE_HOOKS)・検査付き mv 失敗経路・atomic write・trap cleanup を確認。"; then
  exit 1
fi
