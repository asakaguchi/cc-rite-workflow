#!/bin/bash
# rite workflow - PR review-fix cycle branch cleanup (idempotent)
#
# Responsibility: remove residual `pr-{N}-cycle{X}` worktrees and branches
# that leak after reviewer subagent `git worktree add` invocations, plus
# `pr-{N}-{test,experiment,mutation,verify,check,sandbox}` variations that
# reviewers create for verification experiments. The reviewer's
# READ-ONLY contract forbids `git worktree remove` / `git branch -D`, so
# cleanup MUST run from the orchestrator side.
#
# Additionally, reaps orphaned `rite-pr-create-*` workdirs left in
# `${TMPDIR:-/tmp}` by pr/create.md Phase 3.4. Its 3-step protocol
# (mktemp -d -> Write tool -> gh pr create) spans separate processes, so a
# malformed tool-call between workdir allocation and `gh pr create` leaves an
# empty (or partially written) workdir behind. create.md's own signal-specific
# trap only covers the gh-create block, so this cross-process orphan is swept
# here. An age guard (mtime > 24h) ensures only true orphans are reaped, never
# an in-flight workdir held by a paused concurrent session.
#
# Also reaps orphaned `rite-review-mutation-*` detached worktrees left in
# `${TMPDIR:-/tmp}` by reviewer subagents. `_reviewer-base.md`'s
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
# skills/cleanup/SKILL.md §2.6.
#
# Also reaps (Issue #1526):
#   - bare `pr-{N}` (no suffix, `^pr-[0-9]+$`): external/manual PR-checkout leak
#     (`git fetch origin pull/{N}/head:pr-{N}`). rite work branches are
#     `{type}/issue-{N}-{slug}`, so the exact match cannot collide (AC-1/D-02).
#   - `rite-revert-test-*` detached worktrees: same `rite-` reviewer-tmp namespace
#     as `rite-review-mutation-*`, swept by path name in Step 4 (AC-2/D-03).
#   - manifest-recorded artifacts (`.rite/tmp-artifacts.tsv`): name-independent
#     reap of branches/worktrees a producer recorded via rite-tmp-artifact.sh —
#     Step 4.5 deletes ONLY recorded entries, never by guessing names (AC-4/D-05).
#
# Variation history:
#   - `cycle{N}`: orchestrator-created (`/rite:pr-review` cycle worktrees)
#   - `test` / `experiment` / `mutation` / `verify` / `check` / `sandbox`:
#     reviewer-subagent verification experiments (observed in practice).
#     The reviewer's READ-ONLY contract is the prompt-level Layer 1
#     (`agents/_reviewer-base.md`; branch-creating git verbs are no longer
#     machine-gated since Issue #1879), so these names should normally never
#     be created but cannot be structurally prevented. This regex is the
#     designed sweep for reviewer-leaked residue (with Layer 3
#     post-review-state-verify.sh handling in-review detection).
#
# Usage:
#   bash pr-cycle-cleanup.sh [--dry-run]
#
# Output (stdout): one structured status line per invocation
#   [pr-cycle-cleanup] status=<cleaned|noop|failed>; worktrees=<N>; branches=<N>; workdirs=<N>; mutation_worktrees=<N>; session_worktrees=<N>; manifest=<N>
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

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

# Resolve to the SHARED state root (main checkout). When invoked from a linked
# worktree session, GC of `pr-{N}-cycle{X}` worktrees/branches AND the §8 session
# worktree reap (Step 5) MUST run from the main checkout — you cannot
# `git worktree remove` a worktree you are standing in, and a branch checked out
# in another worktree cannot be deleted. state-path-resolve.sh returns
# `git rev-parse --show-toplevel` verbatim for non-worktree sessions, so this is
# byte-identical outside multi-session use (multi-session design §1).
repo_root=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || repo_root=""
[ -n "$repo_root" ] || repo_root=$(git rev-parse --show-toplevel)
if [ -z "$repo_root" ]; then
  echo "ERROR: empty repo_root (git rev-parse race / permission change の可能性)" >&2
  exit 1
fi

# Capture the invocation directory BEFORE `cd` to repo_root below. Step 5's
# self-exclusion guard needs to know which session worktree this run was launched
# from, but the `cd` overwrites $PWD with repo_root (the main checkout). $PWD (a
# string) is preferred over `pwd` so the value survives even when the invocation
# cwd was already deleted (the lost-cwd edge case Step 5 must tolerate).
rite_invocation_pwd="${PWD:-}"
[ -n "$rite_invocation_pwd" ] || rite_invocation_pwd=$(pwd 2>/dev/null) || rite_invocation_pwd=""

cd -- "$repo_root"

# Single source of truth (cycle 1 fix): `PATTERN` 変数を [[ =~ $PATTERN ]] で
# 直接参照することで、worktree-loop と branch-loop の 2 箇所で literal regex を
# duplicate していた drift リスクを解消する (`readonly` で immutable 化)。
readonly PATTERN='^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$'
# Bare `pr-{N}` (no suffix). Not created by rite's own code — it leaks from
# external/manual PR checkout (`git fetch origin pull/{N}/head:pr-{N}`,
# `gh pr checkout`) during the workflow (Issue #1526 §3.2 Open Question resolved:
# rite-internal grep finds no producer). rite's own work branches are
# `{type}/issue-{N}-{slug}`, so an exact `^pr-[0-9]+$` sweep cannot collide with
# them — the same low-risk, naming-convention basis as the suffixed PATTERN above
# (Issue #1526 AC-1 / D-02).
readonly BARE_PR_PATTERN='^pr-[0-9]+$'
readonly WIKI_WORKTREE_PATH=".rite/wiki-worktree"
# Name-independent reap manifest (Issue #1526 D-01/D-05). Producers append
# `<type>\t<value>` via hooks/scripts/rite-tmp-artifact.sh; cleanup reaps each
# recorded branch/worktree by identity, never by guessing the name. Resolved
# under repo_root (the SHARED state root — we already cd'd there).
readonly TMP_ARTIFACT_MANIFEST=".rite/tmp-artifacts.tsv"

worktrees_removed=0
branches_deleted=0
workdirs_reaped=0
mutation_worktrees_reaped=0
session_worktrees_reaped=0
session_branches_deleted=0
manifest_reaped=0
errors=0

# trap + cleanup パターン (canonical: references/bash-trap-patterns.md#signal-specific-trap-template)
# 兄弟スクリプト (wiki-growth-check.sh / wiki-worktree-setup.sh 等) と統一する。
# パス先行宣言 → trap 先行設定 → mktemp の順序で orphan race window を排除する。
wt_list_err=""
prune_err=""
ref_err=""
workdir_find_err=""
mutation_find_err=""
revert_find_err=""
# Step 3/4 の find -print0 出力を保持する NUL-delimited 一時ファイル。
# command substitution は NUL バイトを除去するため list を変数に持てない。find rc 捕捉を
# 保ちつつ改行安全に読むには、出力を一時ファイルに退避して `read -r -d ''` で読む。
workdir_find_out=""
mutation_find_out=""
revert_find_out=""
# Step 4.5 manifest reap の survivor 書き出し用 (NUL 不使用だが trap で確実に掃除する)
manifest_keep=""
_rite_pr_cycle_cleanup() {
  rm -f "${wt_list_err:-}" "${prune_err:-}" "${ref_err:-}" "${workdir_find_err:-}" "${mutation_find_err:-}" \
        "${revert_find_err:-}" "${workdir_find_out:-}" "${mutation_find_out:-}" "${revert_find_out:-}" \
        "${manifest_keep:-}"
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
wt_list_err=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-wt-err-XXXXXX" 2>/dev/null) || wt_list_err=""
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
        if [[ "$branch_name" =~ $PATTERN ]] || [[ "$branch_name" =~ $BARE_PR_PATTERN ]]; then
          if [ "$DRY_RUN" = "1" ]; then
            safe_path=$(printf '%s' "$current_path" | neutralize_ctrl)
            safe_branch=$(printf '%s' "$branch_name" | neutralize_ctrl)
            echo "[dry-run] would remove worktree: $safe_path (branch=$safe_branch)"
          else
            # 失敗時は git の stderr を診断として surface する (`2>/dev/null` で抑制すると
            # 失敗理由 — lock / 権限 / submodule 等 — が落ちる)。
            if wt_rm_err=$(git worktree remove --force "$current_path" 2>&1); then
              worktrees_removed=$((worktrees_removed + 1))
            else
              echo "WARNING: failed to remove worktree '$(printf '%s' "$current_path" | neutralize_ctrl)'" >&2
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
  prune_err=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-prune-err-XXXXXX" 2>/dev/null) || prune_err=""
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
ref_err=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-ref-err-XXXXXX" 2>/dev/null) || ref_err=""
if branches=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>"${ref_err:-/dev/null}"); then
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    if [[ "$br" =~ $PATTERN ]] || [[ "$br" =~ $BARE_PR_PATTERN ]]; then
      if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] would delete branch: $(printf '%s' "$br" | neutralize_ctrl)"
      else
        if git branch -D "$br" >/dev/null 2>&1; then
          branches_deleted=$((branches_deleted + 1))
        else
          echo "WARNING: failed to delete branch '$(printf '%s' "$br" | neutralize_ctrl)'" >&2
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
# Step 3: Reap orphaned `rite-pr-create-*` workdirs.
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
# reap_orphan_dirs: Step 3 (workdir) / Step 4 (mutation worktree) で
# 同型だった orphan ディレクトリ走査を 1 箇所に集約する。両 Step は「tmp_base 正規化 →
# err/out mktemp → mktemp 失敗ガード → find rc 捕捉 → NUL 区切り (-print0) ループ →
# find wholesale 失敗時の err surface」という subtle な不変条件群を共有しており、過去に
# per-item 失敗分岐 と find 出力先 mktemp 失敗 surface を両 Step へ二重
# 修正する copy-paste drift が実際に発生した。本ヘルパーで不変条件を集約し drift を防ぐ。
#
# find は process substitution `< <(find ...)` ではなく出力を一時ファイルに退避して呼ぶ。
# process substitution は subshell の exit code が伝播せず find wholesale 失敗が無言 no-op
# になるため。`if find ... -print0 > "$out"; then` 形式なら find が if の直接コマンドで rc を
# 捕捉でき、失敗を WARNING + errors++ で surface できる。出力保持に command substitution を
# 使わないのは bash の `$(...)` が NUL バイトを除去して -print0 区切りが失われるため。
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
        echo "[dry-run] would reap ${label}: $(printf '%s' "$orphan" | neutralize_ctrl)"
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
# する。
_reap_workdir() {
  local orphan="$1" rm_err=""
  if rm_err=$(rm -rf "$orphan" 2>&1); then
    workdirs_reaped=$((workdirs_reaped + 1))
    return 0
  fi
  echo "WARNING: failed to reap orphan workdir '$(printf '%s' "$orphan" | neutralize_ctrl)'" >&2
  if [ -n "$rm_err" ]; then
    head -3 <<< "$rm_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  errors=$((errors + 1))
  return 0
}

# Step 4 reaper: mutation worktree を `git worktree remove --force` 第一手・`rm -rf` fallback で
# 回収。両手の失敗理由 (stderr) を surface する。
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
  echo "WARNING: failed to reap orphan mutation worktree '$(printf '%s' "$orphan" | neutralize_ctrl)'" >&2
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
workdir_find_err=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-workdir-err-XXXXXX" 2>/dev/null) || workdir_find_err=""
workdir_find_out=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-workdir-out-XXXXXX" 2>/dev/null) || workdir_find_out=""
reap_orphan_dirs "orphan workdir" "$workdir_tmp_base" 'rite-pr-create-*' \
  _reap_workdir "$workdir_find_out" "$workdir_find_err"

# -----------------------------------------------------------------------
# Step 4: Reap orphaned reviewer detached tmp worktrees (`rite-` namespace).
# reviewer subagent の mutation/verification 検証は `_reviewer-base.md` の
# worktree-only mutation pattern (`mktemp -d -t rite-review-mutation-XXXXXX`
# + `git worktree add --detach`) に従って detached worktree を作るが、reviewer は
# READ-ONLY 契約で `git worktree remove` を実行禁止のため自己回収できず、
# orchestrator 側の本 GC が回収する (doc と実装の drift 解消)。
#
# 名前空間: sanctioned な `rite-review-mutation-*` に加え、実機で観測された
# `rite-revert-test-*` (revert して挙動を確認する検証 worktree) も同じ `rite-`
# reviewer-tmp 名前空間として回収する (Issue #1526 AC-2 / D-03)。prefix 自体が
# name-independent な「これは rite 由来 tmp worktree」マーカーとして機能するため、
# 個別命名を regex で追い続けるモグラ叩きを避けられる。
#
# Step 1 の branch-pattern sweep では捕捉できない: これらは `--detach` で named
# branch を持たないため porcelain 出力に `branch refs/heads/...` 行が無く、Step 1 の
# `$PATTERN` (branch 名マッチ) を素通りする。よって path 命名を find で直接 sweep する。
#
# age ガード (mtime > WORKDIR_REAP_AGE_MINUTES) は Step 3 workdir reap と同一閾値
# (24h) を共有する: 健全な検証は reviewer subagent の当該ターン (数分) で完結するため、
# 閾値超過の worktree は確実に orphan。並行 session の in-flight worktree を誤回収しない
# ための保守的マージン (Issue #1526 D-04: 即時 0 残骸ではなく cross-session 安全と両立する
# 確実な最終回収。即時回収は reviewer 側 session-scoped 記録を要し本 Issue の Non-Target)。
# 走査先は create.md / `mktemp -d -t` と同じ `${TMPDIR:-/tmp}` を尊重する。
#
# 回収は `git worktree remove --force` を第一手とする (worktree 登録メタデータと
# ディレクトリを atomically 除去)。登録が既に失われた dir には `rm -rf` で fallback し、
# ループ後の `git worktree prune` で stale メタデータを掃除する。Step 1/3 と同様、
# 失敗は WARNING + errors++ で surface し silent 化しない。両命名とも reviewer detached
# tmp worktree であり、回収手段が同一のため reaper / counter (`mutation_worktrees_reaped`)
# を共有する (status line の `mutation_worktrees=` は両者の合計を報告)。
# -----------------------------------------------------------------------
mutation_tmp_base="${TMPDIR:-/tmp}"
mutation_tmp_base="${mutation_tmp_base%/}"  # strip trailing slash
mutation_find_err=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-mutation-err-XXXXXX" 2>/dev/null) || mutation_find_err=""
mutation_find_out=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-mutation-out-XXXXXX" 2>/dev/null) || mutation_find_out=""
# mutation_reaped_any は reaper (_reap_mutation_worktree) が成功時に 1 を立てるグローバル。
# 走査前に 0 で初期化し、回収が 1 件でも成功したら下記 post-loop prune を起動する。
mutation_reaped_any=0
reap_orphan_dirs "orphan mutation worktree" "$mutation_tmp_base" 'rite-review-mutation-*' \
  _reap_mutation_worktree "$mutation_find_out" "$mutation_find_err"
# 同じ reviewer-tmp 名前空間の `rite-revert-test-*` も同一 reaper / counter で回収する。
revert_find_err=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-revert-err-XXXXXX" 2>/dev/null) || revert_find_err=""
revert_find_out=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-revert-out-XXXXXX" 2>/dev/null) || revert_find_out=""
reap_orphan_dirs "orphan revert-test worktree" "$mutation_tmp_base" 'rite-revert-test-*' \
  _reap_mutation_worktree "$revert_find_out" "$revert_find_err"
# rm -rf fallback で残った stale worktree メタデータを掃除する (remove --force 経路では不要だが冪等)
if [ "$DRY_RUN" = "0" ] && [ "$mutation_reaped_any" = "1" ]; then
  git worktree prune 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# Step 4.5: Name-independent reap of manifest-recorded tmp artifacts
# (Issue #1526 D-01/D-05, AC-4). A producer that creates a throw-away branch /
# worktree whose name no strict pattern above would match records it via
# `rite-tmp-artifact.sh record`; here we reap each recorded entry BY IDENTITY,
# never by guessing the name. 誤削除防止 (AC-3): only entries the manifest lists
# are touched — an unrelated user branch/worktree is invisible to this step.
#
# No age guard: presence in the manifest is an explicit rite-origin "reap me"
# intent, so there is no in-flight ambiguity to protect against (unlike the
# path-name sweeps of Steps 3/4). Worktree entries still honor AC-6 — a dirty
# worktree is skipped (and kept in the manifest for a later retry) so uncommitted
# work is never destroyed. The manifest is contract-bound to EPHEMERAL tmp
# artifacts; session worktrees go through Step 5's gated reap, never here.
#
# Manifest rewrite: lines we reap (or find already-gone) are dropped; skipped
# (dirty) and failed entries are preserved so the next run retries them.
# Malformed / unparseable lines are preserved untouched (conservative).
# -----------------------------------------------------------------------
manifest_path="$repo_root/$TMP_ARTIFACT_MANIFEST"
# Canonical form of repo_root for the containment guard below. `repo_root` comes
# from git rev-parse / state-path-resolve and is NOT symlink-resolved, but the
# per-entry `_m_canon` is (`cd && pwd -P`); on a symlinked-path host (e.g. macOS
# `/tmp`→`/private/tmp`, this script's portability floor) an un-canonicalized
# compare could let the guard miss. Resolve once so the compare holds.
_repo_canon=$( cd -- "$repo_root" 2>/dev/null && pwd -P ) || _repo_canon="$repo_root"
if [ -f "$manifest_path" ]; then
  manifest_keep=$(mktemp "${TMPDIR:-/tmp}/rite-pr-cycle-cleanup-manifest-keep-XXXXXX" 2>/dev/null) || manifest_keep=""
  if [ -z "$manifest_keep" ]; then
    echo "WARNING: manifest reap 用の一時ファイル mktemp に失敗しました。今回の manifest 回収をスキップします" >&2
    errors=$((errors + 1))
  else
    _tab=$'\t'
    while IFS= read -r _m_line || [ -n "$_m_line" ]; do
      [ -z "$_m_line" ] && continue
      # Split on the FIRST tab only (worktree paths may contain further tabs is
      # already excluded by the recorder, but be defensive): type / value.
      case "$_m_line" in
        *"$_tab"*)
          _m_type="${_m_line%%"$_tab"*}"
          _m_val="${_m_line#*"$_tab"}"
          ;;
        *)
          # Malformed (no TAB) — cannot act, preserve verbatim.
          printf '%s\n' "$_m_line" >> "$manifest_keep"
          continue
          ;;
      esac
      case "$_m_type" in
        branch)
          if ! git rev-parse --verify --quiet "refs/heads/$_m_val" >/dev/null 2>&1; then
            # Already gone → drop the stale entry silently (nothing to reap).
            continue
          fi
          if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would reap manifest branch: $(printf '%s' "$_m_val" | neutralize_ctrl)"
            printf '%s\n' "$_m_line" >> "$manifest_keep"
          elif _m_bd_err=$(LC_ALL=C git branch -D -- "$_m_val" 2>&1); then
            manifest_reaped=$((manifest_reaped + 1))
          else
            # #1670: cleanup.md records a deferred SESSION-worktree branch here while
            # it is still checked out in its (not-yet-reaped) worktree. At this point
            # (Step 4.5 < Step 5) `git branch -D` legitimately fails with "used by
            # worktree" / "checked out" — Step 5 reaps that worktree and recovers the
            # branch later in THIS run (the manifest contract "session worktrees go
            # through Step 5's gated reap, never here"). That expected case must NOT
            # count as an error (it would flip a fully-successful run to status=failed)
            # nor emit a "failed to reap" WARNING. Preserve the entry silently; it
            # self-heals on the next run's verify-already-gone drop. LC_ALL=C fixes the
            # git diagnostic locale so the substring match is stable (same convention as
            # cleanup.md Step 5).
            case "$_m_bd_err" in
              *"used by worktree"*|*"checked out"*)
                printf '%s\n' "$_m_line" >> "$manifest_keep" ;;
              *)
                echo "WARNING: failed to reap manifest branch '$(printf '%s' "$_m_val" | neutralize_ctrl)'" >&2
                errors=$((errors + 1))
                printf '%s\n' "$_m_line" >> "$manifest_keep" ;;
            esac
          fi
          ;;
        worktree)
          if [ ! -e "$_m_val" ]; then
            # Path already gone → drop, but prune any dangling registration.
            [ "$DRY_RUN" = "0" ] && git worktree prune 2>/dev/null || true
            continue
          fi
          # Containment guard: the manifest is contract-bound to EPHEMERAL tmp
          # artifacts. A poisoned/buggy entry pointing at the main checkout would
          # otherwise delete repo_root — catastrophic. Both sides are symlink-
          # resolved (`cd && pwd -P`) so the compare holds on symlinked-path hosts.
          _m_canon=$( cd -- "$_m_val" 2>/dev/null && pwd -P ) || _m_canon=""
          if [ -n "$_m_canon" ] && [ "$_m_canon" = "$_repo_canon" ]; then
            echo "WARNING: manifest worktree '$(printf '%s' "$_m_val" | neutralize_ctrl)' は repo_root 自身を指すため reap をスキップし manifest に保持します。" >&2
            printf '%s\n' "$_m_line" >> "$manifest_keep"
            continue
          fi
          # AC-6: never destroy uncommitted work. An indeterminate status
          # (rc != 0, e.g. the path exists but is not a git worktree) is treated
          # as "do not reap". `if/else` (not `var=$(...); rc=$?`) is REQUIRED: a
          # bare command-substitution assignment that fails (git rc=128 on a
          # non-worktree path) aborts the whole script under `set -e` BEFORE the
          # rc is captured, turning this safety branch into dead code.
          if _m_st=$(git -C "$_m_val" status --porcelain 2>/dev/null); then
            _m_st_rc=0
          else
            _m_st_rc=$?
          fi
          if [ "$_m_st_rc" -ne 0 ] || [ -n "$_m_st" ]; then
            echo "WARNING: manifest worktree '$(printf '%s' "$_m_val" | neutralize_ctrl)' は未コミット変更があるか status 判定不能のため reap をスキップし manifest に保持します。" >&2
            printf '%s\n' "$_m_line" >> "$manifest_keep"
            continue
          fi
          if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would reap manifest worktree: $(printf '%s' "$_m_val" | neutralize_ctrl)"
            printf '%s\n' "$_m_line" >> "$manifest_keep"
          elif git worktree remove --force -- "$_m_val" 2>/dev/null || rm -rf -- "$_m_val" 2>/dev/null; then
            manifest_reaped=$((manifest_reaped + 1))
            git worktree prune 2>/dev/null || true
          else
            echo "WARNING: failed to reap manifest worktree '$(printf '%s' "$_m_val" | neutralize_ctrl)'" >&2
            errors=$((errors + 1))
            printf '%s\n' "$_m_line" >> "$manifest_keep"
          fi
          ;;
        *)
          # Unknown type — preserve verbatim (forward-compat / conservative).
          printf '%s\n' "$_m_line" >> "$manifest_keep"
          ;;
      esac
    done < "$manifest_path"

    if [ "$DRY_RUN" = "0" ]; then
      if [ -s "$manifest_keep" ]; then
        if ! cp "$manifest_keep" "$manifest_path" 2>/dev/null; then
          echo "WARNING: manifest '$manifest_path' の書き戻しに失敗しました (回収済エントリが残存する可能性)" >&2
          errors=$((errors + 1))
        fi
      else
        # All entries reaped/dropped → remove the now-empty manifest.
        rm -f "$manifest_path" 2>/dev/null || true
      fi
    fi
    rm -f "$manifest_keep" 2>/dev/null || true
  fi
fi

# -----------------------------------------------------------------------
# Step 5: Lazy reap of orphaned SESSION worktrees (multi-session design §8).
# 責務分担: 正常系の即時削除は cleanup.md (S7) の責務、本 reap は **異常終了の
# 残骸回収のみ**。`.rite/worktrees/issue-{N}` (multi_session.worktree_base 配下)
# を `git worktree list` から列挙し、**Gate 0 + 3 ゲート全通過時のみ** reap する:
#   0. self-exclusion: 実行中の自セッション worktree (起動時 cwd または
#      RITE_WORKTREE env が wt_path と一致/配下) は reap しない。3 ゲートとは独立した
#      第 4 の保護層 — long-lived セッションが review 開始時に自分の作業中 worktree を
#      消す事故を防ぐ。dirty(3)/claim(2) より前段で skip する
#   1. ディレクトリ名が `^issue-[0-9]+$` に完全一致 (strict regex doctrine。
#      `.rite/wiki-worktree` などの非 issue worktree 名前空間
#      とは交差しない)
#   2. claim liveness (S3) が live でない (issue-claim.sh check が stale、または
#      claim 不在 free のとき mtime > 24h の age guard を再利用)
#   3. `git -C <wt> status --porcelain` が空 (dirty worktree は絶対に auto-reap
#      しない — WARNING + 手動コマンド提示で skip)。例外 (Issue #1957): corpse
#      (admin dir の HEAD 欠落 + git 非認識 — sandbox のマスクマウント下で
#      `git worktree remove --force` が半壊させた残骸) は status 判定が構造的に
#      不可能なため本ゲートをバイパスし、claim 非 live + 24h age guard の通過後に
#      rm -rf (working tree + admin dir) + prune で回収する
# 処理は Step 1/4 と同型: `git worktree remove --force` → fallback `rm -rf` →
# ループ後 `git worktree prune` + 対応 claim ファイル削除。
#
# **Branch recovery (Issue #1670)**: worktree reap 後に、その worktree が checkout
# していた feature ブランチを **安全に回収する**。従来は branch を一切削除せず、cleanup.md
# が live-cwd guard で削除を遅延した feature ブランチが回収経路を持たず永久残置 (dead-letter)
# だった。回収は `git branch -d` (safe — 未マージは拒否 → クラッシュセッションの作業を保全, AC-4)
# を第一手とし、`-d` が squash-merge 残渣で拒否しても **reap manifest に記録された** ブランチ
# (cleanup.md が PR merged を確認して記録) のみ `git branch -D` で強制削除する。manifest 未記録の
# 未マージブランチは保持する。これにより #1524 の「branch は保全」方針は「**merge 確認済み**
# ブランチのみ回収・未マージ作業は破壊しない」へと精緻化される。
# -----------------------------------------------------------------------
session_wt_base=""
if [ -f "$repo_root/rite-config.yml" ]; then
  _ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' "$repo_root/rite-config.yml" 2>/dev/null) || _ms_section=""
  session_wt_base=$(printf '%s\n' "$_ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
fi
[ -n "$session_wt_base" ] || session_wt_base=".rite/worktrees"
session_wt_root="$repo_root/$session_wt_base"

# Gate 0 (self-exclusion) helpers. Canonicalize via `cd && pwd -P` rather than
# GNU `realpath` so the macOS bash 3.2 target (this script's portability floor)
# is preserved. The raw string is returned for paths that are not accessible
# directories (already-removed worktree, or a lost invocation cwd) so a plain
# string comparison still has a value to fall back on.
_rite_canonical_dir() {
  local p="$1"
  [ -n "$p" ] || { printf ''; return 0; }
  if [ -d "$p" ]; then
    ( cd -- "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# rc 0 when $1 (the invoking session's dir) is the same directory as $2 (a reap
# candidate worktree) or nested beneath it. Both args must already be
# canonicalized. The trailing-slash prefix test avoids `issue-1` matching
# `issue-12` (a bare prefix test would).
_rite_dir_is_self() {
  local self="$1" wt="$2"
  [ -n "$self" ] && [ -n "$wt" ] || return 1
  [ "$self" = "$wt" ] && return 0
  case "$self/" in
    "$wt"/*) return 0 ;;
  esac
  return 1
}

# Resolve the self worktree once: explicit RITE_WORKTREE env wins (callers that
# know their worktree can set it; robust even when the invocation cwd was lost),
# otherwise the invocation directory captured before the cd to repo_root. Empty
# when neither is resolvable, which disables the guard (no false skips).
rite_self_dir="${RITE_WORKTREE:-$rite_invocation_pwd}"
rite_self_canon=$(_rite_canonical_dir "$rite_self_dir")

# Liveness TTL (Issue #1923). Both signals below used to protect an
# active=true holder with NO time bound, which deadlocks this guard forever
# when a session ends WITHOUT session-end.sh's SessionEnd hook firing (forced
# quit / crash / terminal close — see session-end.sh header for which exits
# skip it): its flow-state stays `active=true` and the worktree/branch it
# holds can never be lazily reaped. TTL_HOURS bounds that: an active=true
# holder is protected only while its `updated_at` is within the TTL.
# Overridable via env for ops/troubleshooting (no new rite-config.yml key —
# CLAUDE.md シンプルさを死守する).
readonly RITE_SESSION_LIVENESS_TTL_HOURS_RAW="${RITE_SESSION_LIVENESS_TTL_HOURS:-24}"
# Validate the env override is a positive base-10 integer with no leading zero
# (ops typo guard, e.g. "24h"): an invalid value must not silently corrupt the
# `* 3600` arithmetic below with a raw bash error. A leading zero (e.g. "010")
# would pass a laxer `^[0-9]+$` check yet be parsed as octal by bash arithmetic
# (`$(( 010 * 3600 ))` = 8h, not 10h) — silently wrong TTL, or a hard arithmetic
# error for octal-invalid digits like "08". `^[1-9][0-9]*$` rejects both "0"
# and any leading-zero value outright, so the surviving values are always
# valid decimal input to `$(( ... * 3600 ))` (this also makes a separate
# `-gt 0` check redundant — the pattern alone guarantees a positive integer).
# Falls back to the 24h default with a WARNING (fail-safe, same "protect on
# anything we can't compute" posture as the rest of this guard).
if [[ "$RITE_SESSION_LIVENESS_TTL_HOURS_RAW" =~ ^[1-9][0-9]*$ ]]; then
  readonly RITE_SESSION_LIVENESS_TTL_HOURS="$RITE_SESSION_LIVENESS_TTL_HOURS_RAW"
else
  echo "WARNING: RITE_SESSION_LIVENESS_TTL_HOURS='$(printf '%s' "$RITE_SESSION_LIVENESS_TTL_HOURS_RAW" | neutralize_ctrl)' は正の整数ではありません（先頭ゼロも不可）。既定値 24 を使用します。" >&2
  readonly RITE_SESSION_LIVENESS_TTL_HOURS=24
fi

# _rite_epoch_of_ts: best-effort ISO 8601 UTC (`Z` suffix OR `+HH:MM`/`-HH:MM`
# offset) -> epoch seconds. Tries GNU `date -d` (Linux) then BSD/macOS
# `date -j -f` — the same two-step technique as session-ownership.sh's
# parse_iso8601_to_epoch — but, unlike that helper, reports failure via return
# code instead of collapsing it to epoch 0. The caller (_rite_ttl_protects)
# must tell "malformed input" and "this host's date binary can't parse a
# well-formed timestamp" apart from "genuinely far in the past" — all three
# would alias to the same huge diff if compared against a fixed epoch-0
# fallback.
# The offset alternation (not `Z`-only) matters: flow-state.sh (the canonical
# writer) emits `Z`, but pre-compact.sh / session-start.sh / session-end.sh
# emit `+00:00` for the same `updated_at` field — a `Z`-only regex would
# silently fall into the "malformed" fail-safe (permanent protect, no WARNING)
# for any session whose last heartbeat came from one of those, reintroducing
# this Issue's own dead-lock.
#
# Single source of truth (Issue #1923 cycle 2 review finding): this regex is
# read by BOTH _rite_epoch_of_ts (below) and _rite_ttl_protects's
# date-incompatible check, to tell "malformed timestamp" (no WARNING, silent
# fail-safe) apart from "well-formed but this host's date can't parse it"
# (WARNING). A prior version duplicated the literal in both places — exactly
# the two-copies-diverge shape that produced this Issue's own cycle-1 CRITICAL
# bug (a `Z`-only literal in one copy). One readonly variable, referenced by
# `=~ $var`, makes that drift structurally impossible.
readonly _RITE_ISO8601_UTC_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$'
# Returns 0 with epoch on stdout, 1 on any parse failure.
_rite_epoch_of_ts() {
  local ts="$1" epoch ts_norm ts_nocolon
  [[ "$ts" =~ $_RITE_ISO8601_UTC_RE ]] || return 1
  # Normalize `Z` to `+00:00` (same technique as session-ownership.sh's
  # parse_iso8601_to_epoch) so both parse paths below only ever see an
  # explicit numeric offset.
  ts_norm="${ts/%Z/+00:00}"
  if epoch=$(date -u -d "$ts_norm" +%s 2>/dev/null); then
    printf '%s' "$epoch"; return 0
  fi
  # BSD/macOS date -j -f with %z needs the offset without a colon (+00:00 -> +0000).
  ts_nocolon="${ts_norm%:*}${ts_norm##*:}"
  if epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts_nocolon" +%s 2>/dev/null); then
    printf '%s' "$epoch"; return 0
  fi
  return 1
}

# _rite_ttl_protects: whether an active=true holder last active at
# `updated_at` (ISO 8601 UTC) is still within the liveness TTL (Issue #1923).
#   0 = protect: within TTL: OR updated_at missing/malformed (AC-4 fail-safe,
#       silent) OR this host's `date` cannot parse a well-formed timestamp
#       (4.5 fail-safe, WARNING emitted once per run — TTL enforcement
#       degrades to the pre-#1923 always-protect behavior on that host)
#   1 = TTL exceeded -> not protected by this signal (still subject to the
#       other liveness signal / Gates 1-3)
# AC-6: the boundary (age == TTL exactly) counts as "within" -> protect.
_rite_date_incompat_warned=0
_rite_ttl_protects() {
  local updated_at="$1" now_epoch upd_epoch age ttl_seconds
  [ -n "$updated_at" ] || return 0
  if ! upd_epoch=$(_rite_epoch_of_ts "$updated_at"); then
    if [[ "$updated_at" =~ $_RITE_ISO8601_UTC_RE ]] \
       && [ "$_rite_date_incompat_warned" != "1" ]; then
      echo "WARNING: この環境の date コマンドで updated_at ($(printf '%s' "$updated_at" | neutralize_ctrl)) を解釈できません。worktree liveness の TTL 判定を skip し、従来どおり active=true holder を無期限に保護します。" >&2
      _rite_date_incompat_warned=1
    fi
    return 0
  fi
  now_epoch=$(date -u +%s 2>/dev/null) || return 0
  age=$(( now_epoch - upd_epoch ))
  ttl_seconds=$(( RITE_SESSION_LIVENESS_TTL_HOURS * 3600 ))
  [ "$age" -le "$ttl_seconds" ]
}

# Worktree liveness guard (Issue #1524 + #1552). The 4th protection layer:
# extend Gate 0 self-exclusion to ALL sessions that may still resume into this
# worktree. Two independent signals, either of which protects (skip reap):
#   (A) flow-state.worktree scan — a session's per-session flow-state records
#       this worktree as its `active` `worktree` (Issue #1524), protected
#       while `updated_at` is within the liveness TTL above (Issue #1923;
#       previously unbounded — "no time bound: an active session protects
#       its tree regardless of idle time").
#   (B) claim-join (Issue #1552) — the issue's claim file records this worktree
#       and its holder session is still `active=true`, EVEN IF the claim's
#       heartbeat (flow-state `updated_at`) has aged past the 2h staleness window
#       used by issue-claim.sh `check` — but, like (A), only while that SAME
#       `updated_at` is within the liveness TTL (Issue #1923). A session that
#       is active=true but idle >2h (and <TTL) has a `stale` claim, which
#       Gate 2 alone would treat as reapable — reaping a worktree the harness
#       can still resume into and restore as cwd, breaking `/clear` with
#       `Path does not exist`. (B) closes that window for sessions whose
#       flow-state.worktree drifted empty/mismatched so (A) misses them,
#       since the claim reliably records the worktree↔holder binding.
# Both signals protect ONLY active=true holders WITHIN the TTL (Issue #1923):
# a deactivated/abandoned holder (active=false) stays reapable as before, and
# an active=true holder whose `updated_at` has aged past the TTL also stops
# being protected — bounding the worktree/branch leak from sessions that end
# without SessionEnd ever clearing `active`. Returns:
#   0 = an active=true session references $2 (canonical wt_path) AND its
#       updated_at is within the TTL (or TTL calc unavailable, fail-safe) → protect
#   2 = the sessions dir cannot be enumerated, or a flow-state cannot be parsed
#       → caller skips conservatively (AC-4): cannot prove no live session needs it
#   1 = no active session references it, or the referencing holder's TTL has
#       exceeded → reap may proceed (subject to other gates)
# Reads the shared-root sessions dir + issue-claims dir ($repo_root/.rite/...).
_rite_worktree_protected_by_flow_state() {
  local issue_num="$1" target_canon="$2"
  # (B) claim-join: protect when the issue's claim holder is still active=true,
  # regardless of the claim's 2h heartbeat staleness. Independent of the sessions
  # dir (the claim lives under .rite/state/issue-claims), so it runs first. A
  # missing/unreadable/corrupt claim simply yields no protection here (the (A)
  # scan and the downstream gates still apply) — NOT a conservative-skip, to avoid
  # over-protecting on a stray claim read error.
  local cfile="$repo_root/.rite/state/issue-claims/issue-${issue_num}.json"
  if [ -f "$cfile" ] && [ -r "$cfile" ]; then
    local _holder _cwt _hactive _hupdated
    _holder=$(jq -r '.session_id // ""' "$cfile" 2>/dev/null) || _holder=""
    _cwt=$(jq -r '.worktree // ""' "$cfile" 2>/dev/null) || _cwt=""
    if [ -n "$_holder" ] && [ -n "$_cwt" ] && { [ "$_cwt" = "$target_canon" ] || [ "$(_rite_canonical_dir "$_cwt")" = "$target_canon" ]; }; then
      _hactive=$(RITE_STATE_ROOT="$repo_root" bash "$SCRIPT_DIR/../flow-state.sh" \
                 get --session "$_holder" --field active --default "false" 2>/dev/null) || _hactive="false"
      if [ "$_hactive" = "true" ]; then
        # TTL gate (Issue #1923): active=true alone no longer protects — the
        # holder's updated_at must also be within the liveness TTL.
        _hupdated=$(RITE_STATE_ROOT="$repo_root" bash "$SCRIPT_DIR/../flow-state.sh" \
                   get --session "$_holder" --field updated_at --default "" 2>/dev/null) || _hupdated=""
        _rite_ttl_protects "$_hupdated" && return 0
      fi
    fi
  fi
  # (A) flow-state.worktree scan (Issue #1524).
  local sdir="$repo_root/.rite/sessions"
  [ -d "$sdir" ] || return 1
  # Existing-but-unreadable dir is an enumeration failure → conservative skip.
  [ -r "$sdir" ] && [ -x "$sdir" ] || return 2
  local f parse_failed=0
  for f in "$sdir"/*.flow-state; do
    [ -f "$f" ] || continue   # literal glob (no matches) or non-file → skip
    local _row _active _wt _updated
    # Single composite read so a corrupt flow-state is caught as a parse failure
    # (→ conservative skip) rather than silently degrading active/worktree to empty.
    _row=$(jq -r '[(.active // false | tostring), (.worktree // ""), (.updated_at // "")] | join("")' "$f" 2>/dev/null) || { parse_failed=1; continue; }
    IFS=$'\x1f' read -r _active _wt _updated <<< "$_row"
    [ "$_active" = "true" ] || continue
    [ -n "$_wt" ] || continue
    if [ "$_wt" = "$target_canon" ] || [ "$(_rite_canonical_dir "$_wt")" = "$target_canon" ]; then
      # TTL gate (Issue #1923): active=true + worktree match alone no longer
      # protects — this holder's updated_at must also be within the TTL.
      _rite_ttl_protects "$_updated" && return 0
    fi
  done
  [ "$parse_failed" -eq 1 ] && return 2
  return 1
}

# After a session worktree is reaped, clear the `worktree` reference from every
# flow-state that still records it, so neither rite's own re-entry path
# (open.md Step 0.5 / recover.md) nor a later harness cwd-restore is pointed at the
# now-deleted directory (Issue #1524 MUST: reap → null the owner's flow-state
# worktree). The write is routed through `flow-state.sh clear-worktree` to honor
# the `_atomic_write` convention; per-session failure WARNs and is non-blocking
# (AC-5). $1 = raw wt_path (already removed), $2 = its canonical form captured
# BEFORE removal (post-removal canonicalization of a deleted dir would not match).
_rite_null_worktree_refs() {
  local wt_raw="$1" wt_canon="$2"
  local sdir="$repo_root/.rite/sessions"
  [ -d "$sdir" ] && [ -r "$sdir" ] || return 0
  local f
  for f in "$sdir"/*.flow-state; do
    [ -f "$f" ] || continue
    local _wt; _wt=$(jq -r '.worktree // ""' "$f" 2>/dev/null) || continue
    [ -n "$_wt" ] || continue
    if [ "$_wt" = "$wt_raw" ] || [ "$_wt" = "$wt_canon" ] || [ "$(_rite_canonical_dir "$_wt")" = "$wt_canon" ]; then
      local _sid; _sid=$(basename "$f"); _sid="${_sid%.flow-state}"
      if RITE_STATE_ROOT="$repo_root" bash "$SCRIPT_DIR/../flow-state.sh" clear-worktree --session "$_sid" >/dev/null 2>&1; then
        :
      else
        echo "WARNING: reap 後の flow-state worktree クリアに失敗しました (session=$(printf '%s' "$_sid" | neutralize_ctrl))。非blocking で継続します。" >&2
      fi
    fi
  done
  # Explicit rc so the for-loop's trailing exit status (a non-matching `if`) never
  # trips the caller's `set -e` when this is invoked as a standalone statement.
  return 0
}

if [ -d "$session_wt_root" ]; then
  while IFS= read -r _wt_line; do
    case "$_wt_line" in
      "worktree "*) wt_path="${_wt_line#worktree }" ;;
      *) continue ;;
    esac
    # Must be a DIRECT child of the session worktree base.
    [ "$(dirname "$wt_path")" = "$session_wt_root" ] || continue
    [ -d "$wt_path" ] || continue
    wt_base=$(basename "$wt_path")
    # Gate 1: strict `^issue-[0-9]+$` (excludes .rite/wiki-worktree, .worktrees/*).
    [[ "$wt_base" =~ ^issue-[0-9]+$ ]] || continue
    issue_num="${wt_base#issue-}"

    # Gate 0: self-exclusion. Never reap the worktree THIS invocation is running
    # from (cwd == wt_path, or cwd nested under it) — a long-lived session must
    # not delete its own active worktree mid-flight. Independent of and evaluated
    # before the dirty (Gate 3) and claim (Gate 2) protections, so
    # even a clean + free + aged self worktree is preserved. Skip is logged (not
    # silent) per AC-2.
    if [ -n "$rite_self_canon" ] && _rite_dir_is_self "$rite_self_canon" "$(_rite_canonical_dir "$wt_path")"; then
      echo "WARNING: session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' は実行中の自セッション worktree のため reap をスキップします (self-exclusion)。" >&2
      continue
    fi

    # Canonicalize once (worktree still exists here): reused by the cross-session
    # liveness guard below AND by the post-reap null-ing (which must use the
    # pre-removal canonical form — a deleted dir no longer canonicalizes).
    _wt_canon=$(_rite_canonical_dir "$wt_path")

    # Gate (worktree liveness, Issue #1524 + #1552): never reap a worktree that a
    # session may still resume into — either a session records it as its active
    # `worktree` (#1524), OR the issue's claim holder is still active=true even
    # though its claim heartbeat aged past the 2h staleness window (#1552: an
    # active-but-idle session whose `stale` claim Gate 2 would otherwise reap).
    # Evaluated before Gate 3/Gate 2, like Gate 0, so a clean+stale+aged worktree
    # still owned by an active session is preserved. Enumeration/parse failure of
    # `.rite/sessions/` → conservative skip (AC-4). Skip is logged (not silent).
    # `func || rc=$?` (not `func; rc=$?`): under `set -e` a bare non-zero return
    # (rc=1 no active ref / rc=2 enum failure) would abort the whole reap loop.
    _live_rc=0
    _rite_worktree_protected_by_flow_state "$issue_num" "$_wt_canon" || _live_rc=$?
    if [ "$_live_rc" -eq 0 ]; then
      echo "WARNING: session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' は所有セッションが active（resume 可能）のため reap をスキップします (worktree liveness)。" >&2
      continue
    elif [ "$_live_rc" -eq 2 ]; then
      echo "WARNING: session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' の保護判定に必要な flow-state の列挙/parse に失敗したため、安全側で reap をスキップします。" >&2
      continue
    fi

    # Gate (OS-level live cwd, Issue #1544): never reap a worktree that ANY live
    # process is standing in (cwd at or under it). This is the flow-state-
    # independent backstop for #1524's recurrence: the cross-session liveness
    # guard above only protects worktrees a session records as its `active`
    # `worktree`, so it misses the dangling cases where the owning session's
    # harness cwd is still in the tree but its flow-state has drifted (active=false,
    # empty/nulled `worktree` field, or stale session-id). Removing such a tree
    # leaves the harness cwd pointing at a deleted dir → `/clear` fails with
    # `Path does not exist`. Delegated to worktree-live-cwd.sh (SoT, shared with
    # cleanup.md Step 4-W). rc 0 = live cwd present → skip; rc 2 = undeterminable
    # (no /proc & no lsof, e.g. older macOS) → fall through to the existing
    # claim/dirty gates (no behavior change vs pre-#1544). `|| _cwd_rc=$?` keeps a
    # non-zero rc from aborting the loop under `set -e`. Evaluated before Gate 3/2,
    # like the other liveness guards, so a clean+stale worktree someone stands in
    # is still preserved.
    _cwd_rc=0
    bash "$SCRIPT_DIR/worktree-live-cwd.sh" "$_wt_canon" >/dev/null 2>&1 || _cwd_rc=$?
    if [ "$_cwd_rc" -eq 0 ]; then
      echo "WARNING: session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' は live プロセスが cwd を置いているため reap をスキップします (live-cwd guard)。" >&2
      continue
    fi

    # Corpse detection (Issue #1957): a sandbox-masked `git worktree remove
    # --force` half-destroys the admin dir — HEAD alone unlinked, commondir /
    # gitdir / index left behind — after which every `git -C <wt>` operation
    # fails ("not a git repository"). Gate 3's conservative skip would protect
    # such a tree forever (its dirty state is structurally undeterminable), and
    # manual `git worktree remove --force` is rejected by validation, so
    # without this branch no recovery path exists. Corpse = admin HEAD missing
    # AND git does not recognize the tree — both required, so a mere
    # permission-broken tree (HEAD present, status rc != 0) stays on the
    # conservative-skip path (AC-5). The admin dir is resolved from the
    # worktree's own `.git` file (`gitdir: <path>` line): suffixed admin ids
    # from basename collisions still resolve, unlike a basename guess.
    _corpse=0
    _admin_dir=$(sed -n 's/^gitdir: //p' "$wt_path/.git" 2>/dev/null | head -1) || _admin_dir=""
    if [ -n "$_admin_dir" ] && [ -d "$_admin_dir" ] && [ ! -f "$_admin_dir/HEAD" ] \
       && ! git -C "$wt_path" rev-parse --git-dir >/dev/null 2>&1; then
      _corpse=1
    fi

    # Gate 3: dirty worktree is NEVER auto-reaped. An indeterminate status
    # (rc != 0) is treated conservatively as "do not reap" to avoid data loss.
    # A corpse bypasses this gate (Issue #1957 D-01): "indeterminable =
    # protect" would mean "protect forever" for a tree git can no longer
    # operate on at all. The uncommitted-work risk is accepted behind the
    # claim gate (Gate 2) plus the corpse age guard below.
    if [ "$_corpse" -eq 0 ]; then
      # `|| _st_rc=$?` (not a bare `$?` read): under `set -e` a non-zero status
      # rc would abort the whole reap loop instead of taking the conservative
      # skip below — the exact broken-tree inputs this gate exists to protect.
      _st_rc=0
      _st_out=$(git -C "$wt_path" status --porcelain 2>/dev/null) || _st_rc=$?
      if [ "$_st_rc" -ne 0 ]; then
        echo "WARNING: session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' の status を判定できません (rc=$_st_rc) — 安全側で reap をスキップします" >&2
        continue
      fi
      if [ -n "$_st_out" ]; then
        echo "WARNING: session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' は未コミット変更があるため auto-reap をスキップします。" >&2
        echo "  手動確認: git -C '$wt_path' status / 不要なら git worktree remove '$wt_path'" >&2
        continue
      fi
    fi

    # Gate 2: claim liveness. issue-claim.sh resolves its own session_id.
    claim_state=$(bash "$SCRIPT_DIR/../issue-claim.sh" check --issue "$issue_num" 2>/dev/null) || claim_state=""
    case "$claim_state" in
      other|own)
        # A live session holds the claim — leave the worktree intact.
        continue
        ;;
      stale)
        : # holder is not live → reapable
        ;;
      free|"")
        # No claim recorded → conservative mtime age guard (24h) so an in-flight
        # worktree that simply has not written a claim yet is not reaped. A fresh
        # corpse is excluded from this silent continue (Issue #1957): cleanup
        # releases the claim unconditionally, so a real-world corpse is claim-free
        # — this path would otherwise hide the anomaly without a WARNING. The
        # corpse falls through to the logged corpse age guard below (same 24h
        # window), which skips it loudly.
        if [ "$_corpse" -eq 0 ] && [ -z "$(find "$wt_path" -maxdepth 0 -mmin +"$WORKDIR_REAP_AGE_MINUTES" 2>/dev/null)" ]; then
          continue
        fi
        ;;
      *)
        continue
        ;;
    esac

    # Corpse age guard (Issue #1957 D-01): a corpse's dirty state cannot be
    # examined, so a not-live claim alone (Gate 2 above) must not reap it —
    # require the same 24h mtime age Gate 2 applies to free claims, for the
    # stale-claim path too (AC-4: a fresh corpse is never reaped). The skip is
    # logged, not silent: a corpse's existence is itself an anomaly the user
    # should see before the guard expires.
    if [ "$_corpse" -eq 1 ] && [ -z "$(find "$wt_path" -maxdepth 0 -mmin +"$WORKDIR_REAP_AGE_MINUTES" 2>/dev/null)" ]; then
      echo "WARNING: corpse session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' (admin HEAD 欠落・git 非認識) は age guard (24h) 未達のため回収を見送ります。" >&2
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      echo "[pr-cycle-cleanup] would reap session worktree: $wt_path (claim=${claim_state:-none}$([ "$_corpse" -eq 1 ] && printf ', corpse'))"
      continue
    fi

    # Corpse reap is loud (Issue #1957 MUST): name the target before touching it.
    if [ "$_corpse" -eq 1 ]; then
      echo "WARNING: corpse session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)' (admin HEAD 欠落・git 非認識) を rm -rf + prune で回収します (Issue #1957)。" >&2
    fi

    # Capture the checked-out branch BEFORE removal (the worktree is gone after) so
    # the post-reap branch recovery (#1670) can target it. Detached HEAD yields
    # "HEAD" → no branch to recover. (A corpse yields "" — git cannot read its
    # HEAD — so branch recovery is structurally skipped for corpses.)
    _reaped_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || _reaped_branch=""

    # Reap: remove --force first (drops worktree metadata + dir atomically),
    # rm -rf fallback for dirs whose registration was already lost. A corpse
    # always takes the rm -rf fallback: `git worktree remove --force` rejects it
    # at validation ("'<wt>/.git' is not a .git file", rc=128) without deleting
    # anything.
    if git worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path" 2>/dev/null; then
      # Corpse admin-dir recovery (Issue #1957): the rm -rf above only removed
      # the working tree; the half-destroyed admin dir would otherwise survive
      # (prune-independent removal — the corrupt entry must not linger in
      # `git worktree list` until the post-loop prune). Failure is non-blocking:
      # the post-loop prune and the next reap run both retry.
      if [ "$_corpse" -eq 1 ] && [ -d "$_admin_dir" ]; then
        if ! rm -rf "$_admin_dir" 2>/dev/null; then
          echo "WARNING: corpse admin dir '$(printf '%s' "$_admin_dir" | neutralize_ctrl)' の削除に失敗しました。手動回収: rm -rf '$_admin_dir' && git worktree prune" >&2
        fi
      fi
      session_worktrees_reaped=$((session_worktrees_reaped + 1))
      rm -f "$repo_root/.rite/state/issue-claims/issue-${issue_num}.json" 2>/dev/null || true
      # Null the dangling `worktree` reference in the owning session's flow-state
      # (uses the pre-removal canonical path) so re-entry / harness cwd-restore is
      # not pointed at the just-removed dir. Non-blocking (AC-5).
      _rite_null_worktree_refs "$wt_path" "$_wt_canon"

      # Branch recovery (#1670): the worktree is gone, so its branch is no longer
      # checked out and can be deleted. SAFE-delete first — `git branch -d` refuses
      # an unmerged branch, preserving a crashed session's in-progress work (AC-4).
      # If `-d` refuses BUT the branch is in the reap manifest, cleanup.md confirmed
      # its PR merged (the squash-merge case `-d` cannot detect, since squashed
      # commits are not ancestors of base) → force-delete is safe. A non-recorded
      # unmerged branch is kept with a WARNING (never destroy unmerged work).
      if [ -n "$_reaped_branch" ] && [ "$_reaped_branch" != "HEAD" ]; then
        # `--` (end-of-options) on every `git branch -d/-D` is a defense-in-depth
        # invariant shared with the manifest reap (`git branch -D -- ...`) and
        # documented in rite-tmp-artifact.sh: `_reaped_branch` comes straight from
        # `git rev-parse --abbrev-ref HEAD` without the recorder's leading-dash guard,
        # so `--` is the explicit backstop against an option-injecting branch name.
        if git branch -d -- "$_reaped_branch" >/dev/null 2>&1; then
          session_branches_deleted=$((session_branches_deleted + 1))
        elif [ -f "$manifest_path" ] && grep -qxF "branch$(printf '\t')$_reaped_branch" "$manifest_path" 2>/dev/null; then
          if git branch -D -- "$_reaped_branch" >/dev/null 2>&1; then
            session_branches_deleted=$((session_branches_deleted + 1))
            # The stale manifest `branch\t<name>` entry self-heals on the next run's
            # Step 4.5 (verify fails → already-gone → dropped), so no rewrite here.
          else
            echo "WARNING: failed to reap session worktree branch '$(printf '%s' "$_reaped_branch" | neutralize_ctrl)'" >&2
            errors=$((errors + 1))
          fi
        else
          echo "WARNING: session worktree branch '$(printf '%s' "$_reaped_branch" | neutralize_ctrl)' は未マージのため保持しました（不要なら手動削除: git branch -D '$(printf '%s' "$_reaped_branch" | neutralize_ctrl)'）。" >&2
        fi
      fi
    else
      echo "WARNING: failed to reap session worktree '$(printf '%s' "$wt_path" | neutralize_ctrl)'" >&2
      errors=$((errors + 1))
    fi
  done < <(git worktree list --porcelain 2>/dev/null)

  if [ "$DRY_RUN" = "0" ] && [ "$session_worktrees_reaped" -gt 0 ]; then
    git worktree prune 2>/dev/null || true
  fi
fi

# -----------------------------------------------------------------------
# Status line
# -----------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  echo "[pr-cycle-cleanup] status=dry-run; pattern=$PATTERN"
elif [ "$errors" -gt 0 ]; then
  echo "[pr-cycle-cleanup] status=failed; worktrees=$worktrees_removed; branches=$branches_deleted; workdirs=$workdirs_reaped; mutation_worktrees=$mutation_worktrees_reaped; session_worktrees=$session_worktrees_reaped; session_branches=$session_branches_deleted; manifest=$manifest_reaped; errors=$errors"
elif [ "$worktrees_removed" -eq 0 ] && [ "$branches_deleted" -eq 0 ] && [ "$workdirs_reaped" -eq 0 ] && [ "$mutation_worktrees_reaped" -eq 0 ] && [ "$session_worktrees_reaped" -eq 0 ] && [ "$session_branches_deleted" -eq 0 ] && [ "$manifest_reaped" -eq 0 ]; then
  echo "[pr-cycle-cleanup] status=noop; worktrees=0; branches=0; workdirs=0; mutation_worktrees=0; session_worktrees=0; session_branches=0; manifest=0"
else
  echo "[pr-cycle-cleanup] status=cleaned; worktrees=$worktrees_removed; branches=$branches_deleted; workdirs=$workdirs_reaped; mutation_worktrees=$mutation_worktrees_reaped; session_worktrees=$session_worktrees_reaped; session_branches=$session_branches_deleted; manifest=$manifest_reaped"
fi

exit 0
