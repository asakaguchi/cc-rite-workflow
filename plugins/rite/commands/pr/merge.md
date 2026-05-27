---
description: PR を squash merge する（cleanup は別コマンド /rite:pr:cleanup）
---

# /rite:pr:merge

## Contract

**Input**: PR number (required)
**Output**: `[merge:returned-to-caller]` / `[merge:not-ready]` / `[merge:error]`

`gh pr merge --squash` を叩いて PR をマージするだけ。**cleanup は走らせない**。マージ後の cleanup (ブランチ削除 / Projects 更新 / Wiki ingest 等) は `/rite:pr:cleanup` を別途実行する。

## Arguments

| Argument | Description |
|----------|-------------|
| `<pr_number>` | マージ対象の PR 番号 (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{pr_number}` | 引数 |
| `{branch_name}` | Step 1 で `flow-state.sh get --field branch` から取得、`[CONTEXT] MERGE_STATE_BRANCH=` で emit |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 1: flow-state 前提条件確認

Bash tool 呼び出し境界では shell 変数が消失するため、判定値を `[CONTEXT]` marker で emit して後段の LLM が読み取れる形にする。

```bash
# pr/open.md Step 0 の方針 (stderr は WARNING channel として残し、2>/dev/null で握りつぶさない) と
# 整合させる。flow-state.sh の `--default ""` は session 解決失敗 / file 不在 / jq parse 失敗を
# すべて吸収するため、外側 `|| var=""` は helper validation 失敗経路のみを catch する defensive
# fallback。stderr は redirect せず WARNING を context に残す。
phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || phase=""
state_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0") || state_pr="0"
state_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "") || state_branch=""

echo "[CONTEXT] MERGE_STATE_PHASE=$phase; MERGE_STATE_PR=$state_pr; MERGE_STATE_BRANCH=$state_branch"
```

**LLM 判定** (会話 context の `[CONTEXT] MERGE_STATE_*` marker を grep して評価):

`MERGE_STATE_PHASE != "ready"` または `MERGE_STATE_PR != "{pr_number}"` の場合は AskUserQuestion で「Ready 化されていない可能性があります。それでも merge しますか？」を提示 (yes / abort)。

`MERGE_STATE_BRANCH` の値は Step 4 完了通知の `{branch_name}` 展開に使用する。

## ステップ 2: mergeable 判定

```bash
gh pr view {pr_number} --json mergeable,mergeStateStatus,isDraft
```

| 状態 | アクション |
|------|-----------|
| `isDraft == true` | `[merge:not-ready]` emit + 「先に `/rite:pr:ready {pr_number}` を実行してください」案内 + 終了 |
| `mergeable != "MERGEABLE"` | `[merge:not-ready]` emit + 原因 (`mergeStateStatus`) 表示 + AskUserQuestion で「再判定 (`mergeStateStatus` を再取得して Step 2 をもう一度実行、1 回のみ) / 中止」を提示 |
| `mergeable == "MERGEABLE"` | ステップ 3 へ |

> **「再判定」option の挙動**: 再判定は **1 回のみ**。再判定後も `MERGEABLE` でなければ `[merge:not-ready]` で確定終了する (ping-pong 防止)。`gh pr view` の mergeable 計算は数秒〜数十秒遅延するため、再判定前に短時間待機 (sleep / 手動 wait) するかはユーザー判断に委ねる。自動 sleep は提供しない (cycle counter なし原則と整合)。

## ステップ 3: マージ実行

```bash
# canonical signal-specific trap pattern (references/bash-trap-patterns.md 参照、fix.md ステップ 2.4 と対称)
gh_err=""
_rite_merge_cleanup() {
  rm -f "${gh_err:-}"
}
trap 'rc=$?; _rite_merge_cleanup; exit $rc' EXIT
trap '_rite_merge_cleanup; exit 130' INT
trap '_rite_merge_cleanup; exit 143' TERM
trap '_rite_merge_cleanup; exit 129' HUP

if gh_err=$(mktemp /tmp/rite-merge-gh-err-XXXXXX 2>/dev/null); then
  :
else
  mktemp_gh_err_rc=$?
  echo "WARNING: gh stderr 退避用 tempfile の mktemp に失敗しました (rc=$mktemp_gh_err_rc)。gh pr merge の stderr 詳細は失われます" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] MERGE_MKTEMP_DEGRADED=1; reason=mktemp_failure_gh_err; rc=$mktemp_gh_err_rc" >&2
  gh_err=""
fi

if gh pr merge {pr_number} --squash --delete-branch=false 2>"${gh_err:-/dev/null}"; then
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "[merge:returned-to-caller]"
  # 成功時のみ stderr の warning (deprecation / rate-limit) を surface する。
  # 失敗時に同 stderr を head -5 で再表示すると、下の else block の head -10 と二重出力に
  # なるため、warning surface は then-branch 内に閉じ込める。
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  WARNING (gh stderr):" >&2
    head -5 "$gh_err" | sed 's/^/    /' >&2
  fi
  # 完了通知は Step 4 で表示
else
  merge_rc=$?
  echo "[merge:error]"
  echo "ERROR: gh pr merge failed (rc=$merge_rc)" >&2
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  詳細 (stderr):" >&2
    head -10 "$gh_err" | sed 's/^/    /' >&2
  fi
  # AskUserQuestion を LLM 側で起動: 「再試行 / 中止」
fi
```

| 終了 status | アクション |
|------------|-----------|
| `[merge:returned-to-caller]` emit | ステップ 4 完了通知へ |
| `[merge:error]` emit | bash block が stderr に gh error 詳細を出力済み。LLM は AskUserQuestion で「再試行 / 中止」を提示 |

## ステップ 4: 完了通知

`MERGE_STATE_BRANCH` を `{branch_name}` placeholder に展開して以下を表示:

```
## /rite:pr:merge 完了

- PR: #{pr_number}
- マージ方式: squash
- ブランチ: {branch_name} (まだ削除されていません)

次のステップ:
- クリーンアップ: /rite:pr:cleanup {pr_number}
  (ブランチ削除 / Projects Status → Done / Issue close / Wiki ingest 等)

<!-- skill return signal: caller must continue next step -->
[merge:returned-to-caller]
```

---

## 設計判断

- **責務は merge のみ**: `gh pr merge` を叩く 1 アクションに専念。cleanup を呼び出さない (`pr.auto_cleanup_after_merge` 等の設定キーも追加しない)
- **`--delete-branch=false` 明示**: ブランチ削除は `/rite:pr:cleanup` の責務であり、`gh` の default 挙動に依存しないことを保証する
- **flow-state は触らない**: マージ完了時点では `phase=ready` のまま。`completed` への遷移は `/rite:pr:cleanup` 末尾で行う (既存仕様維持)
- **マージ戦略は squash ハードコード**: 設定キー (`pr.merge_strategy` 等) を追加すると将来対応スキャフォルディングになる。`merge` / `rebase` に変えたい場合は本ファイルを直接編集する
- **stderr 分離**: `gh pr merge` の stderr は `gh_err` tmpfile に退避し、成功時は warning (deprecation / rate-limit) のみ surface、失敗時は詳細を表示する。`2>&1` で stdout merge すると warning が混在し原因診断が困難になるため避ける
