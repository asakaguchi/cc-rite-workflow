#!/bin/bash
# rite workflow - Pre-Tool Bash Guard (PreToolUse hook)
# Blocks known-bad Bash command patterns before execution.
# Uses only Bash built-ins for pattern matching (no external processes).
#
# Denylist patterns:
#   1. gh pr diff --stat  (unsupported flag)
#   2. gh pr diff -- <path>  (unsupported file filter)
#   3. != null in jq/awk  (history expansion breaks !)
#   4. Reviewer subagent running state-mutating git commands
#      Enforced only when transcript_path contains "/subagents/".
#
# Exit behavior:
#   exit 0 — allow (no output)
#   stdout JSON with permissionDecision: "deny" — block
#
# Fail direction is pattern-specific: Patterns 1-3 (convenience) fail OPEN so an
# edge-case parse crash never false-blocks a legitimate command; Pattern 4 (the
# reviewer state-mutating-git security boundary) fails CLOSED so a parse crash
# never silently bypasses the guard. See the two ERR traps below.
#
# hooks.json timeout: this hook is registered in hooks.json (PreToolUse:Bash) with
# a 10s timeout. hooks.json is strict JSON (no comments), so the rationale lives
# here: the guard is a fast, synchronous pre-execution gate that runs on every
# Bash command using only bash built-ins plus a couple of jq calls, so 10s is a
# generous ceiling that bounds a pathological hang without risking false timeouts —
# aligned with the other lightweight synchronous gates (Stop=10s, the Edit/Write
# bang-backtick hook=10s).
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRETOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# neutralize_ctrl --c0-only (deny フォールバックの JSON エスケープ用)。
# guard なし source は意図的な設計判断: 本 hook は Pattern 1-3 の ERR trap
# (_rite_btg_pattern13_fail_open) が exit 0 = allow を選ぶ設計上 fail-open であり、helper
# 欠落 (= plugin 破損) による source 失敗の exit 1 も PreToolUse では non-blocking = allow
# として同じ fail-open に収束する (flow-state.sh / stop-loop-continuation.sh の必須依存
# precedent と同一)。`|| true` を付けてはならない — neutralize_ctrl 未定義のまま deny
# フォールバックに到達すると command not found で reason を失い placeholder へ縮退する
# だけで、guard を付ける利点がない。
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Deny フォールバック JSON 用の reason エスケープ。適用順序が契約:
# backslash → double-quote → 改行 \n 化 → neutralize_ctrl --c0-only (残存 C0+DEL を ? 化)。
# backslash エスケープが先頭でないと、後続が生成する \" / \n の backslash を二重に
# エスケープしてしまう。--c0-only なのは byte 単位の C1 置換が UTF-8 マルチバイト本文を
# 破壊するため (RFC 8259 が生バイトを禁じるのは U+0000-001F のみ)。neutralize_ctrl 失敗時は
# 非ゼロ exit し、caller が static placeholder へ縮退する (fail-closed)。
# tests/pre-tool-bash-guard.test.sh の TC-117 が本関数定義を境界行
# (`_bash_guard_escape_deny_reason() {` / `}`) で抽出して改行 / raw C0 実入力の変換を
# 直接 pin する — シグネチャ・境界行を変える際はテスト側の抽出パターンも更新すること。
_bash_guard_escape_deny_reason() {
  local _r="$1"
  _r="${_r//\\/\\\\}"
  _r="${_r//\"/\\\"}"
  _r="${_r//$'\n'/\\n}"
  printf '%s' "$_r" | neutralize_ctrl --c0-only
}
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Only inspect Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Reviewer subagent detection.
# Claude Code routes subagent sessions to jsonl files under a "subagents/"
# directory inside the project transcript root; the main session does not.
# When the PreToolUse hook runs inside a subagent, transcript_path therefore
# contains the "/subagents/" path component. Pattern 4 below uses this as a
# heuristic to scope state-mutating git denylist checks to reviewer contexts.
#
# Three-tier detection (future-proofing against SDK convention drift):
#   Tier 1 (primary):  transcript_path glob `*/subagents/*` — current Claude Code
#                      convention. Most reliable signal today.
#   Tier 2 (fallback): hook input JSON `subagent_type` / `agent_type` field —
#                      reserved for future SDK schemas that surface subagent
#                      identity in the hook envelope rather than the path.
#                      Presence-only check on STRING values; numeric/array/object
#                      values are rejected via `| strings` filter to avoid jq's
#                      `//` operator treating only null/false as falsy.
#   Tier 3 (fallback): environment variables CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE —
#                      catch-all if a future SDK exposes subagent context via
#                      env vars before updating the hook input schema. Presence-only.
#
# Forward-compatibility caveat: presence-only check fires on any non-empty string.
# If a future SDK starts emitting `subagent_type: "main"` / `"none"` / `"null"`
# sentinel values on main-session hooks, every main-session git command in this
# block would be blocked (false positive). When such a convention appears,
# upgrade to an allow-list check (e.g. `*-reviewer` glob) here. Tier 3 env vars
# share the same risk — see BLOCKED_ALTERNATIVE recovery text for `unset` guidance.
#
# All three field extractions share a single jq invocation; the original
# three-jq layout would triple subprocess fork overhead on the PreToolUse hot path.
# jq 失敗時の空 fallback は subagent 判定経路を silent に外す危険があるため、stderr を
# tempfile capture し、RITE_DEBUG 設定時は失敗詳細を debug log へ追記する。security 防御層
# (subagent 限定の Tier 3 ガード等) が silent bypass される経路を観測できるようにする。
_jq_input_err=$(mktemp 2>/dev/null) || _jq_input_err=""
JQ_OUT=$(echo "$INPUT" | jq -r '[(.transcript_path // ""), (.subagent_type | strings // ""), (.agent_type | strings // "")] | @tsv' 2>"${_jq_input_err:-/dev/null}") || JQ_OUT=$'\t\t'
if [ -n "${RITE_DEBUG:-}" ] && [ -n "$_jq_input_err" ] && [ -s "$_jq_input_err" ]; then
  printf '[%s] pre-tool-bash-guard: jq input parse stderr: %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(head -c 200 "$_jq_input_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)" \
    >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
fi
[ -n "$_jq_input_err" ] && rm -f "$_jq_input_err"
TRANSCRIPT_PATH=$(printf '%s' "$JQ_OUT" | cut -f1)
INPUT_SUBAGENT_TYPE=$(printf '%s' "$JQ_OUT" | cut -f2)
INPUT_AGENT_TYPE=$(printf '%s' "$JQ_OUT" | cut -f3)
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac
if [ "$IS_SUBAGENT" = "0" ]; then
  if [ -n "$INPUT_SUBAGENT_TYPE" ] || [ -n "$INPUT_AGENT_TYPE" ]; then
    IS_SUBAGENT=1
  fi
fi
if [ "$IS_SUBAGENT" = "0" ]; then
  if [ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    IS_SUBAGENT=1
  fi
fi

# Fail-open ERR trap for Patterns 1-3: if heredoc extraction or simple pattern
# matching crashes on edge-case input, allow the command rather than blocking it.
_rite_btg_pattern13_fail_open() {
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-bash-guard: Pattern 1-3 ERR trap fired — command allowed via fail-open\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  exit 0
}
# Fail-closed ERR trap for Pattern 4 (the reviewer state-mutating-git security
# boundary): if normalization / token-loop evaluation crashes on edge-case input,
# DENY the command (deny JSON + exit 2 + stderr WARNING) instead of allowing it.
# This is the OPPOSITE failure direction from the fail-open trap above: convenience
# patterns must not false-block, but the security pattern must not false-allow — a
# single parse crash must never silently bypass the reviewer read-only guard. This
# trap is installed only for the Pattern 4 block (swapped in at block entry,
# restored to the fail-open trap at block exit), so non-reviewer sessions — which
# never enter that block — are never denied by it.
_rite_btg_pattern4_fail_closed() {
  local _rc=$?
  trap - ERR  # prevent re-entrancy while emitting the deny
  # Visibility: record that the security boundary crashed and we fell closed.
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] pre-tool-bash-guard: WARNING Pattern 4 (reviewer git guard) crashed (rc=$_rc) — command DENIED via fail-closed" >&2
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-bash-guard: Pattern 4 ERR trap fired (rc=%s) — deny fail-closed\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$_rc" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  local _reason="BLOCKED (reviewer-state-mutating-git): Pattern 4 security-boundary evaluation crashed; denying fail-closed to avoid bypassing the reviewer read-only guard. See the bash-guard stderr WARNING for the crash context."
  # Mirror the result-section emit contract: jq for the payload, printf fallback
  # via _bash_guard_escape_deny_reason so a jq failure still emits a valid deny.
  if ! jq -n --arg reason "$_reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }' 2>/dev/null; then
    local _escaped
    _escaped=$(_bash_guard_escape_deny_reason "$_reason" 2>/dev/null) \
      || _escaped="BLOCKED: reviewer git command denied (Pattern 4 crash, fail-closed)."
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$_escaped"
  fi
  exit 2
}
trap '_rite_btg_pattern13_fail_open' ERR

# --- Denylist check (Bash built-ins only) ---

BLOCKED_PATTERN=""
BLOCKED_REASON=""
BLOCKED_ALTERNATIVE=""
# Sub-kind tag for the deny message. Stays empty for git-verb blocks (A)-(G);
# the (Z) shell-wrapper sub-block sets it to "shell-wrapper" so the final deny
# message can explain why a read-only wrapper probe is blocked.
BLOCKED_SUBKIND=""

# --- Reviewer command length guard (O(1), primary fail-closed bound) ---
# Runs BEFORE the heredoc strip and every pattern check because that downstream work
# is whole-string and at least two operations degrade to catastrophically slow on a
# large enough input: the `${COMMAND%%<<*}` heredoc strip below is O(n²) in bash
# (empirically ~45s on ~1.3MB), and Pattern 2's `[[ =~ ]]` regex is O(n²) on a few MB
# of meta chars (empirically >2min). A timed-out PreToolUse hook fails OPEN (Claude
# Code cancels it and lets the tool run), so a reviewer subagent could pad a
# state-mutating git — with huge flag VALUES, thousands of flags, or a giant meta-char
# string — until one of those operations times out, dropping the deny and bypassing
# the guard. The ERR trap cannot catch a timeout (the process is killed externally). A
# legitimate reviewer git command is at most a few KB, so any oversized command is
# denied fail-closed here, before ANY O(n) work: setting BLOCKED_PATTERN both skips the
# O(n²) heredoc strip (below) and short-circuits Patterns 1-4 (all now guarded by
# `[ -z "$BLOCKED_PATTERN" ]`). Guards on the RAW ${#COMMAND} (fast, O(1)-ish) so the
# check itself never triggers the slow path. Scoped to reviewer subagents
# (IS_SUBAGENT=1), so normal main-session Bash is never blocked by size (MUST NOT — the
# pre-existing main-session slowdown on huge input is a separate, out-of-scope
# convenience-pattern concern). The per-flag iteration cap inside the Pattern 4 block
# is a secondary bound on fork COUNT for sub-ceiling commands padded with many flags.
_RITE_BTG_MAX_SUBAGENT_CMD_BYTES=65536
if [ "$IS_SUBAGENT" = "1" ] && [ "${#COMMAND}" -gt "$_RITE_BTG_MAX_SUBAGENT_CMD_BYTES" ]; then
  BLOCKED_PATTERN="reviewer-state-mutating-git"
  # This path builds its own reason/alternative below and never reaches the Pattern 4
  # block's message section (that block is skipped because BLOCKED_PATTERN is now set),
  # so BLOCKED_SUBKIND is intentionally left unset here — it would be an inert write.
  BLOCKED_REASON="This reviewer command is abnormally large (${#COMMAND} bytes, ceiling ${_RITE_BTG_MAX_SUBAGENT_CMD_BYTES}). A command this size could make the guard's parsing exceed the PreToolUse hook timeout, and a timed-out hook fails OPEN (the command would be allowed) — so oversized reviewer commands are denied fail-closed to prevent a timeout-based bypass of the reviewer read-only guard."
  BLOCKED_ALTERNATIVE="Simplify the command — reviewer git operations are at most a few KB. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the read-only command set."
fi

# --- Heredoc-safe command extraction ---
# Strip heredoc content to avoid false positives on text inside commit messages,
# PR descriptions, etc. Only check the command prefix before the first heredoc marker.
# Known limitation: Piped heredoc patterns (e.g., `cat <<EOF | gh pr diff`) bypass
# this stripping because the command before `<<` is `cat`, not the target pattern.
# Risk is limited since such patterns are rare in practice.
# Skipped for an already-denied (oversized) command: `${COMMAND%%<<*}` is O(n²) on
# huge input and would itself time out the fail-open hook (the whole reason the length
# guard runs first). CMD_CHECK is unused in that case (the command is already denied).
if [ -z "$BLOCKED_PATTERN" ]; then
  CMD_CHECK="${COMMAND%%<<*}"
else
  CMD_CHECK=""
fi

# Pattern 1: gh pr diff --stat
# Guarded by `[ -z "$BLOCKED_PATTERN" ]` so the length guard above short-circuits it
# (the `*A*B*` glob would otherwise run over an oversized string). Normally
# BLOCKED_PATTERN is empty here, so this runs exactly as before.
if [ -z "$BLOCKED_PATTERN" ]; then
  case "$CMD_CHECK" in
    *"gh pr diff"*" --stat"*)
      BLOCKED_PATTERN="gh-pr-diff-stat"
      BLOCKED_REASON="gh pr diff does not support the --stat flag."
      BLOCKED_ALTERNATIVE="Use: gh pr view {pr_number} --json files --jq '.files[] | {path, additions, deletions}'"
      ;;
  esac
fi

# Pattern 2: gh pr diff -- <path> (file filter)
# `[^|]*` (zero-or-more) covers both forms: `gh pr diff 123 -- file` and
# `gh pr diff -- file` (when invoked from a PR branch with no positional arg).
# An earlier `[^|]+` (one-or-more) silently missed the bare form.
if [ -z "$BLOCKED_PATTERN" ]; then
  if [[ "$CMD_CHECK" =~ gh[[:space:]]+pr[[:space:]]+diff[[:space:]]+[^|]*[[:space:]]?--[[:space:]] ]]; then
    BLOCKED_PATTERN="gh-pr-diff-file-filter"
    BLOCKED_REASON="gh pr diff does not support -- <path> for per-file filtering."
    BLOCKED_ALTERNATIVE="Use: gh pr diff {pr_number} | awk '/^diff --git/ { found=0 } /^diff --git.*target_pattern/ { found=1 } found { print }'"
  fi
fi

# Pattern 3: != null in jq expressions (history expansion breaks !)
if [ -z "$BLOCKED_PATTERN" ]; then
  case "$CMD_CHECK" in
    *'!= null'*|*'!=null'*)
      BLOCKED_PATTERN="jq-not-equal-null"
      BLOCKED_REASON="!= null causes bash history expansion errors. The ! character is interpreted by bash before reaching jq."
      BLOCKED_ALTERNATIVE="Use: select(.field) for truthiness check, or select(.field == null | not) for explicit null exclusion"
      ;;
  esac
fi

# Pattern 4: Reviewer subagent running state-mutating git commands.
# Scope: only when IS_SUBAGENT=1 (transcript_path contains "/subagents/").
# Main-session git operations (branch switch, commit, etc. performed by
# /rite:open → implement.md Phase 5.1) are NOT affected because IS_SUBAGENT=0 there.
#
# Allowed read-only git commands (NOT matched below):
#   - git diff / git log / git show / git blame / git status / git ls-files /
#     git ls-remote / git rev-parse / git cat-file
#   - git worktree add / git worktree list
#   - git fetch (bare — must NOT include --prune or --force)
#   - git branch with display-only flags: --list / --show-current / -a / -r / -v
#   - git tag -l / git tag --list
#   - git stash list / git stash show
#   - git reflog (bare list, no expire/delete)
#
# Denylist design:
#   (1) Shell meta-character boundary recognition: `;`, `&`, `|`, `(`, backtick,
#       `$` are also treated as word boundaries — prevents bypass via
#       `true;git reset` / `$(git commit)` / `(git checkout ...)` forms.
#   (2) Sub-action precision: `git tag -l` / `git stash list` / `git reflog` (bare)
#       / `git worktree list` must stay allowed. The denylist targets only
#       state-mutating sub-actions of these verbs.
#   (3) Bare new-branch creation: `git branch <name>` (without any flag) creates
#       a new ref and is therefore blocked. `git branch` and `git branch -a`
#       (display) remain allowed.
#   (4) Long-form flag coverage: `git branch --delete/--force/--move/--copy`
#       are treated the same as the short forms `-d/-f/-m/-c/-C`.
if [ -z "$BLOCKED_PATTERN" ] && [ "$IS_SUBAGENT" = "1" ]; then
  # Pattern 4 is the security boundary: swap the Patterns 1-3 fail-OPEN trap for a
  # fail-CLOSED one so an unexpected crash while evaluating a reviewer's git command
  # denies rather than allows. Restored to the fail-open trap at block exit (below)
  # so the shared result-emit section keeps its original fail-open behavior.
  trap '_rite_btg_pattern4_fail_closed' ERR
  # Test-only fault injection for the fail-CLOSED region (no effect in production):
  # Pattern 4 uses only bash built-ins, so — unlike the deny-emit path (see test
  # TC-118) — it cannot be crashed by faking an external binary. This lets the
  # fail-closed regression test raise an ERR deterministically inside the guarded
  # region. Gated on an env var that is never set outside the test suite.
  # Deliberately fail-CLOSED-only: if the env var is ever set in production, the
  # only effect is a DENY (the guard becomes more restrictive) — it can never turn
  # the guard into allow-all. A symmetric fail-OPEN injection was intentionally NOT
  # added, because an env-triggered fail-open path would be an allow-all backdoor to
  # a security boundary. AC-3 (Patterns 1-3 stay fail-open) is instead pinned
  # structurally by the test (default trap is fail-open + restored at block exit).
  if [ "${RITE_BTG_TEST_CRASH:-}" = "pattern4" ]; then
    false
  fi
  # Secondary bound: cap the global-flag normalization iterations (see the loops
  # below). The PRIMARY bound is the length guard above, which denies any command
  # large enough to time out before it is normalized; this cap additionally bounds
  # the fork COUNT for sub-ceiling commands padded with many small global flags (so
  # the per-flag regex+fork loop can't run thousands of times within the byte
  # ceiling). A legitimate reviewer git command has well under this many global
  # flags, so 128 (>10x the realistic maximum) denies such padding while never
  # tripping on a real command. Bounded together with the length guard, the total
  # normalization work is at most ~128 iterations over a <64KB string.
  _RITE_BTG_MAX_GLOBAL_FLAG_NORM=128
  # Normalize whitespace AND shell meta-characters into a single space so that
  # `;git reset` / `(git checkout ...)` / `$(git commit)` / multi-line commands
  # are recognized as `git <verb>` with proper word boundaries.
  CMD_NORMALIZED="${CMD_CHECK//$'\t'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\n'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\r'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//;/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//&/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//|/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//(/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//)/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\{/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\}/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\`/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\$/ }"
  # Snapshot for sub-block (H) .git-write detection, taken HERE — after meta-char collapse but
  # BEFORE the `/git`→` git` path-corrupting substitution below (Issue #1864 fix). The `/git`
  # munge (next block) exists to normalize git INVOCATION forms (`/usr/bin/git`, `\git`) for the
  # (A)-(G) verb globs, but it also splits any redirect-target path whose ancestor contains a
  # literal `/git` segment — `> /srv/git/repo/.git/config` becomes `> /srv git/repo/.git/config`,
  # detaching `>` from the `.git` token so (H)'s adjacency test misses (silent allow of an RCE
  # write). (H) needs the path INTACT, so it tokenizes from this pre-munge snapshot instead of the
  # verb-normalized CMD_NORMALIZED. (`set -u` safety at the (H) use site is via `${_gd_src:-}`.)
  _gd_src="$CMD_NORMALIZED"
  # Absolute-path / explicit-invocation bypass guard:
  # Pattern 4 全体は `*" git <verb> "*` glob に依存するため、`git` を直接呼び出さない
  # 形式 (絶対パス指定 `/usr/bin/git checkout`、`command git checkout`、`exec git checkout`、
  # backslash-escaped `\git checkout` 等) は match せず bypass 可能になる。これらを ` git ` に
  # 正規化することで既存 (A)〜(G) sub-block の glob を改変せずに防御範囲を拡大する。
  #   - `/usr/bin/git` / `/opt/homebrew/bin/git` 等の絶対パス → ` git`
  #   - `command git` / `exec git` / `builtin git` (builtin は構文 invalid だが safety) → ` git`
  #   - `\git` (backslash-escaped) → ` git`
  # Residual gap: alias / function indirection (`alias gg='git'`, `my_git() { ... }`)
  # は parent shell 解決後の独立トークンとして渡るため、本 hook の静的 glob では検出不能。
  # Layer 2 の責務は「静的 token として `git` を含むコマンド」に限定し、一次防御は agent prompt、
  # 三次防御は Layer 3 post-condition state-verify gate に委ねる三層構造を維持する。
  #
  # `/git` substring 全置換の boundary 設計:
  # 本 line は `/git` を ` git` に置換するため `/home/user/.config/git/config` のような
  # path 構成要素も置換対象になる (例: `grep -r foo /home/user/.config/git/config` →
  # `grep -r foo /home/user/.config git/config`)。実装上、現状 false positive は発生しない。
  # 主要因 (全サブブロック共通): path 由来トークンは置換後 ` git/<X>` 形 (前 boundary に leading
  # space、`/` で verb 境界が崩れる) となり、(A)〜(G) すべての deny glob (trailing space 必須形 /
  # 省略形いずれも) が要求する連続 token `git <verb>` シーケンスに到達しないため別経路で safe。
  # 補強要因 (サブブロック別の trailing space): (A) Always-deny verbs の case-glob は
  # `*" git <verb> "*` 形式で trailing space 必須 (verb 末尾の token boundary も二重に保護)。
  # (B) stash / (C) tag / (D) reflog の case-glob、および (E) worktree の case-glob (remove/move/
  # prune 等) は `*" git <verb>"*` 形式で trailing space 省略。(E) worktree の token-loop
  # precondition (`add` 等) は ` git worktree add ` で trailing space 必須。(G) branch は混在で、
  # 短形式 (`-D` / `-d` / `-f` / `-m` / `-M` / `-c` / `-C` 等) は trailing space あり、long-form
  # (`--delete` / `--force` / `--move` / `--copy` 等) は trailing space 省略。
  # 将来、本正規化を `/git ` (後続スペース必須: `${CMD_NORMALIZED//\/git / git }`) に変更すべき
  # ケース: (A) Always-deny に新規 verb を追加し末尾境界条件を緩める設計変更時。(B)-(G) を変更
  # する場合も path 由来トークンとの衝突を再検証する必要がある。
  CMD_NORMALIZED="${CMD_NORMALIZED//\/git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED//\\git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED// command git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED// exec git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED// builtin git/ git}"
  # 注: quote 正規化 (`"` / `'` → space) は false positive 過剰 (TC-061 `echo "git checkout"`
  # のような log 出力経路を阻害) のため採用せず、代わりに quote-shell 経路 (`eval` / `sh -c` /
  # `bash -c` / `zsh -c`) を別 sub-block で明示 block する設計に統一。
  # Collapse multiple spaces into one.
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  # Git global flag normalization:
  # `git -C <dir> checkout -b` / `git --git-dir=<X> checkout -b` 等の global flag が介在する形式は
  # 後続の case glob `*" git checkout "*` / token-loop `[[ " git worktree add " ]]` に match せず
  # Pattern (A)〜(G) を bypass する。global flag 群を ` git ` に圧縮することで、後続の sub-block 全体が
  # flag-presence に関わらず一律に match できる。
  #
  # The substitution `${CMD_NORMALIZED/$_lit/git }` interprets $_lit as a glob pattern (bash
  # parameter-expansion semantics), so a `-C <dir>` value containing `*` / `?` / `[` would be
  # treated as a wildcard and could either overmatch or fail to match. Escape those metacharacters
  # before substituting to keep the normalization literal regardless of input content.
  _escape_glob_meta() {
    local s="$1"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//\[/\\[}"
    printf '%s' "$s"
  }
  # Global-flag normalization iteration cap (fail-closed on abnormally many flags).
  # The per-flag regex + fork loops below are super-linear in the number of git
  # global flags, and the PreToolUse hook timeout is fail-OPEN (a timed-out hook
  # allows the command — Claude Code cancels the hook and lets the tool proceed). A
  # reviewer subagent could therefore pad a state-mutating git with thousands of
  # `-C x` global flags so this normalization exceeds the hook timeout; the deny is
  # never emitted and the padded git executes, bypassing the guard. The ERR trap
  # cannot catch a timeout (the process is killed externally), so this iteration cap
  # is what keeps that failure mode fail-CLOSED. A legitimate reviewer git command
  # has only a handful of global flags, so exceeding the cap means the input is
  # adversarial → deny. The counter is shared across both loops so the total work is
  # bounded regardless of which flag family is padded.
  _gf_norm_iters=0
  while [[ " $CMD_NORMALIZED " =~ \ git\ (-C|--git-dir|--work-tree|--exec-path|--namespace|-c|--config-env)(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)\  ]]; do
    _gf_norm_iters=$((_gf_norm_iters + 1))
    if [ "$_gf_norm_iters" -gt "$_RITE_BTG_MAX_GLOBAL_FLAG_NORM" ]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      BLOCKED_SUBKIND="oversized-normalization"
      break
    fi
    _matched="${BASH_REMATCH[0]}"
    _lit=$(_escape_glob_meta "${_matched# }")
    CMD_NORMALIZED="${CMD_NORMALIZED/$_lit/git }"
  done
  while [[ " $CMD_NORMALIZED " =~ \ git\ (--bare|--no-replace-objects|--paginate|--no-pager|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--info-path|--man-path|--html-path)\  ]]; do
    _gf_norm_iters=$((_gf_norm_iters + 1))
    if [ "$_gf_norm_iters" -gt "$_RITE_BTG_MAX_GLOBAL_FLAG_NORM" ]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      BLOCKED_SUBKIND="oversized-normalization"
      break
    fi
    _matched="${BASH_REMATCH[0]}"
    _lit=$(_escape_glob_meta "${_matched# }")
    CMD_NORMALIZED="${CMD_NORMALIZED/$_lit/git }"
  done
  # Re-collapse spaces after global-flag normalization.
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  PADDED=" $CMD_NORMALIZED "

  # --- (Z) Quote-shell bypass guard ---
  # `eval` / `sh -c` / `bash -c` / `zsh -c` 経由で git command を実行する経路は、
  # quote 内の content が (A)-(G) glob と word-boundary を共有しないため bypass 可能。
  # 例: `eval "git checkout -b evil"` は (A) Always-deny に match しない。
  # reviewer subagent が `eval` / shell `-c` を実行する legitimate な理由はほぼない
  # (read-only な script 実行は `bash <script>` で十分) ため、これらの shell-wrapper を直接 block する。
  # 注: `bash <script.sh>` (引数 1 個目が `-c` でない) は allow し続ける必要があるため、`-c` flag の
  # 直前トークンが shell 名であるパターンのみを block する。
  case "$PADDED" in
    *" eval "*|\
    *" sh -c "*|\
    *" bash -c "*|\
    *" zsh -c "*|\
    *" ksh -c "*|\
    *" dash -c "*|\
    *" fish -c "*)
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      # 中身が read-only でも block するため、deny message 側で理由を明示する。
      # pattern 名は既存テスト (assert_subagent_deny が reason に "reviewer-state-mutating-git"
      # を要求) との互換のため変えず、subkind タグで message だけを分岐する。
      BLOCKED_SUBKIND="shell-wrapper"
      ;;
  esac

  # --- (A) Always-deny verbs (no read-only sub-action exists) ---
  case "$PADDED" in
    *" git checkout "*|\
    *" git reset "*|\
    *" git add "*|\
    *" git rm "*|\
    *" git restore "*|\
    *" git commit "*|\
    *" git push "*|\
    *" git pull "*|\
    *" git merge "*|\
    *" git rebase "*|\
    *" git cherry-pick "*|\
    *" git revert "*|\
    *" git clean "*|\
    *" git gc "*|\
    *" git prune "*|\
    *" git update-ref "*|\
    *" git symbolic-ref "*|\
    *" git am "*|\
    *" git apply "*|\
    *" git mv "*|\
    *" git notes "*|\
    *" git config "*|\
    *" git remote "*|\
    *" git bisect "*|\
    *" git filter-branch "*|\
    *" git filter-repo "*|\
    *" git replace "*)
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      ;;
  esac

  # --- (B) Sub-action precision: git stash push/pop/drop/apply/clear only ---
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git stash push"*|\
      *" git stash pop"*|\
      *" git stash drop"*|\
      *" git stash apply"*|\
      *" git stash clear"*|\
      *" git stash save"*|\
      *" git stash create"*|\
      *" git stash store"*|\
      *" git stash branch"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (C) Sub-action precision: git tag (creation/deletion only) ---
  # Allowed: `git tag -l`, `git tag --list`, `git tag` (bare list)
  # Denied:  `git tag <name>`, `git tag -a`, `git tag -d`, `git tag --delete`,
  #          `git tag -f`, `git tag --force`
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git tag -a"*|\
      *" git tag --annotate"*|\
      *" git tag -d"*|\
      *" git tag --delete"*|\
      *" git tag -f"*|\
      *" git tag --force"*|\
      *" git tag -s"*|\
      *" git tag -u"*|\
      *" git tag -m"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (D) Sub-action precision: git reflog (only expire/delete block) ---
  # Allowed: `git reflog`, `git reflog show`
  # Denied:  `git reflog expire`, `git reflog delete`
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git reflog expire"*|\
      *" git reflog delete"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (E) Sub-action precision: git worktree remove/prune/move + add-with-new-branch ---
  # Allowed: `git worktree list`, `git worktree add --detach <path> <ref>`,
  #          `git worktree add <path> <existing-branch>` (2 positional args: path + existing ref)
  # Denied:  `git worktree remove`, `git worktree prune`, `git worktree move`,
  #          `git worktree add -b <newbranch> ...` (any position) / `-B`, attached forms
  #          `-bNAME` / `-b=NAME` / `--new-branch=NAME`, bare `git worktree add <path>` (1 positional
  #          arg only — Git auto-creates a new named branch matching basename(path)).
  #
  # Failure mode: a reviewer subagent creates a new named branch via `git worktree add -b`,
  # then runs `git checkout` to traverse states, replacing the parent session's working tree
  # with a clean reference. `git checkout` is already blocked by (A) Always-deny, but
  # `git worktree add -b` had been permitted by (E), leaving a structural gap that this
  # sub-block closes.
  #
  # Initial `add -b ` glob required a trailing space and silently passed forms like
  # `add -bNAME`, `add -b=NAME`, `add --track -b NAME` (mid-flag), and `add /tmp/d -b newbr HEAD`
  # (positional after path). The token loop below identifies `-b` / `-B` as standalone flag
  # tokens, with the case glob retained as a first-line defense.
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git worktree remove"*|\
      *" git worktree prune"*|\
      *" git worktree move"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi
  # Token-loop based detection for `git worktree add` forms — covers all bypass paths:
  #   - bare `add <path>` (1 positional arg, no --detach) → leak
  #   - any token equal to `-b` / `-B` / `--new-branch` / `--force-new-branch` / `--orphan` → leak
  #     (regardless of where it appears in args)
  #   - attached forms `-bNAME` / `-BNAME` / `-b=NAME` / `--new-branch=NAME` /
  #     `--force-new-branch=NAME` / `--orphan=NAME` → leak
  # Allowed:
  #   - `--detach` flag present (token equal to `--detach` or attached form `--detach=...`
  #     which is not a real git option but harmless to recognize)
  #   - 2+ positional args (path + existing branch/ref) AND no new-branch flag
  if [ -z "$BLOCKED_PATTERN" ]; then
    if [[ "$PADDED" =~ " git worktree add " ]]; then
      WT_ARGS="${PADDED##* git worktree add }"
      WT_ARGS="${WT_ARGS% }"
      WT_POSITIONAL_COUNT=0
      WT_HAS_DETACH=0
      WT_NEW_BRANCH_FLAG=0
      for tok in $WT_ARGS; do
        case "$tok" in
          --detach|--detach=*)
            WT_HAS_DETACH=1
            ;;
          -b|-B|--new-branch|--force-new-branch|--orphan)
            # standalone new-branch flag (next token is the branch name)
            WT_NEW_BRANCH_FLAG=1
            ;;
          -b*|-B*|--new-branch=*|--force-new-branch=*|--orphan=*)
            # attached form: `-bNAME` / `-BNAME` / `-b=NAME` / long-form `=NAME`
            # Note: `-b*` glob also catches `-b` alone (handled above by exact-match first
            # branch in case statement, but bash case falls through in order — first match wins,
            # so the standalone variant is matched before this attached-form branch).
            WT_NEW_BRANCH_FLAG=1
            ;;
          -*)
            : ;;  # other flag (--track / --quiet / --guess-remote etc.), skip
          *)
            WT_POSITIONAL_COUNT=$((WT_POSITIONAL_COUNT + 1)) ;;
        esac
      done
      # Deny logic:
      #   (a) new-branch flag present at any position → leak (regardless of --detach)
      #   (b) positional_count <= 1 AND no --detach → bare `add <path>`, auto-creates branch → leak
      if [ "$WT_NEW_BRANCH_FLAG" -eq 1 ]; then
        BLOCKED_PATTERN="reviewer-state-mutating-git"
      elif [ "$WT_POSITIONAL_COUNT" -le 1 ] && [ "$WT_HAS_DETACH" -eq 0 ]; then
        BLOCKED_PATTERN="reviewer-state-mutating-git"
      fi
    fi
  fi

  # --- (F) Sub-action precision: git fetch (bare allowed, --prune/--force denied) ---
  # CRITICAL: `-p` / `-f` must be matched as **standalone flag tokens**, not as
  # substrings inside branch names like `hot-fix` / `release-patch` /
  # `v1.0-rc-final` / `main-pipeline`.
  #
  # Use a single bash regex with an optional "leading args" group:
  #   ([^[:space:]]+[[:space:]]+)*
  # This matches zero or more "non-space token + trailing spaces" — allowing
  # the flag to appear either directly after `git fetch ` or after any number
  # of positional args. The flag group `(--prune|--force|-p|-f)` requires an
  # exact token match, so branch names containing `-p`/`-f` as substrings are
  # NOT matched.
  if [ -z "$BLOCKED_PATTERN" ]; then
    if [[ "$PADDED" =~ " git fetch "([^[:space:]]+[[:space:]]+)*(--prune|--force|-p|-f)([[:space:]=]|$) ]]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
    fi
  fi

  # --- (G) git branch: display-only flags allowed, everything else denied ---
  # Display-only flags: --list / --show-current / -a / --all / -r / --remotes /
  #                     -v / -vv / --verbose / -q / --quiet
  # Denied: -D / -d / -f / -m / -M / -c / -C / --delete / --force / --move /
  #         --copy, bare `git branch <name>` (new ref creation)
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Short/long-form deletion and move flags
    case "$PADDED" in
      *" git branch -D "*|\
      *" git branch -d "*|\
      *" git branch -f "*|\
      *" git branch -m "*|\
      *" git branch -M "*|\
      *" git branch -c "*|\
      *" git branch -C "*|\
      *" git branch --delete"*|\
      *" git branch --force"*|\
      *" git branch --move"*|\
      *" git branch --copy"*|\
      *" git branch --set-upstream"*|\
      *" git branch --unset-upstream"*|\
      *" git branch --edit-description"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Bare new-branch creation: `git branch <non-flag-token>` after the verb.
    # Use a bash regex to detect `git branch` followed by a token that does NOT
    # start with `-` (which would indicate a flag). Bare `git branch`
    # (no argument) and `git branch -<flag>` stay in the regex's non-match path.
    if [[ "$PADDED" =~ " git branch "[[:space:]]*[^[:space:]-] ]]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
    fi
  fi

  # --- (H) reviewer WRITE into a .git directory (shell redirect / file-mutating verb) ---
  # pre-tool-edit-guard.sh structurally blocks the Edit/Write/MultiEdit/NotebookEdit path into a
  # parent .git; this closes the sibling Bash-tool gap (Issue #1864 AC-1). A reviewer subagent can
  # `echo pwned > <repo>/.git/hooks/pre-commit` (or via tee/cp/mv/ln/install/rsync/truncate/dd) to
  # plant a hook or rewrite .git/config (core.hooksPath / alias.*=!sh / core.fsmonitor) — either
  # runs arbitrary code in the non-sandboxed MAIN session on the next git op, strictly worse than a
  # source edit and invisible to `git status`. This block runs INSIDE the Pattern-4 fail-CLOSED
  # trap region (before the restore below), so a crash here denies rather than allows. Only WRITES
  # into a .git dir component are denied; READING .git (cat/ls/grep .git/config, `dd if=.git/…`)
  # stays allowed (no write operator/verb targeting .git).
  #
  # SCOPE (deliberate — this is best-effort hardening, per AC-1 "可能な範囲で", NOT full closure):
  # a static bash matcher cannot decide "does this command write to .git" in general. This block
  # matches only STATICALLY-IDENTIFIABLE write targets: a redirect operand (`>`/`>>`), a positional
  # argument of a common file-writing verb (tee/cp/mv/ln/install/rsync/truncate/sponge/patch), and
  # `dd of=<path>`. The file-verb list is a COMMON-SET, deliberately NOT exhaustive — any write
  # tool outside it (in-place editors `sed -i`/`perl -pi`/`ed`/`ex`/`gawk -i inplace`, and other
  # exotic writers) is Layer-1-only, exactly like the interpreter class below. Enumerating every
  # write-capable program is impossible for a static matcher, so the guarantee for the tail is the
  # reviewer prompt, not this hook. The following are OUT OF SCOPE for a static matcher and are
  # covered by Layer 1 (the reviewer prompt / _reviewer-base.md READ-ONLY contract) ONLY — NOT by
  # this hook and NOT by Layer 3:
  #   - Targets needing RUNTIME resolution or `$`-EXPANSION: `> $VAR`, `> $(cmd)`, and ANSI-C
  #     quoting `> $'\x2egit/hooks/x'` (`\x2e`→`.`) — the `$`/`(`/`)` are collapsed to spaces by the
  #     meta-char normalization, so the path is not visible statically (ANSI-C escape decoding is a
  #     `$`-expansion, not plain quote-removal, so it is NOT dequoted below).
  #   - INTERPRETER-embedded writes: `python3 -c "open('.git/hooks/x','w')"`, `perl -e ...` — the
  #     write is inside an opaque quoted argument.
  #   - HEREDOC-body redirects: `cat <<EOF > .git/hooks/x` — CMD_CHECK cuts at `<<`, so a redirect
  #     target after the marker is stripped (`cat > .git/hooks/x <<EOF` IS caught). Scanning raw
  #     $COMMAND to fix this would false-match `>.git` text inside heredoc/PR bodies and, under this
  #     fail-CLOSED region, turn those into spurious denies — so it is deliberately not done.
  #   - FLAG-embedded write targets other than `dd of=`: a target GLUED to a flag — `install
  #     --target-directory=.git/hooks` / `install -t.git/hooks`, GNU `cp --target-directory=.git/…`
  #     — is NOT parsed. Only a .git path that surfaces as its OWN token is matched, i.e. a
  #     positional arg or a SPACE-separated flag argument (`install src .git/hooks/x` and
  #     `install -t .git/hooks src` — the standalone `.git/hooks` token — ARE caught). `dd of=` is
  #     the one glued-target special-cased, because `of=` is dd's SOLE output form (dd has no
  #     positional destination); adding per-flag parsing for every verb (`-t`/`--target-directory=`
  #     /…) is scope creep, so those stay Layer-1-only.
  #   Note: Layer 3 (post-review-state-verify.sh) does NOT backstop these — `.git` writes are
  #   invisible to `git status --porcelain`. A complete guarantee needs a different layer
  #   (filesystem permissions / sandbox), which is out of scope for this hook.
  # Other documented traits (not gaps):
  #   - A `>` or a .git path inside a quoted string (`echo "text > .git/x"`) can false-match. Rare
  #     in a read-only reviewer command; the deny message explains the block so it is recoverable.
  #   - `.git` is matched as a genuine path COMPONENT only (`(^|/).git(/|$)` via the case globs),
  #     so a dir literally named `foo.git/` (e.g. a bare-repo clone) is NOT matched.
  #   - cp/mv/ln/rsync/install fire even when the .git path is the SOURCE (`cp .git/config /tmp/x`),
  #     not only the destination — a read-copy a reviewer should do with `cat` instead; accepted to
  #     keep the matcher simple (an explicit `< .git/x` input redirect IS excluded as a read).
  #   - The file-verb latch is set by a matching token ANYWHERE and persists across the (space-
  #     collapsed) command, so it can over-DENY a later .git READ in the same command line — both a
  #     cross-boundary read (`cp a b ; cat .git/config`) and a path ARG whose basename is a verb
  #     (`grep x /tmp/cp .git/config` → `/tmp/cp` basename `cp` latches). This is fail-CLOSED (it
  #     denies a read, never allows a write), rare, and recoverable via the deny message; accepted
  #     rather than track command boundaries (which the meta-char collapse has already erased).
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Tokenize from _gd_src (the PRE-`/git`-munge snapshot captured above), NOT CMD_NORMALIZED:
    # the `/git`→` git` invocation-normalization corrupts any redirect-target path with a literal
    # `/git` ancestor (`/srv/git/…`, `~/github/…`), splitting `>` from the `.git` token (Issue #1864
    # fix). Meta-chars ;&|(){}`$ are already collapsed to spaces in _gd_src; `>`/`<` survive.
    # Surface `>>`/`>`/`<` as standalone tokens so `x>.git/y` and `x >> .git/y` both tokenize.
    # Append order matters: `>>` before `>`.
    _gdw=" ${_gd_src:-} "
    _gdw="${_gdw//>>/ > }"
    _gdw="${_gdw//>/ > }"
    _gdw="${_gdw//</ < }"
    while [[ "$_gdw" == *"  "* ]]; do _gdw="${_gdw//  / }"; done
    _gd_prev=""
    _gd_fileverb=0
    for _gd_tok in $_gdw; do
      # Dequote the token the way the SHELL does before opening the path, THEN strip a leading `of=`
      # (dd's write-target argument), so `dd … of=.git/hooks/x` is detected while `dd if=.git/config
      # …` (read source) is not. POSIX quote-removal strips exactly THREE characters wherever they
      # sit — `"`, `'`, and unquoted `\` — so ALL three are removed globally here. A fixed
      # surrounding strip, or removing only the quotes, leaves an obfuscated write vector: quotes
      # ANYWHERE (`of='.git/x'`, `of=''.git/x''`, `of=.g'i't/hooks/x`, `> '.git'/hooks/x`) and
      # backslashes ANYWHERE (`> .g\it/hooks/x`, `> \.git/x`, `dd of=.g\it/…`) all still open the
      # real `.git` for the shell. Backslash removal runs BEFORE the `of=` strip so `\of=.git/x`
      # (escaped `o`) normalizes to `of=.git/x` first (Issue #1864 cycle-3/4 fix — interior/nested
      # quotes and backslash-escaped path components were fail-open .git-write bypasses). Only the
      # `.git` component match uses `_gd_p`; `_gd_prev` (redirect / `<` read-skip) and `_gd_verb`
      # (file-verb latch) below use the RAW `_gd_tok`.
      # Note: `$'…'` ANSI-C escape decoding (`$'\x2egit'` → `.git`) is NOT done — that is a
      # `$`-triggered EXPANSION, already class-B out-of-scope (the `$` is collapsed to a space by
      # the meta-char normalization above, same as `$VAR` / `$(cmd)`), covered by Layer 1.
      _gd_p="${_gd_tok//[\"\']/}"
      _gd_p="${_gd_p//\\/}"
      _gd_p="${_gd_p#of=}"
      _gd_is_gitpath=0
      case "$_gd_p" in
        .git|.git/*|*/.git|*/.git/*) _gd_is_gitpath=1 ;;
      esac
      # A .git path that is an INPUT redirect source (`… < .git/config`) is a READ → never a write.
      if [ "$_gd_prev" = "<" ]; then _gd_prev="$_gd_tok"; continue; fi
      # Redirect vector: the previous surfaced token was `>` and this token is a .git path.
      if [ "$_gd_prev" = ">" ] && [ "$_gd_is_gitpath" = "1" ]; then
        BLOCKED_PATTERN="reviewer-gitdir-write"; BLOCKED_SUBKIND="gitdir-write"; break
      fi
      # File-mutating-verb vector: a write verb seen earlier + a .git path arg now. Resolve the verb
      # to its bare form the SAME way the shell does before executing it: strip quotes and
      # backslashes (POSIX quote-removal, mirroring the path dequoting above), THEN take the
      # basename. Dequoting the verb token is required for the same reason as the path token —
      # otherwise an obfuscated verb (`'tee'`, `t\ee`, `t"e"e`) evades the latch while the shell
      # still runs it, re-opening the fail-open on the VERB axis (Issue #1864 cycle-5 fix). The
      # basename after dequote catches absolute-path invocations (`/usr/bin/tee`); `command cp` /
      # `exec cp` already reach here as a bare `cp` token.
      _gd_verb="${_gd_tok//[\"\']/}"; _gd_verb="${_gd_verb//\\/}"; _gd_verb="${_gd_verb##*/}"
      case "$_gd_verb" in
        tee|cp|mv|ln|install|rsync|truncate|dd|sponge|patch) _gd_fileverb=1 ;;
      esac
      if [ "$_gd_is_gitpath" = "1" ] && [ "$_gd_fileverb" = "1" ]; then
        BLOCKED_PATTERN="reviewer-gitdir-write"; BLOCKED_SUBKIND="gitdir-write"; break
      fi
      _gd_prev="$_gd_tok"
    done
  fi

  if [ -n "$BLOCKED_PATTERN" ]; then
    BLOCKED_REASON="Reviewer subagents must not mutate the working tree, index, or refs. State-changing git commands (checkout/reset/add/stash push/restore/commit/push/merge/rebase/cherry-pick/revert/tag -a -d -f/clean/gc/branch -D --delete/update-ref/symbolic-ref/am/apply/mv/notes/config/remote/bisect/filter-branch/replace/reflog expire/worktree remove/fetch --prune/--force/etc.) are forbidden inside reviewer contexts."
    BLOCKED_ALTERNATIVE="Use read-only alternatives: 'git show <ref>:<file>' to read a blob, 'git diff <ref> -- <file>' to compare, 'git worktree add <path> <ref>' to inspect a different ref in an isolated directory, 'git tag -l' / 'git stash list' / 'git reflog' / 'git branch --list' for display-only queries, or bare 'git fetch' (without --prune/--force) for ref sync. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the full list. If this block fires on a main session (not a reviewer subagent), check whether CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE env vars are accidentally set; recover with: unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE"
    # (Z) shell-wrapper の場合は、wrapper 専用の理由・代替を前置する。
    # 汎用 git message だけだと、git を含まない read-only probe (例: `bash -c 'echo x'`) が
    # "State-changing git commands ... forbidden" と表示され、reviewer には over-broad で
    # 不可解な block に見える。なぜ wrapper を一律 block するか / read-only probe をどう書き
    # 直すかを先頭で説明する (既存 git ガイダンスは wrapper が git を包む場合に有効なので残す)。
    if [ "$BLOCKED_SUBKIND" = "shell-wrapper" ]; then
      BLOCKED_REASON="Shell-command wrappers (eval / bash -c / sh -c / zsh -c / ksh -c / dash -c / fish -c) are blocked in reviewer contexts because their quoted argument is opaque to this guard's word-boundary matching and can hide state-mutating git commands. They are therefore blocked unconditionally — even when the wrapped command is read-only. $BLOCKED_REASON"
      BLOCKED_ALTERNATIVE="For a read-only probe, drop the wrapper: run the command directly, group multiple commands in a subshell '( cmd1; cmd2 )', or put them in a file and run 'bash <script.sh>'. $BLOCKED_ALTERNATIVE"
    fi
    # (oversized-normalization) The command has an abnormally large number of git
    # global flags, which would make normalization exceed the fail-open hook timeout.
    # Denied fail-closed to prevent a timeout-based bypass — explain that rather than
    # showing the generic state-mutating message (the command may even be read-only).
    if [ "$BLOCKED_SUBKIND" = "oversized-normalization" ]; then
      BLOCKED_REASON="This reviewer command carries an abnormally large number of git global flags (e.g. many repeated -C / -c). Normalizing that many flags could exceed the PreToolUse hook timeout, and a timed-out hook fails OPEN (the command would be allowed) — so such oversized commands are denied fail-closed to prevent a timeout-based bypass of the reviewer read-only guard. $BLOCKED_REASON"
      BLOCKED_ALTERNATIVE="Simplify the command — reviewer git operations never need this many global flags. $BLOCKED_ALTERNATIVE"
    fi
    # (gitdir-write) Reviewer writing into a .git directory via shell redirect / file-op (H).
    # REPLACE (not prepend) the generic git-verb message — this is not a git command, and the
    # generic "State-changing git commands …" text would mislabel a plain `echo > .git/hooks/x`.
    if [ "$BLOCKED_SUBKIND" = "gitdir-write" ]; then
      BLOCKED_REASON="Reviewer subagents must not WRITE into a Git internal (.git) directory. This command writes into a .git path via a shell redirect (> / >>) or a file-mutating command (tee / cp / mv / ln / install / rsync / truncate / dd of= / sponge / patch). Planting or altering .git/hooks/* or .git/config (core.hooksPath / alias.*=!sh / core.fsmonitor) executes arbitrary code in the non-sandboxed main session on the next git operation — strictly worse than a source edit and invisible to 'git status'. The Edit/Write path is already blocked by pre-tool-edit-guard.sh; this closes the Bash-tool gap (Issue #1864)."
      BLOCKED_ALTERNATIVE="Reviewers are strictly read-only — never write into .git. To INSPECT it, read instead: 'cat .git/config', 'git config --list', 'git cat-file -p <obj>', 'git show <ref>:<file>', 'git rev-parse'. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."
    fi
  fi
  # Restore the Patterns 1-3 fail-open trap for the shared result-emit section
  # below: a crash there keeps the original (pre-fix) fail-open behavior, and the
  # section already has its own fail-closed fallback for the deny-emit path.
  trap '_rite_btg_pattern13_fail_open' ERR
fi

# --- Result ---

if [ -z "$BLOCKED_PATTERN" ]; then
  exit 0
fi

# Log block event (stderr, for effect measurement)
CMD_SUMMARY="${COMMAND:0:80}"
CMD_SUMMARY="${CMD_SUMMARY//\"/\\\"}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] bash-guard: BLOCKED pattern=$BLOCKED_PATTERN cmd=\"$CMD_SUMMARY\"" >&2

# Deny with reason and alternative. jq is required to emit the final permission
# payload; an intermittent jq failure here would silently downgrade the deny to
# allow. Fall back to a literal JSON envelope + exit 2 so the deny is fail-closed.
# reason のエスケープ連鎖 (改行 \n 化 + 残存 C0 の ? 化、
# stop-loop-continuation.sh の JSON emit フォールバックと対称) は
# _bash_guard_escape_deny_reason に集約。neutralize 失敗時は raw を emit せず
# static placeholder へ縮退し、deny + exit 2 の fail-closed 契約を維持する。
_deny_reason="BLOCKED ($BLOCKED_PATTERN): $BLOCKED_REASON $BLOCKED_ALTERNATIVE"
if ! jq -n --arg reason "$_deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'; then
  _deny_reason_escaped=$(_bash_guard_escape_deny_reason "$_deny_reason") \
    || _deny_reason_escaped="BLOCKED: command denied (reason neutralization failed, fail-closed). Check the bash-guard stderr log for the blocked pattern."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$_deny_reason_escaped"
  exit 2
fi
