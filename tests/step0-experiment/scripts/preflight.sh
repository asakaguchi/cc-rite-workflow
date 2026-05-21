#!/usr/bin/env bash
# Step 0 experiment preflight check.
# Verifies the controlled environment before any trial runs (Plan §20.12).
#
# Exit codes:
#   0  — environment is locked; trials may proceed
#   1  — usage error
#   2  — environment mismatch (marketplace cache override, wrong plugin root, dirty git)
#
# Output: structured key=value lines on stdout. Human-readable diagnostics on stderr.

set -uo pipefail

EXPECTED_PLUGIN_ROOT="${EXPECTED_PLUGIN_ROOT:-/home/akiyoshi/Projects/personal/cc-rite-workflow}"

fail() {
  echo "FAIL: $1" >&2
  echo "preflight_ok=false"
  exit 2
}

warn() {
  echo "WARN: $1" >&2
}

# 1. Settings.json marketplace check
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
  warn "settings.json not found at $SETTINGS_FILE — cannot verify marketplace state"
  marketplace_status="unknown"
else
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not installed — falling back to grep"
    if grep -q '"rite@rite-marketplace":[[:space:]]*true' "$SETTINGS_FILE"; then
      fail "rite@rite-marketplace is TRUE in settings.json. This causes stale marketplace plugin to shadow local changes. Set it to false."
    fi
    marketplace_status="grep_check_passed"
  else
    # NOTE: cannot use `// "absent"` because jq treats `false` as falsy and
    # falls through to the alternative, masking the explicit `false` value.
    rite_mp=$(jq -r 'if (.enabledPlugins | has("rite@rite-marketplace")) then (.enabledPlugins["rite@rite-marketplace"] | tostring) else "absent" end' "$SETTINGS_FILE" 2>/dev/null)
    if [ "$rite_mp" = "true" ]; then
      fail "rite@rite-marketplace=true in settings.json. Per CLAUDE.md this shadows local changes. Set to false."
    fi
    marketplace_status="ok (rite@rite-marketplace=$rite_mp)"
  fi
fi
echo "marketplace=$marketplace_status"

# 2. CWD == expected plugin root
ACTUAL_CWD="$(pwd)"
if [ "$ACTUAL_CWD" != "$EXPECTED_PLUGIN_ROOT" ]; then
  fail "CWD=$ACTUAL_CWD does not match EXPECTED_PLUGIN_ROOT=$EXPECTED_PLUGIN_ROOT. Run preflight from the plugin root."
fi
echo "plugin_root=$EXPECTED_PLUGIN_ROOT"

# 3. Git presence + state
if ! command -v git >/dev/null 2>&1; then
  fail "git not installed"
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "not a git repository: $(pwd)"
fi
GIT_HEAD=$(git rev-parse HEAD)
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "git_head=$GIT_HEAD"
echo "git_branch=$GIT_BRANCH"

# Warn (not fail) on uncommitted changes — operator may have intentional edits
if ! git diff --quiet || ! git diff --cached --quiet; then
  warn "uncommitted changes detected. Trials may not reflect the recorded git_head."
  echo "git_dirty=true"
else
  echo "git_dirty=false"
fi

# 4. Required CLI versions
if command -v claude >/dev/null 2>&1; then
  CC_VERSION=$(claude --version 2>/dev/null | head -1)
  echo "claude_cli=$CC_VERSION"
else
  warn "claude CLI not on PATH — version cannot be recorded"
  echo "claude_cli=unknown"
fi

# 5. Bash version (Plan §20.3 requires 4.2+)
BASH_VER="$BASH_VERSION"
BASH_MAJOR="${BASH_VER%%.*}"
if [ "$BASH_MAJOR" -lt 4 ]; then
  fail "Bash $BASH_VER detected; Plan §20.3 requires 4.2+. On macOS, brew install bash."
fi
echo "bash_version=$BASH_VER"

# 6. Plugin fixture files present
REQUIRED=(
  "plugins/rite/commands/test/step0/a-orchestrator.md"
  "plugins/rite/commands/test/step0/a-subskill.md"
  "plugins/rite/commands/test/step0/b-orchestrator.md"
  "plugins/rite/commands/test/step0/c-orchestrator.md"
  "plugins/rite/commands/test/step0/d-orchestrator.md"
  "plugins/rite/commands/test/step0/e-orchestrator.md"
  "plugins/rite/agents/test-step0-b.md"
  "plugins/rite/agents/test-step0-e.md"
  "plugins/rite/scripts/test/step0-worker.sh"
)
missing=0
for f in "${REQUIRED[@]}"; do
  if [ ! -f "$f" ]; then
    warn "missing fixture: $f"
    missing=1
  fi
done
[ "$missing" = 0 ] || fail "step 0 fixtures incomplete; aborting"
echo "fixtures=ok"

echo "preflight_ok=true"
