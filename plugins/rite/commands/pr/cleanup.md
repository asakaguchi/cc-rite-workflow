---
description: PR マージ後のクリーンアップを実行
---

# /rite:pr:cleanup

PR マージ後のクリーンアップを実行する。やることは以下のシーケンシャルなタスク列:

0. flow-state を `phase=cleanup, active=true` に初期化
1. PR とブランチの状態を確認
2. 関連 Issue / 親 Issue を識別
3. 未完了タスクをチェック (あれば Issue 化を提示)
4. base ブランチに切り替えて最新を pull
5. ローカル / リモートブランチを削除
6. PR-specific state ファイルを削除
7. transient cycle ブランチを削除
8. Projects Status を Done に更新
9. (Wiki が有効なら) `rite:wiki:ingest` で raw source を統合
10. 関連 Issue / 親 Issue をクローズ
11. 作業メモリを最終更新 + ローカルファイル削除
12. 完了報告を出す

途中で止まったら flow-state に `phase=cleanup, active=true` が残るので `/rite:resume` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md) で解決する。

## Arguments

| Argument | Description |
|----------|-------------|
| `[branch_name]` | クリーンアップ対象ブランチ（省略時は現在のブランチ） |

---

## ステップ 0: flow-state 初期化

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
  --next "Execute cleanup tasks sequentially." \
  || bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --issue 0 --branch "" --pr 0 --active true \
       --next "Execute cleanup tasks sequentially." \
  || echo "WARNING: flow-state init failed — recovery via /rite:resume may not work." >&2
```

---

## ステップ 1: PR とブランチの状態を確認

### 1.1 現在のブランチを確認

```bash
git branch --show-current
```

### 1.2 base ブランチを取得

`rite-config.yml` の `branch.base` を読む。未設定なら `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'` で検出。検出失敗時は誤ブランチ切替を防ぐため中断 (`rite-config.yml` の `branch.base` 設定 or `git remote set-head origin --auto` を案内)。

引数省略 + base branch 上にいる場合は `git branch --merged {base_branch}` で候補を表示し `/rite:pr:cleanup <branch_name>` の指定を案内する。

### 1.3 関連 PR の検索と状態検証

```bash
gh pr list --head {branch_name} --state all --json number,title,state,mergedAt,url
```

PR 未検出: `AskUserQuestion` で「ブランチを削除して続行 / キャンセル」を確認。未マージ PR: 「キャンセル (推奨) / 強制クリーンアップ」を確認。

### 1.4 リポジトリ情報取得

```bash
gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'
```

---

## ステップ 2: 関連 Issue / 親 Issue を識別

### 2.1 関連 Issue 識別

PR body の `Closes/Fixes/Resolves #XX` またはブランチ名の `issue-XX` から識別:

```bash
gh pr view {pr_number} --json body,headRefName
gh issue view {issue_number} --json number,title,state,body
```

### 2.2 親 Issue 検出

Sub-Issues API を優先し、無ければ Tasklist fallback。見つかれば `{parent_issue_number}` / `{parent_issue_title}` / `{parent_issue_state}` を保持。

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { parent { number title state } } }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

```bash
gh issue list --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number,title,state --jq '.[0]'
```

見つからなければステップ 10 の親処理をスキップ (non-blocking)。

---

## ステップ 3: 未完了タスクのチェック

関連 Issue が識別できなければステップ 4 へ進む。

`.rite-work-memory/issue-{issue_number}.md` を Read で読む。無ければ Issue コメントから work memory を取得:

```bash
comment_body=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body // empty')
```

進捗セクションと Issue 本文の未完了チェックボックス (`- [ ] #XX` の親子 Tasklist は除外) を検出:

```bash
incomplete=$(printf '%s\n' "$comment_body" | sed -n '/### 進捗/,/### /p' \
  | grep -E '^\s*- \[ \]' | grep -v -E '^\s*- \[ \] #[0-9]+' | head -10)
```

未完了タスクがあれば `AskUserQuestion` で「未完了タスクを Issue 化 (推奨) / 無視して続行 / キャンセル」を確認。Issue 化選択時は各タスクを `残作業` label 付きで作成する。

**Placeholder Legend** (cleanup.md ステップ 3 specific、bash skeleton で使用する placeholder の source):

| Placeholder | Source | 例 |
|-------------|--------|----|
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md) | `/home/user/.claude/plugins/rite` |
| `{pr_number}` | ステップ 1 で取得した PR 番号 | `1149` |
| `{pr_title}` | `gh pr view --json title --jq '.title'` | `fix(workflow): ...` |
| `{issue_number}` | ステップ 2 で識別した関連 Issue 番号 | `1144` |
| `{task_title}` | work memory 進捗セクションの未完了タスク見出し | `step-5: references/ 整理` |
| `{task_text}` | 同上の本文 (チェックボックス行のテキスト) | `step-5: references/ 整理` |
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` (boolean) | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `asakaguchi` |

**Issue 本文テンプレート** (cleanup-specific、各タスクごとに以下の形式で生成):

```markdown
## 概要

{task_title}

## 背景・目的

PR #{pr_number} ({pr_title}) のマージ時点で未完了だったタスクを残作業として切り出す。元 PR の context を維持するため、根拠を以下に保持する。

## 関連

- 元 PR: #{pr_number}
- 元 Issue: #{issue_number}
- 元の進捗チェックボックス (work memory より): `- [ ] {task_text}`

## 変更内容

{task_text}

## チェックリスト

- [ ] {task_text}
```

**bash skeleton** (タスクごとに以下を反復実行、`{plugin_root}` / `{pr_number}` / `{pr_title}` / `{issue_number}` / `{task_title}` / `{task_text}` / `{projects_enabled}` / `{project_number}` / `{owner}` は Claude が事前 substitute):

```bash
# 0. `残作業` label を冪等に事前作成 (gh issue create --label X は X 未存在時に
# `could not add label: 'X' not found` で fail し Issue creation 自体が失敗するため必須)
gh label create 残作業 --description "PR マージ後の残作業" --color "fbca04" 2>/dev/null || true

# 1. Issue 本文を tempfile に書き出し
# trap 設置順は references/bash-trap-patterns.md#signal-specific-trap-template と統一。
# HEREDOC delimiter は single-quoted ('BODY_EOF') を必須化する:
#   - peer file convention (commands/issue/create.md L157,287,348 / commands/pr/{create,review,fix}.md) に対称
#   - {task_text} / {pr_title} は work memory / PR title 由来 (外部入力) で `$VAR` / `$(cmd)` / backtick を含み得る
#   - unquoted delimiter は shell expansion と command injection リスクを生む
tmpfile=""
_rite_cleanup_step3_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_cleanup_step3_cleanup; exit $rc' EXIT
trap '_rite_cleanup_step3_cleanup; exit 130' INT
trap '_rite_cleanup_step3_cleanup; exit 143' TERM
trap '_rite_cleanup_step3_cleanup; exit 129' HUP

tmpfile=$(mktemp) || {
  echo "ERROR: ステップ 3 残作業 Issue body tempfile の mktemp に失敗" >&2
  exit 1  # fail-fast (peer file commands/issue/create.md と対称、enclosing loop 非依存)
}
cat > "$tmpfile" <<'BODY_EOF'
{Issue 本文テンプレート (上記) を実値で展開}
BODY_EOF

# mktemp 0-byte ガード: cat 成功でも空ファイルなら create-issue script が
# 空 body Issue を作成する silent regression を防ぐ
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: ステップ 3 Issue 本文の生成に失敗 (tmpfile が空)" >&2
  exit 1
fi

# 2. create-issue-with-projects.sh 呼び出し (result capture + rc check)
# iter_mode は "none" hardcode (peer file commands/issue/create.md と対称、
# 残作業 Issue を特定 iteration に紐付ける要件なし — default Todo backlog で十分)
# args_json を入れ子 $() から分離して構築する (深い入れ子 quoting の malform 源を削減。
# 単一 JSON 引数契約は不変)
args_json=$(jq -n \
  --arg title "残作業: {task_title}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "S" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file, labels: ["残作業"] },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "cleanup", non_blocking_projects: true }
  }') || {
  echo "ERROR: ステップ 3 args_json の jq 構築に失敗しました (タスク: {task_title})" >&2
  exit 1  # fail-fast (peer file commands/issue/create.md と対称)
}
result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$args_json")
if [ -z "$result" ]; then
  echo "ERROR: ステップ 3 create-issue-with-projects.sh が空 result を返しました (タスク: {task_title})" >&2
  echo "  対処: スクリプト stderr / GitHub API 認証 / Projects 設定を確認してください" >&2
  exit 1  # fail-fast (continue は enclosing loop なしで fall-through するため使用しない)
fi

# 3. 作成 Issue の番号 / URL / Projects 警告を表示
new_issue_number=$(printf '%s' "$result" | jq -r '.issue_number // empty')
new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url // empty')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration // empty')
printf '✅ 残作業 Issue 作成: #%s %s\n' "$new_issue_number" "$new_issue_url" >&2
printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do
  echo "  ⚠️ $w" >&2
done
case "$project_reg" in
  partial|failed)
    echo "  ⚠️ Projects 登録: $project_reg (手動登録: gh project item-add {project_number} --owner {owner} --url $new_issue_url)" >&2
    ;;
esac
```

汎用的な argument structure・mapping 表は [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md) を参照。`source: "cleanup"` 引数は本 caller の識別子として必須 (将来 metrics 集計で起点 caller を区別するため)。`残作業` label は **step 0 で `gh label create 残作業` を冪等に事前作成する** ことが必須 (`gh issue create --label X` は X 未存在時に fail するため。`2>/dev/null || true` で既存ラベル時のエラーを無視)。

---

## ステップ 4: セッション worktree の退出・削除 + base 更新

### 4-W セッション worktree の退出・削除（multi_session 有効 + worktree 内から呼ばれた場合）

まず multi_session の有効性と、現在 cwd がこの Issue のセッション worktree かどうかを判定する:

```bash
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
flow_wt=$(bash {plugin_root}/hooks/flow-state.sh get --field worktree --default "") || flow_wt=""
cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
if [ "$ms_enabled" = "true" ] && [ -n "$flow_wt" ] && [ "$flow_wt" = "$cur_top" ]; then
  dirty=$(git status --porcelain 2>/dev/null)
  echo "[CONTEXT] CLEANUP_WT=in_worktree; worktree=$flow_wt; dirty=$([ -n "$dirty" ] && echo yes || echo no)"
else
  echo "[CONTEXT] CLEANUP_WT=$([ "$ms_enabled" = "true" ] && [ -n "$flow_wt" ] && echo in_main || echo none); worktree=$flow_wt"
fi
```

- `CLEANUP_WT=in_worktree`（cwd がセッション worktree）:
  1. `dirty=yes` なら **AskUserQuestion**（「`git stash push` して続行 / 中止」）。stash は common git dir に格納されるため worktree 削除後も `git stash pop` 可能（完了報告の stash 案内は従来文面を流用）。
  2. `ExitWorktree` ツールを `action: "keep"` で呼び出し、main checkout に復帰する（path 入場した worktree は remove でも消えない仕様のため**常に keep**）。
  3. main から worktree を削除する。**削除前に live-cwd guard（Issue #1544）を通す**: 別のセッションの harness cwd がまだこの worktree に立っている場合に削除すると、そのセッションの `/clear` が `Path does not exist` で失敗するため、live プロセスが cwd を置いているときは削除せず遅延 reap（`pr-cycle-cleanup.sh` の session worktree reap）へ委譲する:
     ```bash
     _lc_rc=0
     bash {plugin_root}/hooks/scripts/worktree-live-cwd.sh "{flow_wt}" >/dev/null 2>&1 || _lc_rc=$?
     if [ "$_lc_rc" -eq 0 ]; then
       echo "WARNING: worktree '{flow_wt}' に live プロセスが cwd を置いているため削除を skip しました（遅延 reap pr-cycle-cleanup.sh に委譲。harness cwd dangling → /clear エラーの防止）。" >&2
       echo "[CONTEXT] WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1; path={flow_wt}" >&2
     else
       git worktree remove "{flow_wt}" 2>/dev/null || git worktree remove --force "{flow_wt}" 2>/dev/null || echo "[CONTEXT] WORKTREE_REMOVE_FAILED=1; path={flow_wt}" >&2
       git worktree prune 2>/dev/null || true
     fi
     ```
     > `in_worktree` 経路ではステップ 2 の `ExitWorktree` で harness cwd が main に退避済みのため、この guard は通常 rc=1（live cwd 不在）で削除へ進む。`worktree-live-cwd.sh` が rc=2（`/proc` も `lsof` も無い環境で判定不能）を返す場合は `if` が false となり従来どおり削除を実行する（後方互換）。
  4. 削除失敗（`WORKTREE_REMOVE_FAILED`）または live-cwd skip（`WORKTREE_REMOVE_SKIPPED_LIVE_CWD`）は **WARNING を表示して続行**（non-blocking。`pr-cycle-cleanup.sh` の遅延 reap へ委譲。ステップ 12 報告に失敗/skip と手動コマンドを表示）。
- `CLEANUP_WT=in_main`（resume 等で既に main 復帰済み）: 上記 1〜2 をスキップ。worktree が残っていれば 3 を実行（既削除なら 3 もスキップ = 冪等）。in_main では所有セッションが別セッションの可能性があるため、3 の live-cwd guard が特に重要。
- `CLEANUP_WT=none`（multi_session 無効 or worktree 未記録）: 4-W 全体を no-op でスキップ。

> **復旧: `/clear` が `Path does not exist` で失敗する場合（Issue #1552）**
> セッション worktree（`.rite/worktrees/issue-{N}`）が遅延 reap または手動削除で消えた後、所有セッションをハーネスが resume すると cwd 復元先が無く `/clear` が `Error: Path "...worktrees/issue-{N}" does not exist` で失敗することがある。`pr-cycle-cleanup.sh` の worktree liveness guard（Issue #1524/#1544/#1552）はこれを予防するが、ハーネスの cwd レコード自体は rite から intercept できないため、万一発生した場合は次のいずれかで復旧する:
> 1. リポジトリ root（main checkout）で**新しいセッションを開始**する（cwd が有効になり `/clear` が機能する）。
> 2. 作業を続けるなら、有効なディレクトリで `/rite:resume {issue_number}` を実行する（worktree が消えていれば再構築経路に入る）。
> 3. 残骸が残っていれば `git worktree prune` で参照を整理する。
> session-start hook の挙動は 2 経路に分かれる（相互排他、同一フック実行内では片方のみ発火、いずれも非blocking）: (a) cwd 自体が消えた session worktree を指す場合は上記ガイドを stderr に表示してその場で `exit 0` する、(b) cwd は有効だが記録された worktree 参照だけが消えた場合は flow-state の dangling 参照を自動クリアする。

### 4 base ブランチの更新（安全化）

main checkout の不可侵規約（[git-worktree-patterns.md](../../references/git-worktree-patterns.md#multi-checkout-不可侵-inviolability-convention)）に従い、**main checkout が `{base_branch}` 上にある場合のみ** pull する。別 branch 上では切り替えず WARNING + skip する:

```bash
cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || cur_branch=""
if [ "$cur_branch" = "{base_branch}" ]; then
  # index.lock 競合 3 回リトライ
  n=0; until git pull --ff-only origin {base_branch} 2>/dev/null; do n=$((n+1)); [ "$n" -ge 3 ] && { echo "WARNING: git pull --ff-only origin {base_branch} が失敗しました (index.lock 競合 / コンフリクトの可能性)。git status で確認してください。" >&2; break; }; sleep 1; done
else
  echo "WARNING: main checkout が '{base_branch}' ではなく '$cur_branch' 上にあるため base pull を skip しました。" >&2
  echo "  復旧手順: 別の作業が無いことを確認のうえ 'git switch {base_branch}' で main checkout を base に戻してから再実行してください（rite は multi_session モードで main checkout のカレントブランチを切り替えません）。" >&2
fi
```

> **multi_session 無効（従来モード）の場合**: 従来どおり `git checkout {base_branch} && git pull origin {base_branch}` を実行する（base branch 以外にいて未コミット変更があれば「stash して続行 / キャンセル」を確認。stash は `git stash push -m "rite-cleanup: auto-stash before cleanup"`）。pull コンフリクト時は `git status` で確認・解決後の再実行を案内し terminate。

---

## ステップ 5: ローカル / リモートブランチを削除

> **順序**: branch 削除は **worktree 削除後にのみ成功する**（Git 制約: worktree で checkout 中の branch は削除不可）。multi_session 時は必ずステップ 4-W → 本ステップの順で実行する。

```bash
git branch -d {branch_name}
git ls-remote --heads origin {branch_name} && git push origin --delete {branch_name}
```

ローカル削除が未マージ変更で失敗したら「強制削除 (`-D`) / スキップ」を確認。リモート削除は GitHub auto-delete で既削除のエラーは無視。

---

## ステップ 6: PR-specific state ファイルを削除 <!-- AC-7 -->

マージ済み PR に紐づく state ファイルを削除する。**他 PR 誤削除防止のため glob は `{pr_number}-` prefix 固定**。

> **Acceptance Criteria anchor (AC-7)**: [review-result-schema.md](../../references/review-result-schema.md#クリーンアップ) と双方向リンク。

```bash
pr_number="{pr_number}"
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: invalid pr_number: '$pr_number'" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number" >&2
    exit 0 ;;
esac

rite_rm() {
  local label="$1"; shift
  local f
  for f in "$@"; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    if rm -f "$f"; then
      echo "✅ ${label} を削除: $f" >&2
    else
      echo "WARNING: ${label} 削除失敗 (PR #${pr_number}): $f" >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${label}_rm_failure; pr=${pr_number}" >&2
    fi
  done
}

rite_rm review_results \
  .rite/review-results/${pr_number}-*.json \
  .rite/review-results/${pr_number}-*.json.corrupt-*
rite_rm fix_retry_state ".rite/state/fix-fallback-retry-${pr_number}.count"
rite_rm fix_cycle_state ".rite/fix-cycle-state/${pr_number}.json"
rite_rm legacy_fix_cycle_state ".rite/fix-cycle-state.json"
rite_rm accepted_fingerprints ".rite/state/accepted-fingerprints-${pr_number}.txt"
```

`.rite/wiki-worktree/` は永続 worktree のため削除しない (再作成コストが高く各 PR cycle を跨いで保持する)。手動削除が必要なら `git worktree remove .rite/wiki-worktree && git worktree prune`。

---

## ステップ 7: transient cycle ブランチを削除

Reviewer subagent が作る `pr-{N}-cycle{X}` 命名の transient ブランチを回収する (reviewer は READ-ONLY 制約で自己クリーン不可)。non-blocking:

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

---

## ステップ 8: Projects Status を Done に更新

`rite-config.yml.github.projects.enabled: true` の場合のみ。詳細は [archive-procedures.md](./references/archive-procedures.md) (Projects Status Update セクション)。

結果を `projects_status_updated` (true/false) として context に保持し、ステップ 12 の表示で参照する。

---

## ステップ 9: Wiki Ingest (条件付き)

`wiki.enabled` (default true) かつ `wiki.auto_ingest` (default false) で、pending raw source があれば実行。

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
parse_wiki_key() {
  printf '%s\n' "$wiki_section" | awk -v k="$1" '$0 ~ "^[[:space:]]+" k ":" { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed "s/.*$1:[[:space:]]*//" | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]'
}
wiki_enabled=$(parse_wiki_key enabled)
auto_ingest=$(parse_wiki_key auto_ingest)
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; *) wiki_enabled="true" ;; esac
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac

reason=""
[ "$wiki_enabled" = "false" ] && reason="disabled"
[ -z "$reason" ] && [ "$auto_ingest" = "false" ] && reason="auto_ingest_off"

pending_count=0
wiki_branch=$(parse_wiki_key branch_name); [ -z "$wiki_branch" ] && wiki_branch="wiki"
if [ -z "$reason" ]; then
  ref=""
  git rev-parse --verify "$wiki_branch" >/dev/null 2>&1 && ref="$wiki_branch"
  [ -z "$ref" ] && git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1 && ref="origin/$wiki_branch"
  if [ -n "$ref" ]; then
    pending_count=$(git ls-tree -r --name-only "$ref" .rite/wiki/raw/ 2>/dev/null \
      | while read -r f; do git show "$ref":"$f" 2>/dev/null | grep -q 'ingested: false' && echo "$f"; done | wc -l)
  fi
  [ "$pending_count" -eq 0 ] && reason="no_pending"
fi

if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
fi
echo "wiki_ingest_reason=${reason:-<run>} pending_count=$pending_count wiki_branch=$wiki_branch"
```

`reason` が空なら (pending raw source あり)、まず Stop-hook 継続保証のチェーン handoff をセットする:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
  --handoff "WIKICHAIN:cleanup:{pr_number}" \
  --next "wiki:ingest return 後、cleanup ステップ 10-12 を継続実行" \
  || echo "WARNING: WIKICHAIN handoff set failed — turn 早期終了への構造的 gate なしで続行します。" >&2
```

> **Why (mechanical gate)**: cleanup → wiki:ingest → wiki:lint の 2 段ネスト skill return 直後に LLM が turn を閉じる implicit stop が累積再発している。iterate ループの Stop-hook 継続保証 と同型の one-shot handoff を移植し、チェーン途中で turn が閉じた場合は Stop hook (`stop-loop-continuation.sh`) が `WIKICHAIN:*` を consume して停止を差し戻し、残り step (ingest 残処理 → ステップ 10-12) の継続を強制する。チェーンがステップ 12 まで完走した場合はステップ 12 末尾の `flow-state.sh set` (`--handoff` なし) が handoff を default-clear するため block は発生しない。consume は one-shot のため無限 block しない。
>
> **制約**: 本 set からステップ 12 末尾の set までの間に別の `flow-state.sh set` を挟むと handoff が default-clear されて gate が外れる。このため、ステップ 10-11 への `flow-state.sh set` の追加自体を禁止する (`--handoff` 再指定での回避は TC-1 の単一 SoT 制約と矛盾するため不可)。intervening set が必要になる設計変更では、本 note と `cleanup-wikichain-handoff-parity.test.sh` TC-1/TC-6 を含む handoff lifecycle 全体を同時に見直すこと。

handoff セット後に invoke する:

```
Skill: rite:wiki:ingest
```

skill return 後、出力から以下のいずれかの sentinel を発火させる (ステップ 12 の表示判定に使用):

- 成功: `[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}`
- push 失敗併存 (ingest 出力に `push=failed`): 上記 + `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; source=cleanup_step9`
- 並行 ingest スキップ (ingest 出力に `WIKI_INGEST_SKIPPED reason=concurrent_ingest`): `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=concurrent_ingest`（別 live セッションが ingest 中。pending raw は wiki branch に残り次回 ingest が冪等回収する — multi-session §9）
- 失敗: `[CONTEXT] WIKI_INGEST_FAILED=1; reason=ingest_error`

ingest の成否（skip 含む）に関わらずステップ 10 へ進む。

---

## ステップ 10: 関連 Issue / 親 Issue をクローズ

詳細は [archive-procedures.md](./references/archive-procedures.md) (Issue close / Parent Issue handling セクション)。

- 関連 Issue (`{issue_number}`) を close
- 親 Issue (`{parent_issue_number}`) の Tasklist を更新
- 親 Issue の全子 Issue が完了していれば parent も auto-close

結果を context に保持し、ステップ 12 の表示で参照する。

---

## ステップ 11: 作業メモリを最終更新 + ローカルファイル削除

詳細は [archive-procedures.md](./references/archive-procedures.md) の以下 2 セクション両方を実行する:

- **Work Memory final update セクション** (= `### 3.5`): Issue comment への完了マーク追記 (gh API PATCH)
- **State reset セクション** (= `## Phase 4: Reset State and Delete Local Work Memory`): `cleanup-work-memory.sh` 実行による local `.rite-work-memory/issue-*.md` ファイル削除 + flow state `active: false` リセット

両方を実行しないと、Issue comment は最終化されるがローカル file は永続蓄積し `post-tool-wm-sync.sh` が次セッションで file を再生成する race 経路が開く。

あわせて Issue claim を解放する（`multi_session.enabled` に依らず常時実行。claim 取得は pr:open Step 1.6）。`issue-claim.sh release` は flow-state を変更しないため、ステップ 9 の `WIKICHAIN:` handoff 契約（ステップ 9〜12 間で `flow-state.sh set` を挟まない）に抵触しない:

```bash
bash {plugin_root}/hooks/issue-claim.sh release --issue {issue_number} 2>&1 || echo "WARNING: issue-claim release が失敗しました（claim は stale 判定 + reap で回収されます）。" >&2
```

---

## ステップ 12: 完了報告

```
クリーンアップが完了しました

PR: #{pr_number} - {pr_title}
関連 Issue: #{issue_number}
Status: {projects_status_result}

実行した処理:
- [x] base ブランチに切替・pull
- [{session_worktree_check}] セッション worktree 退出・削除 (multi_session)
- [x] ローカル/リモートブランチ削除
- [{review_cleanup_check}] PR-specific state ファイル削除
- [{projects_check}] Projects Status を Done に更新
- [{wiki_ingest_check}] Wiki ingest (pending raw source のページ統合)
- [x] flow state リセット
- [x] 作業メモリを最終更新 + ローカルファイル削除
- [x] Issue claim 解放
- [x] 関連 Issue をクローズ
- [x] 親 Issue の Tasklist 更新・自動クローズ (該当する場合)
```

各チェックボックスおよび placeholder の判定:

- `{session_worktree_check}`: multi_session 無効 or worktree 未使用なら行ごと省略。以下を**上から評価し最初に一致したもの**を採用する（`WORKTREE_REMOVE_SKIPPED_LIVE_CWD` と `WORKTREE_REMOVE_FAILED` は Step 4-W guard の if/else で排他だが、両 `[CONTEXT]` 行が文脈に残る可能性に備えて評価順序を固定する）:
  - `WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1` のとき（live-cwd guard が削除を skip）: ` ` + 以下を付記
    ```
    ℹ️ セッション worktree は別セッションが cwd を置いているため削除を skip しました（遅延 reap が後で回収します）。
      手動削除（当該セッションの /clear 後）: git worktree remove --force {flow_wt} && git worktree prune
    ```
  - `WORKTREE_REMOVE_FAILED=1` のとき（削除そのものが失敗）: ` ` + 以下を付記
    ```
    ⚠️ セッション worktree の削除に失敗しました（遅延 reap が後で回収します）。
      手動削除: git worktree remove --force {flow_wt} && git worktree prune
    ```
  - いずれの `[CONTEXT]` 行も無い（削除成功）とき: `x`
- `{projects_status_result}`: `projects_status_updated=true` なら `Done`、false なら `⚠️ 更新失敗（手動確認が必要）`
- `{review_cleanup_check}`: `REVIEW_CLEANUP_PARTIAL_FAILURE=1` なら ` ` + 警告付記、なければ `x`
- `{projects_check}`: `projects_status_updated=true` なら `x`、false なら ` ` + 「GitHub Projects 画面で Issue #{issue_number} の Status を Done に変更」を付記
- `{wiki_ingest_check}`: 以下の sentinel を上から評価し最初の一致を採用 (`WIKI_INGEST_DONE` + `WIKI_INGEST_PUSH_FAILED` が併存しうるため順序重要):

  | Sentinel | check | 表示 |
  |---|---|---|
  | `WIKI_INGEST_DONE=1` + `WIKI_INGEST_PUSH_FAILED=1` | ` ` | push 失敗警告 |
  | `WIKI_INGEST_PUSH_FAILED=1` 単独 | ` ` | push 失敗警告 |
  | `WIKI_INGEST_DONE=1` 単独 | `x` | — |
  | `WIKI_INGEST_SKIPPED=1; reason=disabled` | `x` | `ℹ️ Wiki ingest スキップ (wiki.enabled=false)` |
  | `WIKI_INGEST_SKIPPED=1; reason=auto_ingest_off` | `x` | `ℹ️ Wiki ingest スキップ (wiki.auto_ingest=false)` |
  | `WIKI_INGEST_SKIPPED=1; reason=no_pending` | `x` | `ℹ️ Wiki ingest スキップ (pending raw source なし)` |
  | `WIKI_INGEST_SKIPPED=1; reason=concurrent_ingest` | `x` | `ℹ️ Wiki ingest スキップ (別セッションが ingest 中。pending raw は次回回収)` |
  | `WIKI_INGEST_FAILED=1` | ` ` | `⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。` |

  push 失敗警告 (`{wiki_branch}` はステップ 9 で解決済):
  ```
  ⚠️ Wiki ingest: commit は local wiki branch に landed しましたが origin への push に失敗しました。
    手動回復: git -C .rite/wiki-worktree push origin {wiki_branch}
  ```

親 Issue 処理結果 (該当する場合のみ):
```
親 Issue 処理:
- 親 Issue: #{parent_issue_number} - {parent_issue_title}
- 結果: {parent_close_result}
```

`{parent_close_result}` の値域 (ステップ 10 で決定された 4 種類のいずれか):
- `✅ 自動クローズ完了 (全 sub-issue clear)` — 親 Issue が全 sub-issue 完了で自動 close
- `🟡 sub-issue 残あり (close 保留)` — 残 sub-issue があり親は open のまま
- `⚠️ 手動確認推奨` — 親 Issue 状態が判定不能で manual triage 推奨
- `(該当なし)` — 親 Issue が識別されなかった (ステップ 2 で見つからず)

未完了タスク Issue 化結果 (該当する場合のみ):
```
未完了タスク処理 — 作成した Issue:
| Issue | タイトル |
|-------|----------|
| #{new_issue_number} | {task_title}（#{issue_number} 残作業） |
```

`{new_issue_number}` の source: ステップ 3 の `create-issue-with-projects.sh` 出力 `issue_number` フィールド (`jq -r '.issue_number'` で抽出した値)。`{task_title}` / `{issue_number}` は ステップ 3 Placeholder Legend と同一定義 (work memory 進捗セクションの未完了タスク見出し / ステップ 2 で識別した関連 Issue 番号)。

stash した変更があれば「復元する (`git stash pop`) / 後で手動で復元」を確認する。

次のステップ (通常 ordered list として出力 — fenced code block 禁止。`<!-- skill return signal: caller must continue next step -->` + `<!-- [cleanup:returned-to-caller] -->` は最終 list item 末尾に半角スペース区切りで inline 付加):

次のステップ:
1. `/rite:issue:list` で次の Issue を確認
2. `/rite:pr:open <issue_number>` で新しい作業を開始 <!-- skill return signal: caller must continue next step --> <!-- [cleanup:returned-to-caller] -->

> **Why `returned-to-caller` (not `completed`)**: 旧 `cleanup:completed` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、cleanup → wiki:ingest → wiki:lint のネストで lint 直後に turn が暗黙終了する事象が複数回再発した。`returned-to-caller` で terminal vocabulary を構造的に排除する。

最後に flow state を terminal state に落とす:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --next "none" --active false --if-exists \
  || echo "WARNING: flow-state deactivate failed — .active=true が残る可能性。" >&2
```

この set は `--handoff` を持たないため、ステップ 9 でセットした `WIKICHAIN:cleanup:{pr_number}` handoff を default-clear する (チェーン完走 = gate 解除)。チェーン途中で turn が閉じた場合のみ Stop hook が handoff を consume して継続を差し戻す。

---

## Error Handling

詳細は [Common Error Handling](../../references/common-error-handling.md)。

| Error | Recovery |
|-------|----------|
| PR Not Found | [共通パターン](../../references/common-error-handling.md) |
| Branch Deletion Failure | `git branch` でブランチ一覧を確認; base ブランチに切替後再実行 |
| Network Error | [共通パターン](../../references/common-error-handling.md) |
| Issue Not Found | [共通パターン](../../references/common-error-handling.md) |
| Issue Close Failure | `gh issue view {issue_number}` で状態確認; 手動で `gh issue close {issue_number}` |
| Incomplete Task Issue Creation Failure | クリーンアップは続行; タスクを手動で Issue 化 |
