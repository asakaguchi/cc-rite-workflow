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
# Additionally, reaps orphaned `rite-pr-create-*` workdirs left in
# `${TMPDIR:-/tmp}` by pr/create.md Phase 3.4 (Issue #1311). Its 3-step protocol
# (mktemp -d -> Write tool -> gh pr create) spans separate processes, so a
# malformed tool-call between workdir allocation and `gh pr create` leaves an
# empty (or partially written) workdir behind. create.md's own signal-specific
# trap only covers the gh-create block, so this cross-process orphan is swept
# here. An age guard (mtime > 24h) ensures only true orphans are reaped, never
# an in-flight workdir held by a paused concurrent session.
#
# Also reaps orphaned `rite-review-mutation-*` detached worktrees left in
# `${TMPDIR:-/tmp}` by reviewer subagents (Issue #1340). `_reviewer-base.md`'s
# worktree-only mutation pattern (`mktemp -d -t rite-review-mutation-XXXXXX`
# + `git worktree add --detach`) lets reviewers run verification experiments
# without mutating the parent working tree, but the reviewer's READ-ONLY
# contract forbids `git worktree remove`, so these detached worktrees (no named
# branch -> not matched by the Step 1 branch sweep) are swept here by path name
# with the same 24h age guard.
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
#   [pr-cycle-cleanup] status=<cleaned|noop|failed>; worktrees=<N>; branches=<N>; workdirs=<N>; mutation_worktrees=<N>
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
# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"

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

# Single source of truth (cycle 1 fix): `PATTERN` 変数を [[ =~ $PATTERN ]] で
# 直接参照することで、worktree-loop と branch-loop の 2 箇所で literal regex を
# duplicate していた drift リスクを解消する (`readonly` で immutable 化)。
readonly PATTERN='^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$'
readonly WIKI_WORKTREE_PATH=".rite/wiki-worktree"

worktrees_removed=0
branches_deleted=0
workdirs_reaped=0
mutation_worktrees_reaped=0
errors=0

# trap + cleanup パターン (canonical: references/bash-trap-patterns.md#signal-specific-trap-template)
# 兄弟スクリプト (wiki-growth-check.sh / wiki-worktree-setup.sh 等) と統一する。
# パス先行宣言 → trap 先行設定 → mktemp の順序で orphan race window を排除する。
wt_list_err=""
prune_err=""
ref_err=""
workdir_find_err=""
mutation_find_err=""
_rite_pr_cycle_cleanup() {
  rm -f "${wt_list_err:-}" "${prune_err:-}" "${ref_err:-}" "${workdir_find_err:-}" "${mutation_find_err:-}"
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
        if [[ "$branch_name" =~ $PATTERN ]]; then
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
    head -3 "$wt_list_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
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
      head -3 "$prune_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
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
    if [[ "$br" =~ $PATTERN ]]; then
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
    head -3 "$ref_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
fi

# -----------------------------------------------------------------------
# Step 3: Reap orphaned `rite-pr-create-*` workdirs (refs #1311).
# pr/create.md Phase 3.4 の 3 段プロトコル (A: mktemp -d -> B: Write tool ->
# C: gh pr create) は workdir を別プロセスに跨がせるため、(A) 確保後・(C) 到達前の
# malformed tool-call 無言終了 (Cause A) で `${TMPDIR:-/tmp}/rite-pr-create-*` が
# orphan として残る。create.md の signal-specific trap は (C) 自身の中断しか
# カバーできないため、この cross-process orphan は orchestrator 側の本 GC で回収する。
#
# age ガード (mtime > WORKDIR_REAP_AGE_MINUTES) が安全性の核心: 健全な実行では
# workdir は当該ターン (数分) で trap 削除されるため、閾値を超える workdir は確実に
# orphan。マルチセッションで session A が (A)->(C) 間で長時間ポーズしている in-flight
# workdir を session B の cleanup が誤回収しないよう、24h の保守的マージンを取る。
# 内容の有無 (空 / title・body ファイル入り) を問わず `rm -rf` で回収する —
# (B) Write 後に中断した non-empty orphan も age ガードで in-flight 非該当が保証
# されるため安全に掃除できる。走査先は `mktemp -d -t` と同じ `${TMPDIR:-/tmp}` を
# 尊重し create.md と一致させる (テスト時の隔離も可能になる)。
# -----------------------------------------------------------------------
readonly WORKDIR_REAP_AGE_MINUTES=1440  # 24h
workdir_tmp_base="${TMPDIR:-/tmp}"
workdir_tmp_base="${workdir_tmp_base%/}"  # strip trailing slash
# find は process substitution `< <(find ...)` ではなく command substitution + here-string で
# 呼ぶ。process substitution は subshell の exit code がシェルに伝播しないため、$TMPDIR 不在 /
# 権限なし / IO エラーで find が wholesale 失敗しても空ループ → 無言 no-op になり、本ファイルが
# Step 1/2 (wt_list / prune / ref) で確立した「失敗を silent に握り潰さず errors カウンタに加算する」
# 方針 (上記 prune block 参照) と非対称になる。command substitution で rc を捕捉し、失敗時は
# WARNING + errors++ で sibling と対称化する。空 stdout 時の here-string は単一空行を生むが、
# ループ先頭の `[ -z ]` ガードが branch-loop と同様に skip する。
workdir_find_err=$(mktemp /tmp/rite-pr-cycle-cleanup-workdir-err-XXXXXX 2>/dev/null) || workdir_find_err=""
if workdir_list=$(find "$workdir_tmp_base" -maxdepth 1 -type d -name 'rite-pr-create-*' -mmin +"$WORKDIR_REAP_AGE_MINUTES" 2>"${workdir_find_err:-/dev/null}"); then
  while IFS= read -r orphan_workdir; do
    [ -z "$orphan_workdir" ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      echo "[dry-run] would reap orphan workdir: $orphan_workdir"
    else
      if rm -rf "$orphan_workdir" 2>/dev/null; then
        workdirs_reaped=$((workdirs_reaped + 1))
      else
        echo "WARNING: failed to reap orphan workdir '$orphan_workdir'" >&2
        errors=$((errors + 1))
      fi
    fi
  done <<< "$workdir_list"
else
  workdir_find_rc=$?
  echo "WARNING: find による orphan workdir 走査が失敗しました (rc=$workdir_find_rc, base=$workdir_tmp_base)" >&2
  if [ -n "$workdir_find_err" ] && [ -s "$workdir_find_err" ]; then
    head -3 "$workdir_find_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
fi

# -----------------------------------------------------------------------
# Step 4: Reap orphaned `rite-review-mutation-*` worktrees (refs #1340).
# reviewer subagent の mutation/verification 検証は `_reviewer-base.md` の
# worktree-only mutation pattern (`mktemp -d -t rite-review-mutation-XXXXXX`
# + `git worktree add --detach`) に従って detached worktree を作るが、reviewer は
# READ-ONLY 契約で `git worktree remove` を実行禁止のため自己回収できず、
# orchestrator 側の本 GC が回収する (doc と実装の drift 解消)。
#
# Step 1 の branch-pattern sweep では捕捉できない: mutation worktree は
# `--detach` で named branch を持たないため porcelain 出力に `branch refs/heads/...`
# 行が無く、Step 1 の `$PATTERN` (branch 名マッチ) を素通りする。よって path 命名
# (`rite-review-mutation-*`) を find で直接 sweep する。
#
# age ガード (mtime > WORKDIR_REAP_AGE_MINUTES) は Step 3 workdir reap と同一閾値
# (24h) を共有する: 健全な mutation 検証は reviewer subagent の当該ターン (数分) で
# 完結するため、閾値超過の worktree は確実に orphan。並行 session の in-flight worktree
# を誤回収しないための保守的マージン。走査先は create.md / `mktemp -d -t` と同じ
# `${TMPDIR:-/tmp}` を尊重する (テスト時の TMPDIR 隔離も効く)。
#
# 回収は `git worktree remove --force` を第一手とする (worktree 登録メタデータと
# ディレクトリを atomically 除去)。登録が既に失われた dir には `rm -rf` で fallback し、
# ループ後の `git worktree prune` で stale メタデータを掃除する。Step 1/3 と同様、
# 失敗は WARNING + errors++ で surface し silent 化しない。
# -----------------------------------------------------------------------
mutation_tmp_base="${TMPDIR:-/tmp}"
mutation_tmp_base="${mutation_tmp_base%/}"  # strip trailing slash
mutation_find_err=$(mktemp /tmp/rite-pr-cycle-cleanup-mutation-err-XXXXXX 2>/dev/null) || mutation_find_err=""
if mutation_list=$(find "$mutation_tmp_base" -maxdepth 1 -type d -name 'rite-review-mutation-*' -mmin +"$WORKDIR_REAP_AGE_MINUTES" 2>"${mutation_find_err:-/dev/null}"); then
  mutation_reaped_any=0
  while IFS= read -r orphan_wt; do
    [ -z "$orphan_wt" ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      echo "[dry-run] would reap orphan mutation worktree: $orphan_wt"
    else
      # git worktree remove --force を第一手、失敗時のみ rm -rf へ fallback
      if git worktree remove --force "$orphan_wt" >/dev/null 2>&1 || rm -rf "$orphan_wt" 2>/dev/null; then
        mutation_worktrees_reaped=$((mutation_worktrees_reaped + 1))
        mutation_reaped_any=1
      else
        echo "WARNING: failed to reap orphan mutation worktree '$orphan_wt'" >&2
        errors=$((errors + 1))
      fi
    fi
  done <<< "$mutation_list"
  # rm -rf fallback で残った stale worktree メタデータを掃除する (remove --force 経路では不要だが冪等)
  if [ "$DRY_RUN" = "0" ] && [ "$mutation_reaped_any" = "1" ]; then
    git worktree prune 2>/dev/null || true
  fi
else
  mutation_find_rc=$?
  echo "WARNING: find による orphan mutation worktree 走査が失敗しました (rc=$mutation_find_rc, base=$mutation_tmp_base)" >&2
  if [ -n "$mutation_find_err" ] && [ -s "$mutation_find_err" ]; then
    head -3 "$mutation_find_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
fi

# -----------------------------------------------------------------------
# Status line
# -----------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  echo "[pr-cycle-cleanup] status=dry-run; pattern=$PATTERN"
elif [ "$errors" -gt 0 ]; then
  echo "[pr-cycle-cleanup] status=failed; worktrees=$worktrees_removed; branches=$branches_deleted; workdirs=$workdirs_reaped; mutation_worktrees=$mutation_worktrees_reaped; errors=$errors"
elif [ "$worktrees_removed" -eq 0 ] && [ "$branches_deleted" -eq 0 ] && [ "$workdirs_reaped" -eq 0 ] && [ "$mutation_worktrees_reaped" -eq 0 ]; then
  echo "[pr-cycle-cleanup] status=noop; worktrees=0; branches=0; workdirs=0; mutation_worktrees=0"
else
  echo "[pr-cycle-cleanup] status=cleaned; worktrees=$worktrees_removed; branches=$branches_deleted; workdirs=$workdirs_reaped; mutation_worktrees=$mutation_worktrees_reaped"
fi

exit 0
