---
name: resume
description: |
  rite workflow の作業再開スキル: 中断した Issue/PR 作業の状態を検出し適切なステップへ復帰する。
  ユーザーが明示的に /rite:resume で起動する。auto-activate しない。
  起動: /rite:resume
argument-hint: ""
---

# /rite:resume

中断した rite ワークフローを再開する。flow-state (phase enum v3 SoT) と commit 数 / PR 状態 / work memory を cross-check して、最適な再開点を決定する。

**Use cases:**
- Claude Code クラッシュ後の再開
- セッション切断後の再開
- 手動中断後の再開
- **Context 枯渇時の継続**: セッションの context が逼迫した場合は `/clear` で会話履歴をリセットしてから `/rite:resume` を実行する。これが rite workflow における context 枯渇時の **唯一の正規経路** (詳細: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md))。

---

## Arguments

| Argument | Description |
|----------|-------------|
| `[issue_number]` | Issue 番号 (省略時はブランチ名から自動抽出) |

## Placeholder Legend

> 後続 Phase は別々の Bash tool 呼び出しとなりシェル変数を引き継げないため、Phase 3.1 / 3.5 / 4.2 が stdout に emit する `[CONTEXT] STATE_* / RESOLVED_PHASE / FINAL_PHASE` marker を source とし、LLM が会話コンテキストから読んで placeholder を実値置換する (詳細は Phase 5.2 の注記参照)。

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` / `{issue_arg}` / `{number}` | Phase 1.1: 引数 or ブランチ名 `{type}/issue-{number}-{slug}` 抽出 (`[CONTEXT] RESUME_ISSUE` marker) |
| `{title}` | Phase 1.2: `gh issue view` の title |
| `{branch}` / `{git_branch}` | Phase 3.2: `git branch --show-current` |
| `{base_branch}` | Phase 3.2: `rite-config.yml` の `branch.base` (default `develop`) |
| `{git_commit_count}` | Phase 3.2: `git rev-list --count origin/{base_branch}..HEAD` |
| `{git_has_uncommitted}` | Phase 3.2: `git status --porcelain` の非空判定 (サマリでは「あり」/「なし」整形) |
| `{git_conflict_files}` | Phase 3.2: `[CONTEXT] GIT_CONFLICT_FILES` marker (`git status --porcelain` の unmerged マーカー UU/AA/DD 等のファイル一覧、カンマ区切り)。Phase 3.4.5 のコンフリクト優先判定に使用 |
| `{git_in_merge}` | Phase 3.2: `[CONTEXT] GIT_IN_MERGE` marker (`git rev-parse --git-path MERGE_HEAD` の存在判定 = merge 解決待ち) |
| `{git_in_rebase}` | Phase 3.2: `[CONTEXT] GIT_IN_REBASE` marker (`git rev-parse --git-path rebase-merge`/`rebase-apply` の存在判定 = rebase 中断) |
| `{state_next}` | Phase 3.1: `[CONTEXT] STATE_NEXT` marker (flow-state `next_action`) |
| `{state_parent}` | Phase 3.1: `[CONTEXT] STATE_PARENT` marker (flow-state `parent_issue_number`) |
| `{state_parent_display}` | Phase 3.1: `[CONTEXT] STATE_PARENT_DISPLAY` marker (`0`/空 → 「なし」、それ以外 → `#NN` 整形) |
| `{pr_number}` | Phase 3.3: `gh pr view` の `.number` (Phase 3.1 `[CONTEXT] STATE_PR` も参照可) |
| `{pr_state}` | Phase 3.3: `gh pr view` の `.state` (NONE/OPEN/MERGED/CLOSED) |
| `{pr_is_draft}` | Phase 3.3: `gh pr view` の `.isDraft` |
| `{pr_mergeable}` | Phase 3.3: `[CONTEXT] PR_MERGEABLE` marker (`gh pr view` の `.mergeable`: MERGEABLE/CONFLICTING/UNKNOWN)。Phase 3.4.5 で CONFLICTING をコンフリクト状態として扱う |
| `{wm_next}` | Phase 3.4: work memory (`.rite-work-memory/issue-{n}.md`) の `next_action:` |
| `{resolved_phase}` | Phase 3.5: cross-check 確定 phase (`[CONTEXT] RESOLVED_PHASE` marker)。Phase 4.2 で user が phase 変更を選んだ場合は `[CONTEXT] FINAL_PHASE` marker を優先 |
| `{type}` / `{slug}` | ブランチ名 `{type}/issue-{number}-{slug}` の構成要素 |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

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
  # multi_session fallback: クラッシュ後の新セッションは repo root (branch=base) で
  # 開始されるため branch 抽出が失敗する。登録済みセッション worktree から候補を列挙する。
  ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
  ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
  [ -n "$ms_base" ] || ms_base=".rite/worktrees"
  wt_issues=$(git worktree list --porcelain 2>/dev/null | awk '$1=="worktree"{print $2}' \
    | grep -E "/${ms_base}/issue-[0-9]+\$" | sed -nE 's|.*/issue-([0-9]+)$|\1|p' | sort -un)
  cnt=$(printf '%s' "$wt_issues" | grep -c . 2>/dev/null || echo 0)
  echo "[CONTEXT] RESUME_WT_CANDIDATES=$(printf '%s' "$wt_issues" | tr '\n' ',' | sed 's/,$//'); count=$cnt"
fi
if [ -n "$issue_arg" ]; then
  echo "[CONTEXT] RESUME_ISSUE=$issue_arg"
fi
```

`$issue_arg` が確定しなかった場合は `[CONTEXT] RESUME_WT_CANDIDATES=` marker を読んで分岐する:

- `count=0`: 候補なし → 以下を表示して終了:
  ```
  ERROR: Issue 番号が判定できません (引数 / branch 名 / セッション worktree のいずれからも抽出できません)。
    /rite:resume <number> で明示指定するか、Issue ブランチに切り替えてください。
  ```
- `count=1`: その issue 番号を `$issue_arg` として採用し、ユーザーに「#{N} を再開しますか？」を提案してから続行する。
- `count>1`: **AskUserQuestion** で候補の issue 番号を提示し 1 件選択させる。

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

# parent_issue_number=0 は「親 Issue なし」を意味するため、サマリ表示で "#0" を見せないよう "なし" に整形する
# (Phase 4.1 サマリの `Parent Issue: #{state_parent}` 行が `#0` 誤表示するのを防ぐ)。
case "$state_parent" in
  ""|"0"|"null") parent_issue_display="なし" ;;
  *)             parent_issue_display="#$state_parent" ;;
esac

# Emit [CONTEXT] markers so Phase 5.2 (separate Bash tool invocation) can read these values.
# Claude Code Bash tool 境界でシェル状態は失われるため、Phase 5.2 で `$state_phase` を直接参照しても
# 常に空文字となり active=true 復元経路が dead になる。後続ステップは本 [CONTEXT]
# marker を読み、{resolved_phase} / {state_next} placeholder を実値に置換して bash block を出力する。
echo "[CONTEXT] STATE_PHASE=$state_phase"
echo "[CONTEXT] STATE_BRANCH=$state_branch"
echo "[CONTEXT] STATE_ACTIVE=$state_active"
echo "[CONTEXT] STATE_ISSUE=$state_issue"
echo "[CONTEXT] STATE_PR=$state_pr"
echo "[CONTEXT] STATE_NEXT=$state_next"
echo "[CONTEXT] STATE_PARENT=$state_parent"
echo "[CONTEXT] STATE_PARENT_DISPLAY=$parent_issue_display"
```

### 3.1.5 セッション worktree への再入場（multi_session 有効時、cross-check より前）

git/PR 状態クロスチェック（Phase 3.2 / 3.3 の `git rev-list origin/{base}..HEAD` / `gh pr view`）は**カレントブランチ依存**のため、worktree への再入場は**その前に**行う必要がある（順序が本質）。session ⇄ worktree は 1:1 でない（クラッシュで session_id が変わる）ため、**issue 番号 → worktree パス導出（discovery fallback）が正規の対応関係**であり、flow-state `worktree` field は同一セッション内のヒントに留まる:

検出・再構築は共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)、#1676 で #1368 のロジックを SoT 化）に委譲する。ヘルパーは `multi_session` の読取・worktree パス導出（`--git-common-dir` から main checkout root を求める）・branch 解決（issue-N の local/remote ref から自動）・**再構築（`git worktree add`）まで bash 側で完結**し、唯一の `[CONTEXT] WT_ENSURE=` marker を emit する。session ⇄ worktree は 1:1 でない（クラッシュで session_id が変わる）ため、helper は issue 番号 → worktree パス導出を正規の対応とし、flow-state `worktree` field には依存しない:

```bash
bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_arg"
```

> **本ブロックは WT_ENSURE 分岐表の SoT**（review / iterate / fix の入場ゲートが参照する。#1676）。EnterWorktree は LLM ツールのため helper からは呼べず、`reenter` / `reconstructed` の入場のみ下記表に従い LLM が実行する。

`WT_ENSURE` で分岐する:

| `WT_ENSURE` | アクション |
|---|---|
| `disabled` / `already_in` | no-op（従来フロー / 既に worktree 内）。Phase 3.2 へ |
| `reenter` / `reconstructed` | `EnterWorktree` ツールを `path: {path}` で呼び出してから Phase 3.2 へ（`{path}` は marker の `path=` 値。`reconstructed` は helper が `git worktree add` 済み） |
| `residue` | パスは存在するが worktree 未登録（prune 後も残存）→ AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止） |
| `branch_other_worktree` | branch が**別の worktree** で checkout 中（並行セッションの可能性）→ **中止**。`other=` のパスを表示する（git が構造的に保証する二重着手ガード） |
| `branch_absent` | branch がローカル・リモートどこにも無い → **矛盾サマリ + AskUserQuestion**（新規セッション扱い / 中止）。helper は再構築しない（silent に新規扱いもしない） |
| `failed` | 再構築（`git fetch` / `git worktree add`）が失敗（helper rc=1, stderr に原因 + 復旧手順）→ **silent fallback せず明示停止**。develop 上で resume を続行しない |

> **caller-local marker `skip` について**: `review` / `fix` の入場ゲートは PR の `headRefName` が issue ブランチ（`issue-N` 命名）でないとき、helper を呼ばず caller 自身が `[CONTEXT] WT_ENSURE=skip` を emit する（session worktree の対象外＝従来どおり単一ツリーで続行する no-op）。`skip` は helper の出力 case ではなく **caller 固有拡張**であり、`disabled` / `already_in` と同じく no-op として扱う。resume は引数 / branch / 候補列挙で issue を確定してから本 helper を呼ぶため、resume 経路で `skip` は emit されない。

**EnterWorktree が失敗した場合**（`reenter` / `reconstructed` 経路の `EnterWorktree(path)` がエラー）: open Step 2.3-W と同じ切り分けを行い、**silent に新規セッション扱いしない**。

- **harness の git 誤判定**（`.git` が存在し `git -C "{path}" rev-parse` は成功するのに、起動コンテキストが `Is a git repository: false` で EnterWorktree が「not in a git repository」エラーを返す）→ **推奨**。診断とともに「**リポジトリ root から Claude Code を再起動**し、`/rite:resume {issue_number}` を再実行すれば、登録済み worktree が `WT_ENSURE=reenter` で再入場される」と案内する。worktree は保持済みのため破壊しない。
- **worktree path 消失などの別要因** → 再度本ヘルパーを実行すれば `branch_absent` 以外なら再構築される。再起動案内へ誤誘導しない。

再入場後、claim に worktree path を再記録してもよい（`issue-claim.sh claim --issue {issue_number} --worktree "{path}"`、best-effort）。

### 3.2 git 状態取得

```bash
git_branch=$(git branch --show-current 2>/dev/null || echo "")
# develop に到達できない場合は origin/develop or main を base に
base_branch="develop"
git fetch origin "$base_branch" >/dev/null 2>&1 || true
git_commit_count=$(git rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null || echo "0")
git_has_uncommitted=$(git status --porcelain 2>/dev/null | head -1)

# コンフリクト / rebase 状態検出 (#1705): Phase 3.4.5 が phase 推定より優先させる signal。
# worktree 運用でも正しい作業ツリーを判定するため .git/... を直書きせず git rev-parse --git-path で
# 解決する (worktree の MERGE_HEAD / rebase 状態は .git/worktrees/<name>/ 配下にあり、直書きは常に
# 不在扱いとなって merge/rebase 中断を取りこぼす)。
git_conflict_files=$(git status --porcelain 2>/dev/null | grep -E '^(DD|AU|UD|UA|DU|AA|UU) ' | cut -c4- | paste -sd, -)
[ -f "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] && git_in_merge=yes || git_in_merge=no
if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
  git_in_rebase=yes
else
  git_in_rebase=no
fi
echo "[CONTEXT] GIT_CONFLICT_FILES=$git_conflict_files"
echo "[CONTEXT] GIT_IN_MERGE=$git_in_merge"
echo "[CONTEXT] GIT_IN_REBASE=$git_in_rebase"
```

### 3.3 PR 状態取得

```bash
pr_info=$(gh pr view --json state,number,isDraft,mergeable 2>/dev/null || echo '{"state":"NONE","number":0,"isDraft":false,"mergeable":"UNKNOWN"}')
pr_state=$(echo "$pr_info" | jq -r '.state // "NONE"')
pr_number_gh=$(echo "$pr_info" | jq -r '.number // 0')
pr_is_draft=$(echo "$pr_info" | jq -r '.isDraft // false')
# mergeable=CONFLICTING は Phase 3.4.5 のコンフリクト優先判定に使う (base ブランチとの衝突)。
pr_mergeable=$(echo "$pr_info" | jq -r '.mergeable // "UNKNOWN"')
echo "[CONTEXT] PR_MERGEABLE=$pr_mergeable"
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

### 3.4.5 コンフリクト / rebase 状態の優先判定 (#1705)

Phase 3.2 の `[CONTEXT] GIT_CONFLICT_FILES` / `GIT_IN_MERGE` / `GIT_IN_REBASE` marker と Phase 3.3 の `PR_MERGEABLE` marker を読み、**いずれかがコンフリクト / rebase 中断を示す場合は、Phase 3.5 の phase 推定より本判定を優先する**。コンフリクトマーカーが残ったまま generic な「実装途中」扱いで復帰し、未解決の変更を上書きコミットへ誘導される事故を防ぐのが本判定の目的（マーカーの検出は git 実態からの読み取りで完結するため flow-state schema の変更は不要）。

**判定条件（OR、いずれか成立でコンフリクト状態）**:

| signal | 条件 | 意味 |
|---|---|---|
| `GIT_IN_MERGE` | `=yes`（`MERGE_HEAD` 存在） | merge 解決待ちの中断状態 |
| `GIT_IN_REBASE` | `=yes`（`rebase-merge` / `rebase-apply` 存在） | rebase 中断状態 |
| `GIT_CONFLICT_FILES` | 非空（`git status --porcelain` の unmerged マーカー `UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD`） | コンフリクトファイルが残存 |
| `PR_MERGEABLE` | `=CONFLICTING` | PR がベースブランチとコンフリクト |

いずれか成立時は、Phase 3.5 の cross-check へ進む**前に**以下を提示する:

```
⚠️ コンフリクト / rebase 中断を検出しました:
  - Merge 解決待ち (MERGE_HEAD): {GIT_IN_MERGE}
  - Rebase 中断 (rebase-merge/apply): {GIT_IN_REBASE}
  - コンフリクトファイル: {GIT_CONFLICT_FILES: 一覧 or "なし"}
  - PR mergeable: {PR_MERGEABLE}

コンフリクトマーカーが残ったまま実装 phase を継続すると、未解決の変更を上書きコミットする恐れがあります。
```

続けて AskUserQuestion で以下を提示する（rite は**コンフリクトを自動解消・自動コミットしない** — 本 Issue の Non-goal）:

- **解消してから継続（推奨）** — ユーザーがコンフリクトを手動解消（`git` の merge/rebase 続行 or `--abort`）した後、`/rite:resume {issue_arg}` を再実行する旨を案内していったん終了する。解消により上記 signal が消えれば、再実行時は本判定を通過して従来の cross-check に進む
- **中止** — 何もせず終了する

非コンフリクト時（上記 4 条件すべて不成立）は本判定を skip し、Phase 3.5 の従来 4 指標クロスチェックへそのまま進む（AC-3: 非干渉）。

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

判定結果を LLM が prose 推論で確定したら、`$resolved_phase` シェル変数を set してから以下を実行し、Phase 5.2 が読む `[CONTEXT] RESOLVED_PHASE` marker を emit する (Bash tool 境界でシェル状態は失われるため、後段 step は marker 経由でしか値を取れない):

```bash
# resolved_phase は本 Phase 3.5 の判定結果 (v3 enum 13 値のいずれか) を代入
# 例: resolved_phase="implement"
echo "[CONTEXT] RESOLVED_PHASE=$resolved_phase"
```

---

## Phase 4: Resume 確認

### 4.1 状態サマリ表示

```
=== 中断状態 ===
Issue: #{issue_arg} ({title})
Branch: {git_branch}
Phase: {resolved_phase} ({cross-check 結果})
Parent Issue: {state_parent_display}
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
- **新規セッション扱い** — flow-state をクリアして `/rite:open {issue_arg}` を最初から実行
- **中止** — 何もせず終了

ユーザーが「別 phase を選ぶ」を選択し phase を変更した場合は、新値を `$user_selected_phase` シェル変数に set した上で以下を実行し、Phase 5.2 が優先採用する `[CONTEXT] FINAL_PHASE` marker を emit する (RESOLVED_PHASE をオーバーライドする最終確定値):

```bash
# user_selected_phase は AskUserQuestion で user が選んだ v3 enum 値
# 例: user_selected_phase="lint"
echo "[CONTEXT] FINAL_PHASE=$user_selected_phase"
```

「続行」を選んだ場合 (= Phase 3.5 の RESOLVED_PHASE を採用) は FINAL_PHASE を emit せず、Phase 5.2 は RESOLVED_PHASE marker をそのまま使う。

---

## Phase 5: 再開実行

### 5.1 ブランチ切り替え（worktree モードでは検証のみ）

`WT_ENSURE=reenter` / `reconstructed`（Phase 3.1.5 で worktree へ再入場・再構築済み。`already_in` も worktree モード）では、worktree の HEAD は既に state branch を指しているはずなので **`git switch` は行わず検証のみ**にする（worktree 内から base への switch は不可かつ不要）。不一致は WARNING に留める:

```bash
if [ "$RESUME_WT_MODE" = "worktree" ]; then
  # worktree モード: 検証のみ（WT_ENSURE が already_in/reenter/reconstructed だったケース）
  cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || cur=""
  if [ -n "$state_branch" ] && [ "$cur" != "$state_branch" ]; then
    echo "WARNING: worktree のカレントブランチ ($cur) が state branch ($state_branch) と不一致です。手動で git switch '$state_branch' を確認してください。" >&2
  fi
elif [ -n "$state_branch" ] && [ "$git_branch" != "$state_branch" ]; then
  # 従来モード: 切り替え
  git switch "$state_branch" || {
    echo "ERROR: ブランチ切り替え失敗: $state_branch" >&2
    exit 1
  }
fi
```

> `RESUME_WT_MODE` は Phase 3.1.5 の `[CONTEXT] WT_ENSURE=` marker が `already_in` / `reenter` / `reconstructed`（= worktree に入った / 再構築した）のとき `worktree`、それ以外（`disabled`（従来分岐） / `residue` / `branch_other_worktree` / `branch_absent` / `failed`（= worktree に入っていない。停止 or 新規セッション扱いへ分岐）のとき空として LLM が置換する。

### 5.2 flow-state の active=true 復元

中断時 (例: クラッシュ / context 枯渇) で active=false になっている可能性があるため、resume では active=true に復元。merge semantics により他のフィールドは保持される。

> **重要 — Bash tool 境界での変数消失**: 本 step は Phase 3.1 とは別の Bash tool 呼び出しとなるため、`$state_phase` / `$resolved_phase` / `$state_next` 等のシェル変数を直接参照できない (Claude Code の Bash tool 境界でシェル状態は失われる)。LLM は Phase 3.1 末尾で stdout に emit された `[CONTEXT] STATE_PHASE=...` / `[CONTEXT] STATE_NEXT=...` marker と Phase 3.5 の cross-check 結果 `{resolved_phase}` を読み、下記 bash block 内の placeholder を実値に置換してから実行すること。`--if-exists` フラグにより flow state file 不在時は no-op (idempotent)、merge semantics により未指定フィールドは既存値を保持する:

```bash
# Placeholder substitution rule:
#   {resolved_phase} → 最新の [CONTEXT] FINAL_PHASE marker (Phase 4.2 で user が phase 変更を選んだ場合に emit される)、
#                      無ければ [CONTEXT] RESOLVED_PHASE marker (Phase 3.5 cross-check の確定 phase)
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
| `init` | `/rite:open {issue_arg}` をステップ 1 (Issue 取得) から再実行 (idempotent) |
| `branch` | `/rite:open {issue_arg}` をステップ 2 (ブランチ作成) から再開 (既存ブランチがあれば `git switch` で復帰) |
| `plan` | `/rite:open {issue_arg}` をステップ 3 (実装計画) から再開 |
| `implement` | `/rite:open {issue_arg}` をステップ 4 (実装) を継続 — 内部で `rite:issue-implement` を invoke し Issue body の checklist 未完項目から再開 |
| `lint` | `/rite:open {issue_arg}` をステップ 5 (lint 再実行) から再開 |
| `pr` | `/rite:open {issue_arg}` をステップ 6 (PR 作成) から再開 (既に PR 番号が state にあれば検出して `[pr:created:N]` 相当を再構成) |
| `review` | `/rite:iterate {pr_number}` を起動 (review 側から再開) |
| `fix` | `/rite:iterate {pr_number}` を起動 (fix 側から再開) |
| `ready` | `/rite:ready {pr_number}` をステップ 3 から再開 (Ready 化は完了済 — Projects Status In Review → 親判定 → 完了レポート) |
| `ready_error` | `/rite:ready {pr_number}` を ready 化リトライから再開 |
| `cleanup` | `/rite:cleanup {pr_number}` を再実行 |
| `ingest` | `/rite:wiki-ingest` を再呼び出し |
| `completed` | Issue は完結済。AskUserQuestion で「新規作業として再開 / 終了」 |

### 5.4 invoke

確定した phase に応じて Skill ツール経由で対応コマンドを呼ぶ。引数として `{issue_arg}` (`open`) または `{pr_number}` (`iterate` / `ready` / `cleanup`) を渡す。

`/rite:open` は内部の Resume Dispatch (ステップ 0) で `[CONTEXT] RESUME_DISPATCH=1; phase=$resolved_phase; issue=$issue_arg` を観測し、適切な step にジャンプする。`/rite:iterate` は phase に応じて review / fix のどちら側からループを始めるかを自動判定する。

---

## Phase 6: 完了

再開後の最初のサイクルが完了するまで、再開した skill に制御を委譲する。再開先の skill は flow-state を順次更新し、最終的に `completed` または `cleanup` 状態に到達する。

---

## エラー処理

| 状況 | 対応 |
|------|------|
| Issue not found | エラー終了、`gh issue list` で確認するよう案内 |
| Branch 不在 | `gh issue develop` で再生成するよう案内 |
| flow-state 不在 + WM 不在 | 「新規セッション」として `/rite:open {issue_arg}` を提案 |
| 矛盾検出 (phase vs commit/PR) | AskUserQuestion で「推定 phase で再開 / 別 phase を選ぶ / 中止」 |
| migrate 失敗 | WARNING 表示後、cross-check で実態推定して続行 |

---

## Phase enum 13 個 (SoT)

新 v3 schema の phase enum (`flow-state.sh` 内 `PHASE_ENUM_V3` と同期):

```
init / branch / plan / implement / lint / pr / review / fix / ready /
ready_error / cleanup / ingest / completed
```

旧 v1/v2 schema の phase 値 (`cleanup_pre_ingest`, `ingest_pre_lint`, `create_*`, `implementing` 等) は Phase 2 の自動 migration で v3 に変換される。Migration の reduction matrix は `plugins/rite/hooks/flow-state.sh` の `_phase_migrate` 関数を参照。

なお `phase5_*` 系の legacy 名 (pre-v3 の sub-skill chain アーキテクチャが書き込んだ古い state file に残存しうる) は `_phase_migrate` の reduction matrix に **含まれず pass-through される**。これらは PHASE_ENUM_V3 (13 個) に該当しないため Phase 2 migration では変換されず、Phase 3.5 の整合性判定 (cross-check) で再開 phase が確定される (cross-check は rule 1 で v3 enum 値のみを直接採用するため、非 v3 enum の legacy 値はそのまま採用されず、cross-check の判定を経て v3 phase へ解決される)。
