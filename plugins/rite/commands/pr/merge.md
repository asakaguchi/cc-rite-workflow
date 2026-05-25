---
description: PR を squash merge する（cleanup は別コマンド /rite:pr:cleanup）
---

# /rite:pr:merge

## Contract

**Input**: PR number (required)
**Output**: `[merge:completed]` / `[merge:not-ready]` / `[merge:error]`

`gh pr merge --squash` を叩いて PR をマージするだけ。**cleanup は走らせない**。マージ後の cleanup (ブランチ削除 / Projects 更新 / Wiki ingest 等) は `/rite:pr:cleanup` を別途実行する。

## Arguments

| Argument | Description |
|----------|-------------|
| `<pr_number>` | マージ対象の PR 番号 (required) |

---

## ステップ 1: flow-state 前提条件確認

```bash
phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "" 2>/dev/null || echo "")
state_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0" 2>/dev/null || echo "0")
```

`phase != "ready"` または `state_pr != "{pr_number}"` の場合は AskUserQuestion で「Ready 化されていない可能性があります。それでも merge しますか？」を提示 (yes / abort)。

## ステップ 2: mergeable 判定

```bash
gh pr view {pr_number} --json mergeable,mergeStateStatus,isDraft
```

| 状態 | アクション |
|------|-----------|
| `isDraft == true` | `[merge:not-ready]` emit + 「先に /rite:pr:ready {pr_number} を実行してください」案内 |
| `mergeable != "MERGEABLE"` | `[merge:not-ready]` emit + 原因 (`mergeStateStatus`) 表示 + AskUserQuestion で「待つ / 中止」 |
| `mergeable == "MERGEABLE"` | ステップ 3 へ |

## ステップ 3: マージ実行

```bash
gh pr merge {pr_number} --squash --delete-branch=false 2>&1
```

`--delete-branch=false` を明示する: ブランチ削除は `/rite:pr:cleanup` の責務であり、本コマンドからは触らない (責務分離)。

| 終了 status | アクション |
|------------|-----------|
| 成功 (exit 0) | `[merge:completed]` emit + 完了通知 (ステップ 4) |
| 失敗 (branch protection / required checks 等) | `[merge:error]` emit + stderr 表示 + AskUserQuestion で「再試行 / 中止」 |

## ステップ 4: 完了通知

```
## /rite:pr:merge 完了

- PR: #{pr_number}
- マージ方式: squash
- ブランチ: {branch_name} (まだ削除されていません)

次のステップ:
- クリーンアップ: /rite:pr:cleanup {pr_number}
  (ブランチ削除 / Projects Status → Done / Issue close / Wiki ingest 等)

[merge:completed]
```

---

## 設計判断 (Issue #1136)

- **責務は merge のみ**: `gh pr merge --squash` を叩く 1 アクションに専念。cleanup を呼び出さない (`pr.auto_cleanup_after_merge` 等の設定キーも追加しない、squash ハードコード)
- **`--delete-branch=false` 明示**: gh CLI の default 挙動に依存せず、明示的にブランチを残す (cleanup での削除責務を奪わない)
- **flow-state は触らない**: マージ完了時点では `phase=ready` のまま。`completed` への遷移は `/rite:pr:cleanup` 末尾で行う (既存仕様維持)
- **マージ戦略は squash ハードコード**: `rite-config.yml` への `pr.merge_strategy` 等の設定キー追加は将来対応スキャフォルディングなので採用しない。坂口さん運用が `merge` / `rebase` に変わった場合は本ファイルを直接書き換える
