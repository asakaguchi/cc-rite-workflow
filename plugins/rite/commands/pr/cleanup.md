---
description: PR マージ後のクリーンアップを実行
---

# /rite:pr:cleanup

> **Charter**: This command and its `references/` are subject to the [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述・cycle 番号引用・重複 confirmation は書かない。

## Contract
**Input**: Merged PR (auto-detected from current branch or specified)
**Output**: Cleanup result summary table (branch deletion, Status update, Issue close results)

Automate post-PR-merge cleanup tasks (branch deletion, switch to main, Status update)

---

When this command is executed, run the following phases in order.

## Arguments

| Argument | Description |
|----------|-------------|
| `[branch_name]` | Branch name to clean up (defaults to the current branch if omitted) |

---

## Sub-skill Return Protocol

> **Reference**: See `start.md` [Sub-skill Return Protocol (Global)](../issue/start.md#sub-skill-return-protocol-global) and `create.md` [Sub-skill Return Protocol](../issue/create.md#sub-skill-return-protocol) for the canonical contract. Same rules apply: DO NOT end your response after `rite:wiki:ingest` returns, DO NOT re-invoke the completed skill, and IMMEDIATELY proceed to Mandatory After Wiki Ingest in the **same response turn**.

### Routing dispatcher (MUST execute step-by-step)

After any sub-skill return, output two HTML-comment evidence lines (bare bracket form is forbidden — it would conflict with the `[cleanup:completed]` sentinel rule). Neither evidence line may be the response's final line; the final line is reserved for Phase 5.2's last list item with inline `<!-- [cleanup:completed] -->`.

1. `ingest` marker check — grep -F the previous response for any of `[ingest:completed]`, `[ingest:completed:`, `[CONTEXT] WIKI_INGEST_DONE=`, `[CONTEXT] INGEST_DONE=`. Emit `<!-- [routing-check] ingest=matched -->` or `<!-- [routing-check] ingest=unmatched -->`.
2. `cleanup` marker check — grep -F the previous response for `[cleanup:completed]`. Emit `<!-- [routing-check] cleanup=matched -->` or `<!-- [routing-check] cleanup=unmatched -->`.
3. Routing (priority: `ingest=matched` wins over `cleanup=matched` in mixed sessions because the most recent sub-skill return is the true continuation trigger):
   - `ingest=matched` → continuation trigger: immediately run Mandatory After Wiki Ingest (`cleanup_post_ingest` patch → Phase 5 Completion Report) in the same turn.
   - `cleanup=matched` (and `ingest=unmatched`) → terminal reached.
   - Both unmatched → workflow in progress, continue normally.

### Correct continuation pattern

The **correct-pattern**: in the same response turn, immediately (1) run Mandatory After Wiki Ingest Pre-write (`cleanup_post_ingest`); (2) output Phase 5.1 Cleanup Result Summary; (3) output Phase 5.2 Guidance for Next Steps with **inline `<!-- [cleanup:completed] -->` HTML sentinel at the trailing position of the final list item** (not on an independent line); (4) Phase 5.3 Step 1 deactivates flow state (`cleanup_completed`, `active: false`) and the turn closes — DO NOT stop earlier. Ending the turn after `rite:wiki:ingest` returns abandons the cleanup workflow mid-flight, leaves Phase 5 unexecuted, and leaves the flow state non-terminal.

**Completion marker**: `[cleanup:completed]` is emitted as an HTML comment (`<!-- [cleanup:completed] -->`) inline at the trailing position of Phase 5.2's final list item — keeps the marker grep-matchable (`grep -F '[cleanup:completed]'`) while making `クリーンアップが完了しました` the user-visible final content. `stop-guard.sh` blocks premature `end_turn` during `cleanup` / `cleanup_pre_ingest` / `cleanup_post_ingest` and emits `manual_fallback_adopted` for `start.md` Phase 5.4.4.1 (Workflow Incident Detection) consumer.

---

## Phase 1.0: Activate Flow State

> **Plugin Path**: Resolve `{plugin_root}` using the inline one-liner in **Step 0** below before executing bash hook commands in this file. Do NOT improvise a different resolution script.

**Step 0: Resolve plugin root** (execute once, reuse throughout):

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/hooks" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

Retain the `plugin_root` value output above and use it for all subsequent `{plugin_root}` references in this command.

Activate flow state so that `stop-guard.sh` blocks premature `end_turn` during cleanup phases.

> **Fail-safe**: `flow-state-update.sh` 呼び出しは `if ! ... ; then echo "WARNING..." >&2; fi` で包み、失敗時もユーザー可視 WARNING のみで続行する。stop-guard 保護が一時的に無効になっても、ユーザーは "continue" を入力することで recovery できる。

```bash
# state file path を解決。helper が exit 失敗で空文字列を返す異常ケースでは
# 後続 [ -f "" ] が false 評価され create branch に進む (state file 不在と同等の安全動作)。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  # --active true を明示する理由: 前回セッション終了時に flow state が
  # {phase: cleanup_completed, active: false} で残存している場合、patch モードは --active 省略時に
  # .active を更新しないため、stop-guard.sh の active!=true early exit で cleanup Phase 1-4 の
  # protection が silent 無効化される。明示 re-activate でこれを防ぐ。
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "cleanup" --active true --next "Execute cleanup phases. Do NOT stop."; then
    echo "WARNING: flow-state-update.sh patch (cleanup activate) failed — stop-guard will not block premature end_turn during Phase 1-4. Cleanup will still proceed, but the user may need to type 'continue' to resume." >&2
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "cleanup" --issue 0 --branch "" --pr 0 \
      --next "Execute cleanup phases. Do NOT stop."; then
    echo "WARNING: flow-state-update.sh create (cleanup activate) failed — flow state was not created. stop-guard will exit immediately on every stop attempt with no protection." >&2
  fi
fi
```

**Purpose**: After PR merge, flow state is `active: false, phase: completed`。re-activation せず stop-guard が active!=true で early exit すると premature `end_turn` が block されず、ユーザーが "continue" を複数回入力する事象が起きる。

---

## Phase 1: State Verification

### 1.1 Check Current Branch

```bash
git branch --show-current
```

**Retrieving the base branch**: Read tool で `rite-config.yml` を読み `branch.base` を取得 (set されていればその値を `{base_branch}` として採用)。未設定 / ファイル不在の場合、リポジトリのデフォルトブランチを検出する:

```bash
git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'
```

`origin/HEAD` 未設定で `git symbolic-ref` が失敗する場合、誤ったブランチへの切り替え (data loss リスク) を防ぐため処理を中断してエラー表示する (推測 fallback 禁止):

```
エラー: デフォルトブランチを自動検出できませんでした。

rite-config.yml で明示的に設定してください:
  branch:
    base: "your-default-branch"

または origin/HEAD を設定してください:
  git remote set-head origin --auto
```

**When on the base branch** (引数省略時): merged branches を `git branch --merged {base_branch}` で表示し `AskUserQuestion` で選択させる:

```
現在 {branch} ブランチにいます

クリーンアップするブランチを指定してください:
/rite:pr:cleanup <branch_name>

または最近マージされたブランチを確認:
```

### 1.2 Search for Related PR

Search for a PR associated with the current branch (or the specified branch):

```bash
gh pr list --head {branch_name} --state all --json number,title,state,mergedAt,url
```

**If no PR is found:**

```
警告: ブランチ {branch_name} に関連する PR が見つかりません

オプション:
- ブランチを削除してクリーンアップ続行
- キャンセル
```

### 1.3 Verify PR State

**If the PR has not been merged:**

```
警告: PR #{number} はまだマージされていません

状態: {state}
タイトル: {title}

マージされていない PR のブランチを削除すると、作業内容が失われる可能性があります。

オプション:
- キャンセル（推奨）
- 強制的にクリーンアップ
```

**If the PR has been merged:**

Proceed to the next phase.

### 1.4 Retrieve Repository Information

後続 GitHub API 呼び出し用に owner / repo を取得し conversation context に保持する:

```bash
gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'
```

### 1.5 Identify Related Issue

PR body の `Closes #XX` / `Fixes #XX` / `Resolves #XX` パターン、またはブランチ名の `issue-XX` パターンから関連 Issue を識別する:

```bash
gh pr view {pr_number} --json body,headRefName
```

**If an Issue number is identified, retrieve detailed Issue information** (Phase 1.7.3.1 で使用、OPEN/CLOSED どちらでも動作):

```bash
gh issue view {issue_number} --json number,title,state,body --jq '{number, title, state, body}'
```

`{original_issue_number}` / `{original_issue_title}` は Phase 1.7.3 の Issue 作成参照に、`{original_issue_body}` は Phase 1.7.3.1 の `{task_details}` 推論時に LLM が実装要件・背景を抽出するために使用する。

### 1.5.1 Detect Parent Issue

Check whether the related Issue is a child Issue (included in another Issue's Tasklist). Used by Phase 3.6.4 (parent Tasklist checkbox update) and Phase 3.7 (parent auto-close).

#### 1.5.1.1 Detection via GitHub Sub-Issues API (preferred)

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      parent {
        number
        title
        state
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

**Note**: The `GraphQL-Features: sub_issues` header is required (the Sub-Issues API is in beta).

#### 1.5.1.2 Tasklist Fallback

If the Sub-Issues API does not find a parent, search repository Issues to check if the Issue is included in a Tasklist:

```bash
gh issue list --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number,title,state --jq '.[0]'
```

#### 1.5.1.3 Handling Detection Results

| Detection Result | Action |
|-----------------|--------|
| Parent Issue found | Retain `{parent_issue_number}`, `{parent_issue_title}`, `{parent_issue_state}` in the conversation context |
| Parent Issue not found | Skip Phase 3.6.4 and Phase 3.7 |
| API error | Display a warning and skip Phase 3.6.4 and Phase 3.7 (non-blocking — cleanup continues) |

### 1.6 Check Incomplete Tasks in Work Memory

関連 Issue が識別されていれば、作業メモリコメントの未完了タスクをチェックする。識別されていなければ Phase 1.6 / 1.7 をスキップして Phase 2 に進む。

#### 1.6.1 Retrieve Work Memory

**Local work memory (SoT)**: Read `.rite-work-memory/issue-{issue_number}.md` with the Read tool. If the file exists, use its content for incomplete task detection.

**Fallback (local file missing/corrupt)**: Fall back to the Issue comment API. Use `last` to pick the most recent matching comment (defends against multiple matches), and `// empty` to coerce null to empty string:

```bash
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
comment_body=$(echo "$comment_data" | jq -r '.body // empty')
```

`{comment_id}` is reused when updating work memory in Phase 1.7.4 / Phase 3.5; `{comment_body}` feeds incomplete task detection. Bash variables do not persist across Bash tool invocations — the LLM retains `comment_id` in conversation context and embeds it directly in later updates (or re-runs this block to re-fetch).

If no comment is found (both local file and Issue comment), skip this check and proceed to Phase 2.

#### 1.6.2 Detect Incomplete Tasks

Detect unchecked checkboxes (`- [ ]`) in the "Progress" section. The here-string form (`<<<`) avoids SIGPIPE when `head -10` exits early on large `comment_body` (>64KB pipe buffer). `head -10` caps display volume; the `sed` range extraction tolerates progress section at EOF (no trailing `### `):

```bash
progress_section=$(sed -n '/### 進捗/,/### /p' <<< "$comment_body")
incomplete_tasks=$(grep -E '^\s*- \[ \]' <<< "$progress_section" | head -10)
```

#### 1.6.3 Warning When Incomplete Tasks Exist

If incomplete tasks are found, prompt with `AskUserQuestion`:

```
警告: 作業メモリに未完了のタスクがあります

未完了タスク:
{incomplete_tasks}

オプション:
- 未完了タスクを先に完了する（推奨）
- 未完了タスクを自動判定して処理する
- 無視してクリーンアップを続行
- キャンセル
```

「未完了タスクを先に完了 (推奨)」→ クリーンアップを中断し、未完了タスク対応後 `/rite:pr:cleanup` 再実行を案内。「自動判定」→ Phase 1.7。「無視して続行」→ Phase 2。「キャンセル」→ terminate。

#### 1.6.4 When No Incomplete Tasks Exist

未完了タスクがなければ Phase 1.6.5 へ進む。

#### 1.6.5 Check Issue Body Checklist

In addition to checking the work memory, also check the checklist in the Issue body.

**1.6.5.1 Extract Checklist**

Phase 1.5 で取得済みの Issue body からチェックリストを抽出する (再取得不要):

```bash
gh issue view {issue_number} --json body --jq '.body'
```

抽出パターン: `/^- \[[ xX]\] (.+)$/gm`、除外パターン: `/^- \[[ xX]\] #\d+/gm` (parent-child Issue 管理用 Tasklist エントリは除外)。

**1.6.5.2 Detect Incomplete Checklist Items**

抽出されたチェックリストから `- [ ]` 項目を検出。未完了項目が存在する場合 `AskUserQuestion`:

```
警告: Issue 本文に未完了のチェック項目があります

未完了項目:
- [ ] {item_1}
- [ ] {item_2}

オプション:
- Issue 本文のチェックリストを自動更新（推奨）: PR の変更内容を基に完了状態を判定し更新
- チェックリストを手動で確認: クリーンアップを中断し手動確認
- 無視してクリーンアップを続行: 未完了のまま続行
- キャンセル
```

「自動更新」→ Phase 1.6.5.3、「手動で確認」→ 案内表示後 terminate、「無視して続行」→ Phase 2、「キャンセル」→ terminate。

**1.6.5.3 Automatic Checklist Update**

Based on PR changes, determine the completion status of incomplete checklist items and update the Issue body.

**Assessment logic**: 各チェックリスト項目を PR 変更との関連性 ((1) 項目テキスト、(2) `gh pr diff {pr_number} --name-only` 出力、(3) `gh pr diff {pr_number}` 詳細) で判定する:

```
チェック項目: 「現在の CLAUDE.md の内容を評価」
PR 変更ファイル: CLAUDE.md
判定: ✅ CLAUDE.md を変更しているため、完了と判断

チェック項目: 「テストを追加」
PR 変更ファイル: src/utils.ts
判定: ⬜ テストファイルへの変更がないため、未完了と判断
```

**Updating the Issue body**: Follow the "Checkbox Update" pattern in [gh-cli-patterns.md](../../references/gh-cli-patterns.md) — 3 steps (Bash → Read+Write → Bash):

**Step 1 (Bash)**: 一時ファイル取得 + Issue body 読み込み + 検証 (`tmpfile_read=$(mktemp)` / `tmpfile_write=$(mktemp)` / `gh issue view {issue_number} --json body --jq '.body' > "$tmpfile_read"` / 空 body は ERROR で abort / `echo` でパス出力 — 後続 Bash tool call からシェル変数は参照不可のため):

```bash
tmpfile_read=$(mktemp)
tmpfile_write=$(mktemp)
trap 'rm -f "$tmpfile_read" "$tmpfile_write"' EXIT
gh issue view {issue_number} --json body --jq '.body' > "$tmpfile_read"
[ ! -s "$tmpfile_read" ] && { echo "ERROR: Issue body の取得に失敗" >&2; exit 1; }
echo "tmpfile_read=$tmpfile_read"
echo "tmpfile_write=$tmpfile_write"
```

**Step 2 (Read + Write tool)**: Read tool で `$tmpfile_read` を読み、`[ ]` → `[x]` 置換した本文を Write tool で `$tmpfile_write` に書き出す。

**Step 3 (Bash)**: 検証 + 適用 (Step 1 で出力されたパスを literal で記述、シェル変数は引き継がれない):

```bash
tmpfile_read="/tmp/tmp.XXXXXXXXXX"   # ← Step 1 の出力値
tmpfile_write="/tmp/tmp.XXXXXXXXXX"  # ← Step 1 の出力値
[ ! -s "$tmpfile_write" ] && { echo "ERROR: 更新内容が空" >&2; exit 1; }
gh issue edit {issue_number} --body-file "$tmpfile_write"
rm -f "$tmpfile_read" "$tmpfile_write"
```

**Displaying the update results:**

```
Issue 本文のチェックリストを更新しました:

完了に更新:
- [x] {item_1}（CLAUDE.md の変更により判定）
- [x] {item_2}（src/utils.ts の変更により判定）

未完了のまま:
- [ ] {item_3}（関連する変更が見つかりませんでした）
```

**When remaining incomplete items exist:**

```
警告: 以下のチェック項目が未完了のままです:

- [ ] {item_3}

オプション:
- 未完了のまま続行: 後続の作業で対応予定として続行
- 別 Issue として登録: 未完了項目を新しい Issue として作成
- キャンセル
```

| Option | Subsequent Processing |
|--------|----------------------|
| **未完了のまま続行** | Proceed to Phase 2 |
| **別 Issue として登録** | Create an Issue by reusing the Phase 1.7.3 Issue creation flow -> Proceed to Phase 2 |
| **キャンセル** | Terminate processing |

**1.6.5.4 When No Checklist Exists**: Issue body にチェックリストがなければ本セクションをスキップして Phase 2 に進む。

---

## Phase 1.7: Automatic Assessment and Processing of Incomplete Tasks

**Prerequisite**: Phase 1.6.3 で「未完了タスクを自動判定して処理する」が選択された場合のみ実行。

### 1.7.0 Retrieve PR Diff

Retrieve the PR diff for task analysis (used to assess "completed but unchecked" tasks and to generate `{task_details}` in Issue body):

```bash
gh pr diff {pr_number}
```

### 1.7.1 Analyze Tasks

#### 1.7.1.1 Task Assessment

LLM (Claude) は各未完了タスクを以下のカテゴリで分類する:

| Assessment Category | Description | Examples |
|--------------------|-------------|----------|
| **Create Issue** | 残作業として追跡すべきタスク | "Add tests", "Update documentation", "Remove debug logs", TODO 対応 |
| **Completed (unchecked)** | 実際は完了済みだがチェック漏れ | 作業メモリのチェック忘れ |
| **Difficult to assess** | LLM が確信を持って分類できない | 「コード整理」「改善」等の曖昧な記述 |

**Targets for Issue creation** (typical remaining work after PR merge):

- Adding/expanding tests (unit, E2E, etc.)
- Updating documentation (README, API docs, etc.)
- Removing debug code (`console.log`, `print` statements added during development)
- Addressing `// TODO:` comments left in code
- Minor refactoring (XS/S complexity)

Incomplete tasks default to Issue creation (unless the user selects "ignore") because commits to a merged PR branch are not reflected in the base branch and changes made during cleanup are lost when the branch is deleted — Issue conversion preserves traceability.

#### 1.7.1.2 Assessment Algorithm

タスクごとに以下のフローで評価する:

1. **タスク名解析**: 作業内容を特定 (例「テスト追加」「コメント削除」)。
2. **PR diff との照合** (1.7.0 で取得済み diff を使用): キーワードマッチ + 意味的マッチで関連変更を検索。
   - 関連変更あり + 実質完了 → **完了済み（チェック漏れ）**
   - 関連変更あり + 部分的/未完了 → **Issue 化**
   - 関連変更なし → **Issue 化** (未着手)
3. **判定困難条件**: タスク名が曖昧 (例「コード整理」「改善」「確認」) / 差分との関連性が不明確 / 複数解釈可能 のいずれか → **判定困難**。

**Assessment confidence levels** (内部分類用): High = diff で完了が明確 → "completed"、Medium = タスク内容明確かつ diff 変更なし → "create Issue"、Low = それ以外 → "difficult to assess"。

**Analysis perspectives**: (1) タスク内容の明確性、(2) PR diff による完了状況確認 (チェック漏れ判定)、(3) 複雑度 (下記基準)、(4) 優先度 (緊急対応 vs 後回し可)。

**Complexity criteria:**

| Complexity | Description | Guidelines |
|-----------|-------------|------------|
| **XS** | 1-line to a few-line changes, simple deletions/additions | Comment removal, log removal, typo fixes |
| **S** | Localized changes within a single file | Function addition, validation addition, simple tests |
| **M** | Changes spanning multiple files | Feature addition, refactoring |
| **L** | Changes involving design modifications | Architecture changes, large-scale refactoring |

**Displaying analysis results:**

```
未完了タスクを分析しました:

Issue 化:
- [ ] テスト追加 → 別途 Issue として管理（複雑度: S）
- [ ] ドキュメント更新 → 別途 Issue として管理（複雑度: XS）
- [ ] デバッグログ削除 → 別途 Issue として管理（複雑度: XS）

完了済み（チェック漏れ）:
- [ ] バリデーション追加 → PR #{pr_number} で実装済み。チェックを付けます

判定困難（確認が必要）:
- [ ] コード整理 → 内容を確認してください
```

**When assessed as "completed (unchecked)"**: 該当タスクを `- [x]` にマークし Issue 作成をスキップ。更新は Phase 1.7.4 で一括適用 (analysis phase 1.7.1 では結果記録のみ、ユーザーが confirmation 1.7.2 で修正できる余地を残す)。

### 1.7.2 User Confirmation

Display the analysis results and prompt with `AskUserQuestion`:

```
上記の分析結果で処理を進めますか？

オプション:
- この分類で Issue 作成（推奨）
- 個別に確認する
- すべて無視してクリーンアップを続行
- キャンセル
```

**Subsequent processing for each option:**

| Option | Subsequent Processing | Description |
|--------|----------------------|-------------|
| **この分類で Issue 作成（推奨）** | If there are difficult-to-assess tasks: 1.7.2.1 -> 1.7.3, otherwise: 1.7.3 | Create Issues based on the analysis results |
| **個別に確認する** | Individual confirmation flow -> 1.7.3 | Confirm each task individually |
| **すべて無視してクリーンアップを続行** | Skip to Phase 2 | Ignore incomplete tasks |
| **キャンセル** | Terminate processing | Interrupt the entire cleanup process and maintain the current state |

**"Create Issues with this classification" flow**: 判定困難タスクがあれば 1.7.2.1 で解決してから 1.7.3 に進む。なければ 1.7.3 へ直接遷移。

#### 1.7.2.1 Resolving Difficult-to-Assess Tasks

判定困難タスクごとに `AskUserQuestion` で確認 (1.7.3 進入前):

```
「{task_name}」の処理を選択してください:

オプション:
- Issue 化する（推奨）
- 無視する
- キャンセル（後で対応）
```

「Issue 化」 → 次タスクへ。「無視」 → 次タスクへ。「キャンセル」 → 未完了タスク処理を中断し Phase 2 へ進む (後日 `/rite:pr:cleanup` 再実行案内)。全タスクが「Issue 化」or「無視」に分類されるまで繰り返す。

**「個別に確認する」flow**: タスクごとに `AskUserQuestion` で逐次確認する。"Completed (unchecked)" タスクは自動チェック済みで個別確認対象外 ("create Issue" / "difficult to assess" のみ surfacing。Phase 1.7.4 後に手動 uncheck か別 Issue 作成で override 可能、Issue closed 状態でも work memory 編集は動作する):

```
タスク: {task_name}
分析結果: {category}（複雑度: {complexity}）

このタスクの処理を選択してください:

オプション:
- Issue 化する（推奨）
- 無視する
```

全タスクの分類確定後 1.7.3 へ進む。

### 1.7.3 Convert Tasks to Issues

Create Issues for tasks assessed (or confirmed) as "create Issue". Tasks classified as "ignore" are skipped (no Issue created). The checkbox in work memory remains `- [ ]` so a future `/rite:pr:cleanup` run will surface the task again — this preserves the option to revisit the decision.

#### 1.7.3.1 Generate Issue Content

Generate an Issue per task in the format below. The LLM infers `{task_details}` from the PR diff (Phase 1.7.0), the original Issue body (Phase 1.5), and the task name extracted from work memory.

**Placeholder descriptions:**
- `{task_summary}`: One-line summary of the incomplete task (synonymous with `{task_name}` — same value, used in overview vs title).
- `{task_details}`: Specific steps and explanations for the incomplete work. Must include at minimum: target file path, target location (function/class/line), and concrete work content. Example:
  ```markdown
  - `src/utils.ts` の `calculateTotal` 関数にユニットテストを追加する
  - テストケース: 正常系（複数アイテム）、境界値（空配列）、異常系（null 入力）
  - テストファイル: `src/utils.test.ts` に追加
  ```
- `{pr_number}` / `{original_issue_number}` / `{original_issue_title}`: From Phase 1.2 / 1.5.
- `{complexity}`: Determined in Phase 1.7.1 (XS, S, etc.)

**Issue body template:**

```markdown
## 概要

{task_summary}（PR #{pr_number} のマージに伴う残作業）

## 背景・目的

Issue #{original_issue_number} の実装時に完了できなかったタスクです。

## 関連 Issue

- 元 Issue: #{original_issue_number} - {original_issue_title}
- 関連 PR: #{pr_number}

## 変更内容

{task_details}

## 複雑度

{complexity}

## チェックリスト

- [ ] 実装完了
- [ ] テスト追加/更新（必要な場合）
```

#### 1.7.3.2 Create the Issue

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

Issue creation during cleanup uses the common script directly rather than the interactive `/rite:issue:create`. This skips the interview phase and creates the Issue quickly.

**Note**: The block below is a template. Replace `{generated_body}` with the actual Issue body before execution. The single-quoted HEREDOC (`cat <<'BODY_EOF'`) prevents bash variable expansion — Claude must substitute placeholders as an LLM, not via shell. The `残作業` label flags Issues auto-created from incomplete tasks; create it once before first use:

```bash
gh label create 残作業 --description "PR マージ後の残作業" --color "fbca04" 2>/dev/null || true
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{generated_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{task_name}（#{original_issue_number} 残作業）" \
  --arg body_file "$tmpfile" \
  --argjson labels '["残作業"]' \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "{complexity}" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file, labels: $labels },
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
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Placeholder descriptions:**
- `{task_name}` / `{generated_body}`: Task name (work memory) / body generated in 1.7.3.1
- `{original_issue_number}` / `{complexity}`: Phase 1.5 / Phase 1.7.1 values

If Issue creation or field configuration fails, warnings surface from the script result; Projects registration is non-blocking so the Issue is still created. When `github.projects.enabled` is `false` or unset in `rite-config.yml`, skip 1.7.3.2.1 entirely and display:

```
警告: GitHub Projects が設定されていません
Projects への追加をスキップします
```

#### 1.7.3.3 Record Creation Results

Record the information of the created Issue:

```
Issue を作成しました:
- #{new_issue_number} - {task_name}
```

### 1.7.4 Update Work Memory

After all task processing is complete, update the work memory:

```bash
# Step 1: チェックボックス更新（完了済みだがチェック漏れのタスク）
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-checkboxes \
  --tasks "{completed_unchecked_task_names_comma_separated}" \
  2>/dev/null || true

# Step 2: 未完了タスク処理結果を追記
task_result_tmp=$(mktemp)
trap 'rm -f "$task_result_tmp"' EXIT
cat > "$task_result_tmp" << 'RESULT_EOF'
{1.7.4 の内容を実際の値で置換して記述}
RESULT_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "未完了タスクの処理結果" --content-file "$task_result_tmp" \
  2>/dev/null || true

rm -f "$task_result_tmp"
```

**Note for Claude**: `{completed_unchecked_task_names_comma_separated}` を完了済みタスク名のカンマ区切りで置換 (例: `"タスクA,タスクB"`)。`{1.7.4 の内容を実際の値で置換して記述}` は下記「Update content」テンプレートから生成した追記内容で置換する。

**Update content** (preserve existing work memory and append):

1. **Progress section**: 既存チェックリストを保持し末尾に `- [x] 未完了タスク処理済み` を追加
2. **Fix unchecked items**: "completed (unchecked)" タスクの `- [ ]` を `- [x]` に置換 (タスク名 + 行内容の exact match で識別。同名タスク重複時は登場順 top-to-bottom で識別、例: `- [ ] テスト追加` と `- [ ] テスト追加（API）` は別タスク扱い)
3. **New section**: 末尾に `### 未完了タスクの処理結果` を追加

```markdown
### 進捗
- [x] 実装完了
- [x] PR マージ済み
- [x] バリデーション追加    ← チェック漏れ修正
- [x] 未完了タスク処理済み  ← 新規追加

### 未完了タスクの処理結果
| タスク | 処理 | 結果 |
|-------|------|------|
| テスト追加 | Issue 化 | → #101 |
| デバッグログ削除 | Issue 化 | → #102 |
| バリデーション追加 | チェック完了 | 差分で確認済み |
```

**Result 列のフォーマット**: Issue 化 → `→ #{new_issue_number}`、チェック完了 → `差分で確認済み`、無視 → `スキップ`。既存進捗セクションの他チェックリスト項目は保持される (削除されない)。

### 1.7.5 Transition to Phase 2

Phase 1.7.3 処理完了時点で集計し、ユーザーに transition 確認を表示してから Phase 2 (cleanup execution) に進む:

- `{issue_count}`: Issue 化件数
- `{ignored_count}`: 無視件数
- `{checked_count}`: 完了済み (チェック漏れ) 件数

```
未完了タスクの処理が完了しました:
- Issue 化: {issue_count} 件
- チェック完了: {checked_count} 件
- 無視: {ignored_count} 件

クリーンアップを続行します。
```

---

## Phase 2: Cleanup Execution

**Sub-phases** (execute ALL in order — do NOT skip any):

```
2.1 Switch to Default Branch
2.2 Pull Latest Default Branch
2.3 Delete Local Branch
2.4 Check and Delete Remote Branch
2.5 Delete Review Result Local Files and Fix State Files (#443, #450)
```

### 2.1 Switch to Default Branch

If currently on a branch other than the default branch:

```bash
git checkout {base_branch}
```

**If there are uncommitted changes:**

```
警告: 未コミットの変更があります

オプション:
- 変更をスタッシュしてクリーンアップ続行
- キャンセル
```

If stash is selected:

```bash
git stash push -m "rite-cleanup: auto-stash before cleanup"
```

### 2.2 Pull Latest Default Branch

```bash
git pull origin {base_branch}
```

**If a conflict occurs:**

```
エラー: デフォルトブランチの更新中にコンフリクトが発生しました

対処:
1. `git status` で状態を確認
2. コンフリクトを解決
3. 再度クリーンアップを実行
```

Terminate processing.

### 2.3 Delete Local Branch

```bash
git branch -d {branch_name}
```

**If deletion fails (unmerged changes exist):**

```
警告: ブランチ {branch_name} には未マージの変更があります

オプション:
- 強制削除（-D オプション）
- スキップ
```

If force delete is selected:

```bash
git branch -D {branch_name}
```

### 2.4 Check and Delete Remote Branch

Check if the remote branch exists:

```bash
git ls-remote --heads origin {branch_name}
```

**If the remote branch exists:**

```bash
git push origin --delete {branch_name}
```

**Note**: GitHub の auto-delete 設定で既に削除済みの場合、削除エラーは無視して Phase 2.5 へ進む。

### 2.5 Delete Review Result Local Files and Fix State Files <!-- AC-7 -->

> **Acceptance Criteria anchor (AC-7)**: PR マージ時に 5 カテゴリの PR-specific local artifacts を削除する: (1) `.rite/review-results/{pr_number}-*.json` wildcard 固定 prefix、(2) `.rite/review-results/{pr_number}-*.json.corrupt-*` corrupt rename ファイル、(3) `.rite/state/fix-fallback-retry-{pr_number}.count` specific path、(4) `.rite/fix-cycle-state/{pr_number}.json` specific path、(5) `.rite/fix-cycle-state.json` legacy 単一ファイル specific path。他 PR ファイルを誤削除しない。

Delete five categories of PR-specific local artifacts associated with the merged PR:

1. **Review result files**: `.rite/review-results/{pr_number}-*.json` — see [review-result-schema.md](../../references/review-result-schema.md#クリーンアップ) for the contract
2. **Corrupted review result files**: `.rite/review-results/{pr_number}-*.json.corrupt-*` — `.gitignore` 対象 orphan を防ぐため fix.md Phase 1.2.0 Priority 2 の corrupt rename を回収
3. **Fix retry state file**: `.rite/state/fix-fallback-retry-{pr_number}.count`
4. **Fix-cycle state file**: `.rite/fix-cycle-state/{pr_number}.json` — specific path 完全一致 (wildcard 禁止、収束エンジンが fix サイクルごとに記録する状態ファイル)
5. **Legacy fix-cycle state file**: `.rite/fix-cycle-state.json` — workspace 直下に生成された単一ファイル形式の残骸。specific path 完全一致 (wildcard 禁止)、`.gitignore` エントリと併置で defense-in-depth

**Safety constraints**:

- **PR 番号 prefix 固定**: wildcard は `{pr_number}-` で始まるパターンのみ。`*.json` 単独や `.rite/review-results/*`、`.rite/state/*` など他 PR のファイルを巻き込む形式は禁止。state file は specific path 完全一致で削除する
- **Non-blocking**: ファイル不在は silent continue。`rm` 失敗 (permission denied / IO error) は WARNING + `[CONTEXT]` で可視化する (silent 抑制しない)。canonical 定義: [common-error-handling.md](../../references/common-error-handling.md#non-blocking-contract-canonical-定義)
- **Idempotent**: 削除済み / 不在は WARNING / ERROR なしで続行 (`ℹ️  削除対象のレビュー結果ファイルはありません` info は dir 存在 + マッチ 0 件経路で出力)

> **scope note**: 本 bash block は単一 Bash tool invocation 内で閉じる前提で trap は block 外に伝播しない。block 末尾の trap restore は不要。

```bash
# 4 ブロック (matched_files / state_file / cycle_state / legacy_cycle_state) ごとに独立した
# stderr 退避 tempfile を持たせ、非対称再利用による詳細ログ喪失を防ぐ。
matched_files_rm_err=""
state_file_rm_err=""
cycle_state_rm_err=""
legacy_cycle_state_rm_err=""
_rite_cleanup_p25_cleanup() {
  rm -f "${matched_files_rm_err:-}" "${state_file_rm_err:-}" "${cycle_state_rm_err:-}" "${legacy_cycle_state_rm_err:-}"
}
trap 'rc=$?; _rite_cleanup_p25_cleanup; exit $rc' EXIT
trap '_rite_cleanup_p25_cleanup; exit 130' INT
trap '_rite_cleanup_p25_cleanup; exit 143' TERM
trap '_rite_cleanup_p25_cleanup; exit 129' HUP

pr_number="{pr_number}"

# 空 or 非数値の pr_number は glob path が変性して他 PR を誤削除しうる経路があるため
# 早期検証して non-blocking で exit する (silent misclassification 防止)。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 2.5 invoked with invalid pr_number: '$pr_number' (expected: numeric only, non-empty)" >&2
    echo "  対処: 呼び出し元 (cleanup.md Phase 1 で抽出される pr_number) を確認してください" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number" >&2
    exit 0  # non-blocking (cleanup 全体を失敗させない)
    ;;
esac

review_results_dir=".rite/review-results"
if [ -d "$review_results_dir" ]; then
  # bash glob は no-match でリテラル文字列を返すため明示的 nullglob 相当の処理。
  # 通常 `*.json` + fix.md Priority 2 が rename した `*.json.corrupt-*` を pr_number prefix
  # に限定して削除対象に含める。broken symlink も対象 ([ -e ] + [ -L ] 併用)。
  # Known limitation: glob → rm 間に TOCTOU window があるが pr_number prefix 固定 +
  # single-session 運用のため実害リスクは極小 (件数メッセージ不正確化のみ)。
  matched_files=()
  for f in "$review_results_dir"/"${pr_number}"-*.json; do
    { [ -e "$f" ] || [ -L "$f" ]; } && matched_files+=("$f")
  done
  for f in "$review_results_dir"/"${pr_number}"-*.json.corrupt-*; do
    { [ -e "$f" ] || [ -L "$f" ]; } && matched_files+=("$f")
  done
  if [ ${#matched_files[@]} -gt 0 ]; then
    # rm の stderr を独立 tempfile に退避し失敗時に可視化する (silent failure 禁止)。
    # mktemp 構文は Phase 2.5 内 4 ブロックで `mktemp ... 2>/dev/null) || { ... }` 形式に統一。
    matched_files_rm_err=$(mktemp /tmp/rite-cleanup-matched-rm-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: matched_files rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err; pr=${pr_number}" >&2
      echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
      matched_files_rm_err=""
    }
    if rm -f "${matched_files[@]}" 2>"${matched_files_rm_err:-/dev/null}"; then
      echo "✅ レビュー結果ファイルを削除しました: ${#matched_files[@]} 件 (PR #${pr_number})" >&2
    else
      rm_rc=$?
      echo "WARNING: 一部のレビュー結果ファイル削除に失敗 (PR #${pr_number}, rc=$rm_rc)" >&2
      if [ -n "$matched_files_rm_err" ] && [ -s "$matched_files_rm_err" ]; then
        head -5 "$matched_files_rm_err" | sed 's/^/  /' >&2
      fi
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=rm_failure; pr=${pr_number}" >&2
      echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
    fi
  else
    echo "ℹ️  削除対象のレビュー結果ファイルはありません (PR #${pr_number})" >&2
  fi
else
  # Directory absent → nothing to clean up; silent no-op
  :
fi

# fix retry state file 削除。specific path 完全一致 (wildcard 禁止)。
# fix.md Phase 1.2.0.1 Interactive Fallback の retry hard gate state file は PR merge 後不要。
# 独立 stderr 退避 tempfile で matched_files 側と変数分離 (二重障害時の混線防止)。
state_file=".rite/state/fix-fallback-retry-${pr_number}.count"
state_file_rm_err=$(mktemp /tmp/rite-cleanup-state-rm-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: state file rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
  echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err_state_file; pr=${pr_number}" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
  state_file_rm_err=""
}
# state file の存在を事前チェックし、実削除と no-op でメッセージを分岐する
state_file_existed=0
[ -f "$state_file" ] && state_file_existed=1
if rm -f "$state_file" 2>"${state_file_rm_err:-/dev/null}"; then
  if [ "$state_file_existed" = "1" ]; then
    echo "✅ fix retry state file を削除しました: $state_file" >&2
  fi
else
  rm_state_rc=$?
  echo "WARNING: fix retry state file の削除に失敗 (PR #${pr_number}, rc=$rm_state_rc): $state_file" >&2
  if [ -n "$state_file_rm_err" ] && [ -s "$state_file_rm_err" ]; then
    head -5 "$state_file_rm_err" | sed 's/^/  /' >&2
  fi
  echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=state_file_rm_failure; pr=${pr_number}" >&2
  echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
fi

# fix-cycle state file 削除。specific path 完全一致 (wildcard 禁止)。
# 既存の state_file 削除パターン (stderr tempfile + 詳細ログ) に対称化した error handling。
cycle_state_file=".rite/fix-cycle-state/${pr_number}.json"
cycle_state_rm_err=""
if [ -f "$cycle_state_file" ]; then
  cycle_state_rm_err=$(mktemp /tmp/rite-cleanup-cycle-state-rm-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: cycle state file rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err_cycle_state; pr=${pr_number}" >&2
    cycle_state_rm_err=""
  }
  if rm -f "$cycle_state_file" 2>"${cycle_state_rm_err:-/dev/null}"; then
    echo "✅ fix-cycle state file を削除しました: $cycle_state_file" >&2
  else
    rm_cycle_rc=$?
    echo "WARNING: fix-cycle state file の削除に失敗 (PR #${pr_number}, rc=$rm_cycle_rc): $cycle_state_file" >&2
    if [ -n "$cycle_state_rm_err" ] && [ -s "$cycle_state_rm_err" ]; then
      head -5 "$cycle_state_rm_err" | sed 's/^/  /' >&2
    fi
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=cycle_state_file_rm_failure; pr=${pr_number}" >&2
    echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
  fi
  [ -n "$cycle_state_rm_err" ] && rm -f "$cycle_state_rm_err"
fi

# legacy fix-cycle state file 削除。specific path 完全一致 (PR 番号非依存・wildcard 禁止)。
# workspace 直下に生成された単一ファイル形式の残骸を除去する。ファイル不在時は silent no-op、
# 既存 cycle_state_file 削除パターンと対称化した error handling (mktemp + stderr 退避 + non-blocking)。
legacy_cycle_state_file=".rite/fix-cycle-state.json"
if [ -f "$legacy_cycle_state_file" ]; then
  # incident response 用に mtime を捕捉してログ出力 (生成元トレース手段)。
  # GNU stat (Linux) / BSD stat (macOS) 両対応、失敗時は "unknown" を non-blocking で出力。
  legacy_cycle_mtime=$(stat -c '%y' "$legacy_cycle_state_file" 2>/dev/null \
    || stat -f '%Sm' "$legacy_cycle_state_file" 2>/dev/null \
    || echo "unknown")
  echo "ℹ️  legacy fix-cycle state file の mtime: $legacy_cycle_mtime ($legacy_cycle_state_file)" >&2
  echo "[CONTEXT] LEGACY_CYCLE_STATE_MTIME=$legacy_cycle_mtime; pr=${pr_number}" >&2
  legacy_cycle_state_rm_err=$(mktemp /tmp/rite-cleanup-legacy-cycle-rm-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: legacy cycle state file rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err_legacy_cycle; pr=${pr_number}" >&2
    legacy_cycle_state_rm_err=""
  }
  if rm -f "$legacy_cycle_state_file" 2>"${legacy_cycle_state_rm_err:-/dev/null}"; then
    echo "✅ legacy fix-cycle state file を削除しました: $legacy_cycle_state_file" >&2
  else
    rm_legacy_rc=$?
    echo "WARNING: legacy fix-cycle state file の削除に失敗 (PR #${pr_number}, rc=$rm_legacy_rc): $legacy_cycle_state_file" >&2
    if [ -n "$legacy_cycle_state_rm_err" ] && [ -s "$legacy_cycle_state_rm_err" ]; then
      head -5 "$legacy_cycle_state_rm_err" | sed 's/^/  /' >&2
    fi
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=legacy_cycle_state_file_rm_failure; pr=${pr_number}" >&2
    echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
  fi
  [ -n "$legacy_cycle_state_rm_err" ] && rm -f "$legacy_cycle_state_rm_err"
fi

# cleanup 関数が EXIT で stderr tempfile 4 種を削除する。block 末尾で cleanup を先に実行し
# その後 trap reset することで block 外への伝播を遮断する (順序: 解除→cleanup だと解除〜
# cleanup 間のシグナルで未実行になる、defense-in-depth)。
_rite_cleanup_p25_cleanup
trap - EXIT INT TERM HUP
```

**Placeholder**: `{pr_number}` はマージされた PR の番号 (Phase 1.2 で取得済み)。

### 2.6 Wiki Worktree Lifecycle (設計原則 — 削除しない)

`.rite/wiki-worktree/` は **永続化された worktree** であり、`/rite:pr:cleanup` では削除しません。理由:

- `wiki-worktree-setup.sh` は冪等で既存 worktree は no-op になるが再作成コスト (clone 相当の I/O) が高い
- 各 PR cycle で `wiki-ingest-trigger.sh` → `wiki-ingest-commit.sh` (review/fix/close Phase X.X.W.2) および `wiki-worktree-commit.sh` (ingest.md Phase 5.1 page 統合 / init.md Phase 3.5.1 .gitkeep migration / lint.md Phase 8.3 log.md 追記) がここを経由して wiki branch に raw source / page を landing させるため cycle を跨いで保持される必要がある
- `git branch -d` は worktree が checkout している branch を削除できないため、wiki branch 自体への副作用もない

**手動削除が必要な場合** (リポジトリ移動 / 構造変更 / debug):

```bash
# 1. worktree を解除（git の internal 管理から外す）
git worktree remove .rite/wiki-worktree
# 2. dangling な worktree metadata を整理
git worktree prune
```

`git worktree remove` が `worktree contains modified or untracked files` で失敗する場合、`--force` を付けるか、worktree 内で先に commit / push を完了させてから再試行してください。

---

## Phase 3: Projects Status Update

> See [references/archive-procedures.md](./references/archive-procedures.md) for the full archive procedures: Projects Status Update (3.1-3.2), Work Memory final update (3.5), Issue close (3.6), Parent Issue handling (3.6.4, 3.7), and State reset (Phase 4). Status update delegates to `projects-status-update.sh`.

---

## Phase 4.W: Wiki Auto-Ingest (Conditional)

> **Reference**: [Wiki Ingest](../wiki/ingest.md) — `/rite:wiki:ingest` Skill API.
>
> This phase is the **page integration** counterpart: it invokes `/rite:wiki:ingest` (LLM-driven page integration) to process pending raw sources accumulated on the wiki branch during the PR lifecycle. Raw source **accumulation** is handled by `wiki-ingest-trigger.sh` + `wiki-ingest-commit.sh` in `review.md` Phase 6.5.W.2 / `fix.md` Phase 4.6.W.2 / `close.md` Phase 4.4.W.2.
>
> **Loss-safe guarantee**: Ingest failure does NOT fail cleanup. Raw sources remain on the wiki branch and can be processed by a subsequent `/rite:wiki:ingest` invocation.

### 4.W.1 Pre-condition Check

**Step 1**: Check Wiki configuration:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_ingest=""
if [[ -n "$wiki_section" ]]; then
  auto_ingest=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_ingest:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_ingest:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"
```

If `wiki_enabled=false` or `auto_ingest=false`, **emit a skip status line + sentinel and skip to Phase 5** (do not silently skip — the completion report relies on this signal):

```bash
if [ "$wiki_enabled" = "false" ]; then
  reason="disabled"
elif [ "$auto_ingest" = "false" ]; then
  reason="auto_ingest_off"
else
  reason=""
fi
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
  trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
  if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type wiki_ingest_skipped \
      --details "cleanup Phase 4.W skipped: $reason" \
      --pr-number {pr_number} 2>"${emit_err:-/dev/null}"); then
    [ -n "$sentinel_line" ] && echo "$sentinel_line" && echo "$sentinel_line" >&2
  else
    fallback_iter="{pr_number}-$(date +%s)"
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_skipped reason=$reason; iteration_id=$fallback_iter"
    echo "$fallback_sentinel"
    echo "$fallback_sentinel" >&2
    echo "WARNING: workflow-incident-emit.sh (wiki_ingest_skipped) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
    [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
  fi
  [ -n "$emit_err" ] && rm -f "$emit_err"
  trap - EXIT INT TERM HUP
fi
```

If `reason` is non-empty, skip Steps 2-3 and Phase 4.W.2-4.W.3 and proceed to Phase 5. Otherwise continue to Step 2.

**Step 2**: Check for pending raw sources on the wiki branch:

```bash
wiki_branch=$(awk '/^wiki:/{h=1;next} h && /^[[:space:]]+branch_name:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"

# Check if wiki branch exists (local or remote)
# Use git ls-tree -r for flat file listing (avoids git show directory header/subdirectory issues)
pending_count=0
ref=""
if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then
  ref="$wiki_branch"
elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
  ref="origin/$wiki_branch"
fi

if [ -n "$ref" ]; then
  # git ls-tree -r --name-only lists all files recursively under .rite/wiki/raw/
  # (e.g., .rite/wiki/raw/reviews/20260416T075144Z-pr-542.md)
  pending_count=$(git ls-tree -r --name-only "$ref" .rite/wiki/raw/ 2>/dev/null \
    | while read -r filepath; do
        content=$(git show "$ref":"$filepath" 2>/dev/null)
        if echo "$content" | grep -q 'ingested: false'; then
          echo "$filepath"
        fi
      done | wc -l)
fi
echo "pending_count=$pending_count wiki_branch=$wiki_branch ref=$ref"
```

If `pending_count == 0`, **emit a skip sentinel and display message**, then proceed to Phase 5:

```bash
if [ "$pending_count" -eq 0 ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=no_pending"
  echo "ℹ️ pending raw source はありません。Wiki ingest をスキップします。"
fi
```

If `pending_count == 0`, skip Phase 4.W.2-4.W.3 and proceed to Phase 5. Otherwise continue to Phase 4.W.2.

### 4.W.2 Invoke Wiki Ingest

**MUST**: `/rite:wiki:ingest` invoke は本 step の必須処理。**時間的制約・context 残量・セッション経過を理由にした skip は禁止** (LLM の自己判断省略は identity 違反)。skip が許される唯一の条件は Phase 4.W.1 で判定済みの機械的 Skip condition (`wiki.enabled=false` / `auto_ingest=false` / `pending_count == 0`)。

> **Correct pattern**: Phase 4.W.1 で `pending_count >= 1` が確定したら例外なく下記 Skill invocation を実行する。継続困難な場合は `/clear` + `/rite:resume` をユーザーに案内する。
>
> **Identity reference**: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` / `clear_resume_is_canonical` / `quality_over_expediency` principle を参照。

**Pre-write** (before invoking `rite:wiki:ingest`): Update flow state to `cleanup_pre_ingest` so `stop-guard.sh` blocks premature `end_turn` during sub-skill execution and surfaces the phase-specific HINT. The `if ! cmd; then` rc capture is mandatory — silent patch failure here disables the stop-guard defence-in-depth.

```bash
# --active true を明示する理由: Phase 1.0 patch が fail-safe path を経由した場合 active=false
# 残存状態のまま到達する可能性があるため、各 patch で active=true を明示的に pin する。
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_pre_ingest" --active true \
    --next "After rite:wiki:ingest returns: run 🚨 Mandatory After Wiki Ingest (Pre-write cleanup_post_ingest) → Phase 5 Completion Report (cleanup_completed + <!-- [cleanup:completed] --> as inline HTML sentinel at the trailing position of the final list item of Phase 5.2) in the SAME response turn. Do NOT stop." \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (cleanup_pre_ingest) failed — stop-guard defence-in-depth is disabled for this Phase 4.W.2 invocation. Sub-skill rite:wiki:ingest will still be invoked, but premature end_turn will not be blocked." >&2
fi
```

Invoke the `/rite:wiki:ingest` Skill to process pending raw sources into Wiki pages:

```
Skill: rite:wiki:ingest
```

> **⚠️ Loss-safe continuation**: `/rite:wiki:ingest` は同セッション内で Skill ツール経由で invoke される。ingest.md の結果パターン（成功/失敗）を確認し、Phase 4.W.3 に進むこと。ingest 成否に関わらず cleanup は続行する。

> **🚨 Immediate after rite:wiki:ingest returns**: When the sub-skill outputs `<!-- [ingest:completed] -->` and returns control, do **NOT** end the turn. The sub-skill return is a CONTINUATION TRIGGER (see [Correct continuation pattern](#correct-continuation-pattern) above). **Immediately** proceed to Phase 4.W.3 result handling, then to 🚨 Mandatory After Wiki Ingest below, in the **same response turn**.

### 4.W.3 Result Handling

**On success** (ingest completed):

```
✅ Wiki ingest 完了: {pages_created} ページ生成、{raw_processed} raw source 統合済み
[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}; type=cleanup_ingest
```

**Push failure detection**: After the `rite:wiki:ingest` Skill returns, inspect its stdout for the marker `push=failed` (written by `wiki-worktree-commit.sh` when it returns rc=4 — the commit landed on local wiki branch but origin push failed). On detection, emit an observable sentinel so cleanup continues (loss-safe) and the incident layer registers the divergence.

**LLM detection and substitution rule**: Claude inspects the ingest Skill's output in the conversation context for a line matching `push=failed`. Typical positive match: `[wiki-worktree-commit] committed=1; branch=wiki; head=<sha>; push=failed`. Typical negatives: `push=ok`, `reason=no-pending`, or no `[wiki-worktree-commit]` status line (ingest skipped). Substitute `{wiki_push_failed}` with `"true"` (detected) or `"false"` (not detected) — Claude Code's Bash tool does not persist state across tool calls so shell env vars are not viable.

```bash
# Claude substitutes {wiki_push_failed} with "true" or "false" based on ingest output inspection.
# {pr_number} is substituted with the PR number from Phase 1. {plugin_root} is substituted per
# plugin-path-resolution.md.
wiki_push_failed="{wiki_push_failed}"

# Resolve wiki_branch from rite-config.yml (this bash block is a separate invocation from
# Phase 4.W.1 Step 2, so the shell variable from that step is out of scope). Same parser as
# Phase 4.W.1 Step 2.
wiki_branch=$(awk '/^wiki:/{h=1;next} h && /^[[:space:]]+branch_name:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"

if [ "$wiki_push_failed" = "true" ]; then
  # reason=commit_rc_4 で start.md Phase 5.6.2 の aggregation pattern と統一する
  # (cleanup 固有情報は source= key で併記)。
  echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; source=cleanup_4W"
  emit_err=$(mktemp /tmp/rite-wiki-pushfail-emit-err-XXXXXX 2>/dev/null) || emit_err=""
  trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
  if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type wiki_ingest_push_failed \
      --details "wiki-worktree-commit.sh exited 4 (commit landed, push failed) during cleanup Phase 4.W" \
      --pr-number {pr_number} 2>"${emit_err:-/dev/null}"); then
    [ -n "$sentinel_line" ] && echo "$sentinel_line" && echo "$sentinel_line" >&2
  else
    fallback_iter="{pr_number}-$(date +%s)"
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_push_failed; iteration_id=$fallback_iter"
    echo "$fallback_sentinel"
    echo "$fallback_sentinel" >&2
    echo "WARNING: workflow-incident-emit.sh (wiki_ingest_push_failed) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
    [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
  fi
  [ -n "$emit_err" ] && rm -f "$emit_err"
  trap - EXIT INT TERM HUP
  # ユーザー可視の push 失敗警告は Phase 5.1 Completion Report display rules に一元化済み。
fi
```

**Non-blocking guarantee**: push failure does NOT fail cleanup; the commit is preserved on the local wiki branch. The next cleanup / manual push retry can recover the origin state.

**On failure** (ingest error or partial failure):

Emit failure sentinel and continue to Phase 5 (loss-safe continuation):

```bash
echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=ingest_error; phase=cleanup_4W"
emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
    --type wiki_ingest_failed \
    --details "rite:wiki:ingest failed during cleanup Phase 4.W" \
    --pr-number {pr_number} 2>"${emit_err:-/dev/null}"); then
  [ -n "$sentinel_line" ] && echo "$sentinel_line" && echo "$sentinel_line" >&2
else
  fallback_iter="{pr_number}-$(date +%s)"
  fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_failed; iteration_id=$fallback_iter"
  echo "$fallback_sentinel"
  echo "$fallback_sentinel" >&2
  echo "WARNING: workflow-incident-emit.sh (wiki_ingest_failed) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
  [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
fi
[ -n "$emit_err" ] && rm -f "$emit_err"
trap - EXIT INT TERM HUP
```

```
⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。
手動で `/rite:wiki:ingest` を実行してページ統合を再試行できます。
```

**Non-blocking guarantee**: Regardless of success or failure, proceed to Phase 5 (Completion Report).

### 🚨 Mandatory After Wiki Ingest (Defense-in-Depth)

> **⚠️ MUST execute in the SAME response turn**: `rite:wiki:ingest` の return 直後、応答を終了せずに Step 0 → Step 1 → Step 2 を即座に実行する。Phase 5 (Completion Report) は本セクション経由でのみ実行される唯一の経路。
>
> **Layer 2 historical note (#675)**: 以下 prose 中の `stop-guard.sh` への言及 (line 1272 / 1284) は historical context — Layer 2 hard gate (`hooks/stop-guard.sh`) は #675 で撤去済で、現行 runtime には存在しない。Defense は Layer 1 (本 prose 自体) + Layer 3 (caller HTML hint) のみに依存する (`sub-skill-return-protocol.md` Defense-in-depth layers 参照)。protocol violation の post-hoc incident detection も `workflow-incident-emit.sh` に移譲済。

**Self-check and branching**:

1. **Has `<!-- [cleanup:completed] -->` been output (as inline HTML sentinel at the trailing position of Phase 5.2's final list item)?** Use `grep -F '[cleanup:completed]'` for terminal detection.
   - **Yes** — terminal reached. flow state は既に `cleanup_completed, active: false`。Step 0 / Step 1 below MUST be skipped (`flow-state-update.sh patch --if-exists` は active=false でも patch するため、実行すると phase を `cleanup_post_ingest` に巻き戻して flow state を破壊する)。
   - **No** — Phase 5 has NOT been output yet。Steps 0-2 below are critical — execute immediately to force the workflow into the terminal state.

**Step 0: Immediate Bash Action**: **MUST execute** this bash block as your **VERY FIRST tool call** after `rite:wiki:ingest` returns (Self-check No branch), **BEFORE any text output, narrative, or response generation**. text output を先に出すと LLM の turn-boundary heuristic が誤発火し implicit stop の経路が開く (Issue #910 で実証)。This replaces the natural turn-boundary point ("the sub-skill finished") with a concrete next tool call. The block re-affirms the flow-state phase (idempotent with Step 1) and, on failure only, emits `[CONTEXT] STEP_0_PATCH_FAILED=1` to stderr.

```bash
# --preserve-error-count: 未指定時は JQ_FILTER が .error_count = 0 でリセットし、
#   stop-guard.sh の RE-ENTRY DETECTED escalation + THRESHOLD=3 bail-out が unreachable になる。
# --if-exists: flow state file 不在時は silent skip (defense-in-depth)。
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_post_ingest" --active true \
    --next "Step 0 Immediate Bash Action fired; proceeding to Phase 5 Completion Report. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_0_PATCH_FAILED=1" >&2
  # Step 1 が idempotent patch として再試行する non-blocking failure。
fi
```

> **Rationale**: caller が implicit stop し `continue` 介入が必要となる症状の根本原因は、LLM が sub-skill return tag (`<!-- [ingest:completed] -->`) を turn 境界として誤認する turn-boundary heuristic の発火。Step 0 は **具体的な bash tool 呼び出し** を sub-skill return 直後の必須アクションとして挿入することで turn 境界シグナルを消去する。Step 0 / Step 1 は idempotent — この冗長性が防御機構である (Step 0 bash 引数 `--phase` / `--active` / `--next` / `--preserve-error-count` / `--if-exists` は `hooks/stop-guard.sh` `cleanup_pre_ingest` arm WORKFLOW_HINT と対称、片側更新時は対称先も同時更新が必要、対称化テストで担保)。

**Step 1**: Update flow state to post-ingest phase (idempotent re-patch)。Step 0 が既に書いた `cleanup_post_ingest` の timestamp / `next_action` を refresh する。2 重 patch design は transient failure 下でも Step 0 / Step 1 のいずれかが成功することを保証し、同時失敗時のみ `[CONTEXT] STEP_1_PATCH_FAILED=1` を retained flag として残す。`--preserve-error-count` は Step 0 と対称に付与 (RE-ENTRY DETECTED escalation + THRESHOLD bail-out を機能させるため):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_post_ingest" --active true \
    --next "rite:wiki:ingest completed/skipped/failed. Proceed to Phase 5 (Completion Report) and emit <!-- [cleanup:completed] --> as inline HTML sentinel at the trailing position of the final list item of Phase 5.2 in the SAME response turn. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_1_PATCH_FAILED=1" >&2
fi
```

**Step 2**: **→ Proceed to Phase 5 now**. Phase 5 outputs the user-visible completion message, the `<!-- [cleanup:completed] -->` HTML comment sentinel (inline at the trailing position of Phase 5.2's final list item), and the final flow-state deactivate (`cleanup_completed`, `active: false`) in a single contiguous block. Recap lines like "※ wiki ingest 完了" are acceptable as **leading** content only — the final user-visible content MUST be the Phase 5.2 ordered list whose final item carries the inline HTML-commented sentinel (a recap as last line creates a turn-boundary heuristic trigger).

---

## Phase 5: Completion Report

### 5.1 Cleanup Result Summary

> **出力形式 note**: 以下の fenced code block は **テンプレート記法**。LLM は実 output 時に fence なしでテキスト本文のみを展開し、プレースホルダー (`{pr_number}` / `{issue_number}` 等) は実値に置換する。fence そのものを rendered view に出力してはならない (Phase 5.2 と同趣旨の fence 禁止)。

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
- [{review_cleanup_check}] レビュー結果ファイル・fix state ファイルを削除
- [x] flow state をリセット
- [{projects_check}] Projects Status を Done に更新
- [{wiki_ingest_check}] Wiki ingest（pending raw source のページ統合）
- [x] 作業メモリを最終更新
- [x] 関連 Issue をクローズ
- [x] 親 Issue の Tasklist チェックボックスを更新（該当する場合）
- [x] 親 Issue の自動クローズ（該当する場合）
- [x] ローカル作業メモリを削除（該当する場合）
```

**Review cleanup result display rules:**

| `REVIEW_CLEANUP_PARTIAL_FAILURE` | `{review_cleanup_check}` |
|----------------------------------|--------------------------|
| not set (正常) | `x` |
| `1` (部分失敗) | ` ` (space) + 下記の警告を表示 |

When `REVIEW_CLEANUP_PARTIAL_FAILURE` is `1`, append the following after the checklist:

```
⚠️ レビュー結果ファイルの削除が完了しませんでした (reason: {reason})。
手動で確認してください: ls -la .rite/review-results/{pr_number}-* .rite/state/fix-fallback-retry-{pr_number}.count
```

**Projects Status update result display rules:**

| `projects_status_updated` | `{projects_status_result}` | `{projects_check}` |
|---------------------------|---------------------------|---------------------|
| `true` | `Done` | `x` |
| `false` | `⚠️ 更新失敗（手動確認が必要）` | ` ` (space) |

When `projects_status_updated` is `false`, append the following after the checklist:

```
⚠️ Projects Status の更新に失敗しました。手動で更新してください:
GitHub Projects 画面で Issue #{issue_number} の Status を "Done" に変更
```

**Wiki ingest result display rules:**

| Sentinel | `{wiki_ingest_check}` | 表示内容 |
|----------|----------------------|----------|
| `WIKI_INGEST_DONE=1` 単独 | `x` | (追加表示なし) |
| `WIKI_INGEST_DONE=1` + `WIKI_INGEST_PUSH_FAILED=1` 併存 | ` ` (space) | **PUSH_FAILED 優先**: 下記の push 失敗警告を表示 (commit は local wiki branch に保持、origin 側のみ divergence) |
| `WIKI_INGEST_PUSH_FAILED=1` 単独 (DONE なし) | ` ` (space) | 下記の push 失敗警告を表示 |
| `WIKI_INGEST_SKIPPED=1; reason=disabled` | `x` | `ℹ️ Wiki ingest スキップ (wiki.enabled=false)` |
| `WIKI_INGEST_SKIPPED=1; reason=auto_ingest_off` | `x` | `ℹ️ Wiki ingest スキップ (wiki.auto_ingest=false)` |
| `WIKI_INGEST_SKIPPED=1; reason=no_pending` | `x` | `ℹ️ Wiki ingest スキップ (pending raw source なし)` |
| `WIKI_INGEST_FAILED=1` | ` ` (space) | 下記の ingest 失敗警告を表示 |
| sentinel なし (Phase 4.W 未実行) | ` ` (space) | `⚠️ Wiki ingest Phase が実行されませんでした` |

**Sentinel 評価優先順位**: 上記テーブルは上から順に評価し最初にマッチした行を採用する (push failure は ingest 成功 `WIKI_INGEST_DONE=1` と併存可能なため `WIKI_INGEST_PUSH_FAILED=1` 行を優先する)。`{wiki_branch}` は Phase 4.W.1 Step 2 と同じ parser で `rite-config.yml` の `wiki.branch_name` を解決する (未設定時 `wiki`)。

`WIKI_INGEST_PUSH_FAILED` が検出された場合 (`WIKI_INGEST_DONE` との併存有無を問わず)、チェックリストの後に以下を付記する:

```
⚠️ Wiki ingest: commit は local wiki branch に landed しましたが origin への push に失敗しました。
  手動回復: git -C .rite/wiki-worktree push origin {wiki_branch}
```

`WIKI_INGEST_FAILED` が検出された場合、チェックリストの後に以下を付記する:

```
⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。
手動で `/rite:wiki:ingest` を実行してページ統合を再試行できます。
```

**Parent Issue close result (displayed only when Phase 3.7 was executed):**

```
親 Issue 処理:
- 親 Issue: #{parent_issue_number} - {parent_issue_title}
- 結果: {parent_close_result}
```

**Values for `{parent_close_result}`:**

| State | Display Value |
|-------|--------------|
| Auto-close succeeded | `✅ 自動クローズ完了（全子 Issue 完了）` |
| Remaining child Issues | `⏳ 残り {remaining_count} 件の子 Issue が未完了` |
| Already closed | `✅ 既にクローズ済み` |
| Error occurred | `⚠️ クローズ失敗（手動対応が必要）` |

**Incomplete task processing results (displayed only when Phase 1.7 was executed):**

```
未完了タスク処理:
- Issue 化: {issue_count} 件
- チェック完了: {checked_count} 件
- 無視: {ignored_count} 件

作成した Issue:
| Issue | タイトル |
|-------|----------|
| #{new_issue_number} | {task_name}（#{original_issue_number} 残作業） |
```

**Placeholder relationships:**
- `{new_issue_number}`: The number of the new Issue created in Phase 1.7.3.2
- `{task_name}`: The name of the incomplete task extracted from the work memory (base for the Issue title)
- `{original_issue_number}`: The original Issue number (identified in Phase 1.5)

**If there are stashed changes:**

```
スタッシュした変更を復元しますか？

オプション:
- 復元する（git stash pop）
- 後で手動で復元する
```

If restore is selected:

```bash
git stash pop
```

### 5.2 Guidance for Next Steps

> **⚠️ 出力形式**: 以下は **通常 ordered list** として出力する (fenced code block で囲まない)。末尾の HTML コメント sentinel `<!-- [cleanup:completed] -->` は **最終 list item 末尾に半角スペース区切りで inline 付加** する (独立行禁止 — 理由は Phase 5.3 参照)。

次のステップ:
1. `/rite:issue:list` で次の Issue を確認
2. `/rite:issue:start <issue_number>` で新しい作業を開始 <!-- [cleanup:completed] -->

> **⚠️ MUST NOT**:
> - 「次のステップ:」ブロック最終項目直後に余計な空行を出力してはならない (非退行)。
> - Phase 5.2 を fenced code block (` ``` ` で囲む形式) にしてはならない。通常 ordered list として出力する。理由: fenced code block 内では inline HTML が literal 文字列として可視表示され、`[cleanup:completed]` bare bracket 形式の UI 可視化につながる。
> - HTML コメント sentinel を独立行として出力してはならない。独立行だと CommonMark HTML block (type 2) として解釈され、renderer が前後に空行を要求し、`Ran 1 shell command` (下記 Phase 5.3 Step 1 bash UI) と後続 recap の間に余計な空行が rendered view で可視化する。最終 list item `2. /rite:issue:start ...` の末尾に **半角スペース区切りで inline 付加** することで inline HTML として処理され、前後空行要求を回避する。
> - 末尾空行は LLM turn-boundary heuristic を誤発火させうる fragile 要因。本ファイルは `wiki/lint.md` Phase 9.2 三点セット規約 (3 独立ブロック構造) から意図的に divergence し、2 ブロック構造 (完了メッセージ + 次のステップ-with-inline-sentinel) を採用する (rendered view の空行抑制が 3 ブロック規約整合より優先)。

### 5.3 Terminal Completion

> **⚠️ MUST NOT**: 「ユーザー可視最終行 = `[cleanup:completed]` の bare bracket 形式」で turn を終わらせてはならない。bare sentinel は LLM の turn-boundary heuristic を誤発火させ、recap 出力後の implicit stop を再発させる既知リスク。**HTML コメント形式 (`<!-- [cleanup:completed] -->`) のみ許容**、かつ **Phase 5.2 最終 list item 末尾に inline 配置** (独立行禁止)。
>
> **Output ordering** (絶対遵守 — 各ブロック間に余計な空行を挿入しない、HTML sentinel は LLM の独立行として出力しない):
> 1. Phase 5.1 Cleanup Result Summary — 前段で出力済み (ユーザー可視メッセージ + チェックリスト + 警告群)
> 2. Phase 5.2 Guidance for Next Steps — 前段で出力済み (ユーザー可視 ordered list、最終項目末尾に inline HTML sentinel `<!-- [cleanup:completed] -->` を付加)
> 3. Phase 5.3 Step 1: flow-state deactivate (下記 Step 1) — Phase 5.2 最終項目直後に連続実行 (中間に空行を挟まない)。bash 出力はユーザー可視だが、`(Bash completed with no output)` のため最終行にならない

**Step 1**: Deactivate flow state to terminal `cleanup_completed` (idempotent — safe to re-execute). The `if ! cmd; then` rc capture is mandatory — silent failure here leaves `.active = true`、which causes the next session-end / stop-guard evaluation to surface a stale HINT:

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_completed" \
    --next "none" --active false \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (cleanup_completed) failed — flow state may still report active=true. Subsequent self-verification will fail because '.phase = cleanup_completed AND .active = false' won't hold. Manually run: bash {plugin_root}/hooks/flow-state-update.sh patch --phase cleanup_completed --next none --active false --if-exists" >&2
fi
```

上記 Step 1 bash 実行はこの Phase 5.3 で LLM が取る最後の action。直後にさらに text output / tool call を追加してはならない (terminal 条件)。bash tool stdout は markdown text channel と分離されているため sentinel の最終行性質は保たれる。

**Self-verification** (turn 終了直前の必須チェック — 全 3 項目 YES で turn を閉じてよい):
- `grep -F '[cleanup:completed]'` against the response output finds the HTML-commented sentinel in Phase 5.2 final list item? → MUST be YES
- User-visible `クリーンアップが完了しました` checklist + `次のステップ:` ordered list displayed? → MUST be YES
- flow state の `.phase = cleanup_completed` and `.active = false`? → MUST be YES

If all three are YES, stop is allowed. If any is NO, return to the missing step and re-output before ending the turn.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| PR Not Found | See [common patterns](../../references/common-error-handling.md) |
| Branch Deletion Failure | `git branch` でブランチ一覧を確認; デフォルトブランチに切り替えてから再実行 |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
| Issue Close Failure | `gh issue view {issue_number}` で Issue の状態を確認; 手動で `gh issue close {issue_number}` を実行 |
| Incomplete Task Issue Creation Failure | クリーンアップは続行します; 以下のタスクを手動で Issue 化してください: |
