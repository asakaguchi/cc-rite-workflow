#!/bin/bash
# rite workflow - Pre-Tool Edit Guard (PreToolUse hook)
# Blocks reviewer subagents from mutating the parent working tree via the
# Edit / Write / MultiEdit / NotebookEdit tools.
#
# Why this exists (Issue #1860):
#   The sibling `pre-tool-bash-guard.sh` Pattern 4 only blocks state-mutating
#   *git* commands issued through the Bash tool — it does nothing about a
#   reviewer subagent that opens `Edit`/`Write` on a source file in the parent
#   working tree (observed in production: a reviewer edited an implementation
#   file in-place to run a mutation test, then hand-restored it). The prose ban
#   in `agents/_reviewer-base.md` alone does not stop LLM agents. This hook is
#   the structural enforcement layer for the Edit/Write side.
#
# Scope (all three must hold to deny):
#   1. tool_name ∈ {Edit, Write, MultiEdit, NotebookEdit}
#   2. subagent context (reviewer) — same 3-tier detection as pre-tool-bash-guard.sh
#   3. target path is inside the parent repo working tree AND NOT inside a
#      sanctioned reviewer isolation worktree (`rite-review-mutation-*` /
#      `rite-revert-test-*` under $TMPDIR). The isolation allowlist is checked
#      FIRST because a reviewer cd's into the mutation dir, so the repo-internal
#      check would otherwise false-deny legitimate worktree-only mutation testing
#      (AC-4). MultiEdit is included even though Issue #1860's Technical Notes
#      list only {Edit, Write, NotebookEdit}: MultiEdit mutates files identically
#      and omitting it would be a trivial bypass of a security boundary.
#
# Fail direction (mirrors pre-tool-bash-guard.sh Pattern 4):
#   - A crash BEFORE scope (subagent + repo-internal + non-isolation) is confirmed
#     fails OPEN (exit 0 = allow) so a main-session Edit is never false-blocked.
#   - A crash AFTER scope is confirmed fails CLOSED (deny + exit 2) so a single
#     parse crash never silently bypasses the reviewer read-only guard.
#
# Exit behavior:
#   exit 0 — allow (no output)
#   stdout JSON with permissionDecision: "deny" — block
#
# hooks.json timeout: registered as PreToolUse (matcher Edit|Write|MultiEdit|
# NotebookEdit) with a 10s timeout — a fast synchronous gate using bash built-ins
# plus a couple of jq calls, aligned with the sibling lightweight gates.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration parity with
# pre-tool-bash-guard.sh's _RITE_HOOK_RUNNING_PRETOOL, but a distinct var so the
# two PreToolUse hooks never suppress each other).
[ -z "${_RITE_HOOK_RUNNING_PRETOOL_EDIT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL_EDIT=1

# Hook version resolution preamble (before INPUT=$(cat) to preserve stdin).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# Fail-OPEN ERR trap (default): any unexpected crash before scope is confirmed
# allows the tool rather than blocking it. Swapped to fail-CLOSED once the deny
# scope is confirmed (below), mirroring pre-tool-bash-guard.sh Pattern 4.
_rite_teg_fail_open() {
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-edit-guard: ERR trap fired before scope confirmed — allowed via fail-open\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  exit 0
}
_rite_teg_fail_closed() {
  local _rc=$?
  trap - ERR  # prevent re-entrancy while emitting the deny
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] pre-tool-edit-guard: WARNING deny-emit crashed (rc=$_rc) — DENIED via fail-closed" >&2
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (reviewer-edit-parent-tree): scope confirmed but deny-emit crashed; denying fail-closed to avoid bypassing the reviewer read-only guard."}}\n'
  exit 2
}
trap '_rite_teg_fail_open' ERR

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Only inspect the mutating file tools. Non-matching tools (the harness matcher
# should already pre-filter, but this defense-in-depth check survives matcher drift).
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Extract target path (Edit/Write/MultiEdit use .tool_input.file_path;
# NotebookEdit uses .tool_input.notebook_path) and cwd in a single jq spawn.
JQ_OUT=$(echo "$INPUT" | jq -r '[((.tool_input.file_path // .tool_input.notebook_path) // ""), (.cwd // "")] | @tsv' 2>/dev/null) || JQ_OUT=$'\t'
FILE_PATH=$(printf '%s' "$JQ_OUT" | cut -f1)
CWD=$(printf '%s' "$JQ_OUT" | cut -f2)
# No target path → cannot scope the write to the repo; allow (fail-open). A real
# Edit/Write always carries a path, so this only trips on a malformed envelope.
[ -n "$FILE_PATH" ] || exit 0

# --- Reviewer subagent detection (3-tier) ---
# The detection LOGIC (the 3 tiers below) is the canonical copy from
# pre-tool-bash-guard.sh (Pattern 4) and is kept in sync with it: an intentional
# defense-in-depth duplication (a shared lib used by only two hooks would force a
# risky refactor of the heavily-pinned bash-guard). Observability differs by design:
# the sibling wraps this jq with a RITE_DEBUG stderr-capture because it is the first
# jq to touch INPUT there; here two prior jq calls (tool_name, file/notebook path)
# have already parsed the same INPUT, so a parse failure at this third jq is
# unreachable — the `|| JQ_SA=$'\t\t'` fallback is a formality, not a live silent-bypass
# path, and needs no debug logging.
#   Tier 1 (primary):  transcript_path glob `*/subagents/*` — current Claude Code
#                      convention routing subagent sessions under a subagents/ dir.
#   Tier 2 (fallback): hook input JSON `subagent_type` / `agent_type` STRING field
#                      (numeric/array/object rejected via `| strings`).
#   Tier 3 (fallback): env vars CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE (presence-only).
# Forward-compat caveat: presence-only fires on any non-empty string; if a future
# SDK emits sentinel values like "main"/"none" on main-session hooks this would
# false-positive — upgrade to an allow-list glob (e.g. `*-reviewer`) at that point.
JQ_SA=$(echo "$INPUT" | jq -r '[(.transcript_path // ""), (.subagent_type | strings // ""), (.agent_type | strings // "")] | @tsv' 2>/dev/null) || JQ_SA=$'\t\t'
TRANSCRIPT_PATH=$(printf '%s' "$JQ_SA" | cut -f1)
INPUT_SUBAGENT_TYPE=$(printf '%s' "$JQ_SA" | cut -f2)
INPUT_AGENT_TYPE=$(printf '%s' "$JQ_SA" | cut -f3)
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac
if [ "$IS_SUBAGENT" = "0" ] && { [ -n "$INPUT_SUBAGENT_TYPE" ] || [ -n "$INPUT_AGENT_TYPE" ]; }; then
  IS_SUBAGENT=1
fi
if [ "$IS_SUBAGENT" = "0" ] && { [ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; }; then
  IS_SUBAGENT=1
fi
# Main session (not a reviewer subagent) → never blocked. This is the primary
# guarantee that /rite:open → implement.md Edit/Write is unaffected (AC-4).
[ "$IS_SUBAGENT" = "1" ] || exit 0

# --- Absolute path resolution (join relative against cwd; do NOT collapse `..` lexically) ---
# `..` is resolved PHYSICALLY by `git -C` / `[ -d ]` below, never by string munging. A lexical
# collapse (or a raw substring match) would let a reviewer forge an isolation path —
# `<repo>/rite-review-mutation-x/../plugins/rite/hooks.json` re-enters a tracked file, and
# `<repo>/src/rite-review-mutation-hack.py` embeds the token in a filename — both empirically
# bypassed the old substring allowlist (Issue #1860 review cycle 1).
case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *)  ABS_PATH="${CWD%/}/$FILE_PATH" ;;
esac

# --- Resolve the git worktree that OWNS the target ---
# The isolation allowance is defined by "the target lives inside a sanctioned reviewer isolation
# worktree", NOT by "the path string contains the token". Resolve the target's own worktree by
# walking up to its nearest EXISTING ancestor, then asking git. `[ -d ]` and `git -C` both chdir
# and resolve `..` physically, so a path carrying a non-existent `..` segment lands on the real
# parent repo (→ deny), not on a forged isolation dir. Walking to the nearest existing ancestor
# also covers a brand-new file in a not-yet-created dir (the ancestor still resolves to the repo).
_tdir=$(dirname "$ABS_PATH")
while [ -n "$_tdir" ] && [ "$_tdir" != "/" ] && [ ! -d "$_tdir" ]; do
  _tdir=$(dirname "$_tdir")
done
[ -d "$_tdir" ] || _tdir="${CWD:-.}"
# git -C chdir's to the resolved ancestor and reports the worktree toplevel that owns it.
TARGET_ROOT=$(git -C "$_tdir" rev-parse --show-toplevel 2>/dev/null) || TARGET_ROOT=""
# Target is not inside any git repo (e.g. /tmp scratch) → cannot be the parent working tree →
# allow (fail-open; scope not confirmed).
[ -n "$TARGET_ROOT" ] || exit 0
TARGET_ROOT="${TARGET_ROOT%/}"

# --- Isolation allowance: the target's OWN worktree is a sanctioned isolation worktree ---
# Reviewers legitimately run mutation experiments in a detached worktree created via
# `mktemp -d -t rite-review-mutation-XXXXXX` + `git worktree add --detach` (or the
# `rite-revert-test-*` sibling namespace — same prefixes swept by pr-cycle-cleanup.sh Step 4).
# Matching on TARGET_ROOT (the target's resolved worktree root), not the raw path, means only a
# genuine isolation worktree is allowed — closing the substring / `..` re-entry bypass.
case "$TARGET_ROOT" in
  */rite-review-mutation-*|*/rite-revert-test-*) exit 0 ;;
esac

# --- Scope confirmed: subagent + target inside a non-isolation (parent) working tree → DENY ---
# Swap to the fail-CLOSED trap so any crash from here on denies rather than allows.
trap '_rite_teg_fail_closed' ERR

# Log block event (stderr, for effect measurement) — mirror bash-guard's format.
PATH_SUMMARY="${ABS_PATH:0:120}"
PATH_SUMMARY="${PATH_SUMMARY//\"/\\\"}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] edit-guard: BLOCKED tool=$TOOL_NAME path=\"$PATH_SUMMARY\"" >&2

_deny_reason="BLOCKED (reviewer-edit-parent-tree): Reviewer subagents must not mutate the parent working tree. The ${TOOL_NAME} tool targeted '${ABS_PATH}', which resolves inside the repository working tree (${TARGET_ROOT}). Reviewers are strictly read-only — inspect files with Read/Grep and compare historical content with 'git show <ref>:<file>'. If you need a mutation/verification experiment, do it in an isolated detached worktree under \$TMPDIR: 'git worktree add --detach \$(mktemp -d -t rite-review-mutation-XXXXXX) HEAD' and edit files THERE (a real worktree whose root is named rite-review-mutation-* / rite-revert-test-* is allowed). See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement / Mutation experiments)."
# jq is required to emit the permission payload; an intermittent jq failure would
# silently downgrade the deny to allow, so the fail-CLOSED trap catches a crash
# here and emits a static deny + exit 2.
jq -n --arg reason "$_deny_reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
