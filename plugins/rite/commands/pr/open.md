---
description: Issue を起点にブランチ作成・実装・lint・draft PR 作成までを一気通貫で実行
---

# /rite:pr:open

## Contract

**Input**: Issue number (required)
**Output**: 完了通知（draft PR の番号と URL）

Issue を起点に「準備 → ブランチ → 計画 → 実装 → lint → PR」までを一気通貫で実行する。レビュー/修正は `/rite:pr:iterate`、Ready 化は `/rite:pr:ready`、マージは `/rite:pr:merge` で実施する。

**途中で止まったら**: `/rite:resume` が flow-state ファイル (`.rite/sessions/{session_id}.flow-state`) の phase から復帰する。本コマンドの Step 0 が Resume Dispatch を担う。

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | 引数 |
| `{owner}`, `{repo}` | `gh repo view --json owner,name` |
| `{base_branch}` | `branch.base` in `rite-config.yml`（default: `main`） |
| `{branch_name}` | ステップ 2 で生成 |
| `{pr_number}` | ステップ 6 の `[pr:created:N]` から抽出 |
| `{project_number}` | `rite-config.yml` の `github.projects.project_number` |
| `{parent_issue_number}` | ステップ 1.2 で検出した親 Issue 番号（親 detection 時のみ） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 0: Resume Dispatch（`/rite:resume` から呼ばれた場合のジャンプ）

セッション開始時に flow-state を読み、再開かどうかを判定する。新規セッション (state file 不在 or `active=false` or `issue_number` 不一致) の場合は何もせずステップ 1 に進む:

```bash
resume_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || resume_phase=""
resume_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || resume_issue=""
resume_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "") || resume_active=""
resume_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0") || resume_pr="0"

if [ -n "$resume_phase" ] && [ "$resume_active" = "true" ] && [ "$resume_issue" = "{issue_number}" ]; then
  echo "[CONTEXT] RESUME_DISPATCH=1; phase=$resume_phase; issue=$resume_issue; pr=$resume_pr"
else
  echo "[CONTEXT] RESUME_DISPATCH=0; reason=fresh_or_mismatched_session (phase='$resume_phase' active='$resume_active' issue='$resume_issue' arg='{issue_number}')"
fi
```

`{plugin_root}/hooks/flow-state.sh get --default ""` は session 解決失敗 / file 不在 / jq parse 失敗のいずれでも default を stdout に書く設計のため、外側 `|| ...` は helper validation 失敗 (`--field` 引数欠落 / invalid field name) 経路のみを catch する defensive fallback。stderr は WARNING channel として残し、`2>/dev/null` で握りつぶさない (想定外 ERROR を context に残すため)。

**LLM routing rule** (Bash tool shell state は次の Bash 呼び出しでリセットされるため `[CONTEXT] RESUME_DISPATCH=` marker を会話コンテキストから読む):

| `RESUME_DISPATCH` value + `phase` | LLM action |
|---|---|
| `0` | 新規セッション or 別 Issue。ステップ 1 から通常開始 |
| `1` + `phase=init` | ステップ 1 (準備) から再実行 (idempotent) |
| `1` + `phase=branch` | ステップ 2 (ブランチ作成) から再開。既存ブランチがあれば `git switch` で復帰 |
| `1` + `phase=plan` | ステップ 3 (実装計画) から再開。既存の Issue body 実装ステップを再読込 |
| `1` + `phase=implement` | ステップ 4 (実装) を継続。`/rite:issue:implement` の checklist 未完項目から続行 (autonomous lint まで進む内蔵動作あり) |
| `1` + `phase=lint` | ステップ 5 (Step 4 内 autonomous lint の sentinel 検証) から再開。implement が既に lint まで完了している場合は sentinel を context から読み Step 6 へ |
| `1` + `phase=pr` | ステップ 6 (PR 作成) から再開。既存 draft PR があれば検出して `[pr:created:N]` 相当を再構成 |
| `1` + `phase=review` / `fix` | 本コマンドは扱わない。ユーザーに `/rite:pr:iterate <pr={resume_pr}>` を案内 (PR 番号は `[CONTEXT] RESUME_DISPATCH=...; pr=$resume_pr` marker から literal substitute) |
| `1` + `phase=ready` / `ready_error` | 本コマンドは扱わない。`/rite:pr:ready <pr={resume_pr}>` を案内 |
| `1` + `phase=cleanup` / `ingest` / `completed` | 既に PR 段階を超えている。ユーザーに状態を案内して `/rite:pr:cleanup <pr={resume_pr}>` 等を提案 |

`active=false` または `issue_number` が引数と異なる場合は別 Issue の state なので新規セッション扱い (ステップ 1 から開始)。

---

## ステップ 1: 準備（Issue 取得・親判定・品質評価）

### 1.1 Issue 情報取得

```bash
gh issue view {issue_number} --json number,title,body,state,labels,milestone,projectItems
```

State が `closed` の場合は AskUserQuestion で「再オープンして作業 / 中止」を選択。

### 1.2 親 Issue 検出

以下のいずれかに該当すれば親 Issue として扱う:

1. `trackedIssues.nodes` が空でない（GraphQL）
2. Body に `- [ ] #NN` 形式のタスクリストがある
3. ラベルに `epic` / `parent` / `umbrella` のいずれか

親 Issue の場合は AskUserQuestion で「子 Issue を選んで作業 / この親 Issue 自体に対して作業 / 中止」を提示。子 Issue 選択時は trackedIssues から open かつ未着手のものを priority + complexity 順で並べて 1 件選択させ、選択後は `{issue_number}` を子の番号に置換してステップ 1.1 から再実行する。

### 1.3 Issue 品質評価

What / Why / Where / Scope の充足度で A-D 評価。C/D の場合は AskUserQuestion で「既存情報で開始 / Issue を編集してから再実行 / 中止」を選択。

### 1.4 設定読込 (language)

`rite-config.yml` の `language` field を取得し `[CONTEXT] WORKFLOW_LANGUAGE=` marker として emit。ステップ 4 の commit message テンプレで参照される。

### 1.5 Iteration 自動 assign

`iteration.enabled: true` かつ `iteration.auto_assign: true` の場合、現在の active iteration を取得して Issue を assign する (Sprint workflow との統合)。詳細は `commands/sprint/plan.md` 参照。

### 1.6 flow-state 初期化

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase init --issue {issue_number} --branch "" --pr 0 \
  --next "ブランチ作成へ進む"
```

---

## ステップ 2: ブランチと Projects

### 2.1 ブランチ名生成

`rite-config.yml` の `branch.pattern`（default: `{type}/issue-{number}-{slug}`）に従う。

- **type**: labels / title から推定（`bug`/`bugfix` → `fix`、`docs` → `docs`、`refactor` → `refactor`、`chore`/`maintenance` → `chore`、それ以外 → `feat`）
- **slug**: Issue title を kebab-case 化 (英数字 + ハイフン、50 文字上限)

### 2.2 既存ブランチチェック

`git rev-parse --verify {branch_name}` で既存確認。存在する場合は `git switch {branch_name}` で復帰、なければ次へ。

### 2.3 ブランチ作成

```bash
git switch {base_branch} && git pull --ff-only origin {base_branch} && git switch -c {branch_name}
```

### 2.4 GitHub Projects Status 更新

`rite-config.yml.github.projects.enabled: true` の場合、Projects の Status を `In Progress` に更新。詳細は `references/projects-integration.md` 参照。

### 2.5 Work Memory 初期化

Issue の comment として work memory を初期投稿する。`コマンド:` 行は `rite:pr:open` を記載。詳細は `skills/rite-workflow/references/work-memory-format.md` 参照。

### 2.6 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase branch --issue {issue_number} --branch {branch_name} --pr 0 \
  --next "実装計画策定へ進む"
```

---

## ステップ 3: 実装計画

### 3.1 Issue 内容分析

Issue body から「What / Why / Where / Acceptance Criteria」を抽出。

### 3.2 変更対象ファイルの特定

`git grep` / `find` / Read で関連ファイルを特定。Acceptance Criteria に対する責務ファイルを列挙する。

### 3.3 実装計画生成

以下のテンプレートで実装計画を出力:

```
## 実装計画

### 変更対象ファイル
- {file_path_1}: {responsibility}

### 実装ステップ
1. {step_1}
2. {step_2}

### 受入基準マッピング
- AC1 → step {N}

### 注意点
- {note_1}
```

### 3.4 ユーザー確認

AskUserQuestion で「この計画で実装開始 / 計画を修正 / 中止」を選択。

### 3.5 Issue Body Checklist 更新

実装ステップを Issue body の `- [ ]` チェックリストとして追記。詳細は `references/issue-body-checklist.md` 参照。

### 3.6 Work Memory 更新

実装計画を work memory comment に記録。

### 3.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase plan --issue {issue_number} --branch {branch_name} --pr 0 \
  --next "実装作業へ進む"
```

---

## ステップ 4: 実装

```text
skill: rite:issue:implement
args: "{issue_number}"
```

`/rite:issue:implement` は以下を担う:

- チェックリスト駆動で各ステップを実装 (Edit / Write ツール経由)
- conventional commits 形式でコミット (`{type}: {summary} (refs #{issue_number})`)
- Work Memory のチェックリストを完了状態に更新
- 全 step 完了後、autonomous に `rite:lint` を Skill ツール経由で invoke する
  (元 `start.md` の flat 設計を継承した内蔵動作。本コマンドの責務として lint 二重実行を避けるため、Step 5 は no-op になる)

**実態としての挙動**:
- `/rite:issue:implement` 完了時点で `phase=lint` が flow-state に書かれ、`rite:lint` の sentinel
  (`[lint:success]` / `[lint:skipped]` / `[lint:error]` / `[lint:aborted]`) が会話 context に emit 済みとなる
- 本コマンドは Step 5 で sentinel を**読み取るだけ**で `rite:lint` を再 invoke しない
  (Step 4 が autonomous lint を内包しているため)

| Sentinel (Step 4 内部の autonomous lint 結果) | 次のアクション |
|---|---|
| sentinel 不在 (implement abort 等) | AskUserQuestion で「再試行 / 再開 / 中止」を提示 |

`[implement:*]` 系の終了通知 sentinel が unset で `rite:lint` 経路にも進めない場合は AskUserQuestion fallback で処理。

---

## ステップ 5: 品質チェック (Step 4 の autonomous lint 結果検証)

Step 4 で `/rite:issue:implement` が autonomous に invoke した `rite:lint` の sentinel を会話 context から検証する。
本ステップは sentinel を読むだけで、自前で `rite:lint` を再 invoke しない (二重実行防止)。

| Sentinel | 次のアクション |
|---------|--------------|
| `[lint:success]` | ステップ 6 へ進む |
| `[lint:skipped]` | ステップ 6 へ進む (lint 未設定) |
| `[lint:error]` | AskUserQuestion で「修正再実行 / 強制続行 / 中止」を提示 |
| `[lint:aborted]` | エラー終了。ユーザーに復旧手順を案内 |
| sentinel 不在 | Step 4 で `/rite:issue:implement` が autonomous lint まで到達できなかった可能性。AskUserQuestion で「手動で `/rite:lint` 実行 / 中止」を提示 |

`phase=lint` は Step 4 の `/rite:issue:implement` が既に flow-state に書き込んでいるため、本コマンドからの上書きは不要 (二重 write を避ける契約)。

---

## ステップ 6: PR 作成

### 6.1 push

```bash
git push -u origin {branch_name}
```

### 6.2 PR 作成

```text
skill: rite:pr:create
```

`[pr:created:N]` sentinel から PR 番号を抽出して `{pr_number}` として retain。`[pr:create-failed]` の場合は AskUserQuestion で「再試行 / 中止」を提示。

### 6.3 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase pr --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "レビュー/修正ループへ進む (/rite:pr:iterate {pr_number})"
```

---

## 完了通知

draft PR の作成が完了したら、ユーザーに以下を案内する:

```
## /rite:pr:open 完了

- Issue: #{issue_number} - {issue_title}
- ブランチ: {branch_name}
- Draft PR: #{pr_number} - {pr_url}

次のステップ:
- レビュー/修正ループ: /rite:pr:iterate {pr_number}
- Ready 化: /rite:pr:ready {pr_number}
- マージ: /rite:pr:merge {pr_number}
- クリーンアップ (merge 後): /rite:pr:cleanup {pr_number}

途中で止まったら /rite:resume で復帰します。
```

---

## エラー時の方針

- どこで止まっても flow-state.json に phase が記録されている
- `/rite:resume` 経由で本コマンドの該当ステップから再開する
- sub-skill (`rite:issue:implement` / `rite:lint` / `rite:pr:create`) の sentinel drop に備え、各 invoke 後に sentinel 検出を確認、不在なら AskUserQuestion で「再試行 / 中止」
