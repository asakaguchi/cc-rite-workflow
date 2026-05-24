---
description: スプリント計画を実行
---

# /rite:sprint:plan

Execute sprint planning (select Issues from the backlog and assign them to a sprint)

---

When this command is executed, run the following phases in order.

## Prerequisites

- `rite-config.yml` `iteration.enabled` must be `true`
- An Iteration field must exist in GitHub Projects

**If Iteration is disabled**: Display the same message as `/rite:sprint:list` and exit

---

## Phase 1: Determine Target Sprint

### 1.1 Check Arguments

| Argument | Description |
|------|------|
| None | Target the current or next sprint |
| `current` | Target the current sprint |
| `next` | Target the next sprint |
| `"Sprint 4"` | Target the specified sprint |

### 1.2 Select Target Sprint

If no argument is provided, confirm with `AskUserQuestion`:

```
どのスプリントを計画しますか？

オプション:
- 現在のスプリント: Sprint 3 (2025-01-06 - 2025-01-19)
- 次のスプリント: Sprint 4 (2025-01-20 - 2025-02-02)
- 別のスプリントを指定
```

---

## Phase 2: Check Current Sprint Status

### 2.1 Retrieve Existing Issues for Target Sprint

```bash
gh api graphql -f query='
query($projectId: ID!, $iterationId: String!, $fieldId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, filter: {
        field: { fieldId: $fieldId, iterationId: $iterationId }
      }) {
        totalCount
        nodes {
          content {
            ... on Issue {
              number
              title
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}" -f iterationId="{target_iteration_id}" -f fieldId="{iteration_field_id}"
```

### 2.2 Display Current Capacity

```
{name} の計画

現在の状態:
- 割り当て済み Issue: 3件
- 見積もりポイント: 8 / 20

残りキャパシティ: 12ポイント
```

---

## Phase 3: Display Backlog

### 3.1 Retrieve Backlog Issues

Retrieve Issues that have no Iteration assigned:

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100) {
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              state
              labels(first: 5) { nodes { name } }
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldIterationValue {
                iterationId
              }
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}"
```

### 3.2 Display Backlog List

Sort by Priority and Complexity and display:

```
バックログ（{count}件）

  # | Priority | Complexity | Title
----|----------|------------|-------------------------------
 50 | High     | M (3pt)    | ユーザー認証機能の追加
 51 | High     | S (2pt)    | ログ出力の改善
 52 | Medium   | L (5pt)    | ダッシュボード画面の実装
 53 | Medium   | M (3pt)    | API レスポンスのキャッシュ
 54 | Low      | XS (1pt)   | README の更新
 ...

合計: 10件（推定 25ポイント）
```

---

## Phase 4: Select and Assign Issues

### 4.1 Confirm Selection Method

Confirm the selection method with `AskUserQuestion`:

```
Issue の選択方法を選んでください:

オプション:
- 個別に選択: Issue を1件ずつ選択
- Priority で一括選択: High Priority のものをすべて選択
- キャパシティ内で自動選択: Priority 順に自動で選択（推奨）
```

### 4.2 Individual Selection

```
バックログから追加する Issue を選択:

[ ] #50 ユーザー認証機能の追加 (High, M: 3pt)
[ ] #51 ログ出力の改善 (High, S: 2pt)
[ ] #52 ダッシュボード画面の実装 (Medium, L: 5pt)
[ ] #53 API レスポンスのキャッシュ (Medium, M: 3pt)
...

選択した Issue: (なし)
現在の合計: 8pt / 20pt
```

### 4.3 Automatic Selection

```
キャパシティ内で自動選択しました:

選択した Issue:
- #50 ユーザー認証機能の追加 (High, M: 3pt)
- #51 ログ出力の改善 (High, S: 2pt)
- #53 API レスポンスのキャッシュ (Medium, M: 3pt)

合計: 8pt（残りキャパシティ 12pt に収まります）

この選択で進めますか？
- はい、割り当てる
- 選択を変更する
- キャンセル
```

### 4.4 Execute Assignment

Set the Iteration for each selected Issue:

```bash
gh api graphql -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { iterationId: $iterationId }
    }
  ) {
    projectV2Item { id }
  }
}' -f projectId="{project_id}" -f itemId="{item_id}" -f fieldId="{iteration_field_id}" -f iterationId="{target_iteration_id}"
```

---

## Phase 5: Completion Report

```
スプリント計画完了

Sprint 4 (2025-01-20 - 2025-02-02)

追加した Issue:
- #50 ユーザー認証機能の追加
- #51 ログ出力の改善
- #53 API レスポンスのキャッシュ

スプリントの状態:
- 合計 Issue: 6件
- 合計: 16 / 20
- 残りキャパシティ: 4pt

次のアクション:
- `/rite:sprint:current` でスプリント詳細を確認
- `/rite:issue:start <番号>` で Issue の作業を開始
```

---

## Complexity Point Mapping

Default mapping (customizable in `rite-config.yml`):

| Complexity | Points |
|------------|---------|
| XS | 1 |
| S | 2 |
| M | 3 |
| L | 5 |
| XL | 8 |

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Backlog is Empty | See error output for details |
| When Selection Exceeds Capacity | このまま割り当てる（オーバーコミット） / 選択を変更する |
| On API Error | See error output for details |
