#!/bin/bash
# rite workflow - PR review-fix cycle branch cleanup (idempotent)
#
# Responsibility: remove residual `pr-{N}-cycle{X}` worktrees and branches
# that leak after reviewer subagent `git worktree add` invocations. The
# reviewer's READ-ONLY contract forbids `git worktree remove` / `git branch -D`,
# so cleanup MUST run from the orchestrator side.
#
# Strict regex `^pr-[0-9]+-cycle[0-9]+$` protects unrelated branches
# (e.g. `pr-918-cycle4-feature`, `feature/pr-918-cycle4`) from accidental
# deletion. The wiki worktree (`.rite/wiki-worktree`) is excluded
# unconditionally — see commands/pr/cleanup.md §2.6.
#
# Usage:
#   bash pr-cycle-cleanup.sh [--dry-run]
#
# Output (stdout): one structured status line per invocation
#   [pr-cycle-cleanup] status=<cleaned|noop|failed>; worktrees=<N>; branches=<N>
#
# Exit codes:
#   0  cleanup completed (or nothing to clean)
#   1  environment error (not in a git repository)
#
# Notes:
#   - Idempotent: re-running is a no-op when nothing matches.
#   - Non-blocking: the caller pipes `|| true` to keep the workflow alive.
#   - Worktree removal failures are reported on stderr but do not halt
#     subsequent branch deletion attempts.

set -euo pipefail

export GIT_TERMINAL_PROMPT=0

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

PATTERN='^pr-[0-9]+-cycle[0-9]+$'
WIKI_WORKTREE_PATH=".rite/wiki-worktree"

worktrees_removed=0
branches_deleted=0
errors=0

# -----------------------------------------------------------------------
# Step 1: Remove residual worktrees matching the pattern.
# Worktrees holding a matching branch as HEAD must be removed BEFORE the
# branch itself can be deleted (a branch checked out in a worktree cannot
# be deleted with `git branch -D`).
# -----------------------------------------------------------------------
if wt_list=$(git worktree list --porcelain 2>/dev/null); then
  # Parse porcelain output: pair each `worktree <path>` with its `branch refs/heads/<name>`
  current_path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        current_path="${line#worktree }"
        ;;
      "branch "*)
        branch_name="${line#branch refs/heads/}"
        # Skip wiki worktree unconditionally (defensive — its branch name
        # is `wiki` which would not match the regex anyway, but explicit
        # exclusion guards against future config drift).
        if [ "$current_path" = "$repo_root/$WIKI_WORKTREE_PATH" ] \
           || [ "$current_path" = "$WIKI_WORKTREE_PATH" ]; then
          current_path=""
          continue
        fi
        if printf '%s' "$branch_name" | grep -E -q "$PATTERN"; then
          if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would remove worktree: $current_path (branch=$branch_name)"
          else
            if git worktree remove --force "$current_path" 2>/dev/null; then
              worktrees_removed=$((worktrees_removed + 1))
            else
              echo "WARNING: failed to remove worktree '$current_path'" >&2
              errors=$((errors + 1))
            fi
          fi
        fi
        current_path=""
        ;;
      "")
        current_path=""
        ;;
    esac
  done <<< "$wt_list"
fi

# Prune any dangling worktree metadata to keep `git worktree list` clean.
if [ "$DRY_RUN" = "0" ]; then
  git worktree prune 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# Step 2: Delete residual local branches matching the pattern.
# `git for-each-ref` is used instead of `git branch --list` because it
# emits the bare ref name without leading whitespace/asterisks.
# -----------------------------------------------------------------------
if branches=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null); then
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    if printf '%s' "$br" | grep -E -q "$PATTERN"; then
      if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] would delete branch: $br"
      else
        if git branch -D "$br" >/dev/null 2>&1; then
          branches_deleted=$((branches_deleted + 1))
        else
          echo "WARNING: failed to delete branch '$br'" >&2
          errors=$((errors + 1))
        fi
      fi
    fi
  done <<< "$branches"
fi

# -----------------------------------------------------------------------
# Status line
# -----------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  echo "[pr-cycle-cleanup] status=dry-run; pattern=$PATTERN"
elif [ "$errors" -gt 0 ]; then
  echo "[pr-cycle-cleanup] status=failed; worktrees=$worktrees_removed; branches=$branches_deleted; errors=$errors"
elif [ "$worktrees_removed" -eq 0 ] && [ "$branches_deleted" -eq 0 ]; then
  echo "[pr-cycle-cleanup] status=noop; worktrees=0; branches=0"
else
  echo "[pr-cycle-cleanup] status=cleaned; worktrees=$worktrees_removed; branches=$branches_deleted"
fi

exit 0
