#!/bin/bash
# rite workflow - Pre-Tool Bash Guard (PreToolUse hook)
# Blocks known-bad Bash command patterns before execution.
# Uses only Bash built-ins for pattern matching (no external processes).
#
# Denylist patterns:
#   1. gh pr diff --stat  (unsupported flag)
#   2. gh pr diff -- <path>  (unsupported file filter)
#   3. != null in jq/awk  (history expansion breaks !)
#   4. Reviewer subagent running state-mutating git commands (Issue #442)
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
# silent-failure-hunter M-7: 旧 `... 2>/dev/null || true` は source 失敗を完全 silent suppress していた。
# flow-state-update.sh IMP-4 (L62-71) の WARNING emit pattern と writer/reader/caller 3 層対称化。
_hook_preamble_err=$(mktemp /tmp/rite-pretool-preamble-err-XXXXXX 2>/dev/null) || _hook_preamble_err=""
if ! source "$SCRIPT_DIR/hook-preamble.sh" 2>"${_hook_preamble_err:-/dev/null}"; then
  echo "WARNING: pre-tool-bash-guard: source hook-preamble.sh が失敗 (deploy regression / syntax error / permission?)" >&2
  if [ -n "$_hook_preamble_err" ] && [ -s "$_hook_preamble_err" ]; then
    head -3 "$_hook_preamble_err" | sed 's/^/  /' >&2
  fi
fi
[ -n "$_hook_preamble_err" ] && rm -f "$_hook_preamble_err"
# Single source of truth for create_* lifecycle phase names (#501 HIGH).
# Provides rite_phase_is_create_lifecycle_in_progress() used by Pattern 5.
_phase_whitelist_err=$(mktemp /tmp/rite-pretool-whitelist-err-XXXXXX 2>/dev/null) || _phase_whitelist_err=""
if ! source "$SCRIPT_DIR/phase-transition-whitelist.sh" 2>"${_phase_whitelist_err:-/dev/null}"; then
  echo "WARNING: pre-tool-bash-guard: source phase-transition-whitelist.sh が失敗 (helper deploy regression)" >&2
  if [ -n "$_phase_whitelist_err" ] && [ -s "$_phase_whitelist_err" ]; then
    head -3 "$_phase_whitelist_err" | sed 's/^/  /' >&2
  fi
  echo "  影響: Pattern 5 の lifecycle predicate (rite_phase_is_create_lifecycle_in_progress) が inline glob fallback に倒れる" >&2
fi
[ -n "$_phase_whitelist_err" ] && rm -f "$_phase_whitelist_err"

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# silent-failure-hunter M-6: 旧 `... 2>/dev/null || VAR=""` は malformed JSON (Claude Code bug /
# partial flush) を silent suppress していた。攻撃面となる可能性があるため `[ -n "$INPUT" ] && [ -z "$VAR" ]`
# で「INPUT は来たが parse 不能」状態を WARNING emit + 明示的 allow + audit-trail にする。
# Only inspect Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ -n "$INPUT" ] && [ -z "$TOOL_NAME" ]; then
  echo "WARNING: pre-tool-bash-guard: INPUT は非空だが tool_name が parse できません (malformed JSON?)" >&2
fi
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
if [ -n "$INPUT" ] && [ -z "$COMMAND" ]; then
  echo "WARNING: pre-tool-bash-guard: INPUT は非空だが tool_input.command が parse できません (malformed JSON?)" >&2
fi
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Reviewer subagent detection (Issue #442).
# Claude Code routes subagent sessions to jsonl files under a "subagents/"
# directory inside the project transcript root; the main session does not.
# When the PreToolUse hook runs inside a subagent, transcript_path therefore
# contains the "/subagents/" path component. Pattern 4 below uses this as a
# heuristic to scope state-mutating git denylist checks to reviewer contexts.
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT_PATH=""
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac

# --- Fail-open for pattern matching stage (scope-limited) ---
# If heredoc extraction or pattern matching crashes (e.g., edge-case failures with
# large multiline input), allow the command rather than blocking it.
# Placed after JSON parsing (which has its own || fallbacks) to preserve
# error detection for malformed hook input (TC-016).
#
# ⚠️ Scope: ERR trap covers Pattern 1-3 (regex case match) and Pattern 5
# (gh issue create lifecycle detection). It is **explicitly disarmed** after
# Pattern 5 (`trap - ERR` below) so that Pattern 4 (reviewer git denylist)
# and charter-lint strict block exit with fail-closed semantics. Without
# this disarm, the strict-mode `exit 2` BLOCK at L539 could be silently
# downgraded to exit 0 by any failing command in the trap scope (charter-lint
# `if ! jq ... ; then printf fallback; fi; exit 2` defends against this for
# the BLOCK path, but the disarm provides defense-in-depth for the entire
# strict-mode branch).
trap 'exit 0' ERR

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
if [ -z "$BLOCKED_PATTERN" ]; then
  if [[ "$CMD_CHECK" =~ gh[[:space:]]+pr[[:space:]]+diff[[:space:]]+[^|]+[[:space:]]--[[:space:]] ]]; then
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

# Pattern 5: gh issue create direct invocation during /rite:issue:create lifecycle (#475 Mode B).
# The orchestrator (create.md) must delegate Issue creation to rite:issue:create-register or
# rite:issue:create-decompose sub-skills. A direct `gh issue create` call bypasses the entire
# sub-skill delegation protocol, flow-state tracking, and Projects integration.
#
# Detection: .rite-flow-state must exist AND be active AND the phase must be create_interview /
# create_post_interview / create_delegation / create_post_delegation (i.e., create lifecycle is
# in progress but not yet terminated by create_completed).
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
      # silent-failure-hunter M-8: 旧 `... 2>/dev/null || STATE_ROOT_PATH="$CWD"` は stderr 完全捨て +
      # silent CWD fallback。state-path-resolve.sh が deploy regression で失敗した場合、Mode B AND-logic が
      # 誤った state file を読みに行く可能性がある (HIGH-5 と同根の observability gap)。
      _state_path_err=$(mktemp /tmp/rite-pretool-state-path-err-XXXXXX 2>/dev/null) || _state_path_err=""
      if ! STATE_ROOT_PATH=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>"${_state_path_err:-/dev/null}"); then
        echo "WARNING: pre-tool-bash-guard: state-path-resolve.sh 失敗、CWD fallback に倒します ($CWD)" >&2
        if [ -n "$_state_path_err" ] && [ -s "$_state_path_err" ]; then
          head -3 "$_state_path_err" | sed 's/^/  /' >&2
        fi
        echo "  影響: schema_version=2 環境で Mode B AND-logic が誤った state file を参照する可能性" >&2
        STATE_ROOT_PATH="$CWD"
      fi
      [ -n "$_state_path_err" ] && rm -f "$_state_path_err"
    fi
    # State file lookup: if $STATE_ROOT_PATH is empty (e.g., CWD outside git repo and
    # state-path-resolve.sh failed), skip the check entirely — no state file means no
    # create lifecycle to enforce, which is the documented "allow" path.
    #
    # Per-session state path resolution (Issue #681): _resolve-flow-state-path.sh
    # returns the per-session file (`<root>/.rite/sessions/<session_id>.flow-state`)
    # when schema_version=2 with a valid SID, or the legacy `.rite-flow-state` path
    # otherwise. This keeps Pattern 5 working under both schemas without inlining
    # schema/SID resolution here. Mode B AND-logic (.active=true && phase=create_*)
    # below operates on whichever file the resolver returns.
    if [ -n "$STATE_ROOT_PATH" ]; then
      _resolver_err=$(mktemp /tmp/rite-pretool-resolver-err-XXXXXX 2>/dev/null) || _resolver_err=""
      if STATE_FILE_PATH=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT_PATH" 2>"${_resolver_err:-/dev/null}"); then
        :
      else
        # HIGH-5 修正: 旧実装は `[ -n "${RITE_DEBUG:-}" ]` gate で production 環境では完全 silent。
        # helper deploy regression で resolver が失敗し続けた場合、schema_version=2 環境で legacy path
        # に書き続ける silent state drift (Issue #681 F-01) を observability gap として残していた。
        # gate を撤廃し常時 WARNING emit + debug log への append で observability を確保する。
        echo "WARNING: pre-tool-bash-guard: _resolve-flow-state-path.sh が失敗、legacy path に fallback します" >&2
        if [ -n "$_resolver_err" ] && [ -s "$_resolver_err" ]; then
          head -3 "$_resolver_err" | sed 's/^/  /' >&2
        fi
        echo "  影響: schema_version=2 環境では legacy `.rite-flow-state` に書き込まれ Mode B AND-logic が誤動作する可能性" >&2
        # debug log への append は best-effort (audit-trail として残す)
        if ! echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] pre-tool-bash-guard: _resolve-flow-state-path.sh failed, falling back to legacy path" \
          >> "$STATE_ROOT_PATH/.rite-flow-debug.log" 2>/dev/null; then
          : # debug log 書き込み失敗は WARNING 既出のため silent skip
        fi
        STATE_FILE_PATH="${STATE_ROOT_PATH}/.rite-flow-state"
      fi
      [ -n "$_resolver_err" ] && rm -f "$_resolver_err"
      if [ -f "$STATE_FILE_PATH" ]; then
        # silent failure 防止: 旧 `|| STATE_*=""` は jq 失敗時に Pattern 5 全体を silent skip させ、
        # state file 破損時に `gh issue create` 直叩きを silent allow する経路を作っていた。
        # flow-state-update.sh writer の jq stderr 退避 doctrine と対称化して fail-fast にする。
        _state_jq_err=$(mktemp /tmp/rite-pretool-state-jq-err-XXXXXX 2>/dev/null) || _state_jq_err=""
        if ! STATE_PHASE=$(jq -r '.phase // empty' "$STATE_FILE_PATH" 2>"${_state_jq_err:-/dev/null}"); then
          echo "WARNING: pre-tool-bash-guard: jq .phase 抽出失敗 ($STATE_FILE_PATH)" >&2
          [ -n "$_state_jq_err" ] && [ -s "$_state_jq_err" ] && head -3 "$_state_jq_err" | sed 's/^/  /' >&2
          STATE_PHASE=""
        fi
        [ -n "$_state_jq_err" ] && : > "$_state_jq_err"  # truncate before reuse
        if ! STATE_ACTIVE=$(jq -r '.active // false' "$STATE_FILE_PATH" 2>"${_state_jq_err:-/dev/null}"); then
          echo "WARNING: pre-tool-bash-guard: jq .active 抽出失敗 ($STATE_FILE_PATH)" >&2
          [ -n "$_state_jq_err" ] && [ -s "$_state_jq_err" ] && head -3 "$_state_jq_err" | sed 's/^/  /' >&2
          STATE_ACTIVE="false"
        fi
        [ -n "$_state_jq_err" ] && rm -f "$_state_jq_err"
        # Use query function from phase-transition-whitelist.sh as the single source of truth
        # for create_* lifecycle phase names. Fall back to inline glob check when the helper
        # is unavailable (e.g., bash < 4.2 where phase-transition-whitelist.sh exits early).
        if [ "$STATE_ACTIVE" = "true" ]; then
          # >>> DRIFT-CHECK ANCHOR: lifecycle_predicate_pattern_5 <<<
          # phase-transition-whitelist.sh の lifecycle predicate を runtime 参照する箇所。
          # create-interview.md などの docs はこの anchor 名で cite する (行番号 drift 回避)。
          if type rite_phase_is_create_lifecycle_in_progress >/dev/null 2>&1; then
            if rite_phase_is_create_lifecycle_in_progress "$STATE_PHASE"; then
              BLOCKED_PATTERN="create-lifecycle-direct-gh-issue"
            fi
          elif [[ "$STATE_PHASE" == create_* ]] && [ "$STATE_PHASE" != "create_completed" ]; then
            BLOCKED_PATTERN="create-lifecycle-direct-gh-issue"
          fi
          if [ "$BLOCKED_PATTERN" = "create-lifecycle-direct-gh-issue" ]; then
            BLOCKED_REASON="/rite:issue:create lifecycle 中 (phase=$STATE_PHASE) に gh issue create を直接実行することは禁止されています (#475 Mode B)."
            BLOCKED_ALTERNATIVE="rite:issue:create-register を呼ぶべき場面です。Phase 0.6 の Delegation Routing に従い skill: \"rite:issue:create-register\" または skill: \"rite:issue:create-decompose\" を invoke してください。"
          fi
        fi
      fi
    fi
  fi
fi

# >>> DRIFT-CHECK ANCHOR: err_trap_disarm_after_pattern5 <<<
# Pattern 5 終了。ここで ERR trap を解除し、Pattern 4 (reviewer git denylist) と
# charter-lint strict block を fail-closed にする。
trap - ERR

# Pattern 4: Reviewer subagent running state-mutating git commands (Issue #442).
# Scope: only when IS_SUBAGENT=1 (transcript_path contains "/subagents/").
# Main-session git operations (branch switch, commit, etc. performed by
# /rite:issue:start Phase 5.1) are NOT affected because IS_SUBAGENT=0 there.
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
  # Collapse multiple spaces into one.
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  PADDED=" $CMD_NORMALIZED "

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

  # --- (E) Sub-action precision: git worktree remove/prune only ---
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git worktree remove"*|\
      *" git worktree prune"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (F) Sub-action precision: git fetch (bare allowed, --prune/--force denied) ---
  # CRITICAL: `-p` / `-f` must be matched as **standalone flag tokens**, not as
  # substrings inside branch names like `hot-fix` / `release-patch` /
  # `v1.0-rc-final` / `main-pipeline` (cycle 2 HIGH regression).
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
    BLOCKED_ALTERNATIVE="Use read-only alternatives: 'git show <ref>:<file>' to read a blob, 'git diff <ref> -- <file>' to compare, 'git worktree add <path> <ref>' to inspect a different ref in an isolated directory, 'git tag -l' / 'git stash list' / 'git reflog' / 'git branch --list' for display-only queries, or bare 'git fetch' (without --prune/--force) for ref sync. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the full list."
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
        # HIGH-6 修正: 旧実装 `cat ... 2>/dev/null || CHARTER_MSG=""` は I/O error (EACCES /
        # EBADF / FIFO timeout 等) を完全 silent suppress していた。CHARTER_MSG="" になると
        # 後段の `[ -n "$CHARTER_MSG" ]` で false 判定され charter check が silent skip し、
        # I/O error と「lint passed」が区別不能だった。stderr 退避 + 失敗時 WARNING + skip に変更。
        _cat_err=$(mktemp /tmp/rite-pretool-cat-err-XXXXXX 2>/dev/null) || _cat_err=""
        if ! CHARTER_MSG=$(cat "$CHARTER_FILE" 2>"${_cat_err:-/dev/null}"); then
          echo "[charter-lint] WARN: -F file の cat に失敗: $CHARTER_FILE (charter check skipped)" >&2
          if [ -n "$_cat_err" ] && [ -s "$_cat_err" ]; then
            head -3 "$_cat_err" | sed 's/^/  /' >&2
          fi
          CHARTER_MSG=""
          CHARTER_CHECK=0
        fi
        [ -n "$_cat_err" ] && rm -f "$_cat_err"
      else
        echo "[charter-lint] WARN: -F file path unresolvable: $CHARTER_FILE (charter check skipped)" >&2
        CHARTER_CHECK=0
      fi
    else
      CHARTER_CHECK=0
    fi
  fi

  if [ "$CHARTER_CHECK" = "1" ] && [ -n "$CHARTER_MSG" ]; then
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
        # Defense-in-depth: ERR trap は Pattern 5 終了直後の `trap - ERR` で解除済みのため、
        # jq 失敗が ERR trap 経由で silent allow に倒れる経路は構造的に閉じている。
        # 以下の `if !; ... fi; exit 2` パターンは、ERR trap disarm が将来 regression で
        # 後退した場合の defense-in-depth として残す (BLOCK の fail-closed semantics を二重保証)。
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

# Deny with reason and alternative
jq -n \
  --arg reason "BLOCKED ($BLOCKED_PATTERN): $BLOCKED_REASON $BLOCKED_ALTERNATIVE" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
