---
description: PR マージ後のクリーンアップを実行
---

# /rite:pr:cleanup

> **Charter**: This command and its `references/` are subject to the [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述・cycle 番号引用・重複 confirmation は書かない。

## Contract
**Input**: Merged PR (auto-detected from current branch or specified)
**Output**: Cleanup result summary (branch deletion, Status update, Issue close results)

PR マージ後のクリーンアップ（ブランチ削除・デフォルトブランチ切替・Projects Status 更新・関連 Issue クローズ）を自動化する。

途中で止まったら flow-state に `phase=cleanup, active=true` が残るので `/rite:resume` で再開する。Stop hook・自動継続機構・retrospective incident detector は無い（単層 + ユーザー操作の設計）。

## Arguments

| Argument | Description |
|----------|-------------|
| `[branch_name]` | クリーンアップ対象ブランチ（省略時は現在のブランチ） |

---

## Phase 1.0: Activate Flow State

**Step 0: Resolve plugin root**（一度だけ実行し、以降の `{plugin_root}` で再利用）:

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/hooks" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

cleanup が in-flight であることを記録する。`phase=cleanup, active=true` は次 session の `session-end.sh` が中断 cleanup を検出する唯一のシグナル。失敗しても WARNING のみで cleanup ロジックは続行する（recovery は `/rite:resume`）。

```bash
state_file=$(bash {plugin_root}/hooks/flow-state.sh path 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
    --next "Execute cleanup phases. Do NOT stop." \
    || echo "WARNING: flow-state activate failed — cleanup observability degraded. '/rite:resume' で復帰可能." >&2
else
  bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --issue 0 --branch "" --pr 0 \
    --next "Execute cleanup phases. Do NOT stop." \
    || echo "WARNING: flow-state create failed — cleanup の進行記録が残らない." >&2
fi
```

---

## Phase 1: State Verification

### 1.1 Check Current Branch

```bash
git branch --show-current
```

**Base branch の取得**: Read tool で `rite-config.yml` の `branch.base` を読む。未設定ならデフォルトブランチを検出:

```bash
git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'
```

検出失敗時は誤ブランチ切替（data loss リスク）を防ぐため中断する（推測 fallback 禁止）。`rite-config.yml` の `branch.base` 設定、または `git remote set-head origin --auto` を案内する。

**現在 base branch にいる場合**（引数省略時）: `git branch --merged {base_branch}` で候補を表示し、`/rite:pr:cleanup <branch_name>` での指定を案内する。

### 1.2 Search for Related PR

```bash
gh pr list --head {branch_name} --state all --json number,title,state,mergedAt,url
```

PR が見つからない場合は `AskUserQuestion` で「ブランチを削除して続行 / キャンセル」を確認する。

### 1.3 Verify PR State

PR が未マージの場合は警告し「キャンセル（推奨）/ 強制クリーンアップ」を確認する（未マージ PR のブランチ削除は作業内容を失う可能性がある）。マージ済みなら次へ。

### 1.4 Retrieve Repository Information

後続の GitHub API 呼び出し用に owner / repo を取得し context に保持する:

```bash
gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'
```

### 1.5 Identify Related Issue

PR body の `Closes/Fixes/Resolves #XX`、またはブランチ名の `issue-XX` から関連 Issue を識別する:

```bash
gh pr view {pr_number} --json body,headRefName
```

Issue 番号が識別できたら詳細を取得する（`{original_issue_number}` / `{original_issue_title}` を Phase 1.7 の Issue 作成参照に、`{original_issue_body}` を `{task_details}` 推論に使用）:

```bash
gh issue view {issue_number} --json number,title,state,body
```

### 1.5.1 Detect Parent Issue

関連 Issue が子 Issue か（他 Issue の Tasklist に含まれるか）を判定する。Phase 3 の親 Tasklist 更新・親 auto-close で使用。Sub-Issues API を優先し、無ければ Tasklist fallback:

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { parent { number title state } } }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

```bash
gh issue list --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number,title,state --jq '.[0]'
```

親 Issue が見つかれば `{parent_issue_number}` / `{parent_issue_title}` / `{parent_issue_state}` を保持。見つからない / API エラー時は Phase 3 の親処理をスキップ（non-blocking — cleanup は続行）。

### 1.6 Check Incomplete Tasks

関連 Issue が識別されていれば未完了タスクをチェックする（識別できなければ Phase 2 へ）。

**作業メモリ (SoT)**: Read tool で `.rite-work-memory/issue-{issue_number}.md` を読む。無ければ Issue コメント API に fallback（最新の一致コメントを `last` で選択）:

```bash
comment_body=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body // empty')
```

進捗セクションと Issue 本文の未完了チェックボックス（`- [ ]`。ただし `- [ ] #XX` の親子 Tasklist エントリは除外）を検出する:

```bash
incomplete=$(printf '%s\n' "$comment_body" | sed -n '/### 進捗/,/### /p' \
  | grep -E '^\s*- \[ \]' | grep -v -E '^\s*- \[ \] #[0-9]+' | head -10)
```

未完了タスクが無ければ Phase 2 へ。あれば `AskUserQuestion`:

```
警告: 作業メモリ / Issue 本文に未完了のタスクがあります

{incomplete}

オプション:
- 未完了タスクを Issue 化（推奨）
- 無視してクリーンアップを続行
- キャンセル
```

「Issue 化」→ Phase 1.7。「無視して続行」→ Phase 2。「キャンセル」→ terminate。

> マージ済みブランチへのコミットは base branch に反映されず、cleanup 中の変更はブランチ削除で失われる。残作業は Issue 化することで追跡可能性を保つ。

---

## Phase 1.7: Convert Incomplete Tasks to Issues

**Prerequisite**: Phase 1.6 で「Issue 化」が選択された場合のみ実行。各未完了タスクを PR マージ後の残作業として Issue 化する。

### 1.7.1 Generate Issue Content

LLM は PR diff（`gh pr diff {pr_number}`）・元 Issue 本文（Phase 1.5）・タスク名から `{task_details}`（対象ファイルパス・対象箇所・具体的作業内容）を推論する。

**Issue body template:**

```markdown
## 概要
{task_summary}（PR #{pr_number} のマージに伴う残作業）

## 背景・目的
Issue #{original_issue_number} の実装時に完了できなかったタスクです。

## 関連
- 元 Issue: #{original_issue_number} - {original_issue_title}
- 関連 PR: #{pr_number}

## 変更内容
{task_details}

## チェックリスト
- [ ] 実装完了
- [ ] テスト追加/更新（必要な場合）
```

### 1.7.2 Create the Issue

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)（Default Priority: Medium）

cleanup 中の Issue 作成は interactive な `/rite:issue:create` ではなく共通スクリプトを直接使う（interview をスキップ）。`残作業` label は初回のみ作成する:

```bash
gh label create 残作業 --description "PR マージ後の残作業" --color "fbca04" 2>/dev/null || true
```

以下はテンプレート。`cat <<'BODY_EOF'`（single-quoted HEREDOC）は bash 変数展開を抑止するので、`{generated_body}` / 各プレースホルダーは LLM が実値に置換してから実行する:

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'BODY_EOF' > "$tmpfile"
{generated_body}
BODY_EOF
[ -s "$tmpfile" ] || { echo "ERROR: Issue 本文の生成に失敗" >&2; exit 1; }

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{task_name}（#{original_issue_number} 残作業）" \
  --arg body_file "$tmpfile" \
  --argjson labels '["残作業"]' \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg iter_mode "none" \
  '{ issue: { title: $title, body_file: $body_file, labels: $labels },
     projects: { enabled: $projects_enabled, project_number: $project_number, owner: $owner, status: "Todo", priority: $priority, iteration: { mode: $iter_mode } },
     options: { source: "cleanup", non_blocking_projects: true } }')")
[ -n "$result" ] || { echo "ERROR: create-issue-with-projects.sh returned empty result" >&2; exit 1; }
printf '%s' "$result" | jq -r '"作成: #\(.issue_number) \(.issue_url)"'
printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

`github.projects.enabled` が false / 未設定なら Projects 登録はスキップされる（Issue 作成自体は継続）。全タスク作成後、結果を集計して Phase 2 へ:

```
未完了タスクを Issue 化しました:
- #{new_issue_number} - {task_name}
```

---

## Phase 2: Cleanup Execution

サブフェーズを順に全て実行する（スキップ禁止）。

### 2.1 Switch to Default Branch

base branch 以外にいる場合 `git checkout {base_branch}`。未コミット変更があれば「stash して続行 / キャンセル」を確認する（stash 選択時 `git stash push -m "rite-cleanup: auto-stash before cleanup"`）。

### 2.2 Pull Latest Default Branch

```bash
git pull origin {base_branch}
```

コンフリクト時は `git status` で確認・解決後の再実行を案内し terminate。

### 2.3 Delete Local Branch

```bash
git branch -d {branch_name}
```

未マージ変更で失敗したら「強制削除（`-D`）/ スキップ」を確認する。

### 2.4 Check and Delete Remote Branch

```bash
git ls-remote --heads origin {branch_name}
```

存在すれば `git push origin --delete {branch_name}`（GitHub auto-delete で既に削除済みの場合のエラーは無視して次へ）。

### 2.5 Delete PR-Specific Local State Files <!-- AC-7 -->

> **Acceptance Criteria anchor (AC-7)**: マージ済み PR に紐づく PR-specific local artifact を削除する。削除対象と failure reason の単一の真実の源（[review-result-schema.md](../../references/review-result-schema.md#クリーンアップ) と双方向リンク）。**他 PR のファイルを誤削除しないため、glob は `{pr_number}-` prefix 固定、state file は specific path 完全一致**。

削除対象（評価順）:
1. レビュー結果: `.rite/review-results/{pr_number}-*.json`
2. 破損レビュー結果: `.rite/review-results/{pr_number}-*.json.corrupt-*`（fix.md Priority 2 が rename した orphan の回収）
3. fix retry state（legacy）: `.rite/state/fix-fallback-retry-{pr_number}.count` — 旧 retry-counter 機構の orphan 回収（fix.md は #1115 以降生成しない）
4. fix-cycle state: `.rite/fix-cycle-state/{pr_number}.json`
5. legacy fix-cycle state: `.rite/fix-cycle-state.json`（workspace 直下の単一ファイル形式の残骸）
6. accepted fingerprints: `.rite/state/accepted-fingerprints-{pr_number}.txt`

ファイル不在は silent continue（idempotent）。`rm` 失敗は WARNING + `[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1`（Phase 5.1 が表示に使用）。

```bash
pr_number="{pr_number}"
# 空 / 非数値は glob が変性し他 PR を誤削除しうるため早期に non-blocking exit する。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 2.5 invalid pr_number: '$pr_number' (numeric only, non-empty)" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number" >&2
    exit 0 ;;
esac

# glob 無マッチ時は bash がリテラル文字列を返すため、ループ内の存在チェックで弾く（nullglob 不要）。
# broken symlink も対象に含める（-e || -L）。
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
      echo "  対処: permission denied / read-only filesystem / disk I/O のいずれかを確認してください" >&2
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

### 2.6 Wiki Worktree Lifecycle (削除しない)

`.rite/wiki-worktree/` は永続 worktree であり cleanup では削除しない（再作成コストが高く、各 PR cycle の wiki ingest がここを経由して wiki branch に landing するため cycle を跨いで保持する必要がある）。手動削除が必要な場合（リポジトリ移動 / debug）:

```bash
git worktree remove .rite/wiki-worktree   # modified/untracked files があれば --force
git worktree prune
```

### 2.7 PR Review-Fix Cycle Branch Cleanup

Reviewer subagent が作る `pr-{N}-cycle{X}` 命名の transient ブランチ残骸を回収する（reviewer は READ-ONLY 制約で自己クリーン不可）。strict regex `^pr-[0-9]+-cycle[0-9]+$` で照合し `.rite/wiki-worktree` は除外、non-blocking:

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

---

## Phase 3: Projects Status Update / Issue Close / State Reset

> See [references/archive-procedures.md](./references/archive-procedures.md) for the full procedures: Projects Status Update (3.1-3.2), Work Memory final update (3.5), Issue close (3.6), Parent Issue handling (3.6.4, 3.7), and State reset (Phase 4). Status update delegates to `projects-status-update.sh`. The LLM retains `projects_status_updated` in context for Phase 5.1 display.

---

## Phase 4.W: Wiki Auto-Ingest (Conditional)

> **Reference**: [Wiki Ingest](../wiki/ingest.md) — `/rite:wiki:ingest` Skill API.
>
> PR lifecycle 中に wiki branch へ蓄積された pending raw source を page へ統合する。Raw source の **蓄積** は review/fix/close の Phase X.X.W が担当し、本 Phase は **統合 (ingest)** を担う唯一の自動経路。
>
> **Loss-safe**: ingest 失敗は cleanup を失敗させない。raw source は wiki branch に残り、後続の `/rite:wiki:ingest` で処理できる。`/rite:wiki:ingest` invoke 後に turn が止まっても flow-state は `phase=cleanup, active=true` のままなので `/rite:resume` で復帰する。

### 4.W.1 Pre-condition Check

`wiki.enabled`（opt-out, default true）/ `wiki.auto_ingest`（default false）と pending raw source を確認する。skip 時は sentinel を emit する（completion report がこのシグナルに依存するため silent skip しない）:

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
  echo "ℹ️ Wiki ingest をスキップします (reason: $reason)。Phase 5 へ進みます。"
fi
echo "wiki_ingest_reason=${reason:-<run>} pending_count=$pending_count wiki_branch=$wiki_branch"
```

`reason` が非空なら 4.W.2 / 4.W.3 をスキップして Phase 5 へ。空（`<run>`）なら 4.W.2 へ。

### 4.W.2 Invoke Wiki Ingest

pending raw source があれば `/rite:wiki:ingest` を invoke する（機械的 Skip condition 以外での自己判断省略は禁止）:

```
Skill: rite:wiki:ingest
```

return 後は 4.W.3 へ進み、続いて 🚨 Mandatory After Wiki Ingest（Step 0 を VERY FIRST tool call として実行）を経て Phase 5 へ進む。ingest の成否に関わらず cleanup は続行する。

### 4.W.3 Result Handling

ingest Skill の出力を確認し、以下の sentinel を emit する（Phase 5.1 が表示判定に使用）:

- **成功**: `[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}` + `✅ Wiki ingest 完了: {pages_created} ページ生成、{raw_processed} raw source 統合済み`
- **push 失敗併存**（ingest 出力に `push=failed` = `wiki-worktree-commit.sh` rc=4。commit は local wiki branch に landed、origin push のみ失敗）: 上記に加え `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; source=cleanup_4W`（loss-safe に継続）
- **失敗**: `[CONTEXT] WIKI_INGEST_FAILED=1; reason=ingest_error` + `⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。`

いずれの場合も次の 🚨 Mandatory After Wiki Ingest を経由して Phase 5 へ進む。

### 🚨 Mandatory After Wiki Ingest

> **⚠️ MUST execute in the SAME response turn**: `rite:wiki:ingest` の return 直後、応答を終了せず Step 0 → Step 1 を実行し Phase 5 へ進む。Phase 5 はこの section 経由でのみ到達する唯一の経路。Stop hook も retrospective incident detector も無いため、implicit stop からの復帰は `/rite:resume`（flow-state に `phase=cleanup, active=true` が残る）。
>
> **⚠️ ring removal note**: この防御層は cleanup→`rite:wiki:ingest` sub-skill 境界の implicit-stop 回帰（Issue #910/#917）を防ぐ。`wiki/ingest.md` の continuation marker と対になっており、両者の廃止は ingest.md slim 化（PR 4）で一括して行う。

**Step 0 (Immediate Bash Action)**: `rite:wiki:ingest` return 後の **VERY FIRST tool call** として、**BEFORE any text output**（narrative より先に）実行する。text を先に出すと LLM の turn-boundary heuristic が誤発火し implicit stop の経路が開く（Issue #910）。flow-state を `phase=cleanup` に書き戻す（ingest.md が一時的に `phase=ingest` へ上書きした ring を閉じる）:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
  --next "Step 0 fired; proceeding to Phase 5 Completion Report. Do NOT stop." \
  --if-exists --preserve-error-count \
  || echo "[CONTEXT] STEP_0_PATCH_FAILED=1" >&2
```

**Step 1 (idempotent re-patch)**: Step 0 が transient 失敗した場合の冗長 patch。Step 0 / Step 1 の二重化が防御機構（片方が失敗しても他方が正しい phase に書き込む）。同時失敗時のみ `[CONTEXT] STEP_1_PATCH_FAILED=1` を残す:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
  --next "rite:wiki:ingest done. Emit Phase 5 (Completion Report) + <!-- [cleanup:completed] --> in the SAME response turn. Do NOT stop." \
  --if-exists --preserve-error-count \
  || echo "[CONTEXT] STEP_1_PATCH_FAILED=1" >&2
```

**Step 2**: → Phase 5 へ進む。

---

## Phase 5: Completion Report

### 5.1 Cleanup Result Summary

> 以下はテンプレート。実出力では fence なしで本文のみを展開し、プレースホルダー（`{pr_number}` 等）は実値に置換する。

```
クリーンアップが完了しました

PR: #{pr_number} - {pr_title}
関連 Issue: #{issue_number}
Status: {projects_status_result}

実行した処理:
- [x] デフォルトブランチに切り替え
- [x] 最新のデフォルトブランチを pull
- [x] ローカルブランチ {branch_name} を削除
- [x] リモートブランチを削除
- [{review_cleanup_check}] PR-specific state ファイルを削除
- [x] flow state をリセット
- [{projects_check}] Projects Status を Done に更新
- [{wiki_ingest_check}] Wiki ingest（pending raw source のページ統合）
- [x] 作業メモリを最終更新
- [x] 関連 Issue をクローズ
- [x] 親 Issue の Tasklist 更新・自動クローズ（該当する場合）
```

**State ファイル削除の表示**:

| `REVIEW_CLEANUP_PARTIAL_FAILURE` | `{review_cleanup_check}` |
|---|---|
| 未設定（正常） | `x` |
| `1`（部分失敗） | ` ` + 下記警告を付記 |

```
⚠️ 一部の PR-specific state ファイル削除が完了しませんでした (reason: {reason})。
手動確認: ls -la .rite/review-results/{pr_number}-* .rite/state/fix-fallback-retry-{pr_number}.count .rite/fix-cycle-state/{pr_number}.json .rite/fix-cycle-state.json .rite/state/accepted-fingerprints-{pr_number}.txt
```

**Projects Status の表示**:

| `projects_status_updated` | `{projects_status_result}` | `{projects_check}` |
|---|---|---|
| `true` | `Done` | `x` |
| `false` | `⚠️ 更新失敗（手動確認が必要）` | ` ` |

`false` の場合は「GitHub Projects 画面で Issue #{issue_number} の Status を Done に変更」を付記する。

**Wiki ingest の表示**（上から順に評価し最初の一致を採用 — push 失敗は ingest 成功と併存しうるため優先）:

| Sentinel | `{wiki_ingest_check}` | 表示 |
|---|---|---|
| `WIKI_INGEST_DONE=1` + `WIKI_INGEST_PUSH_FAILED=1` | ` ` | push 失敗警告 |
| `WIKI_INGEST_PUSH_FAILED=1` 単独 | ` ` | push 失敗警告 |
| `WIKI_INGEST_DONE=1` 単独 | `x` | （追加なし） |
| `WIKI_INGEST_SKIPPED=1; reason=disabled` | `x` | `ℹ️ Wiki ingest スキップ (wiki.enabled=false)` |
| `WIKI_INGEST_SKIPPED=1; reason=auto_ingest_off` | `x` | `ℹ️ Wiki ingest スキップ (wiki.auto_ingest=false)` |
| `WIKI_INGEST_SKIPPED=1; reason=no_pending` | `x` | `ℹ️ Wiki ingest スキップ (pending raw source なし)` |
| `WIKI_INGEST_FAILED=1` | ` ` | ingest 失敗警告 |
| sentinel なし | ` ` | `⚠️ Wiki ingest Phase が実行されませんでした` |

push 失敗警告（`{wiki_branch}` は Phase 4.W.1 と同じ parser で解決）:
```
⚠️ Wiki ingest: commit は local wiki branch に landed しましたが origin への push に失敗しました。
  手動回復: git -C .rite/wiki-worktree push origin {wiki_branch}
```
ingest 失敗警告:
```
⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。手動で `/rite:wiki:ingest` を再実行できます。
```

**親 Issue 処理結果**（Phase 3.7 が実行された場合のみ）:
```
親 Issue 処理:
- 親 Issue: #{parent_issue_number} - {parent_issue_title}
- 結果: {parent_close_result}
```
`{parent_close_result}`: `✅ 自動クローズ完了（全子 Issue 完了）` / `⏳ 残り {remaining_count} 件の子 Issue が未完了` / `✅ 既にクローズ済み` / `⚠️ クローズ失敗（手動対応が必要）`。

**Issue 化結果**（Phase 1.7 が実行された場合のみ）:
```
未完了タスク処理 — 作成した Issue:
| Issue | タイトル |
|-------|----------|
| #{new_issue_number} | {task_name}（#{original_issue_number} 残作業） |
```

stash した変更があれば「復元する（`git stash pop`）/ 後で手動で復元」を確認する。

### 5.2 Guidance for Next Steps

通常 ordered list として出力する（**fenced code block 禁止** — fence 内では inline HTML が literal 文字列として可視化される）。`<!-- [cleanup:completed] -->` sentinel は **最終 list item 末尾に半角スペース区切りで inline 付加** する（独立行禁止 — 独立行だと CommonMark HTML block 化し rendered view に余計な空行が出る）:

次のステップ:
1. `/rite:issue:list` で次の Issue を確認
2. `/rite:issue:start <issue_number>` で新しい作業を開始 <!-- [cleanup:completed] -->

### 5.3 Terminal Completion

Phase 5.2 出力直後に flow state を terminal state（`phase=cleanup, active=false`）に落とす（idempotent）。silent failure を防ぐため rc を捕捉する:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --next "none" --active false --if-exists \
  || echo "WARNING: flow-state deactivate failed — .active=true が残る可能性。手動: bash {plugin_root}/hooks/flow-state.sh set --phase cleanup --next none --active false --if-exists" >&2
```

この bash 実行が Phase 5.3 で取る最後の action。直後に text output / tool call を追加しない（terminal 条件）。

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| PR Not Found | See [common patterns](../../references/common-error-handling.md) |
| Branch Deletion Failure | `git branch` でブランチ一覧を確認; デフォルトブランチに切り替えてから再実行 |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
| Issue Close Failure | `gh issue view {issue_number}` で状態確認; 手動で `gh issue close {issue_number}` |
| Incomplete Task Issue Creation Failure | クリーンアップは続行; タスクを手動で Issue 化 |
