---
description: Issue を起点にブランチ作成・実装・lint・draft PR 作成までを一気通貫で実行
---

# /rite:pr:open

## Contract

**Input**: Issue number (required)
**Output**: 完了通知（draft PR の番号と URL）

Issue を起点に「準備 → ブランチ → 計画 → 実装 → lint → PR」までを一気通貫で実行する。レビュー/修正は `/rite:pr:iterate`、Ready 化は `/rite:pr:ready`、マージは `/rite:pr:merge` で実施する。

**途中で止まったら**: `/rite:resume` が flow-state ファイル (`.rite/sessions/{session_id}.flow-state`) の phase から復帰する。本コマンドの Step 0 が Resume Dispatch を担う。

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | 引数 |
| `{base_branch}` | `branch.base` in `rite-config.yml`（default: `main`） |
| `{branch_name}` | ステップ 2 で生成 |
| `{pr_number}` | ステップ 6 の `[pr:created:N]` から抽出 |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

> **Note**: `{owner}` / `{repo}` / `{project_number}` / `{parent_issue_number}` 等は下流 sub-skill (`rite:issue:implement` / `rite:pr:create` / Projects integration script 経由) が `rite-config.yml` / `gh` から個別に取得するため、本コマンド body 内で直接 substitute する経路は持たない (responsibility を sub-skill に委譲)。

---

## ステップ 0: Resume Dispatch（`/rite:resume` から呼ばれた場合のジャンプ）

セッション開始時に flow-state を読み、再開かどうかを判定する。新規セッション (state file 不在 or `active=false` or `issue_number` 不一致) の場合は何もせずステップ 1 に進む:

```bash
resume_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || resume_phase=""
resume_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || resume_issue=""
resume_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "") || resume_active=""
resume_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0") || resume_pr="0"

if [ -n "$resume_phase" ] && [ "$resume_active" = "true" ] && [ "$resume_issue" = "{issue_number}" ]; then
  echo "[CONTEXT] RESUME_DISPATCH=1; phase=$resume_phase; issue=$resume_issue; pr=$resume_pr"
else
  echo "[CONTEXT] RESUME_DISPATCH=0; reason=fresh_or_mismatched_session (phase='$resume_phase' active='$resume_active' issue='$resume_issue' arg='{issue_number}')"
fi
```

`{plugin_root}/hooks/flow-state.sh get --default ""` は session 解決失敗 / file 不在 / jq parse 失敗のいずれでも default を stdout に書く設計のため、外側 `|| ...` は helper validation 失敗 (`--field` 引数欠落 / invalid field name) 経路のみを catch する defensive fallback。stderr は WARNING channel として残し、`2>/dev/null` で握りつぶさない (想定外 ERROR を context に残すため)。

**LLM routing rule** (Bash tool shell state は次の Bash 呼び出しでリセットされるため `[CONTEXT] RESUME_DISPATCH=` marker を会話コンテキストから読む)。本表は **本コマンド内部の Step jump 用** の routing。`phase=review/fix/ready/cleanup` を含む外部コマンドへの routing 全体は [commands/resume.md](../resume.md) Phase 5.3 Phase enum → Step mapping (SoT) を参照:

| `RESUME_DISPATCH` value + `phase` | LLM action |
|---|---|
| `0` | 新規セッション or 別 Issue。ステップ 1 から通常開始 |
| `1` + `phase=init` | ステップ 1 (準備) から再実行 (idempotent) |
| `1` + `phase=branch` | ステップ 2 (ブランチ作成) から再開。既存ブランチがあれば `git switch` で復帰 |
| `1` + `phase=plan` | ステップ 3 (実装計画) から再開。既存の Issue body 実装ステップを再読込 |
| `1` + `phase=implement` | ステップ 4 (実装) を継続。`/rite:issue:implement` の checklist 未完項目から続行 (autonomous lint まで進む内蔵動作あり) |
| `1` + `phase=lint` | ステップ 5 (Step 4 内 autonomous lint の sentinel 検証) から再開。implement が既に lint まで完了している場合は sentinel を context から読み Step 6 へ |
| `1` + `phase=pr` | ステップ 6 (PR 作成) から再開。既存 draft PR があれば検出して `[pr:created:N]` 相当を再構成 |
| `1` + `phase=review` / `fix` | 本コマンドは扱わない。ユーザーに `/rite:pr:iterate <pr={resume_pr}>` を案内 (PR 番号は `[CONTEXT] RESUME_DISPATCH=...; pr=$resume_pr` marker から literal substitute) |
| `1` + `phase=ready` / `ready_error` | 本コマンドは扱わない。`/rite:pr:ready <pr={resume_pr}>` を案内 |
| `1` + `phase=cleanup` / `ingest` / `completed` | 既に PR 段階を超えている。ユーザーに状態を案内して `/rite:pr:cleanup <pr={resume_pr}>` 等を提案 |

`active=false` または `issue_number` が引数と異なる場合は別 Issue の state なので新規セッション扱い (ステップ 1 から開始)。

### 0.5 Worktree Re-entry（multi_session 有効時の Resume Dispatch）

`RESUME_DISPATCH=1`（同一セッション内の再開）で、かつ flow-state に `worktree` field がセットされている場合、復帰先ステップへジャンプする**前に**そのセッション worktree へ再入場する。Bash ツール呼び出しと EnterWorktree ツールの cwd を一致させるための前処理:

```bash
resume_wt=$(bash {plugin_root}/hooks/flow-state.sh get --field worktree --default "") || resume_wt=""
cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
echo "[CONTEXT] WORKTREE_REENTRY=$([ -n "$resume_wt" ] && [ "$resume_wt" != "$cur_top" ] && echo needed || echo none); worktree=$resume_wt"
```

- `WORKTREE_REENTRY=needed`（flow-state `worktree` が現在の作業ツリーと不一致）→ `EnterWorktree` ツールを `path: {worktree}` で呼び出し（`{worktree}` は上記 marker の値）、その後にステップ 0 の routing 表で決まった復帰先ステップへジャンプする。
- `WORKTREE_REENTRY=none` → そのまま復帰先ステップへ。
- 入場後に worktree が消失している等で `EnterWorktree` が失敗した場合は、ステップ 8（resume / S8）の worktree 再構築経路に委ねる（本コマンドでは新規 worktree を作らず、ユーザーに `/rite:resume {issue_number}` を案内する）。

`MULTI_SESSION_ENABLED=false` または flow-state に `worktree` が無い場合は no-op。

---

## ステップ 1: 準備（Issue 取得・親判定・品質評価）

### 1.1 Issue 情報取得

```bash
gh issue view {issue_number} --json number,title,body,state,labels,milestone,projectItems
```

State が `closed` の場合は AskUserQuestion で「再オープンして作業 / 中止」を選択。

### 1.2 親 Issue 検出

以下のいずれかに該当すれば親 Issue として扱う:

1. `trackedIssues.nodes` が空でない（GraphQL）
2. Body に `- [ ] #NN` 形式のタスクリストがある
3. ラベルに `epic` / `parent` / `umbrella` のいずれか

親 Issue の場合は AskUserQuestion で「子 Issue を選んで作業 / この親 Issue 自体に対して作業 / 中止」を提示。子 Issue 選択時は trackedIssues から open かつ未着手のものを priority + complexity 順で並べて 1 件選択させ、選択後は `{issue_number}` を子の番号に置換してステップ 1.1 から再実行する。

### 1.3 Issue 品質評価

What / Why / Where / Scope の充足度で A-D 評価。C/D の場合は AskUserQuestion で「既存情報で開始 / Issue を編集してから再実行 / 中止」を選択。

### 1.4 設定読込 (language / multi_session)

`rite-config.yml` の `language` field を取得し `[CONTEXT] WORKFLOW_LANGUAGE=` marker として emit。ステップ 4 の commit message テンプレで参照される。

あわせて `multi_session` を読み、ステップ 2.2-W / 2.3-W のセッション worktree 分岐判定に使う `[CONTEXT]` marker を emit する（Bash ツール間でシェル変数は保持されないため marker 経由で参照する）:

```bash
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -n "$ms_base" ] || ms_base=".rite/worktrees"
echo "[CONTEXT] MULTI_SESSION_ENABLED=$ms_enabled; WORKTREE_BASE=$ms_base"
```

新規プロジェクトはテンプレート config が `enabled: true`（デフォルト ON）のため `MULTI_SESSION_ENABLED=true` となりステップ 2 で 2.2-W / 2.3-W（セッション worktree）を実行する。`MULTI_SESSION_ENABLED=false`（`enabled: false` を明示設定 / `multi_session:` ブロックが存在しない旧 config — 上記 `case` の fallback）のときは従来の Step 2.2 / 2.3 をそのまま実行し、挙動は単一セッション時と完全一致する。`multi_session:` キー欠落時の fallback を `false` に保つことで既存プロジェクトの後方互換を担保する（デフォルト変更が効くのは新規 `/rite:init` 生成時のみ）。

### 1.5 Iteration 自動 assign

`iteration.enabled: true` かつ `iteration.auto_assign: true` の場合、現在の active iteration を取得して Issue を assign する。手順: Projects の Iteration フィールド (`iteration.field_name`、既定 `Sprint`) の `configuration.iterations` を取得し、`startDate <= today < startDate + duration` を満たす iteration を「現在」とみなす。該当 iteration の `id` を `updateProjectV2ItemFieldValue` mutation で対象 Issue の Iteration フィールドに設定する。該当なしの場合は assign をスキップする。

### 1.6 flow-state 初期化 + Issue claim 取得

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase init --issue {issue_number} --branch "" --pr 0 \
  --next "ブランチ作成へ進む"
```

続けて Issue claim を取得する（**branch / worktree 作成という副作用の前の fail-fast**。`multi_session.enabled` に依らず常時有効 — Decision D-3）:

```bash
claim_out=$(bash {plugin_root}/hooks/issue-claim.sh claim --issue {issue_number} 2>&1); claim_rc=$?
echo "[CONTEXT] ISSUE_CLAIM=$claim_out; rc=$claim_rc"
```

- `rc=0`（`claimed` / `own` / stale 奪取）→ そのままステップ 2 へ進む。
- `rc=10`（`other` = 他の live セッションが同一 Issue を作業中）→ **AskUserQuestion** で対応を選択する（無人での奪取はしない）:
  - 「中止（推奨）」: 他セッションの作業を尊重して終了する。
  - 「強制取得して続行」: 他セッションと衝突するリスクを表示した上で、`issue-claim.sh claim --issue {issue_number}` の再実行ではなく、ユーザーが当該セッションを停止済みであることを確認してから続行する（最終ガードはステップ 2.2-W の branch 衝突検出）。
- それ以外の非 0 rc（環境エラー）→ stderr を表示して中止する。

---

## ステップ 2: ブランチと Projects

### 2.1 ブランチ名生成

`rite-config.yml` の `branch.pattern`（default: `{type}/issue-{number}-{slug}`）に従う。

- **type**: labels / title から推定（`bug`/`bugfix` → `fix`、`docs` → `docs`、`refactor` → `refactor`、`chore`/`maintenance` → `chore`、それ以外 → `feat`）
- **slug**: Issue title を kebab-case 化 (英数字 + ハイフン、50 文字上限)

> **ステップ 2.2 / 2.3 の分岐**: ステップ 1.4 の `[CONTEXT] MULTI_SESSION_ENABLED=` marker を読む。`true`（新規プロジェクトのデフォルト）→ 下記 **2.2-W / 2.3-W**（セッション worktree）を実行し、従来の 2.2 / 2.3 は **置換**してスキップする。`false`（`enabled: false` 明示設定 / `multi_session:` ブロック欠落の旧 config）→ 下記 **2.2 / 2.3**（従来動作、単一セッション時と完全一致）を実行する。

### 2.2 既存ブランチチェック（multi_session 無効時）

`git rev-parse --verify {branch_name}` で既存確認。存在する場合は `git switch {branch_name}` で復帰、なければ次へ。

### 2.3 ブランチ作成（multi_session 無効時）

```bash
git switch {base_branch} && git pull --ff-only origin {base_branch} && git switch -c {branch_name}
```

### 2.2-W セッション worktree の冪等準備（multi_session 有効時、2.2/2.3 を置換）

worktree path は `{worktree_base}/issue-{issue_number}`（`{worktree_base}` は 1.4 の `WORKTREE_BASE` marker 値、絶対パスは `{repo_root}/{worktree_base}/issue-{issue_number}`）。base ref は checkout 中 branch の fetch 更新不可制約のため **`origin/{base_branch}` を直接指定**する（local {base_branch} を経由しない）:

```bash
worktree_base="{worktree_base}"
wt_rel="$worktree_base/issue-{issue_number}"
repo_root=$(git rev-parse --show-toplevel)
wt_path="$repo_root/$wt_rel"
branch="{branch_name}"
base="{base_branch}"

# ref lock 競合対策の 3 回リトライ (references/git-worktree-patterns.md 参照)
n=0; until git fetch origin "$base" 2>/dev/null; do n=$((n+1)); [ "$n" -ge 3 ] && break; sleep 1; done

# 冪等 5 ケースを判定して [CONTEXT] marker で LLM に分岐させる
wt_registered=$(git worktree list --porcelain | awk -v p="$wt_path" '$1=="worktree" && $2==p {print "yes"}')
branch_exists=$(git rev-parse --verify "$branch" >/dev/null 2>&1 && echo yes || echo no)
branch_wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
  $1=="worktree"{wt=$2} $1=="branch" && $2==b {print wt}')

if [ "$wt_registered" = "yes" ] && [ "$branch_wt" = "$wt_path" ]; then
  echo "[CONTEXT] WT_CASE=reuse; path=$wt_path"
elif [ -e "$wt_path" ] && [ "$wt_registered" != "yes" ]; then
  git worktree prune
  if [ -e "$wt_path" ]; then echo "[CONTEXT] WT_CASE=stale_residue; path=$wt_path"; else echo "[CONTEXT] WT_CASE=create_new; path=$wt_path"; fi
elif [ -n "$branch_wt" ] && [ "$branch_wt" != "$wt_path" ]; then
  echo "[CONTEXT] WT_CASE=branch_other_worktree; path=$wt_path; other=$branch_wt"
elif [ "$branch_exists" = "yes" ]; then
  echo "[CONTEXT] WT_CASE=branch_only; path=$wt_path"
else
  echo "[CONTEXT] WT_CASE=create_new; path=$wt_path"
fi
```

`WT_CASE` で分岐（worktree を作る場合の base は常に `origin/{base_branch}`）:

| `WT_CASE` | アクション |
|---|---|
| `reuse` | worktree 登録済 + branch 一致 → 再利用（resume 相当、`git worktree add` しない） |
| `stale_residue` | パス存在・worktree 未登録（prune 後も残存）→ AskUserQuestion（「削除して再作成」= `rm -rf {path}` 後に create / 「中止」） |
| `branch_only` | branch 存在・worktree なし → `git worktree add "{path}" "{branch}"`（`-b` なし） |
| `create_new` | branch も worktree もなし → `git worktree add -b "{branch}" "{path}" "origin/{base_branch}"` |
| `branch_other_worktree` | branch が**別の worktree** で checkout 中 → **中止**（他セッション作業中の可能性。`other=` のパスを表示。git が構造的に保証する二重着手ガード） |

### 2.3-W EnterWorktree 入場（multi_session 有効時）

worktree を作成・再利用したら、`.rite-plugin-root` を worktree root へコピーしてから入場する:

```bash
[ -f "$repo_root/.rite-plugin-root" ] && cp "$repo_root/.rite-plugin-root" "$wt_path/.rite-plugin-root" 2>/dev/null || true
```

その後 `EnterWorktree` ツールを `path: {wt_path}` で呼び出す（`{wt_path}` は 2.2-W の `WT_CASE` marker の `path=` 値。EnterWorktree のツール側ガード「ユーザー / プロジェクト指示で明示された場合のみ」は、`rite-config.yml` の `multi_session.enabled: true`（リポジトリにコミットされた**プロジェクト指示**。値がテンプレートのデフォルト ON 由来かユーザーの明示編集由来かに依らずプロジェクト指示として成立する）+ 本コマンド定義の明示指示の両方で満たす。デフォルトが ON でも、この `enabled: true` を marker 経由で確認した分岐内でのみ EnterWorktree を呼ぶため、ガードの根拠は default off 時と変わらず成立する）。

- **EnterWorktree が不在 / 失敗の場合**: **silent fallback はしない**。まず失敗原因を切り分ける（補助情報として `git -C "{wt_path}" rev-parse --is-inside-work-tree` の結果を提示してよい）:
  - **(A) harness の git 誤判定**（`.git` が存在し `git -C "{wt_path}" rev-parse` は成功するのに、起動コンテキストが `Is a git repository: false` で EnterWorktree が「not in a git repository」エラーを返す）→ **推奨**。これは harness がセッション起動時に launch ディレクトリを git リポジトリと認識できなかったことが原因で、プラグインからは直せない。診断とともに「**リポジトリ root から Claude Code を再起動**し、`/rite:pr:open {issue_number}` を再実行すれば、作成済み worktree が 2.2-W で `WT_CASE=reuse` と判定され**再作成せず継続**できる」と案内する。worktree は保持済みのため破壊しない。
  - **(B) worktree path 消失などの別要因**（harness 誤判定以外）→ 既存どおりステップ 8（resume / S8）の worktree 再構築経路 / `/rite:resume {issue_number}` に委譲する（本コマンドでは新規 worktree を作らない。再起動案内へ誤誘導しない）。
  - **(C) エスケープハッチ**（ユーザーが明示選択した場合のみ）: 「従来 `git switch -c` で続行」は **recommended にしない**。worktree 分離を破棄する明示的な選択肢としてのみ残し、他セッション併走中は作業ツリーを破壊し合う危険がある旨を**警告**した上でステップ 2.3 にフォールバックする。
  - Bash 永続 cwd 駆動（cwd を main checkout に残したまま絶対パスで操作する経路）は**導入しない**（main tree を誤更新するリスクのため）。

入場後、claim に worktree path を記録する（reap / resume の discovery 用）:

```bash
bash {plugin_root}/hooks/issue-claim.sh claim --issue {issue_number} --worktree "{wt_path}" >/dev/null 2>&1 || true
```

ステップ 3〜6（implement / lint / push / PR create）は cwd 相対で完結するため**無変更**（S1 の state root 統一が前提）。

### 2.4 GitHub Projects Status 更新

`rite-config.yml.github.projects.enabled: true` の場合、Projects の Status を `In Progress` に更新。詳細は `../../references/projects-integration.md` 参照。

### 2.5 Work Memory 初期化

Issue の comment として work memory を初期投稿する。`コマンド:` 行は `rite:pr:open` を記載。詳細は `../../skills/rite-workflow/references/work-memory-format.md` 参照。

### 2.6 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase branch --issue {issue_number} --branch {branch_name} --pr 0 \
  --next "実装計画策定へ進む"
```

`MULTI_SESSION_ENABLED=true` のときは末尾に `--worktree "{wt_path}"` を追加する（`{wt_path}` は 2.2-W の `path=` 値）。`--worktree` は merge-preserve かつ conditional-write のため、無効時（値が空）は state file に key を付与せず挙動は不変。

---

## ステップ 3: 実装計画

### 3.1 Issue 内容分析

Issue body から「What / Why / Where / Acceptance Criteria」を抽出。

### 3.2 変更対象ファイルの特定

`git grep` / `find` / Read で関連ファイルを特定。Acceptance Criteria に対する責務ファイルを列挙する。

### 3.3 実装計画生成

以下のテンプレートで実装計画を出力:

```
## 実装計画

### 変更対象ファイル
- {file_path_1}: {responsibility}

### 実装ステップ
1. {step_1}
2. {step_2}

### 受入基準マッピング
- AC1 → step {N}

### 注意点
- {note_1}
```

### 3.4 ユーザー確認

AskUserQuestion で「この計画で実装開始 / 計画を修正 / 中止」を選択。

### 3.5 Issue Body Checklist 更新

実装ステップを Issue body の `- [ ]` チェックリストとして追記。詳細は `../../references/gh-cli-patterns.md#safe-checklist-operation-patterns` 参照。

### 3.6 Work Memory 更新

実装計画を work memory comment に記録。

### 3.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase plan --issue {issue_number} --branch {branch_name} --pr 0 \
  --next "実装作業へ進む"
```

---

## ステップ 4: 実装

```text
skill: rite:issue:implement
args: "{issue_number}"
```

`/rite:issue:implement` は以下を担う:

- チェックリスト駆動で各ステップを実装 (Edit / Write ツール経由)
- `tdd.enabled: true`（デフォルト, opt-out）のとき、実装は Canon TDD サイクル（テストリスト → Red → Green → Refactor、Issue の Section 6 Test Specification を初期ソースとする）で進む。`commands.test` 未設定時は Red/Green 実行を skip して test-list 規律のみ維持、`tdd.enabled: false` では従来フロー（詳細は `commands/issue/implement.md` § 5.0.T）
- conventional commits 形式でコミット (`{type}: {summary} (refs #{issue_number})`)
- Work Memory のチェックリストを完了状態に更新
- 全 step 完了後、autonomous に `rite:lint` を Skill ツール経由で invoke する
  (旧 `start.md` — 本 PR で削除済 — の flat 設計を継承した内蔵動作。本コマンドの責務として lint 二重実行を避けるため、Step 5 は no-op になる)

**実態としての挙動**:
- `/rite:issue:implement` 完了時点で `phase=lint` が flow-state に書かれ、`rite:lint` の sentinel
  (`[lint:success]` / `[lint:skipped]` / `[lint:error]` / `[lint:aborted]`) が会話 context に emit 済みとなる
- 本コマンドは Step 5 で sentinel を**読み取るだけ**で `rite:lint` を再 invoke しない
  (Step 4 が autonomous lint を内包しているため)
- `/rite:issue:implement` 自体は固有 sentinel (`[implement:*]`) を emit しない設計のため、本ステップでは
  `[lint:*]` sentinel の context 投入のみを期待し、判定そのものは Step 5 に委譲する (no-op step)

Step 4 では Step 5 への引き渡し前提のため、本ステップ単体での sentinel routing table は持たない。
`rite:lint` も含めて context に sentinel が全く emit されない場合 (implement が autonomous lint へ
到達せず abort した稀ケース) は Step 5 末尾の「sentinel 不在」行で catch する。

---

## ステップ 5: 品質チェック (Step 4 の autonomous lint 結果検証)

Step 4 で `/rite:issue:implement` が autonomous に invoke した `rite:lint` の sentinel を会話 context から検証する。
本ステップは sentinel を読むだけで、自前で `rite:lint` を再 invoke しない (二重実行防止)。

| Sentinel | 次のアクション |
|---------|--------------|
| `[lint:success]` | ステップ 6 へ進む |
| `[lint:skipped]` | ステップ 6 へ進む (lint 未設定) |
| `[lint:error]` | AskUserQuestion で「修正再実行 / 強制続行 / 中止」を提示 |
| `[lint:aborted]` | エラー終了。ユーザーに復旧手順を案内 |
| sentinel 不在 | Step 4 で `/rite:issue:implement` が autonomous lint まで到達できなかった可能性。AskUserQuestion で「手動で `/rite:lint` 実行 / 中止」を提示 |

`phase=lint` は Step 4 の `/rite:issue:implement` が既に flow-state に書き込んでいるため、本コマンドからの上書きは不要 (二重 write を避ける契約)。

---

## ステップ 6: PR 作成

### 6.1 push

```bash
git push -u origin {branch_name}
```

### 6.2 PR 作成

```text
skill: rite:pr:create
```

`rite:pr:create` の出力 sentinel を会話 context から検証する:

| Sentinel | 次のアクション |
|---------|--------------|
| `[pr:created:N]` | PR 番号 `N` を `{pr_number}` として retain → ステップ 6.3 へ |
| `[pr:create-failed]` | AskUserQuestion で「再試行 / 中止」を提示 |
| **sentinel 不在 (missing-sentinel)** | `[pr:created:N]` / `[pr:create-failed]` のいずれも context に無い。Phase 3.4 の `gh pr create` が malformed tool-call で無言終了した可能性 (Cause A: harness/transport 側ゆらぎ、rite では除去不能 — 詳細は下記「malformed tool-call 回復契約」)。下記手順で回復する |

**malformed tool-call 回復契約**:

sub-skill (`rite:pr:create` / `rite:issue:implement` / `rite:lint`) のターンが sentinel を 1 つも emit せず無言で終了した場合、flow-state には直前 phase が保持されているため作業は失われない。orchestrator は以下で回復する:

1. **既存 draft PR の検出**: `gh pr list --head {branch_name} --json number,url,isDraft` で当該ブランチの PR が既に作成済みか確認する。存在すれば実質 `[pr:created:N]` 相当として `{pr_number}` を再構成し、ステップ 6.3 へ進む (push/PR は冪等に再開可能)
2. **未作成の場合**: AskUserQuestion で「PR 作成を再試行 / 中止」を提示する。中止時は flow-state の phase が保持されるため `/rite:resume` で本ステップから再開できる旨を案内する

> Phase 3.4 の Write tool 委譲 は Cause B (インライン heredoc / 特殊文字 title による malform 増幅) を除去して発生確率を下げる対策であり、Cause A 自体は消せない。そのため本回復契約が最終的な堅牢化の担保となる。

### 6.3 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase pr --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "レビュー/修正ループへ進む (/rite:pr:iterate {pr_number})"
```

`MULTI_SESSION_ENABLED=true` のときは末尾に `--worktree "{wt_path}"` を追加する（merge-preserve のため省略しても保持されるが、明示することで `--worktree` を伴わない他経路の set との順序非依存を担保する）。

---

## 完了通知

draft PR の作成が完了したら、ユーザーに以下を案内する:

```
## /rite:pr:open 完了

- Issue: #{issue_number} - {issue_title}
- ブランチ: {branch_name}
- Draft PR: #{pr_number} - {pr_url}

次のステップ:
- レビュー/修正ループ: /rite:pr:iterate {pr_number}
- Ready 化: /rite:pr:ready {pr_number}
- マージ: /rite:pr:merge {pr_number}
- クリーンアップ (merge 後): /rite:pr:cleanup {pr_number}

途中で止まったら /rite:resume で復帰します。
```

---

## エラー時の方針

- どこで止まっても flow-state.json に phase が記録されている
- `/rite:resume` 経由で本コマンドの該当ステップから再開する
- sub-skill (`rite:issue:implement` / `rite:lint` / `rite:pr:create`) の sentinel drop に備え、各 invoke 後に sentinel 検出を確認、不在なら AskUserQuestion で「再試行 / 中止」
- **malformed tool-call による無言終了** (sub-skill が sentinel を 1 つも emit せずターン終了。Cause A: harness/transport 側ゆらぎ、rite では除去不能) も missing-sentinel として同様に扱う。PR 作成ステップの具体的な回復手順 (既存 draft PR 検出 → `/rite:resume`) はステップ 6.2「malformed tool-call 回復契約」を参照
