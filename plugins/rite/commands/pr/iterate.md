---
description: PR のレビュー/修正サイクルを mergeable まで無限ループ
---

# /rite:pr:iterate

`/rite:pr:review` ↔ `/rite:pr:fix` を **指摘ゼロになるまで無限ループ** する。やることは以下のシーケンシャルなタスク列:

0. flow-state から issue_number / branch_name を復元
1. `/rite:pr:review` を invoke
2. review sentinel を判定（`[review:mergeable]` → 終了 / `[review:fix-needed:N]` → ステップ 3 / その他 → AskUserQuestion）
3. `/rite:pr:fix` を invoke
4. fix sentinel を判定（`[fix:pushed]` → ステップ 1 に戻る / `[fix:replied-only]` `[fix:cancelled-by-user]` → 終了 / `[fix:error]` → AskUserQuestion）
5. 完了通知を出す

cycle counter / N 回上限 / quality-signal escalation / ping-pong サーキットブレーカーは **一切ない** (Issue #1136 設計確定)。中断経路は 2 種類: (a) ユーザーが fix.md 内 AskUserQuestion で「中止」を選択 → `[fix:cancelled-by-user]` emit + ループ終了、(b) ユーザーが Ctrl+C で中断 → flow-state phase 残存。どちらも `/rite:resume` で再開可。

途中で止まったら flow-state に現 phase (review or fix) が残るので `/rite:resume` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (required)
**Output**: 完了通知（`[review:mergeable]` 到達 or `[fix:replied-only]` 終了 or `[fix:cancelled-by-user]` 中断 or Ctrl+C 中断）

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

## ステップ 0: flow-state から issue_number / branch_name を復元

`{issue_number}` / `{branch_name}` は standalone 起動でも flow-state set 呼び出しで必須のため、本コマンド冒頭で flow-state から復元する。pr/open.md Step 0 の canonical pattern (一行 + `|| var=""` fallback) と対称化する。

```bash
iterate_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || iterate_issue=""
iterate_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "") || iterate_branch=""
echo "[CONTEXT] ITERATE_ISSUE=$iterate_issue; ITERATE_BRANCH=$iterate_branch"
```

LLM は `[CONTEXT] ITERATE_ISSUE` / `ITERATE_BRANCH` から値を読み、後続の flow-state.sh set 呼び出しで `--issue` / `--branch` に literal substitute する。値が空の場合は AskUserQuestion で「Issue 番号 / ブランチ名を入力 / 中止」を提示。

---

## ステップ 1: /rite:pr:review を invoke

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

---

## ステップ 2: review sentinel を判定

| Sentinel | アクション |
|---------|-----------|
| `[review:mergeable]` | **ループ終了**（完了通知へ） |
| `[review:fix-needed:N]` | ステップ 3 (fix invoke) へ |
| `[review:error]` | AskUserQuestion で「再試行 / 中止」を提示 (sentinel 不在とは別経路で reviewer 側エラーを明示) |
| sentinel 不在 | AskUserQuestion で「再試行 / 中止」を提示 |

---

## ステップ 3: /rite:pr:fix を invoke

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

---

## ステップ 4: fix sentinel を判定

| Sentinel | アクション |
|---------|-----------|
| `[fix:pushed]` | ステップ 1 (review 再実行) に戻る — **ループ継続** |
| `[fix:pushed-wm-stale]` | ステップ 1 に戻る (WM stale 警告は表示するが loop は継続) |
| `[fix:replied-only]` | **ループ終了**（reply のみで完結） |
| `[fix:cancelled-by-user]` | **ループ終了**（ユーザーが fix.md 内 cancel 経路 — ステップ 1.4 Cancel option / Fast Path Cancel handoff 等 — で中止選択。`/rite:resume` で再開可） |
| `[fix:error]` | AskUserQuestion で「再試行 / 中止」を提示 |
| sentinel 不在 | AskUserQuestion で「再試行 / 中止」を提示 (どの sentinel が期待されていたか、直近の fix 出力 100 行、flow-state phase を表示) |

---

## ステップ 5: 完了通知

### 正常終了 (`[review:mergeable]` or `[fix:replied-only]`)

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

### ユーザー中断 (`[fix:cancelled-by-user]`)

```
## /rite:pr:iterate 中断

- PR: #{pr_number}
- 終了理由: fix:cancelled-by-user (fix.md 内 AskUserQuestion で中止選択)
- ブランチ: {branch_name}

再開方法:
- /rite:resume で本コマンドが再起動 (flow-state phase=fix のため fix invoke から再開)
- 手動で /rite:pr:iterate {pr_number} を再実行することも可
```

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:resume` で本コマンドが再起動する (詳細な phase → command routing は [commands/resume.md](../resume.md) Phase 5.3 を参照)
- `[fix:error]` 時: 自動継続せず必ず AskUserQuestion で確認 (silent regression 防止)
- reviewer が non-deterministic に振動 (毎 cycle で別の指摘) する場合: ループは継続する。ユーザーは観察して Ctrl+C で中断する判断が可能 (cycle counter での自動停止は提供しない)

---

## ループ継続の構造的保証 (Issue #1168)

ステップ 2 / ステップ 4 の「次のコマンドへ進む」遷移は本来 LLM が prose 指示 ("Do NOT stop") に従って自走するが、LLM が継続 sentinel を出した直後に要約を表示して turn を終了する中断が観測された (PR #1167)。これを防ぐため、prose に依存しない **構造的な継続層** を `Stop` hook で実装している:

- **handoff マーカー (one-shot)**: 継続 sentinel を出す sub-skill が flow-state に handoff をセットする。
  - `[review:fix-needed:N]` → review.md Step 8.0 が `--handoff "/rite:pr:fix {pr}"`
  - `[fix:pushed]` / `[fix:pushed-wm-stale]` → fix.md Step 5.1 が `--handoff "/rite:pr:review {pr}"`
  これらは sub-skill 内の defense-in-depth set で行われるため、**LLM が turn を終える前に確実に実行される**。
- **Stop hook が consume + 再注入**: `stop-loop-continuation.sh` が turn 終了時に `flow-state.sh consume-handoff` で handoff を読み取り + 削除し、非空なら `decision:block` で停止を差し戻して次コマンド (`/rite:pr:fix` / `/rite:pr:review`) を再注入する。
- **終了 sentinel は handoff を持たない**: `[review:mergeable]` / `[fix:replied-only]` / `[fix:cancelled-by-user]` は `--handoff` を付けないため (`flow-state.sh set` がデフォルトクリア)、Stop hook は停止を許可する → ループは正しく終了する。
- **無限 block ループ防止**: handoff は consume で one-shot 消費される。進捗なく再度停止すれば handoff は空 → block しない。cycle counter は持たない (#1136 と整合 — 安全網は終了 sentinel + Ctrl+C に委ねる)。
- **resume との二層構造**: flow-state の `next_action` は Ctrl+C 中断後の `/rite:resume` 用の secondary な網。Stop hook は自動継続の primary 層。

## 設計判断 (Issue #1136)

- **指摘ゼロになるまでループ** がユーザー要件 — 安全網 (N 回上限 / 同一 fingerprint 検出 / quality signal escalation) は意図的に削除
- **手動 abort のみ**: 自動停止すると「無限ループ」要件と矛盾する
- **cycle counter なし**: state file (`.rite/state/fix-fallback-retry-{pr}.count` 等) も持たない、retain しない (Stop hook の handoff も counter ではなく one-shot consume される継続マーカーのため #1136 と整合)
- 別 Issue 化経路は廃止済み (commit 1a で fix.md Phase 4.3 削除) — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている
