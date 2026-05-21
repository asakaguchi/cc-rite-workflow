---
description: |
  Issue 作成 / new issue / 起票 / Issue 化 — 新規 Issue を作成し、GitHub Projects に登録する。
  重複検出・親 Issue 候補検出・XL 自動分解（Sub-Issue 作成 + 設計仕様書生成）を含む。
  Use when 「Issue 作って」「タスクを起票」「create issue」「新規 Issue」など。
---

# /rite:issue:create

新規 Issue を作成し、GitHub Projects に登録する。重複検出・親 Issue 候補検出・XL 自動分解を含む。

**途中で止まったらユーザーは `/rite:resume` で再開する**。

## Arguments

| Argument | Description |
|----------|-------------|
| `<title or description>` | Issue title or description (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{owner}`, `{repo}` | `gh repo view --json owner,name` |
| `{project_number}` | `rite-config.yml` の `github.projects.project_number` |
| `{language}` | `rite-config.yml` の `language`（`ja` / `en` / `auto`、未設定 `auto`） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 1: 入力解析と前提取得

### 1.1 リポジトリと Project 設定取得

```bash
gh repo view --json owner,name
```

Project 番号は `rite-config.yml` の `github.projects.project_number` を最優先。未設定なら `gh api graphql` でリポジトリの `projectsV2(first:10)` を取得して最も関連するものを選択。Project が見つからない場合は warning + Projects 追加を skip。

### 1.2 言語設定

`rite-config.yml` の `language`（`ja` / `en` / `auto`、未設定 `auto`） に従い AskUserQuestion を表示する。`auto` は CJK 文字を検出して Japanese を選択（default Japanese）。

### 1.3 入力から What / Why / Where 抽出

ユーザー入力から:

- **What**: 何をするか
- **Why**: なぜ必要か
- **Where**: 変更対象（ファイル / モジュール / 機能領域）
- **Scope**: 影響範囲
- **Constraints**: 制約・前提

を抽出する。Short input（10 文字未満）の場合は AskUserQuestion で詳細を要求する。

### 1.4 slug 生成

title を lowercase、空白を `-` に置換、30 字以内で slug を生成。日本語タイトルは関連英単語に翻訳して slug 化。

---

## ステップ 2: 重複検出

### 2.1 類似 Issue 検索

```bash
result=$(gh issue list --search "is:open <keywords>" --limit 10 --json number,title,labels)
[ "$(echo "$result" | jq 'length')" -eq 0 ] && \
  result=$(gh issue list --state all --limit 10 --json number,title,labels)
```

keywords は What から 2-3 語抽出（stop word 除去、日本語は as-is）。

### 2.2 候補の評価

title 類似度 / label 一致 / 更新日時 / state（OPEN > CLOSED）で top 5 を選定。

### 2.3 分岐

| 候補数 | Options（AskUserQuestion） |
|--------|---------------------------|
| 0 件 | 次ステップへ |
| 1 件 | (a) #{number} の拡張 → body に `Extends: #{number}` 追記 / (b) 既存 Issue を使用 → 終了 + `/rite:issue:start {number}` 提案 / (c) 関連なし |
| 2+ 件 | (a) #{番号} の拡張 / (b) 別 Issue 番号入力 / (c) 関連なし |

---

## ステップ 3: 規模判定と親 Issue 候補検出

### 3.1 規模ヒューリスティック

以下のいずれかに該当すれば **大型タスク候補**（分解推奨）:

1. 複数の distinct change を含む（"Add auth, logging, and caching" 等）
2. Scope keywords を含む（"全体的に" / "across all" / "multiple files" / "一括" 等）
3. Complexity ≥ L（推定）
4. Umbrella/epic 表現を含む（"プロジェクト" / "epic" / "umbrella" / "phase"）

該当しない場合は **単一 Issue**として扱い、ステップ 4 へ。

### 3.2 分解確認

該当時は AskUserQuestion で「Sub-Issue に分解する（推奨） / 単一 Issue として作成 / 中止」を選択。

- **分解**: ステップ 5 へ（Sub-Issue 分解パス）
- **単一**: ステップ 4 へ（単一 Issue パス）
- **中止**: workflow 終了

---

## ステップ 4: 単一 Issue 作成（Single Issue Path）

### 4.1 Issue 情報の最終確認

AskUserQuestion で Issue の以下を確認/補完する:

- title（slug ベース）
- type（feat / fix / docs / refactor / chore）
- priority（High / Medium / Low）
- complexity（XS / S / M / L / XL）
- labels（推測されたもの + 追加）

### 4.2 Issue Body 生成

`templates/issue/default.md` のテンプレートに沿って body を生成する:

```markdown
## What
{what}

## Why
{why}

## Where
{where}

## Acceptance Criteria
- [ ] AC-1: {ac1}
- [ ] AC-2: {ac2}

## Implementation Notes
{notes_if_any}

## Out of Scope
- {out_of_scope_if_any}
```

### 4.3 Issue 作成 + Projects 登録

`create-issue-with-projects.sh` に委譲（Issue 作成 + Projects へ追加 + status / priority / complexity フィールド設定を 1 ステップで実行）:

```bash
bash {plugin_root}/scripts/create-issue-with-projects.sh \
  --title "{title}" \
  --body "{body}" \
  --labels "{labels_csv}" \
  --priority "{priority}" \
  --complexity "{complexity}" \
  --status "Todo" \
  --project-number {project_number} \
  --owner {owner}
```

出力から `{issue_number}` を抽出。

### 4.4 完了レポート

```markdown
✅ Issue #{issue_number} を作成しました

| 項目 | 内容 |
|------|------|
| Title | {title} |
| Type | {type} |
| Priority | {priority} |
| Complexity | {complexity} |
| URL | {issue_url} |

### 次のアクション
- `/rite:issue:start {issue_number}` で作業を開始
- または `/rite:pr:create` で Issue なしで PR を作成
```

ステップ 6（共通完結処理）へ。

---

## ステップ 5: Sub-Issue 分解（Decompose Path）

### 5.1 仕様書生成

大型 Issue から「設計仕様書」を生成する。以下のセクションを含む:

```markdown
## 1. 目的（Goal）
{why}

## 2. スコープ
- In scope: {in_scope}
- Out of scope: {out_of_scope}

## 3. 受入基準
- AC-1: {ac1}
- AC-2: {ac2}

## 4. 設計方針
{design_approach}

## 5. Sub-Issue 構成
1. Sub-1: {sub_1_title}（complexity: {sub_1_complexity}）
2. Sub-2: {sub_2_title}（complexity: {sub_2_complexity}）
...

## 6. 依存関係
- Sub-2 は Sub-1 完了後
- Sub-3 は独立

## 7. リスク・考慮事項
{risks}
```

### 5.2 ユーザー確認

AskUserQuestion で「この分解で進める / 分解を修正 / 中止」を選択。修正の場合は仕様書を再提示。

### 5.3 親 Issue 作成

仕様書を body として親 Issue を作成（complexity = XL を設定）。

```bash
bash {plugin_root}/scripts/create-issue-with-projects.sh \
  --title "{parent_title}" \
  --body "{spec_document}" \
  --labels "epic,{labels_csv}" \
  --priority "{priority}" \
  --complexity "XL" \
  --status "Todo" \
  --project-number {project_number} \
  --owner {owner}
```

出力から `{parent_issue_number}` を抽出。

### 5.4 Sub-Issue 一括作成

各 Sub-Issue を順次作成し、親 Issue にリンクする:

```bash
for sub in $sub_issues; do
  sub_number=$(bash {plugin_root}/scripts/create-issue-with-projects.sh \
    --title "{sub_title}" \
    --body "{sub_body}" \
    --labels "{labels_csv}" \
    --priority "{priority}" \
    --complexity "{sub_complexity}" \
    --status "Todo" \
    --project-number {project_number} \
    --owner {owner} \
    --parent-issue {parent_issue_number} \
    | jq -r .issue_number)

  bash {plugin_root}/scripts/link-sub-issue.sh \
    --parent {parent_issue_number} --child $sub_number
done
```

### 5.5 親 Issue body 更新

Sub-Issue 一覧を親 Issue body に追記:

```bash
gh issue edit {parent_issue_number} --body "$(gh issue view {parent_issue_number} --json body --jq .body)

## Sub-Issues
- [ ] #{sub_1_number} {sub_1_title}
- [ ] #{sub_2_number} {sub_2_title}
- [ ] #{sub_3_number} {sub_3_title}"
```

### 5.6 完了レポート

```markdown
✅ Issue #{parent_issue_number} を分解して {sub_count} 件の Sub-Issue を作成しました

### 親 Issue
- #{parent_issue_number} {parent_title}

### Sub-Issues
- #{sub_1_number} {sub_1_title}（complexity: {sub_1_complexity}）
- #{sub_2_number} {sub_2_title}（complexity: {sub_2_complexity}）
- ...

### 次のアクション
- `/rite:issue:start {first_sub_issue}` で最初の Sub-Issue から作業を開始
- `/rite:issue:list` で全 Sub-Issue 一覧を確認
```

ステップ 6 へ。

---

## ステップ 6: 共通完結処理

### 6.1 flow-state 完結

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase completed --active false --next "none" \
  --if-exists --preserve-error-count 2>/dev/null || true
```

create.md は作業 phase ではなく Issue 作成のみなので、flow-state は必ずしも必要ない（`patch --if-exists` で file 不在時は no-op）。

---

## エラー時の方針

- 各ステップで止まっても Issue が作成されていなければ、ユーザーは同じ入力で `/rite:issue:create` を再実行できる
- Issue 作成後（`{issue_number}` 確定後）はその Issue を起点に作業を進められる（重複作成を避けるためステップ 2 の重複検出が活きる）
- AskUserQuestion で「中止」が選ばれた場合のみ workflow 終了
- sentinel emit / sub-skill return protocol / Mandatory After scaffolding は廃止

---

## E2E Output Minimization

ステップ間の出力は最小限に。各ステップは:

- 開始時に 1 行 status（「ステップ N: 〜」）
- bash / AskUserQuestion の結果
- 完了時の最終レポート（ステップ 4.4 / 5.6）

中間説明・サマリ・guidance text は省略する。

## Standalone Usage

`/rite:issue:create` 単独で動作する。Issue 作成後に作業を開始するには `/rite:issue:start {issue_number}` を実行する。

## Error Handling

- `gh repo view` 失敗 → エラー、認証確認を案内
- Projects 未設定 → warning、Projects 追加を skip
- Issue 作成失敗 → AskUserQuestion で「再試行 / 手動作成 / 中止」
- 親-子リンク失敗 → warning、後で手動リンクを案内
