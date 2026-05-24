---
description: Sprint/Iteration 一覧を表示
context: fork
---

# /rite:sprint:list

Display a list of Sprint/Iterations

---

When this command is executed, run the following phases in order.

## Prerequisites

- `rite-config.yml` must have `iteration.enabled` set to `true`
- An Iteration field must exist in GitHub Projects

**If Iteration is disabled**:

```
Iteration 機能は無効化されています

有効にするには:
1. GitHub Projects で Iteration フィールドを作成
2. rite-config.yml の iteration.enabled を true に設定
3. /rite:init を再実行

詳細は /rite:workflow を参照してください。
```

---

## Phase 1: Retrieve Configuration and Field Information

### 1.1 Load rite-config.yml

```bash
# rite-config.yml から iteration 設定を読み込み
# iteration.enabled が false の場合は上記のメッセージを表示して終了
```

### 1.2 Get Project ID

```bash
gh api graphql -f query='
query($owner: String!, $number: Int!) {
  user(login: $owner) {
    projectV2(number: $number) {
      id
    }
  }
}' -f owner="{owner}" -F number={project_number}
```

### 1.3 Retrieve Iteration Field and All Iterations

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

---

## Phase 2: Determine Iteration Status

### 2.1 Compare with Current Date

Determine the status of each iteration:

```
アルゴリズム:
1. 今日の日付を取得
2. 各イテレーションについて:
   - endDate = startDate + duration (days)
   - 今日 < startDate → "future" (予定)
   - startDate <= 今日 < endDate → "current" (現在)
   - endDate <= 今日 → "past" (過去)
```

### 2.2 Get Issue Count for Each Iteration

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
}' -f projectId="{project_id}" -f iterationId="{iteration_id}" -f fieldId="{iteration_field_id}"
```

---

## Phase 3: Display List

### 3.1 Default Display (Current + Next + Most Recent Past)

```
Sprint 一覧

  [現在] Sprint 3 (2025-01-06 - 2025-01-19)
         Issue: 5件 (完了: 2, 進行中: 2, 未着手: 1)

  [次回] Sprint 4 (2025-01-20 - 2025-02-02)
         Issue: 3件 (すべて未着手)

  [過去] Sprint 2 (2024-12-23 - 2025-01-05)
         Issue: 8件 (すべて完了)

合計: 3 スプリント表示 (全 5 スプリント表示)
```

### 3.2 Filter Options

| Option | Description |
|-----------|------|
| `--all` | Display all iterations |
| `--current` | Current iteration only |
| `--past` | Past iterations only |
| `--upcoming` | Upcoming iterations only |

### 3.3 When No Current Iteration Exists

```
Sprint 一覧

現在アクティブなスプリントがありません

  [次回] Sprint 4 (2025-01-20 - 2025-02-02)
         Issue: 3件 (すべて未着手)

  [過去] Sprint 3 (2025-01-06 - 2025-01-19)
         Issue: 5件 (すべて完了)

ヒント: GitHub Projects でイテレーションの期間を確認してください。
```

---

## Phase 4: Present Next Actions

```
次のアクション:
- `/rite:sprint:current` で現在のスプリント詳細を表示
- `/rite:sprint:plan` でスプリント計画を実行
- `/rite:issue:list --sprint current` で現在スプリントの Issue 一覧
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Iteration Field Is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When No Iterations Are Configured | See error output for details |
| On API Errors | See error output for details |
