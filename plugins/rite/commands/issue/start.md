---
description: Issue の作業を開始（ブランチ作成 → 実装 → PR → レビュー → 完結）
---

# /rite:issue:start

## Contract

**Input**: Issue number (required)
**Output**: `## 完了報告`（Issue/PR の詳細と進捗テーブル）

Issue を起点に「準備 → ブランチ → 計画 → 実装 → lint → PR → レビュー/修正 → Ready & 完結」を一気通貫で実行する。

**途中で止まったらユーザーは `/rite:resume` で flow-state.json に記録された phase から再開する**。

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
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

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

```bash
gh api graphql -f query='
  query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner:$owner, name:$repo) {
      issue(number:$number) {
        trackedIssues(first:50) { nodes { number title state } }
      }
    }
  }' -f owner={owner} -f repo={repo} -F number={issue_number}
```

親 Issue の場合は AskUserQuestion で「子 Issue を選んで作業 / この親 Issue 自体に対して作業 / 中止」を提示し、選択により分岐:

- **子 Issue 選択**: trackedIssues から open かつ未着手のものを優先順位順（priority: High > Medium > Low、complexity: XS > S > M > L > XL）に並べ、AskUserQuestion で 1 件選択。選択後は `{issue_number}` を子の番号に置換してステップ 1.1 から再実行。
- **親 Issue 自体**: そのまま続行（実装が親 Issue body で完結する場合）。
- **中止**: workflow 終了。

### 1.3 Issue 品質評価

| Score | 条件 |
|-------|------|
| A | What / Why / Where / Scope すべて記載 |
| B | What / Why 明確、Where/Scope 推測可能 |
| C | What のみ明確、詳細不足 |
| D | Body 20 単語未満、または What/Why/Where すべて不明 |

C/D の場合は AskUserQuestion で「既存情報で開始 / Issue を編集してから再実行 / 中止」を選択。

### 1.4 flow-state 初期化

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase init --issue {issue_number} --branch "" --pr 0 \
  --next "ブランチ作成へ進む"
```

---

## ステップ 2: ブランチと Projects

### 2.1 ブランチ名生成

`rite-config.yml` の `branch.pattern`（default: `{type}/issue-{number}-{slug}`）に従う。

- **type**: labels / title から推定（`bug`/`bugfix` → `fix`、`docs` → `docs`、`refactor` → `refactor`、`chore`/`maintenance` → `chore`、それ以外 → `feat`）
- **slug**: title を lowercase、空白を `-` に置換、30 字以内

### 2.2 既存ブランチチェック

```bash
local_match=$(git branch --list "{branch_name}")
remote_match=$(git branch -r --list "origin/{branch_name}")
if [ -n "$local_match" ] || [ -n "$remote_match" ]; then
  echo "BRANCH_EXISTS"
fi
```

> **注意**: `git branch --list` は常に exit 0 を返すので、出力文字列の空チェックで判定する。

存在する場合は AskUserQuestion で「既存ブランチに切り替え / 別名で作成（サフィックス追加） / 中止」を選択。

### 2.3 ブランチ作成

`{base_branch}` から派生して作成。`{base_branch}` がリモートにのみ存在する場合は `origin/{base_branch}` から派生。

```bash
git fetch origin {base_branch} 2>/dev/null
if git rev-parse --verify "{base_branch}" >/dev/null 2>&1; then
  git switch -c "{branch_name}" "{base_branch}"
elif git rev-parse --verify "origin/{base_branch}" >/dev/null 2>&1; then
  git switch -c "{branch_name}" "origin/{base_branch}"
else
  default_branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
  git switch -c "{branch_name}" "origin/${default_branch}"
fi
```

Issue にブランチを関連付け:

```bash
gh issue develop {issue_number} --branch "{branch_name}" 2>/dev/null || true
```

### 2.4 GitHub Projects Status 更新

`rite-config.yml` の `github.projects.enabled: true` の場合のみ実行。`projects-status-update.sh` に委譲:

```bash
bash {plugin_root}/scripts/projects-status-update.sh \
  --issue {issue_number} --status "In Progress" --owner {owner} --project {project_number}
```

親 Issue が存在する場合は親も同様に `In Progress` に更新。失敗時は warning を出して continue（non-blocking）。

### 2.5 Iteration 割り当て（任意）

`rite-config.yml` の `iteration.enabled: true` かつ `iteration.auto_assign: true` の場合のみ実行。現在の iteration を取得して assign。失敗時は warning + continue。

### 2.6 Work Memory 初期化

```bash
WM_SOURCE="init" WM_PHASE="branch" WM_PHASE_DETAIL="ブランチ作成・準備" \
  WM_NEXT_ACTION="実装計画を生成" \
  WM_BODY_TEXT="Issue #{issue_number} の作業を開始しました。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh
```

Issue コメントへの同期は post-tool-wm-sync hook が自動で行う。

### 2.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase branch --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "実装計画を生成"
```

---

## ステップ 3: 実装計画

### 3.1 Issue 内容分析

ステップ 1.1 で取得した body / labels / title から:

- 達成すべき outcome（What）
- 制約・前提（Where）
- 受入基準（Acceptance Criteria）

を抽出する。

### 3.2 変更対象ファイルの特定

Issue body や関連リンクから推測される変更対象ファイル候補を grep / Glob で探索:

```bash
grep -rln "<keyword from issue>" --include="*.{ext}" .
```

### 3.3 実装計画生成

以下の構造で計画を生成する:

```markdown
## 実装計画

### 変更対象ファイル
- `path/to/file1.ext` — 変更理由
- `path/to/file2.ext` — 変更理由

### 実装ステップ
1. ステップ 1: 〜
2. ステップ 2: 〜
3. ステップ 3: 〜

### 受入基準マッピング
- AC-1 → ステップ 1, 2
- AC-2 → ステップ 3

### 注意点
- 〜
```

### 3.4 ユーザー確認

AskUserQuestion で「この計画で進める / 計画を修正 / 中止」を選択。

「修正」の場合は計画を AskUserQuestion で再提示して合意を取る。

### 3.5 Issue Body Checklist 更新

Issue body に実装ステップを `- [ ]` 形式で追記/更新する:

```bash
gh issue edit {issue_number} --body "$(gh issue view {issue_number} --json body --jq .body)

## 実装ステップ
- [ ] ステップ 1: 〜
- [ ] ステップ 2: 〜
- [ ] ステップ 3: 〜"
```

### 3.6 Work Memory 更新

work memory に計画を保存:

```bash
WM_SOURCE="plan" WM_PHASE="plan" WM_PHASE_DETAIL="実装計画作成完了" \
  WM_NEXT_ACTION="実装を開始" \
  WM_BODY_TEXT="実装計画を生成しました。{steps_count} ステップで進めます。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh
```

### 3.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase plan --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "実装に着手"
```

---

## ステップ 4: 実装

### 4.1 実装作業

計画のステップに沿ってコード変更を実施する。各ステップ完了ごとに:

1. 変更内容を確認（`git diff`）
2. conventional commits 規約でコミット:
   - `feat:` 新機能
   - `fix:` バグ修正
   - `docs:` ドキュメント
   - `refactor:` リファクタ
   - `chore:` 雑務
3. work memory のチェックリストを更新

### 4.2 コミット例

```bash
git add <changed-files>
git commit -m "$(cat <<'EOF'
feat(scope): ステップ 1 の outcome 一文

詳細な変更内容と why を 1-2 文で。

Refs: #{issue_number}

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### 4.3 Work Memory 更新

各コミット後に進捗を work memory に反映:

```bash
WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="ステップ {N} 完了" \
  WM_NEXT_ACTION="次ステップ or 品質チェック" \
  WM_BODY_TEXT="ステップ {N}: {what} を実装しました。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh
```

### 4.4 すべてのステップ完了確認

すべてのステップを完了したら、変更ファイル一覧と Issue body のチェックリスト更新を確認:

```bash
gh issue view {issue_number} --json body --jq .body | grep "^- \[ \]"
```

未完了項目がある場合は AskUserQuestion で「実装を続ける / 残項目を別 Issue に分離して PR へ / 中止」を選択。

### 4.5 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase implement --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "品質チェック (rite:lint)"
```

---

## ステップ 5: 品質チェック

### 5.1 lint 実行

`skill: "rite:lint"` を invoke する。

戻り値パターン:

- `[lint:success]` → ステップ 6 へ
- `[lint:error]` → AskUserQuestion で「修正して再実行 / 強制続行 / 中止」を選択

「修正して再実行」の場合は LLM が修正を実装してコミット → 再度 `skill: "rite:lint"`。

### 5.2 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase lint --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "PR 作成"
```

---

## ステップ 6: PR 作成

### 6.1 push

```bash
git push -u origin "{branch_name}"
```

### 6.2 PR 作成

`skill: "rite:pr:create"` を invoke。

戻り値パターン:

- `[pr:created:N]` → `{pr_number}` を抽出してステップ 7 へ
- `[pr:create-failed]` → AskUserQuestion で「手動作成して PR 番号を入力 / 再試行 / 中止」

### 6.3 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase pr --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
  --next "レビュー/修正ループ"
```

---

## ステップ 7: レビュー/修正ループ

### 7.1 review

`skill: "rite:pr:review", args: "{pr_number}"` を invoke。

戻り値パターン:

- `[review:mergeable]` → ステップ 8 へ
- `[review:fix-needed:N]` → ステップ 7.2 へ

### 7.2 fix

`skill: "rite:pr:fix", args: "{pr_number}"` を invoke。

戻り値パターン:

- `[fix:pushed]` → ステップ 7.1 へ戻る（再レビュー）
- `[fix:replied-only]` → ステップ 8 へ（return-only: review は finding を維持するが merge OK と判断）
- `[fix:error]` → AskUserQuestion で「手動修正してから再レビュー / 中止」

### 7.3 ループ上限

7.1 ↔ 7.2 のループが 5 回に達したら AskUserQuestion で「続行 / 中止」を選択。

### 7.4 flow-state 更新

review / fix の各 invoke 前に:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase review --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
  --next "fix or ready 判定"
```

または `--phase fix`。

---

## ステップ 8: Ready & 完結

### 8.1 Ready 化確認

AskUserQuestion で「PR を Ready for review に変更する / Draft のまま / 中止」を選択。

### 8.2 Ready 化

`skill: "rite:pr:ready", args: "{pr_number}"` を invoke。

戻り値パターン:

- `[ready:completed]` → ステップ 8.3 へ
- `[ready:error]` → AskUserQuestion で「手動 Ready 化 / 中止」

### 8.3 Projects Status In Review

`rite-config.yml.github.projects.enabled: true` の場合:

```bash
bash {plugin_root}/scripts/projects-status-update.sh \
  --issue {issue_number} --status "In Review" --owner {owner} --project {project_number}
```

### 8.4 親 Issue の完結判定

ステップ 1.2 で親 Issue を検出していた場合、親の trackedIssues 状態を再確認:

```bash
gh api graphql -f query='...' -F number={parent_issue_number}
```

すべての子 Issue が closed なら AskUserQuestion で「親 Issue を完了とする / そのまま」を選択。完了選択時:

```bash
gh issue close {parent_issue_number} --comment "すべての子 Issue が完了したため、親 Issue を完了します。"
bash {plugin_root}/scripts/projects-status-update.sh \
  --issue {parent_issue_number} --status "Done" --owner {owner} --project {project_number}
```

### 8.5 完了レポート出力

```markdown
## 完了報告

| 項目 | 内容 |
|------|------|
| Issue | #{issue_number} {title} |
| ブランチ | `{branch_name}` |
| PR | #{pr_number} {pr_url} |
| 状態 | Ready for review |

### 実装ステップ
- [x] ステップ 1: 〜
- [x] ステップ 2: 〜
- [x] ステップ 3: 〜

### 次のアクション
- レビュー後、`/rite:pr:fix {pr_number}` で再対応 or merge 後 `/rite:pr:cleanup` でクリーンアップ
```

### 8.6 flow-state 完結

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase completed --active false --next "none" \
  --if-exists --preserve-error-count
```

---

## エラー時の方針

- どのステップで止まっても `flow-state.json` に `phase` が記録されているので、ユーザーは `/rite:resume` で次のステップから再開できる
- sentinel emit / sub-skill return protocol / Mandatory After scaffolding は廃止
- 各ステップは「Bash 実行 → 結果確認 → 次へ」のフラットな逐次フロー
- AskUserQuestion で明示的に「中止」が選ばれた場合のみ workflow 終了

## E2E Output Minimization

ステップ間の出力は最小限に。各ステップは:

- 開始時に 1 行 status（「ステップ N: 〜」）
- bash / skill invoke の結果
- 完了時に sentinel pattern（外部 API 的に有用なもののみ: `[lint:*]`, `[pr:created:N]`, `[review:*]`, `[fix:*]`, `[ready:completed]`）

中間説明・サマリ・guidance text は省略する。

## Interruption / Resumption

- ブランチ・work memory・Projects Status・実装計画は途中状態でも保持される
- 中断時は `/rite:resume {issue_number}` で復帰
- 中断状態の `phase` に応じてステップを再開（例: `phase=plan` で中断 → ステップ 4 から再開）

## Standalone Usage

各 skill は単独でも呼び出せる:

- `/rite:lint` — 品質チェック
- `/rite:pr:create` — Issue なしで PR 作成
- `/rite:pr:review {pr_number}` — 既存 PR のレビュー
- `/rite:pr:fix {pr_number}` — レビューフィードバックへの対応
- `/rite:pr:ready {pr_number}` — Draft → Ready 化

## Error Handling

- Issue not found → エラー表示、`gh issue list` を提案
- Closed Issue → AskUserQuestion で reopen / cancel
- ブランチ作成失敗 → `git status` で状態確認
- Projects 未設定 → warning 表示、skip
- API エラー → 3 回まで指数バックオフでリトライ、それでも失敗なら skip

詳細は [GraphQL Helpers](../../references/graphql-helpers.md#error-handling) を参照。
