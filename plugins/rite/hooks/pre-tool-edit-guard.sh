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
# CANONICAL COPY lives in pre-tool-bash-guard.sh (Pattern 4). Keep the two in
# sync: this is an intentional defense-in-depth duplication (a shared lib used by
# only two hooks would force a risky refactor of the heavily-pinned bash-guard).
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

# --- Absolute path resolution (naive join; no symlink/`..` canonicalization) ---
# A relative file_path is resolved against the tool's cwd. `..` escapes are not
# normalized here: an adversarial `..`-laden path simply won't match the repo
# prefix below and falls OPEN — the post-condition axis (post-review-state-verify.sh
# worktree hash) still catches the resulting dirty tree (defense-in-depth).
case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *)  ABS_PATH="${CWD%/}/$FILE_PATH" ;;
esac

# --- Isolation allowlist (checked BEFORE repo-internal — AC-4 critical) ---
# Reviewers legitimately cd into a detached mutation worktree created via
# `mktemp -d -t rite-review-mutation-XXXXXX` / `rite-revert-test-*` under $TMPDIR
# (see agents/_reviewer-base.md "Mutation experiments"). Because the reviewer cd's
# INTO that dir, `git -C "$cwd" rev-parse --show-toplevel` returns the mutation
# dir itself, so the repo-internal check below would false-deny a legitimate
# in-worktree edit. Short-circuit to allow when the target is under a sanctioned
# reviewer isolation prefix. (Namespace source of truth: the same prefixes swept
# by hooks/scripts/pr-cycle-cleanup.sh Step 4.)
case "$ABS_PATH" in
  */rite-review-mutation-*|*/rite-revert-test-*) exit 0 ;;
esac

# --- Repo-internal check ---
# Resolve the parent working tree root from the tool cwd. If git can't resolve a
# toplevel (not a repo), we cannot confirm the write is repo-internal → allow
# (fail-open; scope not confirmed).
REPO_ROOT=$(git -C "${CWD:-.}" rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
[ -n "$REPO_ROOT" ] || exit 0
REPO_ROOT="${REPO_ROOT%/}"

# Deny only when the absolute target path is under the repo root.
case "$ABS_PATH" in
  "$REPO_ROOT"/*) ;;   # inside the parent working tree → fall through to deny
  *) exit 0 ;;         # outside the repo (e.g. /tmp scratch) → allow
esac

# --- Scope confirmed: subagent + repo-internal + non-isolation → DENY ---
# Swap to the fail-CLOSED trap so any crash from here on denies rather than allows.
trap '_rite_teg_fail_closed' ERR

# Log block event (stderr, for effect measurement) — mirror bash-guard's format.
PATH_SUMMARY="${ABS_PATH:0:120}"
PATH_SUMMARY="${PATH_SUMMARY//\"/\\\"}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] edit-guard: BLOCKED tool=$TOOL_NAME path=\"$PATH_SUMMARY\"" >&2

_deny_reason="BLOCKED (reviewer-edit-parent-tree): Reviewer subagents must not mutate the parent working tree. The ${TOOL_NAME} tool targeted '${ABS_PATH}', which is inside the repository working tree (${REPO_ROOT}). Reviewers are strictly read-only — inspect files with Read/Grep and compare historical content with 'git show <ref>:<file>'. If you need a mutation/verification experiment, do it in an isolated detached worktree under \$TMPDIR: 'git worktree add --detach \$(mktemp -d -t rite-review-mutation-XXXXXX) HEAD' and edit files THERE (paths under rite-review-mutation-* / rite-revert-test-* are allowed). See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement / Mutation experiments)."
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
