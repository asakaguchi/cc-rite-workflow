---
description: 中断した作業を再開
---

# /rite:resume

中断した rite ワークフローを再開する。flow-state (phase enum v3 SoT) と commit 数 / PR 状態 / work memory を cross-check して、最適な再開点を決定する。

**Use cases:**
- Claude Code クラッシュ後の再開
- セッション切断後の再開
- 手動中断後の再開
- **Context 枯渇時の継続**: セッションの context が逼迫した場合は `/clear` で会話履歴をリセットしてから `/rite:resume` を実行する。これが rite workflow における context 枯渇時の **唯一の正規経路** (詳細: [workflow-identity.md](../skills/rite-workflow/references/workflow-identity.md))。

---

## Arguments

| Argument | Description |
|----------|-------------|
| `[issue_number]` | Issue 番号 (省略時はブランチ名から自動抽出) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | 引数 or ブランチ名抽出 |
| `{branch}` | `git branch --show-current` |
| `{plugin_root}` | [Plugin Path Resolution](../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## Phase 1: Issue 番号確定

### 1.1 引数優先

引数があればそれを使う。なければブランチ名 `{type}/issue-{number}-{slug}` から抽出。

```bash
# Auto-detect from branch name when argument is missing
branch=$(git branch --show-current 2>/dev/null || echo "")
issue_arg="${1:-}"
if [ -z "$issue_arg" ]; then
  issue_arg=$(echo "$branch" | sed -nE 's|^[a-z]+/issue-([0-9]+)-.*$|\1|p')
fi
if [ -z "$issue_arg" ]; then
  echo "ERROR: Issue 番号が判定できません (引数も branch 名からの抽出も失敗)" >&2
  echo "  current branch: $branch" >&2
  echo "  /rite:resume <number> で明示指定するか、Issue ブランチに切り替えてください" >&2
  exit 1
fi
echo "[CONTEXT] RESUME_ISSUE=$issue_arg"
```

### 1.2 Issue 存在確認

```bash
if ! gh issue view "$issue_arg" --json number,title,state >/dev/null 2>&1; then
  echo "ERROR: Issue #$issue_arg が見つかりません" >&2
  exit 1
fi
```

---

## Phase 2: 自動 migration (v1/v2 → v3)

旧 schema の flow-state ファイルを v3 schema (新 phase enum 13 個) に自動移行する。失敗してもベストエフォートで続行 (cross-check で実態を再推定する)。

```bash
bash {plugin_root}/hooks/flow-state.sh migrate --verbose 2>&1 || \
  echo "WARNING: migrate に失敗しました — cross-check で実態を推定します" >&2
```

---

## Phase 3: 状態の cross-check (4 指標から実態 phase を推定)

### 3.1 flow-state から状態取得

```bash
state_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "")
state_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "")
state_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "true")
state_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "0")
state_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0")
state_next=$(bash {plugin_root}/hooks/flow-state.sh get --field next_action --default "")
state_parent=$(bash {plugin_root}/hooks/flow-state.sh get --field parent_issue_number --default "0")

# Emit [CONTEXT] markers so Phase 5.2 (separate Bash tool invocation) can read these values.
# Claude Code Bash tool 境界でシェル状態は失われるため、Phase 5.2 で `$state_phase` を直接参照しても
# 常に空文字となり active=true 復元経路が dead になる (PR #1089 review C2)。後続ステップは本 [CONTEXT]
# marker を読み、{resolved_phase} / {state_next} placeholder を実値に置換して bash block を出力する。
echo "[CONTEXT] STATE_PHASE=$state_phase"
echo "[CONTEXT] STATE_BRANCH=$state_branch"
echo "[CONTEXT] STATE_ACTIVE=$state_active"
echo "[CONTEXT] STATE_ISSUE=$state_issue"
echo "[CONTEXT] STATE_PR=$state_pr"
echo "[CONTEXT] STATE_NEXT=$state_next"
echo "[CONTEXT] STATE_PARENT=$state_parent"
```

### 3.2 git 状態取得

```bash
git_branch=$(git branch --show-current 2>/dev/null || echo "")
# develop に到達できない場合は origin/develop or main を base に
base_branch="develop"
git fetch origin "$base_branch" >/dev/null 2>&1 || true
git_commit_count=$(git rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null || echo "0")
git_has_uncommitted=$(git status --porcelain 2>/dev/null | head -1)
```

### 3.3 PR 状態取得

```bash
pr_info=$(gh pr view --json state,number,isDraft 2>/dev/null || echo '{"state":"NONE","number":0,"isDraft":false}')
pr_state=$(echo "$pr_info" | jq -r '.state // "NONE"')
pr_number_gh=$(echo "$pr_info" | jq -r '.number // 0')
pr_is_draft=$(echo "$pr_info" | jq -r '.isDraft // false')
```

### 3.4 Work Memory 状態取得

```bash
LOCAL_WM=".rite-work-memory/issue-${issue_arg}.md"
wm_phase=""
wm_next=""
if [ -f "$LOCAL_WM" ]; then
  wm_phase=$(grep "^phase:" "$LOCAL_WM" 2>/dev/null | head -1 | sed 's/phase: *//' | tr -d '"')
  wm_next=$(grep "^next_action:" "$LOCAL_WM" 2>/dev/null | head -1 | sed 's/next_action: *//' | tr -d '"')
fi
```

### 3.5 整合性判定 (cross-check)

以下の優先順で実態 phase を確定:

1. **state_phase が v3 enum (13 個) の有効値** → state_phase を採用
2. **state_phase が空 + wm_phase が有効値** → wm_phase を採用 (work memory fallback)
3. **state_phase が空 + wm_phase も空 + pr_state=OPEN** → `review` (PR がある → レビュー段階)
4. **state_phase が空 + wm_phase も空 + git_commit_count>0** → `implement` (コミットあり → 実装段階)
5. **state_phase が空 + wm_phase も空 + git_branch が refactor/feat/fix/chore/issue ブランチ** → `branch` (ブランチのみある状態)
6. **どれも該当しない** → `init` (新規スタート相当)

矛盾検出時 (例: state_phase=plan だが git_commit_count>5):

```
⚠️ flow-state と実態の不整合を検出しました:
  - flow-state phase: $state_phase
  - 実態 commit 数: $git_commit_count
  - 推定 phase: <推定値>
```

AskUserQuestion で「推定 phase で再開 / 別 phase を選ぶ / 中止」を提示。

---

## Phase 4: Resume 確認

### 4.1 状態サマリ表示

```
=== 中断状態 ===
Issue: #{issue_arg} ({title})
Branch: {git_branch}
Phase: {resolved_phase} ({cross-check 結果})
Parent Issue: #{state_parent} (あれば)
PR: #{pr_number} ({pr_state}, draft={pr_is_draft})
Commits ahead of {base_branch}: {git_commit_count}
Uncommitted changes: {git_has_uncommitted: "あり" or "なし"}
Next action (state): {state_next}
Next action (WM):    {wm_next}
```

### 4.2 ユーザー確認

AskUserQuestion で:
- **続行 (推定 phase で再開)** — 推定された phase に対応する Step / Skill を実行
- **別 phase を選ぶ** — phase 一覧から手動選択
- **新規セッション扱い** — flow-state をクリアして `/rite:issue:start {issue_arg}` を最初から実行
- **中止** — 何もせず終了

---

## Phase 5: 再開実行

### 5.1 ブランチ切り替え

ブランチが state_branch と一致しない場合のみ切り替え:

```bash
if [ -n "$state_branch" ] && [ "$git_branch" != "$state_branch" ]; then
  git switch "$state_branch" || {
    echo "ERROR: ブランチ切り替え失敗: $state_branch" >&2
    exit 1
  }
fi
```

### 5.2 flow-state の active=true 復元

中断時 (例: クラッシュ / context 枯渇) で active=false になっている可能性があるため、resume では active=true に復元。merge semantics により他のフィールドは保持される。

> **重要 — Bash tool 境界での変数消失** (PR #1089 review C2): 本 step は Phase 3.1 とは別の Bash tool 呼び出しとなるため、`$state_phase` / `$resolved_phase` / `$state_next` 等のシェル変数を直接参照できない (Claude Code の Bash tool 境界でシェル状態は失われる)。LLM は Phase 3.1 末尾で stdout に emit された `[CONTEXT] STATE_PHASE=...` / `[CONTEXT] STATE_NEXT=...` marker と Phase 3.5 の cross-check 結果 `{resolved_phase}` を読み、下記 bash block 内の placeholder を実値に置換してから実行すること。`--if-exists` フラグにより flow state file 不在時は no-op (idempotent)、merge semantics により未指定フィールドは既存値を保持する:

```bash
# Placeholder substitution rule:
#   {resolved_phase} → Phase 3.5 cross-check の確定 phase (v3 enum 13 値のいずれか)
#   {state_next}     → Phase 3.1 [CONTEXT] STATE_NEXT marker の値 (空なら "resume from {resolved_phase}" を代入)
# {resolved_phase} が空の場合 (flow-state 不在 + WM 不在 + git/PR 推定も不可能 → Phase 3.5 で `init` 採用)
# でも `--if-exists` により file 不在なら no-op となるため、unconditional 呼び出しで安全。
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "{resolved_phase}" \
  --next "{state_next}" \
  --active true --if-exists
```

### 5.3 Phase enum → Step mapping (SoT)

| phase | 再開アクション |
|-------|---------------|
| `init` | `/rite:issue:start {issue_arg}` をステップ 1 (Issue 取得) から再実行 (idempotent) |
| `branch` | `/rite:issue:start {issue_arg}` をステップ 2 (ブランチ作成) から再開 (既存ブランチがあれば `git switch` で復帰) |
| `plan` | `/rite:issue:start {issue_arg}` をステップ 3 (実装計画) から再開 |
| `implement` | `/rite:issue:start {issue_arg}` をステップ 4 (実装) を継続 (Issue body の checklist 未完項目から) |
| `lint` | `/rite:issue:start {issue_arg}` をステップ 5 (lint 再実行) から再開 |
| `pr` | `/rite:issue:start {issue_arg}` をステップ 6 (PR 作成) から再開 (既に PR 番号が state にあればステップ 7 へジャンプ) |
| `review` | `/rite:pr:review {pr_number}` を再実行 |
| `fix` | `/rite:pr:fix {pr_number}` を再実行 |
| `ready` | `/rite:issue:start {issue_arg}` をステップ 8.3 から再開 (Ready は完了済 — Projects Status In Review → 親判定 → 完了レポート) |
| `ready_error` | `/rite:issue:start {issue_arg}` をステップ 8 (Ready & 完結) から再開 |
| `cleanup` | `/rite:pr:cleanup {pr_number}` を再実行 |
| `ingest` | `/rite:wiki:ingest` を再呼び出し |
| `completed` | Issue は完結済。AskUserQuestion で「新規作業として再開 / 終了」 |

### 5.4 invoke

確定した phase に応じて Skill ツール経由で対応コマンドを呼ぶ。引数として `{issue_arg}` (issue 系) または `{pr_number}` (pr 系) を渡す。

`/rite:issue:start` 系は内部の Resume Dispatch (ステップ 0) で `[CONTEXT] RESUME_DISPATCH=1; phase=$resolved_phase; issue=$issue_arg` を観測し、適切な step にジャンプする。

---

## Phase 6: 完了

再開後の最初のサイクルが完了するまで、再開した skill に制御を委譲する。再開先の skill は flow-state を順次更新し、最終的に `completed` または `cleanup` 状態に到達する。

---

## エラー処理

| 状況 | 対応 |
|------|------|
| Issue not found | エラー終了、`gh issue list` で確認するよう案内 |
| Branch 不在 | `gh issue develop` で再生成するよう案内 |
| flow-state 不在 + WM 不在 | 「新規セッション」として `/rite:issue:start {issue_arg}` を提案 |
| 矛盾検出 (phase vs commit/PR) | AskUserQuestion で「推定 phase で再開 / 別 phase を選ぶ / 中止」 |
| migrate 失敗 | WARNING 表示後、cross-check で実態推定して続行 |

---

## Phase enum 13 個 (SoT)

新 v3 schema の phase enum (`flow-state.sh` 内 `PHASE_ENUM_V3` と同期):

```
init / branch / plan / implement / lint / pr / review / fix / ready /
ready_error / cleanup / ingest / completed
```

旧 v1/v2 schema の phase 値 (`cleanup_pre_ingest`, `ingest_pre_lint`, `create_*`, `phase5_*` 等) は Phase 2 の自動 migration で v3 に変換される。Migration の reduction matrix は `plugins/rite/hooks/flow-state.sh` の `_phase_migrate` 関数を参照。
