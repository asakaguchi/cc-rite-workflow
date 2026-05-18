# 完了報告フォーマット定義

このファイルは `/rite:issue:start` の完了報告フォーマットを一元管理する。
Phase 4.1（作業開始）と Phase 5.6（一気通貫フロー完了）の両方で、このファイルを読み込んでフォーマットを参照する。

---

## フォーマット使用時の注意（必読）

> **絶対厳守**: 以下のテンプレートを**そのまま使用**すること
>
> - 独自のフォーマットや創作は**禁止**
> - テーブル構造と見出しを正確に再現すること
> - プレースホルダ `{...}` の部分のみを実際の値で置換すること
>
> **⚠️ aggregate label 禁止 (Issue #1042)**: 完了報告で **件数のみの aggregate label** で推奨事項を済ませることは禁止。canonical 禁止 phrase list は [`commands/issue/start-finalize.md` Phase 5.6.3 Step 3](../commands/issue/start-finalize.md) を **唯一の真実の源 (SoT)** として参照すること。reviewer が出した推奨事項は必ず disposition breakdown (actionable → Issue 番号一覧 / boundary → 件数 / design_confirmation → 件数) として明示する。aggregate label による責任曖昧化は `aggregate-recommendation-label-evasion` anti-pattern であり、過去 PR #1039 で事後 Issue 化漏れ (#1040 / #1041) を引き起こした失敗事例の根本原因。

---

## 作業開始時のフォーマット（Phase 4.1 用）

Phase 2 のブランチ作成・準備が完了した後に使用する。

```markdown
## 作業開始

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| ブランチ | {branch_name} |
| Status | In Progress |
| Iteration | {iteration_title} |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ⏳ | - |
| 品質チェック | ⏳ | - |
| PR 作成 | ⏳ | - |
| セルフレビュー | ⏳ | - |

作業メモリを初期化しました。
```

**注意:**
- Iteration 行は `iteration.enabled: true` の場合のみ表示（無効時は行ごと省略）

---

## 一気通貫フロー完了時のフォーマット（Phase 5.6 用）

Phase 5 の実装 → lint → PR 作成 → レビューが完了した後に使用する。

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | #{pr_number} |
| PR URL | https://github.com/{owner}/{repo}/pull/{pr_number} |
| PR 状態 | {pr_state} |
| 関連 Issue | #{number} |
| Status | {status} |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ✅ | lint 通過 |
| PR 作成 | ✅ | #{pr_number} |
| セルフレビュー | ✅ | {review_result} |

### 推奨事項 disposition (Issue #1042)

<!-- ⚠️ MANDATORY: 推奨事項が 0 件の場合のみ「推奨事項なし」と記載。1 件以上ある場合は本テーブルを必ず出力すること。
     「推奨 N 件 (全て scope 外)」のような aggregate label は禁止 — disposition breakdown で各 item の処理結果を明示する。 -->

| 分類 | 件数 | 詳細 |
|------|------|------|
| actionable (Issue 化済) | {actionable_count} | {actionable_issues} |
| boundary (user 判断) | {boundary_count} | {boundary_details} |
| design_confirmation (観察のみ) | {design_confirmation_count} | {design_confirmation_details} |

### 次のステップ

1. レビュアーに PR レビューを依頼
2. レビューコメントに対応
3. PR マージ後、Issue は自動クローズ
```

---

## PR 未作成時のフォーマット（エッジケース）

Phase 5 が途中で中断された場合など、PR が作成されていない状態で完了報告を行う場合。

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | 未作成 |
| ブランチ | {branch_name} |
| Status | In Progress |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ⏳ | 未実施 |
| PR 作成 | ⏳ | - |
| セルフレビュー | ⏳ | - |

### 推奨事項 disposition

_推奨事項なし_

<!-- Case B (PR 未作成時) は review が実行されていないため `_推奨事項なし_` 固定。
     ただし self-verification checklist 整合性のため heading + 内容を必ず出力する。aggregate label は禁止。 -->

### 次のステップ

1. `/rite:pr:create` で PR を作成
2. `/rite:pr:review` でセルフレビュー
3. レビュアーに PR レビューを依頼
```

---

## プレースホルダ一覧

| プレースホルダ | 説明 | 取得方法 |
|---------------|------|----------|
| `{number}` | Issue 番号 | コマンド引数から取得 |
| `{title}` | Issue タイトル | `gh issue view --json title` |
| `{owner}` | リポジトリオーナー | `gh repo view --json owner` |
| `{repo}` | リポジトリ名 | `gh repo view --json name` |
| `{branch_name}` | 作成したブランチ名 | Phase 2.3 で作成 |
| `{iteration_title}` | Iteration 名 | Phase 2.5 で取得 |
| `{score}` | 品質スコア（A/B/C/D） | Phase 1.1 で判定 |
| `{pr_number}` | PR 番号 | Phase 5.3 で作成 |
| `{pr_state}` | PR 状態（Draft / Ready for Review / Merged） | `gh pr view --json isDraft,state` |
| `{status}` | Projects Status（In Progress / In Review / Done） | Projects API |
| `{changed_files_count}` | 変更ファイル数 | `git diff --stat` |
| `{review_result}` | レビュー結果（マージ可 / 要修正） | Phase 5.4 の結果 |
| `{actionable_count}` | actionable 分類の推奨事項件数 | Phase 5.1 `recommendation_items` から filter (`classification == "actionable"`) |
| `{actionable_issues}` | actionable 分類で Issue 化された Issue 番号一覧 (例: `#1040, #1041`) | Phase 7.4 で起票された `new_issue_number` を集約。0 件の場合は `—` |
| `{boundary_count}` | boundary 分類の推奨事項件数 | Phase 5.1 `recommendation_items` から filter (`classification == "boundary"`) |
| `{boundary_details}` | boundary 分類の各 item の user 判断結果 (例: `2 件: 1 件 Issue 化済 #N, 1 件無視`) | Phase 7.2 `AskUserQuestion` 応答から集約。0 件の場合は `—` |
| `{design_confirmation_count}` | design_confirmation 分類の推奨事項件数 | Phase 5.1 `recommendation_items` から filter (`classification == "design_confirmation"`) |
| `{design_confirmation_details}` | design_confirmation 分類のサマリー (例: `3 件: reviewer 自身が対応不要と結論`) | Phase 5.1 collection 結果から集約。0 件の場合は `—` |

---

## エッジケース対応表

| ケース | 対応 |
|--------|------|
| PR 未作成 | 「PR 未作成時のフォーマット」を使用 |
| PR がマージ済み | PR 状態を「Merged」と表示し、次のステップに `/rite:pr:cleanup` を案内 |
| レビュー未実施 | セルフレビュー行の状態を「⏳ 保留」、備考を「未実施」と表示 |
| lint スキップ | 品質チェック行の備考を「lint スキップ」と表示 |
| Iteration 無効 | Iteration 行を省略（行ごと削除） |
