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
# Step 3/4 の find -print0 出力を保持する NUL-delimited 一時ファイル (refs #1351)。
# command substitution は NUL バイトを除去するため list を変数に持てない。find rc 捕捉を
# 保ちつつ改行安全に読むには、出力を一時ファイルに退避して `read -r -d ''` で読む。
workdir_find_out=""
mutation_find_out=""
_rite_pr_cycle_cleanup() {
  rm -f "${wt_list_err:-}" "${prune_err:-}" "${ref_err:-}" "${workdir_find_err:-}" "${mutation_find_err:-}" \
        "${workdir_find_out:-}" "${mutation_find_out:-}"
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
            # 失敗時は git の stderr を診断として surface する (refs #1352、従来は
            # `2>/dev/null` で失敗理由 — lock / 権限 / submodule 等 — が落ちていた)。
            if wt_rm_err=$(git worktree remove --force "$current_path" 2>&1); then
              worktrees_removed=$((worktrees_removed + 1))
            else
              echo "WARNING: failed to remove worktree '$current_path'" >&2
              if [ -n "$wt_rm_err" ]; then
                head -3 <<< "$wt_rm_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
              fi
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

# ---------------------------------------------------------------------------
# reap_orphan_dirs (refs #1352): Step 3 (workdir) / Step 4 (mutation worktree) で
# 同型だった orphan ディレクトリ走査を 1 箇所に集約する。両 Step は「tmp_base 正規化 →
# err/out mktemp → mktemp 失敗ガード → find rc 捕捉 → NUL 区切り (-print0) ループ →
# find wholesale 失敗時の err surface」という subtle な不変条件群を共有しており、過去に
# per-item 失敗分岐 (#1349) と find 出力先 mktemp 失敗 surface (#1351) を両 Step へ二重
# 修正する copy-paste drift が実際に発生した。本ヘルパーで不変条件を集約し drift を防ぐ。
#
# find は process substitution `< <(find ...)` ではなく出力を一時ファイルに退避して呼ぶ。
# process substitution は subshell の exit code が伝播せず find wholesale 失敗が無言 no-op
# になるため。`if find ... -print0 > "$out"; then` 形式なら find が if の直接コマンドで rc を
# 捕捉でき、失敗を WARNING + errors++ で surface できる。出力保持に command substitution を
# 使わないのは bash の `$(...)` が NUL バイトを除去して -print0 区切りが失われるため (#1351)。
#
# Args: $1 label (WARNING 用) / $2 base / $3 name_pattern / $4 reaper_fn /
#       $5 find_out (mktemp 済み、空=失敗) / $6 find_err (mktemp 済み、stderr 退避用)
# reaper_fn: orphan path を $1 で受け取るコールバック。成功時にカウンタ加算、失敗時に
#            WARNING + errors++ を自身で行う (戻り値は使わない)。
# Globals: errors (加算) / DRY_RUN / WORKDIR_REAP_AGE_MINUTES
# find_out/find_err は呼び出し側が pre-declare + trap 登録した一時ファイルを渡すため、中断時
# の cleanup は呼び出し側の signal-specific trap が担う (本ヘルパーは local temp を作らない)。
# ---------------------------------------------------------------------------
reap_orphan_dirs() {
  local label="$1" base="$2" pattern="$3" reaper_fn="$4" find_out="$5" find_err="$6"
  if [ -z "$find_out" ]; then
    echo "WARNING: ${label} 走査の出力先 mktemp に失敗しました。今回の回収をスキップします (次回 age 超過で回収)" >&2
    errors=$((errors + 1))
    return 0
  fi
  if find "$base" -maxdepth 1 -type d -name "$pattern" -mmin +"$WORKDIR_REAP_AGE_MINUTES" -print0 > "$find_out" 2>"${find_err:-/dev/null}"; then
    local orphan
    while IFS= read -r -d '' orphan; do
      [ -z "$orphan" ] && continue
      if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] would reap ${label}: $orphan"
      else
        "$reaper_fn" "$orphan"
      fi
    done < "$find_out"
  else
    local rc=$?
    echo "WARNING: find による ${label} 走査が失敗しました (rc=$rc, base=$base)" >&2
    if [ -n "$find_err" ] && [ -s "$find_err" ]; then
      head -3 "$find_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    errors=$((errors + 1))
  fi
}

# Step 3 reaper: orphan workdir を rm -rf で回収。失敗時は rm の stderr を診断として surface
# する (refs #1352、従来は `2>/dev/null` で失敗理由が落ちていた)。
_reap_workdir() {
  local orphan="$1" rm_err=""
  if rm_err=$(rm -rf "$orphan" 2>&1); then
    workdirs_reaped=$((workdirs_reaped + 1))
    return 0
  fi
  echo "WARNING: failed to reap orphan workdir '$orphan'" >&2
  if [ -n "$rm_err" ]; then
    head -3 <<< "$rm_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
  return 0
}

# Step 4 reaper: mutation worktree を `git worktree remove --force` 第一手・`rm -rf` fallback で
# 回収。両手の失敗理由 (stderr) を surface する (refs #1352、Step 1/4 の診断性向上)。
# 成功時に mutation_reaped_any=1 を立て、呼び出し側の post-loop prune を起動する。
_reap_mutation_worktree() {
  local orphan="$1" wt_err="" rm_err=""
  if wt_err=$(git worktree remove --force "$orphan" 2>&1); then
    mutation_worktrees_reaped=$((mutation_worktrees_reaped + 1))
    mutation_reaped_any=1
    return 0
  fi
  if rm_err=$(rm -rf "$orphan" 2>&1); then
    mutation_worktrees_reaped=$((mutation_worktrees_reaped + 1))
    mutation_reaped_any=1
    return 0
  fi
  echo "WARNING: failed to reap orphan mutation worktree '$orphan'" >&2
  if [ -n "$wt_err" ]; then
    echo "  git worktree remove --force:" >&2
    head -2 <<< "$wt_err" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2
  fi
  if [ -n "$rm_err" ]; then
    echo "  rm -rf:" >&2
    head -2 <<< "$rm_err" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2
  fi
  errors=$((errors + 1))
  return 0
}

workdir_tmp_base="${TMPDIR:-/tmp}"
workdir_tmp_base="${workdir_tmp_base%/}"  # strip trailing slash
workdir_find_err=$(mktemp /tmp/rite-pr-cycle-cleanup-workdir-err-XXXXXX 2>/dev/null) || workdir_find_err=""
workdir_find_out=$(mktemp /tmp/rite-pr-cycle-cleanup-workdir-out-XXXXXX 2>/dev/null) || workdir_find_out=""
reap_orphan_dirs "orphan workdir" "$workdir_tmp_base" 'rite-pr-create-*' \
  _reap_workdir "$workdir_find_out" "$workdir_find_err"

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
mutation_find_out=$(mktemp /tmp/rite-pr-cycle-cleanup-mutation-out-XXXXXX 2>/dev/null) || mutation_find_out=""
# mutation_reaped_any は reaper (_reap_mutation_worktree) が成功時に 1 を立てるグローバル。
# 走査前に 0 で初期化し、回収が 1 件でも成功したら下記 post-loop prune を起動する。
mutation_reaped_any=0
reap_orphan_dirs "orphan mutation worktree" "$mutation_tmp_base" 'rite-review-mutation-*' \
  _reap_mutation_worktree "$mutation_find_out" "$mutation_find_err"
# rm -rf fallback で残った stale worktree メタデータを掃除する (remove --force 経路では不要だが冪等)
if [ "$DRY_RUN" = "0" ] && [ "$mutation_reaped_any" = "1" ]; then
  git worktree prune 2>/dev/null || true
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
