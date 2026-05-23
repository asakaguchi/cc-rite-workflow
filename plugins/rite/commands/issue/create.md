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
| 1 件 | (a) #{number} の拡張 → body に `Extends: #{number}` 追記 / (b) 既存 Issue を使用 → 終了 + `/rite:issue:start {number}` 提案 / (c) 関連なし |
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

完了レポートの最終行は `<!-- [create:completed:{issue_number}] -->` HTML コメント sentinel とし、user-visible な末端は `✅ ...` 完了メッセージで終わる。sentinel は hook / grep 契約のため必須だが、HTML コメント化することでユーザーに「完了したのか途中なのか」の判別を阻害しない。

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
- `/rite:issue:start {issue_number}` で作業を開始
- または `/rite:pr:create` で Issue なしで PR を作成

<!-- [create:completed:{issue_number}] -->
```

ステップ 6（共通完結処理）へ。

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

### 5.3 + 5.4 + 5.5 Step 1: 親 Issue 作成 + Sub-Issue 一括作成 + fetch（単一 bash block）

> **⚠️ CRITICAL — Bash tool invocation 境界**: 本セクションの bash code block は **単一の Bash tool invocation で連続実行する**。`tmpdir` / `parent_issue_number` / `created_count` 等のシェル変数は Bash 呼び出しを跨ぐと消失する (Claude Code Bash tool は呼び出しごとに新シェルプロセス)。LLM は本 block を分割実行してはならない。次の Step 2 (LLM 編集) と Step 3 (apply) は CONTEXT marker 経由で値を受け渡す。
>
> Sub-Issue ループの placeholder protocol: `{sub_count}` / `{REPEAT_FOR_EACH_SUB_ISSUE}` ... `{END_REPEAT}` の間を、LLM が反復回数だけ実値展開して bash literal を生成する。`{sub_N_title}` `{sub_N_body}` `{sub_N_complexity}` を各反復で実値置換。

```bash
# ============================================================
# Step 5.3 親 Issue 作成
# ============================================================
tmpdir=$(mktemp -d -t rite-create-XXXXXX)
# Centralize cleanup via trap so every exit path (success, error, SIGINT, SIGTERM)
# removes the tmpdir. Per-branch `rm -rf` calls in early-exit arms are easy to
# forget and leak the tmpdir on signal-interrupt.
trap 'rm -rf "$tmpdir"' EXIT INT TERM
parent_tmpfile="$tmpdir/parent_body.md"
cat > "$parent_tmpfile" <<'PARENT_BODY_EOF'
{spec_document}
PARENT_BODY_EOF

[ -s "$parent_tmpfile" ] || { echo "ERROR: parent Issue body is empty" >&2; rm -rf "$tmpdir"; exit 1; }

labels_json=$(printf '%s' "epic,{labels_csv}" | jq -R 'split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))')

parent_result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{parent_title}" \
  --arg body_file "$parent_tmpfile" \
  --argjson labels "$labels_json" \
  --argjson enabled true \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg status "Todo" \
  --arg priority "{priority}" \
  --arg complexity "XL" \
  --arg iter_mode "none" \
  --arg source "xl_decomposition" \
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
  echo "ERROR: 親 Issue 作成失敗" >&2
  rm -rf "$tmpdir"
  exit 1
}

parent_issue_number=$(printf '%s' "$parent_result" | jq -r '.issue_number // empty')
[ -z "$parent_issue_number" ] && { echo "ERROR: 親 Issue の issue_number 取得失敗: $parent_result" >&2; rm -rf "$tmpdir"; exit 1; }

# ============================================================
# Step 5.4 Sub-Issue 一括作成
# ============================================================
created_count=0
failed_count=0
link_failures=0
created_numbers=()
expected_sub_count={sub_count}
# Surface jq parse failure (malformed CSV / embedded newline) instead of
# silently falling back to an empty labels array — a silent empty would
# strip the user's intended labels without any visible signal.
sub_labels_json=$(printf '%s' "{labels_csv}" | jq -R 'split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))' 2>/dev/null) || {
  echo "WARNING: labels_csv の jq パースに失敗。labels を空で続行: {labels_csv}" >&2
  sub_labels_json="[]"
}

i=0
{REPEAT_FOR_EACH_SUB_ISSUE}
i=$((i + 1))
sub_tmpfile="$tmpdir/sub_${i}_body.md"
cat > "$sub_tmpfile" <<'SUB_BODY_EOF'
{sub_N_body}
SUB_BODY_EOF
if [ ! -s "$sub_tmpfile" ]; then
  echo "WARNING: Sub-Issue '{sub_N_title}' body が空、skip" >&2
  failed_count=$((failed_count + 1))
else
  sub_result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
      --arg title "{sub_N_title}" \
      --arg body_file "$sub_tmpfile" \
      --argjson labels "$sub_labels_json" \
      --argjson enabled true \
      --argjson project_number {project_number} \
      --arg owner "{owner}" \
      --arg status "Todo" \
      --arg priority "{priority}" \
      --arg complexity "{sub_N_complexity}" \
      --arg iter_mode "none" \
      --arg source "xl_decomposition" \
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
      }')" 2>&1)
  create_rc=$?
  if [ $create_rc -ne 0 ]; then
    echo "WARNING: Sub-Issue '{sub_N_title}' の作成に失敗: $sub_result" >&2
    failed_count=$((failed_count + 1))
  else
    sub_number=$(printf '%s' "$sub_result" | jq -r '.issue_number // empty')
    if [ -z "$sub_number" ] || [ "$sub_number" = "null" ]; then
      echo "WARNING: Sub-Issue '{sub_N_title}' の result に issue_number 無し: $sub_result" >&2
      failed_count=$((failed_count + 1))
    else
      # Sub-issues API linkage — canonical SoT [`sub-issue-link-handler.md`](../../references/sub-issue-link-handler.md)
      # Variant B (counting). link-sub-issue.sh は非 blocking failure 時に exit 0 + status="failed"
      # を返す契約のため、bash exit code ではなく JSON stdout の `.status` を inspect すること。
      # ⚠️ DRIFT 警告: 本 case 文を編集する際は SoT `references/sub-issue-link-handler.md`
      # Variant B を同時に更新する責務がある。
      # link-sub-issue.sh normally returns JSON on stdout (status="failed" for
      # non-blocking failures). Only construct fallback JSON on fatal exit.
      # Build it via `jq -n --arg` so embedded `"` in stderr cannot break the
      # JSON the caller will parse.
      link_result=$(bash {plugin_root}/scripts/link-sub-issue.sh \
          "{owner}" "{repo}" "$parent_issue_number" "$sub_number" 2>&1) || link_result=$(jq -n \
            --arg err "$link_result" \
            '{status:"failed",message:"link-sub-issue.sh fatal exit",warnings:[$err]}')
      link_status=$(printf '%s' "$link_result" | jq -r '.status // "failed"' 2>/dev/null || echo "failed")
      link_msg=$(printf '%s' "$link_result" | jq -r '.message // ""' 2>/dev/null || echo "")
      case "$link_status" in
        ok|already-linked)
          echo "✅ $link_msg"
          ;;
        failed)
          printf '%s' "$link_result" | jq -r '.warnings[]?' 2>/dev/null \
            | while read -r w; do echo "⚠️ $w" >&2; done
          echo "⚠️ Sub-issues API linkage failed for #$sub_number; body meta fallback in place" >&2
          link_failures=$((link_failures + 1))
          ;;
        *)
          # 未知 status を silent 通過させない (Issue #514 MUST NOT)
          echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
          link_failures=$((link_failures + 1))
          ;;
      esac

      created_numbers+=("$sub_number")
      created_count=$((created_count + 1))
    fi
  fi
fi
{END_REPEAT}

# ============================================================
# zero-iteration guard (silent placeholder expansion failure 検出)
# ============================================================
if [ "$created_count" -eq 0 ] && [ "$expected_sub_count" -gt 0 ]; then
  echo "WARNING: Expected $expected_sub_count Sub-Issues but created 0 (placeholder expansion or shell loop failure). parent=#$parent_issue_number" >&2
fi

# ============================================================
# Loop-abort sanity check: if created+failed != expected, the loop dropped
# iterations to an unexpected shell error (set -e upstream, jq crash, signal),
# and the partial state would otherwise go silently missing from the report.
# ============================================================
loop_processed=$((created_count + failed_count))
if [ "$loop_processed" -ne "$expected_sub_count" ] && [ "$expected_sub_count" -gt 0 ]; then
  echo "WARNING: Loop processed $loop_processed of $expected_sub_count expected Sub-Issues (created=$created_count, failed=$failed_count). Possible mid-loop abort. parent=#$parent_issue_number" >&2
fi

# ============================================================
# Step 5.5 Step 1: fetch (親 Issue body の取得)
# ============================================================
fetch_output=$(bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue "$parent_issue_number" --parent 2>&1) || fetch_output=""

# ============================================================
# CONTEXT markers — 後続 Step 2 (LLM 編集) と Step 3 (apply) に値を受け渡す
# ============================================================
echo "[CONTEXT] PARENT_ISSUE_NUMBER=$parent_issue_number"
echo "[CONTEXT] SUB_ISSUE_RESULT created=$created_count failed=$failed_count link_failures=$link_failures"
echo "[CONTEXT] SUB_ISSUE_NUMBERS=${created_numbers[*]}"
# tmpfile_read=, tmpfile_write=, original_length= は fetch_output に含まれる
printf '%s\n' "$fetch_output"
```

> **シェル変数の受け渡し**: 上記 block 内では `tmpdir` / `parent_issue_number` / `created_count` 等が連続して使われる。Step 5.5 Step 2-3 では Block 外に出るため、`[CONTEXT] PARENT_ISSUE_NUMBER=N` と fetch_output 内の `tmpfile_read=...` 等を marker として LLM が literal 置換する。

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

Decompose path も完了レポートの最終行は `<!-- [create:completed:{parent_issue_number}] -->` HTML コメント sentinel で終わる。Single Issue path と同じく、sentinel は hook / grep 契約のため必須で、HTML コメント化することで user-visible な末端は `✅ ...` 完了メッセージとなる。`link_failures > 0` 時の警告ブロックは sentinel より前に挿入する。

```markdown
✅ Issue #{parent_issue_number} を分解して {sub_count} 件の Sub-Issue を作成しました

### 親 Issue
- #{parent_issue_number} {parent_title}

### Sub-Issues
- #{sub_1_number} {sub_1_title}（complexity: {sub_1_complexity}）
- #{sub_2_number} {sub_2_title}（complexity: {sub_2_complexity}）
- ...

### 次のアクション
- `/rite:issue:start {first_sub_issue}` で最初の Sub-Issue から作業を開始
- `/rite:issue:list` で全 Sub-Issue 一覧を確認

<!-- [create:completed:{parent_issue_number}] -->
```

`link_failures > 0` の場合は完了メッセージと sentinel の間に以下を併記し、ユーザーに復旧を促す:

```markdown
### ⚠️ Sub-issues API リンク失敗 ({link_failures} 件)
- 親 #{parent_issue_number} ←→ 子 #{sub_X_number} の link 確立に失敗した Sub-Issue があります（API 失敗 / rate limit / token scope 等）
- 親 Issue body の Tasklist と `## 親 Issue` body meta は fallback として残っています
- 復旧: `bash {plugin_root}/scripts/link-sub-issue.sh {owner} {repo} {parent_issue_number} {sub_X_number}` を該当 Sub-Issue ごとに手動再実行してください
```

ステップ 6 へ。

---

## ステップ 6: 共通完結処理

### 6.1 flow-state 完結

`--preserve-error-count` はこの patch で `.error_count` を 0 にリセットせず保持する general flag。現時点で `.error_count` を読む reader は無いが、再導入時の累積カウントが意図せずリセットされないよう reserved API として保持する。

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase completed --active false --next "none" \
  --if-exists --preserve-error-count 2>/dev/null || true
```

create.md は作業 phase ではなく Issue 作成のみなので、flow-state は必ずしも必要ない（`patch --if-exists` で file 不在時は no-op）。

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

`/rite:issue:create` 単独で動作する。Issue 作成後に作業を開始するには `/rite:issue:start {issue_number}` を実行する。

## Error Handling

- `gh repo view` 失敗 → エラー、認証確認を案内
- Projects 未設定 → warning、Projects 追加を skip
- Issue 作成失敗 → AskUserQuestion で「再試行 / 手動作成 / 中止」
- 親-子リンク失敗 → warning、後で手動リンクを案内
