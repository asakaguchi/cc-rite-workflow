---
description: Issue の作業を開始（ブランチ作成 → 実装 → PR → レビュー → 完結）
---

# /rite:issue:start

## Contract

**Input**: Issue number (required)
**Output**: `## 完了報告`（Issue/PR の詳細と進捗テーブル）

Issue を起点に「準備 → ブランチ → 計画 → 実装 → lint → PR → レビュー/修正 → Ready & 完結」を一気通貫で実行する。

**途中で止まったらユーザーは `/rite:resume` で flow-state ファイル (`.rite/sessions/{session_id}.flow-state` / legacy `.rite-flow-state` の fallback) に記録された phase から再開する**。

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | 引数 |
| `{owner}`, `{repo}` | `gh repo view --json owner,name` |
| `{base_branch}` | `branch.base` in `rite-config.yml`（default: `main`） |
| `{branch_name}` | ステップ 2 で生成 |
| `{pr_number}` | ステップ 6 の `[pr:created:N]` から抽出 |
| `{project_number}` | `rite-config.yml` の `github.projects.project_number`（Projects enabled 時のみ） |
| `{parent_issue_number}` | ステップ 1.2 で検出した親 Issue 番号（親 detection 時のみ） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 0: Resume Dispatch（`/rite:resume` から呼ばれた場合のジャンプ）

セッション開始時に flow-state を読み、`/rite:resume` 経由の再開かどうかを判定する。新規セッション (state file 不在) の場合は何もせずステップ 1 に進む:

```bash
resume_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "" 2>/dev/null || echo "")
resume_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "" 2>/dev/null || echo "")
# flow-state.sh の boolean field は `--default ""` で読むのが推奨 (ヘッダ documented contract)。
# `--default "false"` は missing と stored false の区別を失うため使わない (`pr/ready.md` Phase 2.1 と同形)。
resume_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "" 2>/dev/null || echo "")

if [ -n "$resume_phase" ] && [ "$resume_active" = "true" ] && [ "$resume_issue" = "{issue_number}" ]; then
  echo "[CONTEXT] RESUME_DISPATCH=1; phase=$resume_phase; issue=$resume_issue"
else
  echo "[CONTEXT] RESUME_DISPATCH=0; reason=fresh_or_mismatched_session (phase='$resume_phase' active='$resume_active' issue='$resume_issue' arg='{issue_number}')"
fi
```

**LLM routing rule** (Bash tool shell state は次の Bash 呼び出しでリセットされるため `[CONTEXT] RESUME_DISPATCH=` marker を会話コンテキストから読む):

| `RESUME_DISPATCH` value + `phase` | LLM action |
|---|---|
| `0` | 新規セッション or 別 Issue。ステップ 1 (Issue 情報取得) から通常開始 |
| `1` + `phase=init` | ステップ 1.5 の `flow-state.sh set` をやり直すためステップ 1 から再実行 (idempotent) |
| `1` + `phase=branch` | ステップ 2 (ブランチ作成) から再開。既存ブランチがあれば `git switch` で復帰 |
| `1` + `phase=plan` | ステップ 3 (実装計画) から再開。既存の Issue body 実装ステップを再読込 |
| `1` + `phase=implement` | ステップ 4 (実装) を継続。Issue body の checklist 未完項目から続行 |
| `1` + `phase=lint` | ステップ 5 (lint 再実行)。既に lint 完了済みなら ステップ 5.2 (flow-state 更新) は overwrite される |
| `1` + `phase=pr` | ステップ 6 (PR 作成) から再開。既に PR 番号が state にあればステップ 7 へジャンプ |
| `1` + `phase=review` | ステップ 7.1 (review 再実行) |
| `1` + `phase=fix` | ステップ 7.2 (fix 再実行) |
| `1` + `phase=ready` | ステップ 8.3 から再開 (Ready は完了済 — Projects Status In Review → 親判定 → 完了レポート) |
| `1` + `phase=ready_error` | ステップ 8 (Ready & 完結) から再開。PR は既に存在するため `/rite:pr:create` は呼ばない |
| `1` + `phase=completed` | Issue は既に完結。AskUserQuestion で「新規作業として再開 / 中止」を提示 |
| `1` + `phase=<legacy>` (`phase5_*` 等) | Phase 2 の自動 migration で v3 enum に変換された後、`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の対応行に従う |

`active=false` または `issue_number` が引数と異なる場合は、別 Issue の state が残っているだけなので新規セッション扱い (ステップ 1 から開始)。state file は新 phase 書き込み時に `previous_phase` がシフトされるため、誤った overwrite は発生しない。

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

```bash
gh api graphql -f query='
  query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner:$owner, name:$repo) {
      issue(number:$number) {
        trackedIssues(first:50) { nodes { number title state } }
      }
    }
  }' -f owner={owner} -f repo={repo} -F number={issue_number}
```

親 Issue の場合は AskUserQuestion で「子 Issue を選んで作業 / この親 Issue 自体に対して作業 / 中止」を提示し、選択により分岐:

- **子 Issue 選択**: trackedIssues から open かつ未着手のものを優先順位順（priority: High > Medium > Low、complexity: XS > S > M > L > XL）に並べ、AskUserQuestion で 1 件選択。選択後は `{issue_number}` を子の番号に置換してステップ 1.1 から再実行。
- **親 Issue 自体**: そのまま続行（実装が親 Issue body で完結する場合）。
- **中止**: workflow 終了。

### 1.3 Issue 品質評価

| Score | 条件 |
|-------|------|
| A | What / Why / Where / Scope すべて記載 |
| B | What / Why 明確、Where/Scope 推測可能 |
| C | What のみ明確、詳細不足 |
| D | Body 20 単語未満、または What/Why/Where すべて不明 |

C/D の場合は AskUserQuestion で「既存情報で開始 / Issue を編集してから再実行 / 中止」を選択。

### 1.4 設定読込 (language)

`rite-config.yml` の `language` field を取得。後続ステップ (4.2 コミット例) で使う。Bash tool は invocation 境界でシェル変数を失うため、CONTEXT marker として stdout に emit し、LLM はステップ 4.2 で marker から literal 置換する:

```bash
language=$(awk -F: '/^language:[[:space:]]*/ {sub(/^[[:space:]]+/, "", $2); gsub(/["'"'"'\r]/, "", $2); print $2; exit}' rite-config.yml 2>/dev/null)
awk_rc=$?
if [ $awk_rc -ne 0 ]; then
  echo "WARNING: rite-config.yml の language field 取得 awk が rc=$awk_rc で失敗。default 'ja' を使用します" >&2
fi
[ -z "$language" ] && language="ja"  # default
echo "[CONTEXT] WORKFLOW_LANGUAGE=$language"
```

> ステップ 4.2 (コミット例) では、上記 `[CONTEXT] WORKFLOW_LANGUAGE=` marker から literal で `language` 値を読み取り、テンプレ分岐 (`ja` / `en` 等) を選択する。`$language` を bash 変数として参照すると invocation 境界で失われるため必ず marker 経由を使うこと。

### 1.5 flow-state 初期化

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase init --issue {issue_number} --branch "" --pr 0 \
  --next "ブランチ作成へ進む"
```

---

## ステップ 2: ブランチと Projects

### 2.1 ブランチ名生成

`rite-config.yml` の `branch.pattern`（default: `{type}/issue-{number}-{slug}`）に従う。

- **type**: labels / title から推定（`bug`/`bugfix` → `fix`、`docs` → `docs`、`refactor` → `refactor`、`chore`/`maintenance` → `chore`、それ以外 → `feat`）
- **slug**: title を lowercase、空白を `-` に置換、30 字以内

### 2.2 既存ブランチチェック

```bash
local_match=$(git branch --list "{branch_name}")
remote_match=$(git branch -r --list "origin/{branch_name}")
if [ -n "$local_match" ] || [ -n "$remote_match" ]; then
  echo "BRANCH_EXISTS"
fi
```

> **注意**: `git branch --list` は常に exit 0 を返すので、出力文字列の空チェックで判定する。

存在する場合は AskUserQuestion で「既存ブランチに切り替え / 別名で作成（サフィックス追加） / 中止」を選択。

### 2.3 ブランチ作成

`{base_branch}` から派生して作成。`{base_branch}` がリモートにのみ存在する場合は `origin/{base_branch}` から派生。

```bash
fetch_err=$(git fetch origin {base_branch} 2>&1) || \
  echo "WARNING: git fetch origin {base_branch} failed (stale local ref で進む可能性あり): $fetch_err" >&2

if git rev-parse --verify "{base_branch}" >/dev/null 2>&1; then
  git switch -c "{branch_name}" "{base_branch}"
elif git rev-parse --verify "origin/{base_branch}" >/dev/null 2>&1; then
  git switch -c "{branch_name}" "origin/{base_branch}"
else
  default_branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
  if [ -z "$default_branch" ]; then
    echo "ERROR: 'gh repo view' で default branch を解決できませんでした。'gh auth status' を確認してください" >&2
    exit 1
  fi
  git switch -c "{branch_name}" "origin/${default_branch}"
fi
```

Issue にブランチを関連付け (失敗しても workflow は続行するが、stderr に WARNING を出力):

```bash
if ! develop_err=$(gh issue develop {issue_number} --name "{branch_name}" 2>&1); then
  # Strip control characters before truncation. gh error messages occasionally
  # contain binary bytes; allowing them through could break JSON details
  # serialization or trigger unintended terminal escape sequences downstream.
  develop_err_short=$(printf '%s' "$develop_err" | tr -d '\000-\010\013\014\016-\037' | head -c 500)
  echo "WARNING: Issue→branch link failed (GitHub UI Development パネルが空のまま): $develop_err_short" >&2
fi
```

### 2.4 GitHub Projects Status 更新

`rite-config.yml` の `github.projects.enabled: true` の場合のみ実行。`projects-status-update.sh` に委譲（実 interface は JSON 単一引数。canonical SoT: [`projects-status-update-callsites.md`](./references/projects-status-update-callsites.md)）。スクリプトは非 blocking failure 時に **exit 0 + `.result == "failed"` / `"skipped_not_in_project"`** を返すため、bash exit code ではなく JSON stdout `.result` を inspect すること（Common contract §3-§5）。失敗時は WARNING を stderr に出力する:

```bash
status_result=$(bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
    --argjson issue {issue_number} \
    --arg owner "{owner}" \
    --arg repo "{repo}" \
    --argjson project_number {project_number} \
    --arg status "In Progress" \
    --argjson auto_add true \
    --argjson non_blocking true \
    '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>&1) || status_result="{\"result\":\"failed\",\"warnings\":[\"projects-status-update.sh fatal exit\"]}"
status_value=$(printf '%s' "$status_result" | jq -r '.result // "failed"' 2>/dev/null || echo "failed")
case "$status_value" in
  updated) ;;
  skipped_not_in_project)
    echo "WARNING: Issue #{issue_number} は Project に未登録 (Callsite 1)" >&2
    ;;
  failed|*)
    printf '%s' "$status_result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do echo "WARNING: $w" >&2; done
    ;;
esac
```

親 Issue が存在する場合 (ステップ 1.2 で検出) は親も同様に `In Progress` に更新（`{issue_number}` を `{parent_issue_number}` に差し替え、同じ JSON pattern + 上記 `.result` inspection を再実行）。

### 2.5 Iteration 割り当て（任意）

`rite-config.yml` の `iteration.enabled: true` かつ `iteration.auto_assign: true` の場合のみ実行。現在の iteration を取得して assign。失敗時は warning + continue。

### 2.6 Work Memory 初期化

> `local-wm-update.sh` は best-effort (exit 1=skip / exit 2=lock 失敗)。script header の SoT 契約に従い `2>/dev/null || true` で wrap する。

```bash
WM_SOURCE="init" WM_PHASE="branch" WM_PHASE_DETAIL="ブランチ作成・準備" \
  WM_NEXT_ACTION="実装計画を生成" \
  WM_BODY_TEXT="Issue #{issue_number} の作業を開始しました。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/tmp/rite-wm-err-$$.log
wm_rc=$?
if [ $wm_rc -eq 2 ]; then
  echo "WARNING: local-wm-update.sh exit 2 (lock failure / concurrent session contention). stderr: $(head -c 200 /tmp/rite-wm-err-$$.log 2>/dev/null | tr '\n' ' ')" >&2
fi
rm -f /tmp/rite-wm-err-$$.log
true
```

Issue コメントへの同期は post-tool-wm-sync hook が自動で行う。

### 2.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase branch --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "実装計画を生成"
```

---

## ステップ 3: 実装計画

### 3.1 Issue 内容分析

ステップ 1.1 で取得した body / labels / title から:

- 達成すべき outcome（What）
- 制約・前提（Where）
- 受入基準（Acceptance Criteria）

を抽出する。

### 3.2 変更対象ファイルの特定

Issue body や関連リンクから推測される変更対象ファイル候補を grep / Glob で探索:

```bash
grep -rln "<keyword from issue>" --include="*.{ext}" .
```

### 3.3 実装計画生成

以下の構造で計画を生成する:

```markdown
## 実装計画

### 変更対象ファイル
- `path/to/file1.ext` — 変更理由
- `path/to/file2.ext` — 変更理由

### 実装ステップ
1. ステップ 1: 〜
2. ステップ 2: 〜
3. ステップ 3: 〜

### 受入基準マッピング
- AC-1 → ステップ 1, 2
- AC-2 → ステップ 3

### 注意点
- 〜
```

### 3.4 ユーザー確認

AskUserQuestion で「この計画で進める / 計画を修正 / 中止」を選択。

「修正」の場合は計画を AskUserQuestion で再提示して合意を取る。

### 3.5 Issue Body Checklist 更新

Issue body に実装ステップを `- [ ]` 形式で追記/更新する。`issue-body-safe-update.sh` の 3-step pattern (fetch → 編集 → apply) を使い、内側 `gh issue view` 失敗時の body truncation を防ぐ:

```bash
# Step 1: fetch
fetch_output=$(bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {issue_number} 2>&1) || fetch_output=""
# fetch_output 内の tmpfile_read= / tmpfile_write= / original_length= は LLM が
# 直後の Step 2 で読み取り、Step 3 の bash block 内に literal 置換する。
# fetch 失敗時 (script 自体の非ゼロ exit、または stdout に tmpfile_read= を含まない) は
# Step 3 で WARNING を stderr に出力し、Issue body checklist 更新を skip する。
printf '%s\n' "$fetch_output"
```

fetch 成功時は `tmpfile_read` / `tmpfile_write` / `original_length` が stdout に出力される。LLM は `tmpfile_read` を Read し、`## 実装ステップ` セクションを追加/更新した body を `tmpfile_write` に Write する。Step 3 では LLM が直前の bash 出力から `{TMPFILE_READ}` / `{TMPFILE_WRITE}` / `{ORIGINAL_LENGTH}` を literal 置換する:

```bash
# Step 3: apply (LLM が tmpfile_write を書いた後)
# apply mode は safety guard (空 write / 50% 未満 shrinkage / gh edit 失敗 / diff IO エラー) を
# helper 内で plain WARNING として stderr に出力するため、orchestrator 側は stderr を観測する
# のみに留める。tmpfile 受け取り失敗時 (fetch が tmpfile パスを返さなかった) のみ
# caller 側で WARNING を出して checklist 更新を skip する。
if [ -n "{TMPFILE_READ}" ] && [ -n "{TMPFILE_WRITE}" ]; then
  apply_err=$(bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
    --issue {issue_number} \
    --tmpfile-read "{TMPFILE_READ}" \
    --tmpfile-write "{TMPFILE_WRITE}" \
    --original-length "{ORIGINAL_LENGTH}" 2>&1) || true
  if [ -n "$apply_err" ]; then
    if [ "${#apply_err}" -gt 500 ]; then
      apply_err_short="${apply_err:0:500}...truncated(${#apply_err})"
    else
      apply_err_short="$apply_err"
    fi
    echo "WARNING: Issue body の更新で診断メッセージ: $apply_err_short" >&2
  fi
else
  echo "WARNING: Issue #{issue_number}: fetch did not return tmpfile paths (gh issue view 失敗 or 空 body); Issue body checklist 更新を skip" >&2
fi
```

### 3.6 Work Memory 更新

work memory に計画を保存 (best-effort):

```bash
WM_SOURCE="plan" WM_PHASE="plan" WM_PHASE_DETAIL="実装計画作成完了" \
  WM_NEXT_ACTION="実装を開始" \
  WM_BODY_TEXT="実装計画を生成しました。{steps_count} ステップで進めます。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/tmp/rite-wm-err-$$.log
wm_rc=$?
if [ $wm_rc -eq 2 ]; then
  echo "WARNING: local-wm-update.sh exit 2 (lock failure / concurrent session contention). stderr: $(head -c 200 /tmp/rite-wm-err-$$.log 2>/dev/null | tr '\n' ' ')" >&2
fi
rm -f /tmp/rite-wm-err-$$.log
true
```

### 3.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase plan --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "実装に着手"
```

---

## ステップ 4: 実装

### 4.1 実装作業

計画のステップに沿ってコード変更を実施する。各ステップ完了ごとに:

1. 変更内容を確認（`git diff`）
2. conventional commits 規約でコミット:
   - `feat:` 新機能
   - `fix:` バグ修正
   - `docs:` ドキュメント
   - `refactor:` リファクタ
   - `chore:` 雑務
3. work memory のチェックリストを更新

### 4.2 コミット例

`language=ja` の場合:

```bash
git add <changed-files>
git commit -m "$(cat <<'EOF'
feat(scope): ステップ 1 の outcome 一文

詳細な変更内容と why を 1-2 文で。

Refs: #{issue_number}

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

`language=en` の場合は subject + body を英語で:

```bash
git commit -m "$(cat <<'EOF'
feat(scope): one-line outcome of step 1

1-2 sentences describing what changed and why.

Refs: #{issue_number}

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

LLM はステップ 1.4 で stdout に emit された `[CONTEXT] WORKFLOW_LANGUAGE=<value>` marker を直前の conversation context から読み取り、`ja` / `en` のいずれかをテンプレ分岐に literal 置換する。Bash 変数 `$language` は invocation 境界を越えると失われるため、ここでは shell 変数ではなく marker 経由で値を取得すること。

### 4.3 Work Memory 更新

各コミット後に進捗を work memory に反映 (best-effort):

```bash
WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="ステップ {N} 完了" \
  WM_NEXT_ACTION="次ステップ or 品質チェック" \
  WM_BODY_TEXT="ステップ {N}: {what} を実装しました。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/tmp/rite-wm-err-$$.log
wm_rc=$?
if [ $wm_rc -eq 2 ]; then
  echo "WARNING: local-wm-update.sh exit 2 (lock failure / concurrent session contention). stderr: $(head -c 200 /tmp/rite-wm-err-$$.log 2>/dev/null | tr '\n' ' ')" >&2
fi
rm -f /tmp/rite-wm-err-$$.log
true
```

### 4.4 すべてのステップ完了確認

すべてのステップを完了したら、変更ファイル一覧と Issue body のチェックリスト更新を確認。Sub-Issue Tasklist (`- [ ] #123 title`) は実装ステップではないため除外する:

```bash
gh issue view {issue_number} --json body --jq .body | grep "^- \[ \]" | grep -v "^- \[ \] #"
```

未完了項目がある場合は AskUserQuestion で「実装を続ける / 残項目を別 Issue に分離して PR へ / 中止」を選択。

### 4.5 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase implement --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "品質チェック (rite:lint)"
```

---

## ステップ 5: 品質チェック

### 5.1 lint 実行

`skill: "rite:lint"` を invoke する。

戻り値パターン:

- `[lint:success]` → ステップ 6 へ
- `[lint:skipped]` → ステップ 6 へ (`commands.lint` 未設定 / drift 警告のみ等)
- `[lint:error]` → AskUserQuestion で「修正して再実行 / 強制続行 / 中止」を選択
- `[lint:aborted]` → user 起因の中止。ステップ 8.5 (完了レポート) に直接遷移し、abort context を含めて workflow 終了。PR 作成はスキップ
- **default (上記 4 sentinel いずれも観測されない)** → `rite:lint` skill の load 失敗 / Skill ツール timeout / context 削減で sentinel 行が drop した可能性。`[lint:success]` 扱いで silent recovery してはならない。`echo "WARNING: rite:lint invocation returned no recognizable sentinel ([lint:success|skipped|error|aborted])" >&2` で stderr に記録のうえ、AskUserQuestion で「再試行 / 強制続行 (リスク承知) / 中止」を提示する。**「強制続行」を選んだ場合**はステップ 6 の PR 作成時に PR body 冒頭に「⚠️ Lint sentinel was dropped; this PR has NOT been lint-verified」を自動挿入する。

「修正して再実行」の場合は LLM が修正を実装してコミット → 再度 `skill: "rite:lint"`。

### 5.2 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase lint --issue {issue_number} --branch "{branch_name}" --pr 0 \
  --next "PR 作成"
```

---

## ステップ 6: PR 作成

### 6.1 push

push 失敗時は `exit 1` で bash を停止し、workflow fallthrough を防ぐ（後続の `gh pr create` が「No commits between branches」で奇怪な失敗をするのを回避）。retry / 手動継続 / 中止の判断は LLM が AskUserQuestion で行い、ユーザー選択後に再実行する:

```bash
if ! push_err=$(git push -u origin "{branch_name}" 2>&1); then
  push_err_short="${push_err:0:500}"
  echo "ERROR: git push failed: $push_err_short" >&2
  echo "[CONTEXT] PHASE_6_1_STATE=push_failed; LLM must AskUserQuestion: retry / 手動 push 完了後に続行 / 中止" >&2
  exit 1
fi
```

LLM はこの bash block の exit 1 を観測したら、AskUserQuestion で「再試行 / 手動 push 完了後に続行 / 中止」を提示する。続行選択時はステップ 6.2 から再開、中止選択時は ERROR がすでに stderr に出力されているので workflow を終了する。

### 6.2 PR 作成

`skill: "rite:pr:create"` を invoke。

戻り値パターン:

- `[pr:created:N]` → `{pr_number}` を抽出してステップ 7 へ。**この sentinel は `rite:pr:create` の出力に含まれており、本 conversation context に残るため、上位 caller (`/rite:sprint:execute` 等) から grep 可能**
- `[pr:create-failed]` → `echo "WARNING: rite:pr:create failed: {short_reason from rite:pr:create return}" >&2` で stderr に記録のうえ、AskUserQuestion で「手動作成して PR 番号を入力 / 再試行 / 中止」を提示する。
- **default (上記 2 sentinel いずれも観測されない)** → `rite:pr:create` skill の load 失敗 / sentinel drop の可能性。`[pr:created:N]` 扱いで silent continue してはならない。`echo "WARNING: rite:pr:create returned no recognizable sentinel" >&2` のうえ AskUserQuestion で「手動作成して PR 番号を入力 / 再試行 / 中止」を提示する。

### 6.3 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase pr --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
  --next "レビュー/修正ループ"
```

---

## ステップ 7: レビュー/修正ループ

### 7.1 review

> **Pre-invoke flow-state update (MANDATORY)**: skill 呼び出し直前に必ず実行する。
> ```bash
> bash {plugin_root}/hooks/flow-state.sh set \
>   --phase review --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
>   --next "fix or ready 判定"
> ```

`skill: "rite:pr:review", args: "{pr_number}"` を invoke。

戻り値パターン:

- `[review:mergeable]` → ステップ 8 へ
- `[review:fix-needed:N]` → ステップ 7.2 へ
- **default (上記 2 sentinel いずれも観測されない)** → `rite:pr:review` skill の load 失敗 / sentinel drop。silent continue してはならない。`echo "WARNING: rite:pr:review returned no recognizable sentinel ([review:mergeable|fix-needed:N])" >&2` のうえ AskUserQuestion で「再試行 / 強制続行 (リスク承知) / 中止」を提示。

### 7.2 fix

> **Pre-invoke flow-state update (MANDATORY)**: skill 呼び出し直前に必ず実行する。
> ```bash
> bash {plugin_root}/hooks/flow-state.sh set \
>   --phase fix --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
>   --next "再レビュー or ready 判定"
> ```

`skill: "rite:pr:fix", args: "{pr_number}"` を invoke。

戻り値パターン:

- `[fix:pushed]` → ステップ 7.1 へ戻る（再レビュー）
- `[fix:pushed-wm-stale]` → AskUserQuestion で「stale work-memory のまま re-review (推奨) / wm を refresh してから re-review / 中止」を選択。stale context のまま review すると review が古い情報に基づく可能性があることをユーザーに明示する
- `[fix:issues-created:N]` → fix 中に新規 Issue が N 件作成された (scope-creep finding 抽出など)。完了レポートに作成 Issue 番号を含めてからステップ 7.1 へ戻る
- `[fix:replied-only]` → fix iteration は LLM 修正なしでレビュー返信のみで完結 (push 未実施)。AskUserQuestion で「ステップ 8 (Ready 化) へ進む / 追加の修正を依頼 / 中止」を提示し、merge OK の判断はユーザーに委ねる
- `[fix:error]` → AskUserQuestion で「手動修正してから再レビュー / 中止」
- **default (上記 5 sentinel いずれも観測されない)** → `rite:pr:fix` skill の load 失敗 / sentinel drop。silent continue してはならない。`echo "WARNING: rite:pr:fix returned no recognizable sentinel ([fix:pushed|pushed-wm-stale|issues-created:N|replied-only|error])" >&2` のうえ AskUserQuestion で「再試行 / 強制続行 (リスク承知) / 中止」を提示。

### 7.3 ループ上限

7.1 ↔ 7.2 のループが 5 回に達したら AskUserQuestion で「続行 / 中止」を選択。

### 7.4 flow-state 更新パターン

ステップ 7.1 / 7.2 の各冒頭に inline 展開した Pre-invoke flow-state update がこの phase の canonical site。本セクションは記録目的で、`--phase review` / `--phase fix` のいずれかを selected step に応じて書き込む。

---

## ステップ 8: Ready & 完結

### 8.1 Ready 化確認

AskUserQuestion で「PR を Ready for review に変更する / Draft のまま / 中止」を選択。

### 8.2 Ready 化

`skill: "rite:pr:ready", args: "{pr_number}"` を invoke。

戻り値パターン:

- `[ready:completed]` → ステップ 8.3 へ
- `[ready:error]` → AskUserQuestion で「手動 Ready 化 / 中止」
- **default (上記 2 sentinel いずれも観測されない)** → `rite:pr:ready` skill の load 失敗 / sentinel drop。silent continue してはならない。`echo "WARNING: rite:pr:ready returned no recognizable sentinel ([ready:completed|error])" >&2` のうえ AskUserQuestion で「再試行 / 強制続行 (リスク承知) / 中止」を提示。

### 8.3 Projects Status In Review

`rite-config.yml.github.projects.enabled: true` の場合。canonical JSON pattern（[`projects-status-update-callsites.md`](./references/projects-status-update-callsites.md) Callsite 2 と同形）。`.result` inspection を Common contract §5 に従って実行し、失敗時は WARNING を stderr に出力:

```bash
status_result=$(bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
    --argjson issue {issue_number} \
    --arg owner "{owner}" \
    --arg repo "{repo}" \
    --argjson project_number {project_number} \
    --arg status "In Review" \
    --argjson auto_add false \
    --argjson non_blocking true \
    '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>&1) || status_result="{\"result\":\"failed\",\"warnings\":[\"projects-status-update.sh fatal exit\"]}"
status_value=$(printf '%s' "$status_result" | jq -r '.result // "failed"' 2>/dev/null || echo "failed")
case "$status_value" in
  updated) ;;
  skipped_not_in_project)
    echo "WARNING: Issue #{issue_number} は Project に未登録 (Callsite 2)" >&2
    ;;
  failed|*)
    printf '%s' "$status_result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do echo "WARNING: $w" >&2; done
    ;;
esac
```

### 8.4 親 Issue の完結判定

ステップ 1.2 で親 Issue を検出していた場合、親の trackedIssues 状態を再確認:

```bash
gh api graphql -f owner={owner} -f repo={repo} -F number={parent_issue_number} -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        trackedIssues(first: 100) {
          nodes { number state }
          totalCount
        }
      }
    }
  }' --jq '.data.repository.issue.trackedIssues.nodes'
```

すべての子 Issue (上記出力の各 node) が `state: "CLOSED"` なら AskUserQuestion で「親 Issue を完了とする / そのまま」を選択。完了選択時 (両 command を実行、片方失敗時も warning + continue で非ブロッキング):

```bash
# Step 1: gh issue close — exit code を別変数で捕捉（stderr/stdout は close_err、成功時も URL が含まれるため空判定は不可）
if close_err=$(gh issue close {parent_issue_number} \
    --comment "すべての子 Issue が完了したため、親 Issue を完了します。" 2>&1); then
  close_rc=0
else
  close_rc=$?
  echo "WARNING: gh issue close failed for parent #{parent_issue_number} (rc=$close_rc): $close_err" >&2
fi

# Step 2: Projects Status → Done — `.result` inspection (Callsite 3 / Common contract §5)
status_result=$(bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
    --argjson issue {parent_issue_number} \
    --arg owner "{owner}" \
    --arg repo "{repo}" \
    --argjson project_number {project_number} \
    --arg status "Done" \
    --argjson auto_add false \
    --argjson non_blocking true \
    '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>&1) || status_result="{\"result\":\"failed\",\"warnings\":[\"projects-status-update.sh fatal exit\"]}"
status_value=$(printf '%s' "$status_result" | jq -r '.result // "failed"' 2>/dev/null || echo "failed")
case "$status_value" in
  updated) ;;
  skipped_not_in_project)
    echo "WARNING: parent Issue #{parent_issue_number} は Project に未登録 (Callsite 3, gh issue close rc=$close_rc)" >&2
    ;;
  failed|*)
    printf '%s' "$status_result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do echo "WARNING: $w" >&2; done
    ;;
esac
```

### 8.5 完了レポート出力

```markdown
## 完了報告

| 項目 | 内容 |
|------|------|
| Issue | #{issue_number} {title} |
| ブランチ | `{branch_name}` |
| PR | #{pr_number} {pr_url} |
| 状態 | Ready for review |

### 実装ステップ
- [x] ステップ 1: 〜
- [x] ステップ 2: 〜
- [x] ステップ 3: 〜

### 次のアクション
- レビュー後、`/rite:pr:fix {pr_number}` で再対応 or merge 後 `/rite:pr:cleanup` でクリーンアップ
```

### 8.6 flow-state 完結

`--preserve-error-count` はこの patch で `.error_count` を 0 にリセットせず保持する general flag。現時点で `.error_count` を読む reader は無いが、再導入時の累積カウントが意図せずリセットされないよう reserved API として保持する。

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase completed --active false --next "none" \
  --if-exists --preserve-error-count
```

---

## エラー時の方針

- どのステップで止まっても flow-state ファイル (`.rite/sessions/{session_id}.flow-state` / legacy `.rite-flow-state` fallback) に `phase` が記録されているので、ユーザーは `/rite:resume` で対応ステップから再開できる (`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) を参照)
- 各ステップは「Bash 実行 → 結果確認 → 次へ」のフラットな逐次フロー
- AskUserQuestion で明示的に「中止」が選ばれた場合のみ workflow 終了
- bash command 失敗時は stderr に `WARNING` または `ERROR` プレフィックスを残し、復旧不能なケースのみ workflow を停止する

## E2E Output Minimization

ステップ間の出力は最小限に。各ステップは:

- 開始時に 1 行 status（「ステップ N: 〜」）
- bash / skill invoke の結果
- 完了時に sentinel pattern（外部 API 的に有用なもののみ: `[lint:*]`, `[pr:created:N]`, `[review:*]`, `[fix:*]`, `[ready:completed]`）

中間説明・サマリ・guidance text は省略する。

## Interruption / Resumption

- ブランチ・work memory・Projects Status・実装計画は途中状態でも保持される
- 中断時は `/rite:resume {issue_number}` で復帰
- phase → step mapping は `commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) が SoT (例: `phase=plan` で中断 → ステップ 3 から再開、`phase=fix` で中断 → ステップ 7.2 から)

## Standalone Usage

各 skill は単独でも呼び出せる:

- `/rite:lint` — 品質チェック
- `/rite:pr:create` — Issue なしで PR 作成
- `/rite:pr:review {pr_number}` — 既存 PR のレビュー
- `/rite:pr:fix {pr_number}` — レビューフィードバックへの対応
- `/rite:pr:ready {pr_number}` — Draft → Ready 化
- `/rite:pr:cleanup {pr_number}` — merge 後のクリーンアップ (完了レポートで次アクションとして案内する)

## Error Handling

- Issue not found → エラー表示、`gh issue list` を提案
- Closed Issue → AskUserQuestion で reopen / cancel
- ブランチ作成失敗 → `git status` で状態確認
- Projects 未設定 → warning 表示、skip
- API エラー → 3 回まで指数バックオフでリトライ、それでも失敗なら skip

詳細は [GraphQL Helpers](../../references/graphql-helpers.md#error-handling) を参照。
