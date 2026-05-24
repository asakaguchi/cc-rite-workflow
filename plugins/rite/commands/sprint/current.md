---
description: 現在のスプリント詳細を表示
context: fork
---

# /rite:sprint:current

Display detailed information about the current sprint (Iteration)

---

When this command is executed, run the following phases in order.

## Prerequisites

- `rite-config.yml` must have `iteration.enabled` set to `true`
- An Iteration field must exist in GitHub Projects

**If Iteration is disabled**: Display the same message as `/rite:sprint:list` and exit

---

## Phase 1: Identify the Current Iteration

### 1.1 Retrieve the Iteration Field and All Iterations

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2IterationField {
            id
            name
            configuration {
              iterations {
                id
                title
                startDate
                duration
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}"
```

### 1.2 Determine the Current Iteration

```
アルゴリズム:
1. 今日の日付を取得
2. 各イテレーションについて:
   - endDate = startDate + duration (days)
   - startDate <= 今日 < endDate → これが「現在」
3. 該当なし → 「現在アクティブなスプリントがありません」
```

---

## Phase 2: Retrieve Issues for the Current Sprint

### 2.1 Retrieve Issue List

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
              state
              assignees(first: 3) { nodes { login } }
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
}' -f projectId="{project_id}" -f iterationId="{current_iteration_id}" -f fieldId="{iteration_field_id}"
```

### 2.2 Group by Status

```
Status でグループ化:
- Todo: まだ着手していない
- In Progress: 作業中
- In Review: レビュー待ち
- Done: 完了
```

---

## Phase 3: Display Details

### 3.1 Sprint Information

```
現在のスプリント: Sprint 3

期間: 2025-01-06 - 2025-01-19 (14日間)
残り: 8日間

進捗: ████████░░░░░░░░ 50% (4/8 完了)
```

### 3.2 Issue List (by Status)

```
## In Progress (2件)

  #42  ログイン機能を追加
       担当: @user1  ラベル: enhancement

  #45  API エンドポイント実装
       担当: @user2  ラベル: enhancement

## Todo (2件)

  #48  テスト追加
       担当: 未割当  ラベル: testing

  #49  ドキュメント更新
       担当: @user1  ラベル: documentation

## Done (4件)

  #40  初期設定  ✓
  #41  DB スキーマ  ✓
  #43  認証基盤  ✓
  #44  エラーハンドリング  ✓
```

### 3.3 Summary

```
サマリー:
- 完了: 4件
- 進行中: 2件
- 未着手: 2件
- 合計: 8件
```

---

## Phase 4: Suggest Next Actions

```
次のアクション:
- `/rite:issue:start <番号>` で Issue の作業を開始
- `/rite:sprint:plan` で次スプリントの計画
- `/rite:issue:list --sprint current` で詳細一覧
```

---

## When No Current Iteration Exists

```
現在アクティブなスプリントがありません

次のスプリント: {sprint_name}: Sprint 4
開始日: 2025-01-20

ヒント:
- GitHub Projects でイテレーションの期間を調整してください
- または /rite:sprint:plan で次スプリントの計画を開始
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When There Are No Issues | See error output for details |
| On API Error | See error output for details |
