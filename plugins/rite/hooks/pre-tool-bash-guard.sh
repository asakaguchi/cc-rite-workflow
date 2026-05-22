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
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRETOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# Single source of truth for create_* lifecycle phase names. Provides
# rite_phase_is_create_lifecycle_in_progress() used by Pattern 5. The whitelist
# itself warns on bash < 4.2, but a parser-level syntax error would otherwise
# silently disable Pattern 5 — surface it instead.
source "$SCRIPT_DIR/phase-transition-whitelist.sh" 2>/dev/null \
  || echo "[rite] WARNING: phase-transition-whitelist.sh source failed in pre-tool-bash-guard.sh; Pattern 5 lifecycle detection disabled" >&2

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
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(head -c 200 "$_jq_input_err" | tr '\n' ' ')" \
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
# Pattern 5 needs explicit per-call fallbacks for complex state-file ops and
# releases this trap (`trap - ERR`) before its own logic.
#
# Side effect: a subtle bash builtin failure or heredoc extraction crash will
# silently downgrade a would-be deny to allow. Under RITE_DEBUG the fail-open
# fires a debug-log line so the trip can be traced after the fact.
#
# Function defined before the trap registration so that the trap target always
# exists when ERR fires.
_rite_btg_pattern13_fail_open() {
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-bash-guard: Pattern 1-3 ERR trap fired — command allowed via fail-open\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  exit 0
}
trap '_rite_btg_pattern13_fail_open' ERR

# --- Heredoc-safe command extraction ---
# Strip heredoc content to avoid false positives on text inside commit messages,
# PR descriptions, etc. Only check the command prefix before the first heredoc marker.
# Known limitation: Piped heredoc patterns (e.g., `cat <<EOF | gh pr diff`) bypass
# this stripping because the command before `<<` is `cat`, not the target pattern.
# Risk is limited since such patterns are rare in practice.
CMD_CHECK="${COMMAND%%<<*}"

# --- Denylist check (Bash built-ins only) ---

BLOCKED_PATTERN=""
BLOCKED_REASON=""
BLOCKED_ALTERNATIVE=""

# Pattern 1: gh pr diff --stat
case "$CMD_CHECK" in
  *"gh pr diff"*" --stat"*)
    BLOCKED_PATTERN="gh-pr-diff-stat"
    BLOCKED_REASON="gh pr diff does not support the --stat flag."
    BLOCKED_ALTERNATIVE="Use: gh pr view {pr_number} --json files --jq '.files[] | {path, additions, deletions}'"
    ;;
esac

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

# Pattern 5: gh issue create direct invocation during /rite:issue:create lifecycle.
# The orchestrator (create.md) MUST delegate Issue creation to
# `scripts/create-issue-with-projects.sh` (Projects 統合 + label/status field 設定を 1 ステップで
# 実行)。直接 `gh issue create` を実行すると Projects 登録と field 設定が抜け落ちる。
#
# create.md は flat workflow に統合されており、新規 state file は terminal の
# `phase=completed` のみを書き、中間 `create_*` phase は出現しない。本 Pattern は legacy
# state file (旧 sub-skill chain 時代の `create_interview` / `create_post_interview` /
# `create_delegation` / `create_post_delegation`) が残った環境のみで trigger する forward-compat
# 防御として残置。静的な防御は `scripts/check-no-direct-gh-issue-create.sh` (Phase 3.14 lint)
# が担う。
#
# Bypass prevention — Pattern 5 normalization:
#   Pattern 5 normalizes shell meta-characters (;, &, |, parens, braces, backticks, $, quotes) to
#   spaces so that `true; gh issue create` / `echo x | gh issue create` / `{gh issue create;}` /
#   `eval "gh issue create"` all match the same `gh issue create` pattern. Backslash line
#   continuations (`gh \\\n  issue \\\n create`) are also normalized because `\n` and `\` are both
#   replaced with space.
#
# ⚠️ IMPORTANT — Pattern 5 uses $COMMAND (full input) not $CMD_CHECK:
#   Patterns 1-4 operate on $CMD_CHECK which is $COMMAND with content after the first `<<`
#   heredoc marker stripped (to avoid false positives from heredoc body content). Pattern 5
#   MUST NOT use CMD_CHECK because of a legitimate Mode B bypass: `cat <<EOF | sh ... gh issue
#   create ... EOF` would be stripped to `cat ` and Pattern 5 would silently miss it. Using
#   $COMMAND directly means heredoc bodies ARE scanned — the false positive risk (PR/Issue
#   body text containing the literal `gh issue create`) is acceptable because (a) such text
#   is rare in practice, and (b) the create lifecycle scope filter below limits exposure.
#
# Scope exclusions (allow):
#   - no .rite-flow-state (manual gh invocation outside any workflow)
#   - .rite-flow-state exists but active=false or phase=create_completed (lifecycle finished)
#   - .rite-flow-state phase is not create_* (different workflow like /rite:issue:start)
#   - gh issue subcommands other than `cr` prefix (close/comment/delete/edit/list/view/etc. allowed)
#     — gh CLI resolves `cr` unambiguously to `create` (the only `gh issue` subcommand starting
#     with `cr`), so `cr` is the minimum unambiguous prefix and must be caught. `c` alone is
#     ambiguous and gh CLI itself rejects it, so we do not block it here.
if [ -z "$BLOCKED_PATTERN" ]; then
  # Pattern 5 owns its own per-call fallbacks (`|| STATE_PHASE=""` etc.).
  # Release the Patterns 1-3 fail-open ERR trap so jq/state-read failures
  # cannot silently turn into "allow" by accident.
  trap - ERR
  # Normalize $COMMAND directly (NOT $CMD_CHECK) to catch heredoc-body bypass (#501 HIGH).
  CMD_P5="${COMMAND//$'\t'/ }"
  CMD_P5="${CMD_P5//$'\n'/ }"
  CMD_P5="${CMD_P5//$'\r'/ }"
  CMD_P5="${CMD_P5//\\/ }"
  CMD_P5="${CMD_P5//;/ }"
  CMD_P5="${CMD_P5//&/ }"
  CMD_P5="${CMD_P5//|/ }"
  CMD_P5="${CMD_P5//(/ }"
  CMD_P5="${CMD_P5//)/ }"
  CMD_P5="${CMD_P5//\{/ }"
  CMD_P5="${CMD_P5//\}/ }"
  CMD_P5="${CMD_P5//\`/ }"
  CMD_P5="${CMD_P5//\$/ }"
  CMD_P5="${CMD_P5//\"/ }"
  CMD_P5="${CMD_P5//\'/ }"
  while [[ "$CMD_P5" == *"  "* ]]; do
    CMD_P5="${CMD_P5//  / }"
  done
  PADDED_P5=" $CMD_P5 "

  # gh subcommand prefix match: gh supports prefix shortcuts when unambiguous.
  # Among `gh issue` subcommands (close / comment / create / delete / develop / edit / list /
  # lock / pin / reopen / status / transfer / unlock / unpin / view), only `create` starts with
  # `cr`, so `cr` is the minimum unambiguous prefix for `create`. `c` alone is ambiguous
  # (matches close / comment / create) and gh CLI itself rejects it, so we don't block it.
  # Match `cr` through `create` as trailing tokens, leaving `close` / `comment` / etc. untouched.
  if [[ "$PADDED_P5" =~ " gh issue "(create|creat|crea|cre|cr)([[:space:]]|$) ]]; then
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
    STATE_ROOT_PATH=""
    if [ -n "$CWD" ] && [ -d "$CWD" ]; then
      STATE_ROOT_PATH=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT_PATH="$CWD"
    fi
    # State file lookup: if $STATE_ROOT_PATH is empty (e.g., CWD outside git repo and
    # state-path-resolve.sh failed), skip the check entirely — no state file means no
    # create lifecycle to enforce, which is the documented "allow" path.
    #
    # Per-session state path resolution: _resolve-flow-state-path.sh
    # returns the per-session file (`<root>/.rite/sessions/<session_id>.flow-state`)
    # when schema_version=2 with a valid SID, or the legacy `.rite-flow-state` path
    # otherwise. This keeps Pattern 5 working under both schemas without inlining
    # schema/SID resolution here. Mode B AND-logic (.active=true && phase=create_*)
    # below operates on whichever file the resolver returns.
    if [ -n "$STATE_ROOT_PATH" ]; then
      if STATE_FILE_PATH=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT_PATH" 2>/dev/null); then
        :
      else
        # Resolver failed (helper deploy regression / path validation rejection).
        # Without this unconditional WARNING, a broken resolver on schema_version=2
        # would silently route Pattern 5 detection to the wrong state file — Mode B
        # AND-logic against the legacy file always evaluates false, silently
        # bypassing the guard.
        echo "[rite] WARNING: pre-tool-bash-guard: _resolve-flow-state-path.sh failed; Pattern 5 detection falling back to legacy path ($STATE_ROOT_PATH/.rite-flow-state)" >&2
        # `{ ... } || true` doubles up the failure suppression with the WARNING
        # branch's `||`. A plain `if` avoids the redundant trap and keeps the
        # intent — only append to the debug log when RITE_DEBUG is set, and
        # surface a WARNING if the append itself fails.
        if [ -n "${RITE_DEBUG:-}" ]; then
          echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] pre-tool-bash-guard: _resolve-flow-state-path.sh failed, falling back to legacy path" \
            >> "$STATE_ROOT_PATH/.rite-flow-debug.log" 2>/dev/null \
            || echo "[rite] WARNING: pre-tool-bash-guard: failed to write debug log to $STATE_ROOT_PATH/.rite-flow-debug.log (disk full / permission denied?)" >&2
        fi
        STATE_FILE_PATH="${STATE_ROOT_PATH}/.rite-flow-state"
      fi
      if [ -f "$STATE_FILE_PATH" ]; then
        # corrupt JSON で Pattern 5 (security defense layer) が silent fail-open すると、
        # create_* lifecycle 中の `gh issue create` 直接呼び出しがブロックされない経路ができる。
        # RITE_DEBUG 時に debug log へ trace を残し、operator が "なぜ Pattern 5 が発火しなかったか"
        # を triage 可能にする。
        _p5_phase_err=$(mktemp 2>/dev/null) || _p5_phase_err=""
        STATE_PHASE=$(jq -r '.phase // empty' "$STATE_FILE_PATH" 2>"${_p5_phase_err:-/dev/null}") || STATE_PHASE=""
        if [ -n "${RITE_DEBUG:-}" ] && [ -n "$_p5_phase_err" ] && [ -s "$_p5_phase_err" ]; then
          echo "[rite] DEBUG: pre-tool-bash-guard Pattern 5: jq .phase 失敗 ($STATE_FILE_PATH may be corrupt) — fail-open" >&2
          head -3 "$_p5_phase_err" | sed 's/^/  /' >&2
        fi
        [ -n "$_p5_phase_err" ] && rm -f "$_p5_phase_err"
        _p5_active_err=$(mktemp 2>/dev/null) || _p5_active_err=""
        STATE_ACTIVE=$(jq -r '.active // false' "$STATE_FILE_PATH" 2>"${_p5_active_err:-/dev/null}") || STATE_ACTIVE="false"
        if [ -n "${RITE_DEBUG:-}" ] && [ -n "$_p5_active_err" ] && [ -s "$_p5_active_err" ]; then
          echo "[rite] DEBUG: pre-tool-bash-guard Pattern 5: jq .active 失敗 ($STATE_FILE_PATH may be corrupt) — fail-open" >&2
          head -3 "$_p5_active_err" | sed 's/^/  /' >&2
        fi
        [ -n "$_p5_active_err" ] && rm -f "$_p5_active_err"
        # Use query function from phase-transition-whitelist.sh as the single source of truth
        # for create_* lifecycle phase names. Fall back to inline glob check when the helper
        # is unavailable (e.g., bash < 4.2 where phase-transition-whitelist.sh exits early).
        if [ "$STATE_ACTIVE" = "true" ]; then
          if type rite_phase_is_create_lifecycle_in_progress >/dev/null 2>&1; then
            if rite_phase_is_create_lifecycle_in_progress "$STATE_PHASE"; then
              BLOCKED_PATTERN="create-lifecycle-direct-gh-issue"
            fi
          elif [[ "$STATE_PHASE" == create_* ]] && [ "$STATE_PHASE" != "create_completed" ]; then
            BLOCKED_PATTERN="create-lifecycle-direct-gh-issue"
          fi
          if [ "$BLOCKED_PATTERN" = "create-lifecycle-direct-gh-issue" ]; then
            BLOCKED_REASON="/rite:issue:create lifecycle 中 (phase=$STATE_PHASE) に gh issue create を直接実行することは禁止されています."
            BLOCKED_ALTERNATIVE="Projects 統合 + label/status 設定のため、bash {plugin_root}/scripts/create-issue-with-projects.sh \"\$(jq -n --arg title ... --arg body_file ... --argjson labels ... --argjson projects ... '{issue:{title:\$title,body_file:\$body_file,labels:\$labels},projects:\$projects}')\" の canonical JSON pattern で呼び出してください (create.md ステップ 4.3 / 5.4 および references/issue-create-with-projects.md 参照)。"
          fi
        fi
      fi
    fi
  fi
  # Re-arm the fail-open trap so Patterns 4 / 6 inherit the same regex-compile and
  # bash-error fail-open behavior as Patterns 1-3. Without re-arming, a future bash
  # builtin failure inside those patterns would abort the hook silently and Claude
  # Code would interpret the missing deny JSON as "allow".
  trap 'exit 0' ERR
fi

# Pattern 4: Reviewer subagent running state-mutating git commands.
# Scope: only when IS_SUBAGENT=1 (transcript_path contains "/subagents/").
# Main-session git operations (branch switch, commit, etc. performed by
# /rite:issue:start → implement.md Phase 5.1) are NOT affected because IS_SUBAGENT=0 there.
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
  while [[ " $CMD_NORMALIZED " =~ \ git\ (-C|--git-dir|--work-tree|--exec-path|--namespace|-c|--config-env)(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)\  ]]; do
    _matched="${BASH_REMATCH[0]}"
    _lit=$(_escape_glob_meta "${_matched# }")
    CMD_NORMALIZED="${CMD_NORMALIZED/$_lit/git }"
  done
  while [[ " $CMD_NORMALIZED " =~ \ git\ (--bare|--no-replace-objects|--paginate|--no-pager|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--info-path|--man-path|--html-path)\  ]]; do
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

  if [ -n "$BLOCKED_PATTERN" ]; then
    BLOCKED_REASON="Reviewer subagents must not mutate the working tree, index, or refs. State-changing git commands (checkout/reset/add/stash push/restore/commit/push/merge/rebase/cherry-pick/revert/tag -a -d -f/clean/gc/branch -D --delete/update-ref/symbolic-ref/am/apply/mv/notes/config/remote/bisect/filter-branch/replace/reflog expire/worktree remove/fetch --prune/--force/etc.) are forbidden inside reviewer contexts."
    BLOCKED_ALTERNATIVE="Use read-only alternatives: 'git show <ref>:<file>' to read a blob, 'git diff <ref> -- <file>' to compare, 'git worktree add <path> <ref>' to inspect a different ref in an isolated directory, 'git tag -l' / 'git stash list' / 'git reflog' / 'git branch --list' for display-only queries, or bare 'git fetch' (without --prune/--force) for ref sync. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the full list. If this block fires on a main session (not a reviewer subagent), check whether CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE env vars are accidentally set; recover with: unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE"
  fi
fi

# Pattern 6 (charter-lint): commit message charter pattern enforcement.
# Scope: `git commit -m "..."` / `git commit -F <file>` invocations.
# Default: WARN to stderr (exit 0 — commit passes).
# RITE_COMMIT_LINT_STRICT=true: BLOCK via JSON deny + exit 2.
# Exclusions:
#   (a) commits whose staged files are ALL under docs/designs/
#   (b) message ranges enclosed by triple-backtick Markdown fences
#       (only when fence pairs are balanced — odd fence count disables exclusion)
# Independent of $BLOCKED_PATTERN: when set by Pattern 1-5 (gh-pr-diff / jq != null /
# create-lifecycle / reviewer subagent state-mutating git), Pattern 6 is skipped so the
# more specific block reason takes precedence.
#
# Known limitations (acknowledged false negatives):
#   - HEREDOC subshell form (`-m "$(cat <<EOF ... EOF)"`) is not parsed; the regex captures
#     up to the first `"` of `$(cat <<EOF`, leaving the body unchecked. Project canonical
#     commit patterns that use this form bypass the lint.
#   - `--message=...` long-form, `--file=...` long-form, multiple `-m` flags
#     (`-m title -m body`), and editor mode (no `-m`/`-F`) are not parsed.
# Pattern matching is heredoc-aware via the heredoc-stripped $CMD_CHECK at line ~70.
if [ -z "$BLOCKED_PATTERN" ]; then
  CHARTER_CHECK=0
  # Detect `git commit` with word boundaries (Pattern 4/5 normalization style):
  # normalize shell meta-chars + whitespace to single space, then match space-padded
  # `git commit ` to avoid false positives on `git commit-tree`, `echo "git commit"`,
  # function definitions, and comment lines.
  CHARTER_NORM="${COMMAND//$'\t'/ }"
  CHARTER_NORM="${CHARTER_NORM//$'\n'/ }"
  CHARTER_NORM="${CHARTER_NORM//$'\r'/ }"
  CHARTER_NORM="${CHARTER_NORM//;/ }"
  CHARTER_NORM="${CHARTER_NORM//&/ }"
  CHARTER_NORM="${CHARTER_NORM//|/ }"
  CHARTER_NORM="${CHARTER_NORM//(/ }"
  CHARTER_NORM="${CHARTER_NORM//)/ }"
  CHARTER_NORM="${CHARTER_NORM//\{/ }"
  CHARTER_NORM="${CHARTER_NORM//\}/ }"
  CHARTER_NORM="${CHARTER_NORM//\`/ }"
  CHARTER_NORM="${CHARTER_NORM//\$/ }"
  while [[ "$CHARTER_NORM" == *"  "* ]]; do
    CHARTER_NORM="${CHARTER_NORM//  / }"
  done
  CHARTER_PADDED=" $CHARTER_NORM "
  case "$CHARTER_PADDED" in
    *" git commit "*) CHARTER_CHECK=1 ;;
  esac

  CHARTER_MSG=""
  if [ "$CHARTER_CHECK" = "1" ]; then
    if [[ "$COMMAND" =~ -m[[:space:]]+\"([^\"]*)\" ]]; then
      CHARTER_MSG="${BASH_REMATCH[1]}"
    elif [[ "$COMMAND" =~ -m[[:space:]]+\'([^\']*)\' ]]; then
      CHARTER_MSG="${BASH_REMATCH[1]}"
    elif [[ "$COMMAND" =~ -F[[:space:]]+([^[:space:]]+) ]]; then
      CHARTER_FILE="${BASH_REMATCH[1]}"
      if [ -f "$CHARTER_FILE" ] && [ -r "$CHARTER_FILE" ]; then
        CHARTER_MSG=$(cat "$CHARTER_FILE" 2>/dev/null) || CHARTER_MSG=""
      else
        echo "[charter-lint] WARN: -F file path unresolvable: $CHARTER_FILE (charter check skipped)" >&2
        CHARTER_CHECK=0
      fi
    else
      CHARTER_CHECK=0
    fi
  fi

  if [ "$CHARTER_CHECK" = "1" ] && [ -n "$CHARTER_MSG" ]; then
    # When CWD is not a git work tree, `git diff --cached` returns empty silently
    # and the loop below would treat that as "all design files" and skip charter
    # lint — a silent fail-open. Detect the repo-less case explicitly so the
    # skip is loud (charter lint must be opt-out, not opt-out-by-accident).
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "[charter-lint] ERROR: CWD is not inside a git work tree (charter check explicitly skipped — review hook harness)" >&2
      CHARTER_CHECK=0
    else
      STAGED_FILES=$(git diff --cached --name-only 2>/dev/null) || STAGED_FILES=""
      if [ -n "$STAGED_FILES" ]; then
        ALL_DESIGNS=1
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          case "$f" in
            docs/designs/*) ;;
            *) ALL_DESIGNS=0; break ;;
          esac
        done <<< "$STAGED_FILES"
        if [ "$ALL_DESIGNS" = "1" ]; then
          CHARTER_CHECK=0
        fi
      fi
    fi
  fi

  if [ "$CHARTER_CHECK" = "1" ] && [ -n "$CHARTER_MSG" ]; then
    # Code block exclusion is only safe when fence pairs are balanced. An unclosed
    # fence (odd fence count) would make the awk toggle consume everything after the
    # opening fence and silently drop a real charter pattern. Count fences first; if
    # odd, fall back to the raw message.
    CHARTER_FENCE_COUNT=$(grep -c '^[[:space:]]*```' <<< "$CHARTER_MSG" 2>/dev/null) || CHARTER_FENCE_COUNT=0
    if [ $((CHARTER_FENCE_COUNT % 2)) -eq 0 ]; then
      CHARTER_MSG_STRIPPED=$(awk '
        BEGIN { in_block = 0 }
        /^[[:space:]]*```/ { in_block = !in_block; next }
        !in_block { print }
      ' <<< "$CHARTER_MSG") || CHARTER_MSG_STRIPPED="$CHARTER_MSG"
    else
      CHARTER_MSG_STRIPPED="$CHARTER_MSG"
    fi

    CHARTER_HIT=""
    if [[ "$CHARTER_MSG_STRIPPED" =~ verified-review[[:space:]]+cycle ]]; then
      CHARTER_HIT="verified-review cycle"
    elif [[ "$CHARTER_MSG_STRIPPED" =~ cycle[[:space:]]+[0-9]+ ]]; then
      CHARTER_HIT="cycle [0-9]+"
    elif [[ "$CHARTER_MSG_STRIPPED" =~ Issue[[:space:]]+#[0-9]+[[:space:]]+で.*対応 ]]; then
      CHARTER_HIT="Issue #[0-9]+ で.*対応"
    fi

    if [ -n "$CHARTER_HIT" ]; then
      STRICT_MODE="${RITE_COMMIT_LINT_STRICT:-false}"
      case "$STRICT_MODE" in
        true|yes|1|TRUE|YES) STRICT_MODE="true" ;;
        *) STRICT_MODE="false" ;;
      esac

      if [ "$STRICT_MODE" = "true" ]; then
        echo "[charter-lint] BLOCK: commit message contains charter-forbidden pattern: $CHARTER_HIT" >&2
        echo "[charter-lint] See: plugins/rite/skills/rite-workflow/references/simplification-charter.md" >&2
        # jq must succeed; if it fails the script's `set -e` + `trap 'exit 0' ERR` would
        # silently downgrade the BLOCK to allow. Force fail-closed by emitting a minimal
        # JSON deny inline and exiting 2 explicitly.
        if ! jq -n --arg reason "BLOCKED (commit-msg-charter-violation): commit message contains charter-forbidden pattern: $CHARTER_HIT. Rewrite without literal cycle numbers / Issue references / verified-review cycle text. See plugins/rite/skills/rite-workflow/references/simplification-charter.md." \
          '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'; then
          echo "[charter-lint] FATAL: jq invocation failed; emitting fallback deny" >&2
          printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (commit-msg-charter-violation): jq unavailable; failing closed."}}\n'
        fi
        exit 2
      else
        echo "[charter-lint] WARN: commit message contains charter-forbidden pattern: $CHARTER_HIT" >&2
        echo "[charter-lint] See: plugins/rite/skills/rite-workflow/references/simplification-charter.md" >&2
        echo "[charter-lint] Set RITE_COMMIT_LINT_STRICT=true to block this commit." >&2
      fi
    fi
  fi
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
# allow because the Patterns 1-3 ERR trap is no longer active (Pattern 5 released
# it). Fall back to a literal JSON envelope + exit 2 so the deny is fail-closed.
_deny_reason="BLOCKED ($BLOCKED_PATTERN): $BLOCKED_REASON $BLOCKED_ALTERNATIVE"
if ! jq -n --arg reason "$_deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'; then
  _deny_reason_escaped="${_deny_reason//\\/\\\\}"
  _deny_reason_escaped="${_deny_reason_escaped//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$_deny_reason_escaped"
  exit 2
fi
