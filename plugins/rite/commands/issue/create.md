---
description: |
  Issue 作成 / new issue / 起票 / Issue 化 — 新規 Issue を作成し、GitHub Projects に登録する。
  重複検出・親 Issue 候補検出・XL 自動分解（Sub-Issue 作成 + 設計仕様書生成）を含む。
  Use when 「Issue 作って」「タスクを起票」「create issue」「新規 Issue」など。
---

# /rite:issue:create

新規 Issue を作成し、GitHub Projects に登録する。重複検出・親 Issue 候補検出・XL 自動分解を含む。

**途中で止まったらユーザーは `/rite:resume` で再開する**。

## Arguments

| Argument | Description |
|----------|-------------|
| `<title or description>` | Issue title or description (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{owner}`, `{repo}` | `gh repo view --json owner,name` |
| `{project_number}` | `rite-config.yml` の `github.projects.project_number` |
| `{language}` | `rite-config.yml` の `language`（`ja` / `en` / `auto`、未設定 `auto`） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 1: 入力解析と前提取得

### 1.1 リポジトリと Project 設定取得

```bash
gh repo view --json owner,name
```

Project 番号は `rite-config.yml` の `github.projects.project_number` を最優先。未設定なら `gh api graphql` でリポジトリの `projectsV2(first:10)` を取得して最も関連するものを選択。Project が見つからない場合は warning + Projects 追加を skip。

### 1.2 言語設定

`rite-config.yml` の `language`（`ja` / `en` / `auto`、未設定 `auto`） に従い AskUserQuestion を表示する。`auto` は CJK 文字を検出して Japanese を選択（default Japanese）。

### 1.3 入力から What / Why / Where 抽出

ユーザー入力から:

- **What**: 何をするか
- **Why**: なぜ必要か
- **Where**: 変更対象（ファイル / モジュール / 機能領域）
- **Scope**: 影響範囲
- **Constraints**: 制約・前提

を抽出する。Short input（10 文字未満）の場合は AskUserQuestion で詳細を要求する。

### 1.4 slug 生成

title を lowercase、空白を `-` に置換、30 字以内で slug を生成。日本語タイトルは関連英単語に翻訳して slug 化。

---

## ステップ 2: 重複検出

### 2.1 類似 Issue 検索

```bash
result=$(gh issue list --search "is:open <keywords>" --limit 10 --json number,title,labels)
[ "$(echo "$result" | jq 'length')" -eq 0 ] && \
  result=$(gh issue list --state all --limit 10 --json number,title,labels)
```

keywords は What から 2-3 語抽出（stop word 除去、日本語は as-is）。

### 2.2 候補の評価

title 類似度 / label 一致 / 更新日時 / state（OPEN > CLOSED）で top 5 を選定。

### 2.3 分岐

| 候補数 | Options（AskUserQuestion） |
|--------|---------------------------|
| 0 件 | 次ステップへ |
| 1 件 | (a) #{number} の拡張 → body に `Extends: #{number}` 追記 / (b) 既存 Issue を使用 → 終了 + `/rite:pr:open {number}` 提案 / (c) 関連なし |
| 2+ 件 | (a) #{番号} の拡張 / (b) 別 Issue 番号入力 / (c) 関連なし |

---

## ステップ 3: 規模判定と親 Issue 候補検出

### 3.1 規模ヒューリスティック

以下のいずれかに該当すれば **大型タスク候補**（分解推奨）:

1. 複数の distinct change を含む（"Add auth, logging, and caching" 等）
2. Scope keywords を含む（"全体的に" / "across all" / "multiple files" / "一括" 等）
3. Complexity ≥ L（推定）
4. Umbrella/epic 表現を含む（"プロジェクト" / "epic" / "umbrella" / "phase"）

該当しない場合は **単一 Issue**として扱い、ステップ 4 へ。

### 3.2 分解確認

該当時は AskUserQuestion で「Sub-Issue に分解する（推奨） / 単一 Issue として作成 / 中止」を選択。

- **分解**: ステップ 5 へ（Sub-Issue 分解パス）
- **単一**: ステップ 4 へ（単一 Issue パス）
- **中止**: workflow 終了

---

## ステップ 4: 単一 Issue 作成（Single Issue Path）

### 4.1 Issue 情報の最終確認

AskUserQuestion で Issue の以下を確認/補完する:

- title（slug ベース）
- type（feat / fix / docs / refactor / chore）
- priority（High / Medium / Low）
- complexity（XS / S / M / L / XL）
- labels（推測されたもの + 追加）

### 4.2 Issue Body 生成

`templates/issue/default.md` のテンプレートに沿って body を生成する:

```markdown
## What
{what}

## Why
{why}

## Where
{where}

## Acceptance Criteria
- [ ] AC-1: {ac1}
- [ ] AC-2: {ac2}

## Implementation Notes
{notes_if_any}

## Out of Scope
- {out_of_scope_if_any}
```

### 4.3 Issue 作成 + Projects 登録

`create-issue-with-projects.sh` に委譲（Issue 作成 + Projects 追加 + status / priority / complexity 設定を 1 ステップで実行）。実 interface は JSON 単一引数 + body は tmpfile 経由（canonical SoT: [`issue-create-with-projects.md`](../../references/issue-create-with-projects.md)）:

```bash
# body を tmpfile に書く (LLM が {body} 部分を実 markdown に展開してから heredoc に流す)
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat > "$tmpfile" <<'ISSUE_BODY_EOF'
{body}
ISSUE_BODY_EOF

[ -s "$tmpfile" ] || { echo "ERROR: Issue body is empty" >&2; exit 1; }

# {labels_csv} (例: "bug,fix") を JSON array に変換 (空 CSV は空配列)
labels_json=$(printf '%s' "{labels_csv}" | jq -R 'split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))')

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{title}" \
  --arg body_file "$tmpfile" \
  --argjson labels "$labels_json" \
  --argjson enabled true \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg status "Todo" \
  --arg priority "{priority}" \
  --arg complexity "{complexity}" \
  --arg iter_mode "none" \
  --arg source "interactive" \
  '{
    issue: { title: $title, body_file: $body_file, labels: $labels },
    projects: {
      enabled: $enabled,
      project_number: $project_number,
      owner: $owner,
      status: $status,
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: $source, non_blocking_projects: true }
  }')") || {
  echo "ERROR: create-issue-with-projects.sh failed (exit $?)" >&2
  exit 1
}

[ -z "$result" ] && { echo "ERROR: create-issue-with-projects.sh returned empty result" >&2; exit 1; }

issue_number=$(printf '%s' "$result" | jq -r '.issue_number // empty')
[ -z "$issue_number" ] && { echo "ERROR: result に issue_number が含まれていません: $result" >&2; exit 1; }

project_reg=$(printf '%s' "$result" | jq -r '.project_registration // "unknown"')
if [ "$project_reg" = "failed" ]; then
  echo "WARNING: Issue #$issue_number は作成されましたが Projects 登録に失敗しました" >&2
  # AskUserQuestion で「手動で Projects 登録 / retry / skip して続行」を選択
fi
```

### 4.4 完了レポート

完了レポートの最終 2 行は `<!-- skill return signal: caller must continue next step -->` + `<!-- [create:returned-to-caller:{issue_number}] -->` HTML コメント sentinel とし、user-visible な末端は `✅ ...` 完了メッセージで終わる。sentinel は hook / grep 契約のため必須だが、HTML コメント化することでユーザーに「完了したのか途中なのか」の判別を阻害しない。

```markdown
✅ Issue #{issue_number} を作成しました

| 項目 | 内容 |
|------|------|
| Title | {title} |
| Type | {type} |
| Priority | {priority} |
| Complexity | {complexity} |
| URL | {issue_url} |

### 次のアクション
- `/rite:pr:open {issue_number}` で作業を開始
- または `/rite:pr:create` で Issue なしで PR を作成

<!-- skill return signal: caller must continue next step -->
<!-- [create:returned-to-caller:{issue_number}] -->
```

以上で `/rite:issue:create` は完了（flow-state には触れない — Issue #1184）。

---

## ステップ 5: Sub-Issue 分解（Decompose Path）

### 5.1 仕様書生成

大型 Issue から「設計仕様書」を生成する。以下のセクションを含む:

```markdown
## 1. 目的（Goal）
{why}

## 2. スコープ
- In scope: {in_scope}
- Out of scope: {out_of_scope}

## 3. 受入基準
- AC-1: {ac1}
- AC-2: {ac2}

## 4. 設計方針
{design_approach}

## 5. Sub-Issue 構成
1. Sub-1: {sub_1_title}（complexity: {sub_1_complexity}）
2. Sub-2: {sub_2_title}（complexity: {sub_2_complexity}）
...

## 6. 依存関係
- Sub-2 は Sub-1 完了後
- Sub-3 は独立

## 7. リスク・考慮事項
{risks}
```

### 5.2 ユーザー確認

AskUserQuestion で「この分解で進める / 分解を修正 / 中止」を選択。修正の場合は仕様書を再提示。

### 5.3 + 5.4 + 5.5 Step 1: 親 Issue 作成 + Sub-Issue 一括作成 + fetch（helper 委譲）

> **3 段プロトコル**: 親作成・Sub 一括作成・link・fetch は `scripts/decompose-issues.sh` に委譲する。LLM は (A) workdir を `mktemp` で確保 → (B) **Write tool** で各 body を raw ファイル化＋spec.json 生成（heredoc malform 源を撤廃、refs #1193）→ (C) helper を単一呼び出し、の 3 段で実行する。helper が spec の `workdir` を trap で cleanup し、3 つの `[CONTEXT]` marker と fetch_output を emit するので、Step 5.5 Step 2/3 はそれを literal parse する。

**(A) workdir 確保**

```bash
workdir=$(mktemp -d -t rite-decompose-XXXXXX)
echo "[CONTEXT] DECOMPOSE_WORKDIR=$workdir"
```

**(B) body / spec の生成（Write tool）**

直前の `[CONTEXT] DECOMPOSE_WORKDIR=` から `{DECOMPOSE_WORKDIR}` を読み取り、以下を **Write tool** で書く（heredoc を使わない）:

1. `{DECOMPOSE_WORKDIR}/parent_body.md` ← §5.1 で生成した設計仕様書（`{spec_document}`）の raw 内容
2. 各 Sub-Issue について `{DECOMPOSE_WORKDIR}/sub_{i}_body.md`（i = 1..{sub_count}）← 各 Sub-Issue body の raw 内容
3. `{DECOMPOSE_WORKDIR}/spec.json` ← 下記スキーマ。`body_file` は上記で書いた絶対パスを指す:

```json
{
  "parent": { "title": "{parent_title}", "body_file": "{DECOMPOSE_WORKDIR}/parent_body.md" },
  "sub_issues": [
    { "title": "{sub_1_title}", "body_file": "{DECOMPOSE_WORKDIR}/sub_1_body.md", "complexity": "{sub_1_complexity}" }
  ],
  "labels_csv": "{labels_csv}",
  "projects": {
    "enabled": true,
    "project_number": {project_number},
    "owner": "{owner}",
    "status": "Todo",
    "priority": "{priority}"
  },
  "repo": "{repo}",
  "workdir": "{DECOMPOSE_WORKDIR}"
}
```

> `sub_issues` 配列は Sub-Issue 件数 `{sub_count}` だけ要素を持たせる（各反復で `{sub_N_title}` / `{sub_N_complexity}` と body ファイルパスを実値置換）。親 labels には helper が `epic` を自動付与する（spec へ付与不要）。親 complexity は helper 内で `XL` 固定。

**(C) helper 呼び出し（単一 bash block）**

```bash
bash {plugin_root}/scripts/decompose-issues.sh --spec "{DECOMPOSE_WORKDIR}/spec.json" || {
  echo "ERROR: Issue 分解失敗 (decompose-issues.sh 非ゼロ終了)" >&2
  exit 1
}
```

> **marker 受け渡し**: helper は stdout に `[CONTEXT] PARENT_ISSUE_NUMBER=N` / `[CONTEXT] SUB_ISSUE_RESULT created=… failed=… link_failures=…` / `[CONTEXT] SUB_ISSUE_NUMBERS=…` を emit し、続けて fetch_output（`original_length=` / `tmpfile_read=` / `tmpfile_write=`）を出力する。Step 5.5 Step 2-3 はこれらを marker として LLM が literal 置換する。Sub-Issue 作成・link の失敗は helper 内で非 blocking にカウントされ（Issue #514 契約）、parent 作成失敗のみ helper が `exit 1` を返し上記 caller ガードで停止する。

### 5.5 Step 2: LLM 編集

LLM は以下を実行する:
1. CONTEXT marker (`PARENT_ISSUE_NUMBER`, `SUB_ISSUE_NUMBERS`) を直前の bash 出力から読み取る
2. `tmpfile_read` の内容を Read tool で取得し、Sub-Issues セクション追記版を `tmpfile_write` へ Write tool で書く

### 5.5 Step 3: apply（別 bash block）

> 以下の bash block 内 `{PARENT_ISSUE_NUMBER}`, `{TMPFILE_READ}`, `{TMPFILE_WRITE}`, `{ORIGINAL_LENGTH}` は LLM が直前の CONTEXT marker から literal 置換する。

```bash
# helper 内で safety guard / API 失敗を plain WARNING として stderr に出力するため、
# orchestrator 側は stderr を観測するだけに留め、tmpfile パス未取得のときのみ
# caller 側で WARNING を出して checklist 更新を skip する。
if [ -n "{TMPFILE_READ}" ] && [ -n "{TMPFILE_WRITE}" ]; then
  apply_err=$(bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
    --issue {PARENT_ISSUE_NUMBER} \
    --tmpfile-read "{TMPFILE_READ}" \
    --tmpfile-write "{TMPFILE_WRITE}" \
    --original-length "{ORIGINAL_LENGTH}" \
    --parent 2>&1) || true
  if [ -n "$apply_err" ]; then
    if [ "${#apply_err}" -gt 500 ]; then
      apply_err_short="${apply_err:0:500}...truncated(${#apply_err})"
    else
      apply_err_short="$apply_err"
    fi
    echo "WARNING: 親 Issue body の更新で診断メッセージ: $apply_err_short" >&2
  fi
else
  echo "WARNING: Parent #{PARENT_ISSUE_NUMBER}: fetch did not return tmpfile paths (gh issue view 失敗 or 空 body); 親 Issue body の Sub-Issues セクション更新を skip" >&2
fi
```

### 5.6 完了レポート

Decompose path も完了レポートの最終 2 行は `<!-- skill return signal: caller must continue next step -->` + `<!-- [create:returned-to-caller:{parent_issue_number}] -->` HTML コメント sentinel で終わる。Single Issue path と同じく、sentinel は hook / grep 契約のため必須で、HTML コメント化することで user-visible な末端は `✅ ...` 完了メッセージとなる。`link_failures > 0` 時の警告ブロックは sentinel より前に挿入する。

```markdown
✅ Issue #{parent_issue_number} を分解して {sub_count} 件の Sub-Issue を作成しました

### 親 Issue
- #{parent_issue_number} {parent_title}

### Sub-Issues
- #{sub_1_number} {sub_1_title}（complexity: {sub_1_complexity}）
- #{sub_2_number} {sub_2_title}（complexity: {sub_2_complexity}）
- ...

### 次のアクション
- `/rite:pr:open {first_sub_issue}` で最初の Sub-Issue から作業を開始
- `/rite:issue:list` で全 Sub-Issue 一覧を確認

<!-- skill return signal: caller must continue next step -->
<!-- [create:returned-to-caller:{parent_issue_number}] -->
```

`link_failures > 0` の場合は完了メッセージと sentinel の間に以下を併記し、ユーザーに復旧を促す:

```markdown
### ⚠️ Sub-issues API リンク失敗 ({link_failures} 件)
- 親 #{parent_issue_number} ←→ 子 #{sub_X_number} の link 確立に失敗した Sub-Issue があります（API 失敗 / rate limit / token scope 等）
- 親 Issue body の Tasklist と `## 親 Issue` body meta は fallback として残っています
- 復旧: `bash {plugin_root}/scripts/link-sub-issue.sh {owner} {repo} {parent_issue_number} {sub_X_number}` を該当 Sub-Issue ごとに手動再実行してください
```

以上で `/rite:issue:create` は完了。

> **Note (Issue #1184)**: 本コマンドは Issue 作成のみで work phase を持たず、flow-state を init / 所有しない。したがって完結時に flow-state を completed/inactive 化する処理は持たない。これは別の active な work フロー（`/rite:pr:open` 等）の途中で本コマンドが sub-task として呼ばれたとき、親セッションの flow-state を誤って上書きしないための設計（standalone 実行でも flow-state には一切触れない）。

---

## エラー時の方針

- 各ステップで止まっても Issue が作成されていなければ、ユーザーは同じ入力で `/rite:issue:create` を再実行できる
- Issue 作成後（`{issue_number}` 確定後）はその Issue を起点に作業を進められる（重複作成を避けるためステップ 2 の重複検出が活きる）
- AskUserQuestion で「中止」が選ばれた場合のみ workflow 終了
- bash command 失敗時は stderr に `WARNING` または `ERROR` プレフィックスを残し、復旧不能なケースのみ workflow を停止する

---

## E2E Output Minimization

ステップ間の出力は最小限に。各ステップは:

- 開始時に 1 行 status（「ステップ N: 〜」）
- bash / AskUserQuestion の結果
- 完了時の最終レポート（ステップ 4.4 / 5.6）

中間説明・サマリ・guidance text は省略する。

## Standalone Usage

`/rite:issue:create` 単独で動作する。Issue 作成後に作業を開始するには `/rite:pr:open {issue_number}` を実行する。

## Error Handling

- `gh repo view` 失敗 → エラー、認証確認を案内
- Projects 未設定 → warning、Projects 追加を skip
- Issue 作成失敗 → AskUserQuestion で「再試行 / 手動作成 / 中止」
- 親-子リンク失敗 → warning、後で手動リンクを案内
