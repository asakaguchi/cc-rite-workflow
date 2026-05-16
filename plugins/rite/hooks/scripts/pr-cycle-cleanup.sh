#!/bin/bash
# rite workflow - PR review-fix cycle branch cleanup (idempotent)
#
# Responsibility: remove residual `pr-{N}-cycle{X}` worktrees and branches
# that leak after reviewer subagent `git worktree add` invocations, plus
# `pr-{N}-{test,experiment,mutation,verify,check,sandbox}` variations that
# reviewers create for verification experiments (Issue #995). The reviewer's
# READ-ONLY contract forbids `git worktree remove` / `git branch -D`, so
# cleanup MUST run from the orchestrator side.
#
# Strict regex `^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$`
# protects unrelated branches (e.g. `pr-918-cycle4-feature`,
# `feature/pr-918-cycle4`, `pr-994-testing-suite`) from accidental deletion
# by requiring an **exact-match suffix** rather than a substring. The wiki
# worktree (`.rite/wiki-worktree`) is excluded unconditionally — see
# commands/pr/cleanup.md §2.6.
#
# Variation history:
#   - `cycle{N}`: orchestrator-created (`/rite:pr:review` cycle worktrees)
#   - `test` / `experiment` / `mutation` / `verify` / `check` / `sandbox`:
#     reviewer-subagent verification experiments. Observed in Issue #995
#     (PR #994 cycle 3 review where a reviewer created `pr-994-test`).
#     The reviewer's READ-ONLY contract is enforced primarily by
#     `pre-tool-bash-guard.sh` Pattern 4 (PreToolUse hook block), and these
#     names should normally never be created. This regex serves as the
#     defense-in-depth sweep for cases where the hook fails to fire
#     (e.g., transcript_path subagent detection edge case).
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
# bash 3.2 (macOS default) では `set -u` 配下で空 `$@` が unbound variable 扱いになる
# 既知の挙動があるため、`${@:-}` で展開してガードする。
for arg in "${@:-}"; do
  [ -z "$arg" ] && continue
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
if [ -z "$repo_root" ]; then
  echo "ERROR: empty repo_root (git rev-parse race / permission change の可能性)" >&2
  exit 1
fi
cd -- "$repo_root"

PATTERN='^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$'
WIKI_WORKTREE_PATH=".rite/wiki-worktree"

worktrees_removed=0
branches_deleted=0
errors=0

# trap + cleanup パターン (canonical: references/bash-trap-patterns.md#signal-specific-trap-template)
# 兄弟スクリプト (wiki-growth-check.sh / wiki-worktree-setup.sh 等) と統一する。
# パス先行宣言 → trap 先行設定 → mktemp の順序で orphan race window を排除する。
wt_list_err=""
prune_err=""
ref_err=""
_rite_pr_cycle_cleanup() {
  rm -f "${wt_list_err:-}" "${prune_err:-}" "${ref_err:-}"
}
trap 'rc=$?; _rite_pr_cycle_cleanup; exit $rc' EXIT
trap '_rite_pr_cycle_cleanup; exit 130' INT
trap '_rite_pr_cycle_cleanup; exit 143' TERM
trap '_rite_pr_cycle_cleanup; exit 129' HUP

# -----------------------------------------------------------------------
# Step 1: Remove residual worktrees matching the pattern.
# Worktrees holding a matching branch as HEAD must be removed BEFORE the
# branch itself can be deleted (a branch checked out in a worktree cannot
# be deleted with `git branch -D`).
# -----------------------------------------------------------------------
wt_list_err=$(mktemp /tmp/rite-pr-cycle-cleanup-wt-err-XXXXXX 2>/dev/null) || wt_list_err=""
if wt_list=$(git worktree list --porcelain 2>"${wt_list_err:-/dev/null}"); then
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
        if [[ "$branch_name" =~ ^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$ ]]; then
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
else
  wt_rc=$?
  echo "WARNING: git worktree list --porcelain が失敗しました (rc=$wt_rc)" >&2
  if [ -n "$wt_list_err" ] && [ -s "$wt_list_err" ]; then
    head -3 "$wt_list_err" | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
fi

# Prune any dangling worktree metadata to keep `git worktree list` clean.
# AC-3 (異常終了経路) の核心ロジックのため、失敗を silent に握り潰さず errors カウンタに加算する。
if [ "$DRY_RUN" = "0" ]; then
  prune_err=$(mktemp /tmp/rite-pr-cycle-cleanup-prune-err-XXXXXX 2>/dev/null) || prune_err=""
  # bash の `if ! cmd; then rc=$?` は `!` 演算子が exit status を反転させるため
  # then ブロック内の `$?` は常に 0 になる仕様。`if cmd; then :; else rc=$?; fi` 形式で
  # 元コマンドの非ゼロ exit code を正しく取得する (兄弟スクリプト wt_list / ref と統一)。
  if git worktree prune 2>"${prune_err:-/dev/null}"; then
    :
  else
    prune_rc=$?
    echo "WARNING: git worktree prune が失敗しました (rc=$prune_rc)" >&2
    if [ -n "$prune_err" ] && [ -s "$prune_err" ]; then
      head -3 "$prune_err" | sed 's/^/  /' >&2
    fi
    errors=$((errors + 1))
  fi
fi

# -----------------------------------------------------------------------
# Step 2: Delete residual local branches matching the pattern.
# `git for-each-ref` is used instead of `git branch --list` because it
# emits the bare ref name without leading whitespace/asterisks.
# -----------------------------------------------------------------------
ref_err=$(mktemp /tmp/rite-pr-cycle-cleanup-ref-err-XXXXXX 2>/dev/null) || ref_err=""
if branches=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>"${ref_err:-/dev/null}"); then
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    if [[ "$br" =~ ^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$ ]]; then
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
else
  ref_rc=$?
  echo "WARNING: git for-each-ref refs/heads/ が失敗しました (rc=$ref_rc)" >&2
  if [ -n "$ref_err" ] && [ -s "$ref_err" ]; then
    head -3 "$ref_err" | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
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
