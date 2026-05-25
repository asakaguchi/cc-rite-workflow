---
description: PR のレビュー/修正サイクルを mergeable まで無限ループ
---

# /rite:pr:iterate

## Contract

**Input**: PR number (required)
**Output**: 完了通知（`[review:mergeable]` 到達 or `[fix:replied-only]` 終了 or ユーザー中断）

`/rite:pr:review` ↔ `/rite:pr:fix` を **指摘ゼロになるまで無限ループ**する。cycle counter / N 回上限 / quality-signal escalation / ping-pong サーキットブレーカー は**一切ない** (Issue #1136 設計確定)。中断は **Ctrl+C のみ**、その後 `/rite:resume` で復帰できる。

## Arguments

| Argument | Description |
|----------|-------------|
| `<pr_number>` | レビュー/修正対象の PR 番号 (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{pr_number}` | 引数 |
| `{issue_number}` | flow-state `issue_number` field |
| `{branch_name}` | flow-state `branch` field |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ループ仕様

### 1. review invoke

flow-state を `phase=review` に更新後、`/rite:pr:review` を invoke:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "review 実行中"
```

```text
skill: rite:pr:review
args: "{pr_number}"
```

### 2. review sentinel 判定

| Sentinel | アクション |
|---------|-----------|
| `[review:mergeable]` | **ループ終了**（完了通知へ） |
| `[review:fix-needed:N]` | ステップ 3 (fix invoke) へ |
| sentinel 不在 | AskUserQuestion で「再試行 / 中止」を提示 |

### 3. fix invoke

flow-state を `phase=fix` に更新後、`/rite:pr:fix` を invoke:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase fix --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "fix 実行中"
```

```text
skill: rite:pr:fix
args: "{pr_number}"
```

### 4. fix sentinel 判定

| Sentinel | アクション |
|---------|-----------|
| `[fix:pushed]` | ステップ 1 (review 再実行) に戻る — **ループ継続** |
| `[fix:pushed-wm-stale]` | ステップ 1 に戻る (WM stale 警告は表示するが loop は継続) |
| `[fix:replied-only]` | **ループ終了**（reply のみで完結） |
| `[fix:error]` | AskUserQuestion で「再試行 / 中止」を提示 |
| sentinel 不在 | AskUserQuestion で「再試行 / 中止」を提示 |

---

## 完了通知

`[review:mergeable]` or `[fix:replied-only]` でループ終了したら以下を案内:

```
## /rite:pr:iterate 完了

- PR: #{pr_number}
- 終了理由: {review:mergeable | fix:replied-only}
- ブランチ: {branch_name}

次のステップ:
- Ready 化: /rite:pr:ready {pr_number}
- マージ (Ready 後): /rite:pr:merge {pr_number}

flow-state は phase={review|fix} のままです。`/rite:pr:ready` 実行時に phase=ready に遷移します。
```

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:resume` で本コマンドが再起動する
- `[fix:error]` 時: 自動継続せず必ず AskUserQuestion で確認 (silent regression 防止)
- reviewer が non-deterministic に振動 (毎 cycle で別の指摘) する場合: ループは継続する。ユーザーは観察して Ctrl+C で中断する判断が可能 (cycle counter での自動停止は提供しない)

---

## 設計判断 (Issue #1136)

- **指摘ゼロになるまでループ** がユーザー要件 — 安全網 (N 回上限 / 同一 fingerprint 検出 / quality signal escalation) は意図的に削除
- **手動 abort のみ**: 自動停止すると「無限ループ」要件と矛盾する
- **cycle counter なし**: state file (`.rite/state/fix-fallback-retry-{pr}.count` 等) も持たない、retain しない
- 別 Issue 化経路は廃止済み (commit 1a で fix.md Phase 4.3 削除) — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている
