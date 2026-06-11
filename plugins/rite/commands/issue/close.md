---
description: Issue の完了状態を確認
---

# /rite:issue:close

Check the completion status of an Issue and guide necessary actions.

> **Charter**: This command is subject to the [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述・cycle 番号引用・重複 confirmation は書かない。

---

## Arguments

| Argument | Description |
|------|------|
| `<issue_number>` | Issue number to check (required) |

---

## Shared: Projects Status → Done (delegate pattern)

Phase 1.3.2 / 4.2 / 4.6.3 はいずれも Projects Status を **Done** に更新する。直接の `gh api graphql` + `field-list` + `item-edit` インライン呼び出しは substep 間で LLM attention が失われ silent skip を生むため、共通スクリプト `projects-status-update.sh` に委譲する（`pr/open.md` ステップ 2.4 / `pr/ready.md` Phase 4 と同一）。スクリプトは冪等で、API 詳細は [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update) を参照。

**委譲呼び出し**（`{issue}` は対象 Issue 番号、`auto_add false`・`non_blocking true`）:

```bash
status_json_args=$(jq -n \
  --argjson issue {issue} --arg owner "{owner}" --arg repo "{repo}" \
  --argjson project_number {project_number} --arg status "Done" \
  --argjson auto_add false --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"
```

**`.result` による分岐**（全分岐 non-blocking — Status 更新失敗は close フローを止めない）:

| `.result` | 表示 |
|-----------|------|
| `"updated"` | `Projects Status を "Done" に更新しました`（冪等のため既 Done も updated になる） |
| `"skipped_not_in_project"` | `警告: Issue #{issue} は Project に登録されていません` |
| `"failed"` | `.warnings[]` を stderr に出し、`警告: Projects Status の "Done" 更新に失敗。手動: GitHub Projects 画面で Status を Done に変更、または gh project item-edit ...` |

---

## Phase 1: Check Issue Status

### 1.1 Retrieve Issue Information

```bash
gh issue view {issue_number} --json number,title,body,state,labels,closedAt
```

### 1.2 Determine Issue State

**Issue が既にクローズ済みの場合:**

```
Issue #{number} は既にクローズされています

タイトル: {title}
クローズ日時: {closed_at}

追加のアクションは不要です
```

→ Phase 1.3 へ。**Open の場合**は Phase 2 へ。

---

## Phase 1.3: Projects Status Sync for Already-Closed Issues

Issue が既にクローズ済みでも Projects Status が "Done" でない場合（rite 外でクローズされた等）に同期する。

### 1.3.1 Projects Enabled Check

Read tool で `rite-config.yml` の `github.projects.enabled` を確認。`false`（または未設定）なら本 Phase をスキップして Phase 5 へ。

### 1.3.2 Update Status

[Shared: Projects Status → Done](#shared-projects-status--done-delegate-pattern) の委譲パターンを実行する（`{issue}` = `{issue_number}`、`auto_add false` の理由: 既に CLOSED の Issue を auto-add するのは config drift を masking するため）。結果分岐は共通テーブルに従い、いずれの場合も Phase 5 へ進む（non-blocking — Issue は既にクローズ済み）。

---

## Phase 2: Search for Linked PRs

### 2.1 Search for Related PRs

```bash
gh pr list --state all --search "linked:issue:{issue_number}" --json number,title,state,mergedAt,url
```

見つからなければ PR body の close キーワードを検索する:

```bash
gh pr list --state all --json number,title,state,body,mergedAt,url
```

body が `Closes/Fixes/Resolves #{issue_number}`（大文字小文字とも）を含むか確認する。

### 2.2 Search PRs by Branch Name

```bash
gh pr list --state all --head "*issue-{issue_number}*" --json number,title,state,mergedAt,url
```

### 2.3 Aggregate Search Results

| # | タイトル | 状態 | マージ日時 |
|---|---------|------|----------|
| #{pr_number} | {pr_title} | {state} | {merged_at} |

---

## Phase 3: Auto-Close Determination

### 3.1 Auto-Close Conditions

Issue が自動クローズされる条件: (1) リンク PR の body に `Closes/Fixes/Resolves #XXX` が含まれ、(2) その PR がマージ済み。

### 3.2 Determination Results by Scenario

#### Pattern A: Already Auto-Closed (or Scheduled)

リンク PR がマージ済みかつ close キーワードを含む場合:

```
Issue #{number} は自動的にクローズされます

紐づく PR:
- #{pr_number}: {pr_title} (Merged)

GitHub のキーワード連携により、PR マージ時に Issue は自動クローズされます
追加のアクションは不要です
```

#### Pattern B: PR Exists but No Auto-Close

リンク PR はあるが close キーワードが無い場合:

```
Issue #{number} に紐づく PR がありますが、自動クローズは設定されていません

紐づく PR:
- #{pr_number}: {pr_title} ({state})

推奨アクション:
1. PR 本文に "Closes #{number}" を追加してマージ
2. 手動で Issue をクローズ
```

#### Pattern C: PR Awaiting Merge

リンク PR が open の場合:

```
Issue #{number} に紐づく PR がマージ待ちです

紐づく PR:
- #{pr_number}: {pr_title} (Open)
  URL: {pr_url}

推奨アクション:
1. PR をレビュー・マージ
2. マージ後、Issue は自動的にクローズされます
```

#### Pattern D: No PR Found

関連 PR が無い場合:

```
Issue #{number} に紐づく PR が見つかりません
```

`AskUserQuestion` で次のアクションを確認する:

```
どのアクションを実行しますか？

オプション:
- PR を作成する (/rite:pr:create)
- Issue を手動でクローズする（gh issue close {number}）
- 何もしない
```

---

## Phase 4: Execute Actions

### 4.1 Execute Manual Close

ユーザーが手動クローズを選択した場合:

```bash
gh issue close {issue_number}
```

### 4.2 Update Projects Status

`github.projects.enabled: false` ならスキップして Phase 4.3 へ。そうでなければ [Shared: Projects Status → Done](#shared-projects-status--done-delegate-pattern) の委譲パターンを実行する（`{issue}` = `{issue_number}`、`auto_add false` の理由: close 時点で `pr/open.md` ステップ 2.4 が登録済み）。結果分岐は共通テーブルに従い、いずれの場合も Phase 4.3 へ（non-blocking — close は Phase 4.1 で実行済み）。

### 4.3 Update Local Work Memory

Phase 5 の削除前に完了状態をローカル作業メモリに記録する:

```bash
WM_SOURCE="close" \
  WM_PHASE="completed" \
  WM_PHASE_DETAIL="Issue クローズ完了" \
  WM_NEXT_ACTION="なし" \
  WM_BODY_TEXT="Issue closed." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

lock 失敗時は WARNING を出して続行（best-effort — Phase 5 でどのみち削除される）。Issue コメントへの backup sync は不要（最終的な archival record は `rite:pr:cleanup` Phase 4.5 が更新する）。

### 4.4 Completion Report

```
Issue #{number} をクローズしました

タイトル: {title}
Status: Done

関連 PR: #{pr_number} (Merged)
```

→ Phase 4.4.W へ。

### 4.4.W Wiki Ingest Trigger (Conditional)

> **Reference**: [Wiki Ingest](../wiki/ingest.md) — `wiki-ingest-trigger.sh` API。本 Phase は raw source の **蓄積** を担う（page 統合は後続の `/rite:wiki:ingest` が冪等に行う）。raw 蓄積と page 統合を分離することで、page 統合が skip / 失敗しても raw source は失われない。

> **⚠️ E2E Mandatory**: 本 Phase は出力最小化ルールで skip しない。orchestrator 経由 (例: `/rite:pr:open` 後の parent close routing) でも実行する。唯一の正当な skip は Step 1 の config ベース skip（`WIKI_INGEST_SKIPPED=1` sentinel + WARNING を必ず emit）。

**Step 1**: Wiki 設定を確認する（`wiki.enabled` opt-out default true / `wiki.auto_ingest` default false）:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
parse_wiki_key() {
  printf '%s\n' "$wiki_section" | awk -v k="$1" '$0 ~ "^[[:space:]]+" k ":" { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed "s/.*$1:[[:space:]]*//" | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]'
}
wiki_enabled=$(parse_wiki_key enabled)
auto_ingest=$(parse_wiki_key auto_ingest)
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; *) wiki_enabled="true" ;; esac
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac

reason=""
[ "$wiki_enabled" = "false" ] && reason="disabled"
[ -z "$reason" ] && [ "$auto_ingest" = "false" ] && reason="auto_ingest_off"
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  echo "WARNING: close Phase 4.4.W Wiki ingest skipped: $reason" >&2
fi
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest reason=${reason:-<run>}"
```

`reason` が非空なら Step 2 / Phase 4.4.W.2 をスキップして Phase 4.5 へ。

**Step 2**: Issue コンテキストから retrospective Raw Source を生成する。`wiki-ingest-trigger.sh` は `--content-file` に `$PWD` 配下または `/tmp/rite-*` prefix のみを受容する（mktemp デフォルトの `/tmp/tmp.*` では silent fail する）:

```bash
tmpfile=$(mktemp /tmp/rite-wiki-content-XXXXXX)
trigger_stderr=$(mktemp /tmp/rite-wiki-trigger-err-XXXXXX) || trigger_stderr=/dev/null
trap 'rm -f "$tmpfile"; [ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT

cat <<'RETRO_EOF' > "$tmpfile"
## Issue Close Retrospective

- **Issue**: #{issue_number} — {title}
- **Type**: retrospective
- **Closed at**: {timestamp}

### Summary
{retrospective_summary — Issue の作業中に学んだこと、予想外の困難、有効だったアプローチを LLM が Issue body + work memory から要約して埋め込む}
RETRO_EOF

bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
  --type retrospectives --source-ref "issue-{issue_number}" \
  --content-file "$tmpfile" --issue-number {issue_number} \
  --title "Issue #{issue_number} close retrospective" \
  2>"$trigger_stderr"
trigger_exit=$?
echo "trigger_exit=$trigger_exit"
# trigger 失敗 (exit != 0 かつ != 2; exit 2 = Wiki disabled/uninitialized = legitimate skip) を surface
if [ "$trigger_exit" -ne 0 ] && [ "$trigger_exit" -ne 2 ]; then
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
  echo "WARNING: wiki-ingest-trigger.sh exited $trigger_exit during close Phase 4.4.W" >&2
  if [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
    head -3 "$trigger_stderr" | sed 's/^/  /' >&2
  fi
fi
```

**Non-blocking**: trigger 失敗は workflow を止めない。LLM は `trigger_exit` を読み、非 0 なら Phase 4.4.W.2 をスキップする。

### 4.4.W.2 Wiki Raw Commit

> raw source の commit を単一スクリプト `wiki-ingest-commit.sh`（stash→checkout→add→commit→push→checkout-back→stash-pop を 1 プロセスで完結）に委譲する。LLM の multi-step orchestration に依存した旧 Skill 設計が E2E で fragile だったため。**本 block は raw source のみ commit**（page 統合は `/rite:wiki:ingest`）。

**Condition**: `wiki_enabled=true` AND `auto_ingest=true` AND `trigger_exit=0` の場合のみ実行。満たさなければスキップして Phase 4.5 へ。

```bash
commit_err=$(mktemp /tmp/rite-wiki-commit-err-XXXXXX 2>/dev/null) || commit_err=/dev/null
trap 'rm -f "${commit_err:-}"' EXIT INT TERM HUP
commit_rc=0
if commit_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh 2>"${commit_err}"); then
  echo "$commit_out"
  echo "[CONTEXT] WIKI_INGEST_DONE=1; issue={issue_number}; type=retrospectives"
else
  commit_rc=$?
  [ "$commit_err" != "/dev/null" ] && [ -s "$commit_err" ] && head -5 "$commit_err" | sed 's/^/  /' >&2
  # exit 2 = legitimate skip (wiki branch missing/disabled); exit 4 = commit landed, push failed
  case "$commit_rc" in
    2) echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing; exit_code=$commit_rc"
       echo "WARNING: wiki-ingest-commit.sh exited 2 (wiki branch missing/disabled) during close Phase 4.4.W.2" >&2 ;;
    4) echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=$commit_rc"
       [ -n "${commit_out:-}" ] && echo "$commit_out"
       echo "WARNING: wiki-ingest-commit.sh exited 4 (commit landed locally, push failed) during close Phase 4.4.W.2" >&2 ;;
    *) echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_$commit_rc; exit_code=$commit_rc"
       echo "WARNING: wiki-ingest-commit.sh exited $commit_rc during close Phase 4.4.W.2" >&2 ;;
  esac
fi
[ "$commit_err" != "/dev/null" ] && rm -f "$commit_err"
trap - EXIT INT TERM HUP
```

**Non-blocking**: 失敗は close を止めない。`wiki-ingest-commit.sh` は失敗時に cleanup trap で raw source を復元するので次回再試行できる。→ Phase 4.5 へ。

---

## Phase 4.5: Parent Issue Body Update

子 Issue がクローズされたら、親 Issue の body に完了状態を反映する。

### 4.5.1 Detect Parent Issue

親 Issue を **3 method の OR 検出**で特定する。この 3-method 構造は [`projects-integration.md` §2.4.7.1](../../references/projects-integration.md#247-parent-issue-status-update-for-child-issues) と一致させる（method 順序・OR 意味・total-failure 時の `[DEBUG] parent not detected` emission を揃える。乖離すると Issue #115/#381/#15 の silent-skip 回帰が再発する）。

**Method 1: `## 親 Issue` body meta（PRIMARY）** — `/rite:issue:create`（Decompose Path）が書く section:

```bash
issue_body=$(gh issue view {issue_number} --json body --jq '.body')
parent_number=$(grep -A2 '^## 親 Issue' <<< "$issue_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
echo "method1_parent=${parent_number:-none}"
```

非空なら 4.5.2 へ。

**Method 2: Sub-Issues API（secondary）** — Method 1 が空の場合:

```bash
parent_number=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { parent { number } } }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number} \
  --jq '.data.repository.issue.parent.number // empty')
echo "method2_parent=${parent_number:-none}"
```

非空なら 4.5.2 へ。

**Method 3: Tasklist search（last resort）** — 両 method が失敗した場合。GitHub code search の `[`/`]` は不安定なので最後の手段。`--state all`（closing Issue の親が既に closed の可能性）:

```bash
parent_number=$(gh issue list --state all --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number --limit 1 --jq '.[0].number // empty')
echo "method3_parent=${parent_number:-none}"
```

**3 method すべて失敗（`parent_number` 空）の場合**は standalone として処理する（AC-4 — 正常動作。silent-skip 回帰検出のため debug log は残す）:

```bash
echo "[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods: body_meta, sub_issues_api, tasklist_search)"
```

`親 Issue の参照が見つかりませんでした。親 Issue 更新をスキップします。` を表示し、Phase 4.5 残り + Phase 4.6 をスキップして Phase 5 へ。

### 4.5.2 Update Parent Issue Body

`issue-body-safe-update.sh` の 3-step safe update pattern（fetch/edit/apply + body shrinkage detection + diff-check 冪等性。`implement.md` / `archive-procedures.md` と同パターン）で親の Sub-Issues checkbox と実装フェーズ status を更新する。

**Step 1: Fetch**:

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {parent_number} --parent
```

出力に `tmpfile_read=` / `tmpfile_write=` / `original_length=` があれば Step 2 へ。WARNING のみ / 失敗なら警告して Phase 5 へ（non-blocking, AC-4）。

**Step 2: Read tool + Write tool で更新** — Read tool で `$tmpfile_read` を読み、以下 2 置換を適用して Write tool で `$tmpfile_write` に書く:
1. **Sub-Issues checkbox**: `- [ ] #{issue_number}` 行の `- [ ]` を `- [x]` に（該当 Issue 番号行のみ）
2. **実装フェーズ table**: `内容` 列に `#{issue_number}` を含む行の `[ ] 未着手` を `[x] 完了` に

`#{issue_number}` を含む行のみ変更（他 section は不変）。

**Step 3: Apply**:

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
  --issue {parent_number} --tmpfile-read "$tmpfile_read" --tmpfile-write "$tmpfile_write" \
  --original-length "$original_length" --parent --diff-check
```

exit 0 で成功（`--diff-check` で変更不要時は skip）。非 0 なら警告して Phase 4.6 へ（non-blocking, AC-4。close 自体は Phase 4.1 で成功済み）。→ Phase 4.6 へ。

---

## Phase 4.6: Parent Auto-Close (All Children Completed)

検出した親のすべての子 Issue が closed になったら、親の auto-close を提案する（"child close → parent stays Open" の silent-skip hole を塞ぐ、Issue #513 AC-2）。

**実行条件**: Phase 4.5.1 で `{parent_number}` が検出された場合のみ。未検出なら Phase 4.6 全体をスキップして Phase 5 へ。**直接の親のみ処理**し、祖父母には再帰しない（three-level nesting は out of scope）。

### 4.6.0 + 4.6.1 Idempotency Check & Child Enumeration

冪等性チェック（親が既 closed なら no-op）→ 子 Issue 列挙 → `all_closed` 判定を **単一 Bash block** で行う（block 間の shell state 喪失を回避）。stderr は tempfile に退避して surface する（`2>/dev/null` の silent-skip anti-pattern を避ける）。`set -uo pipefail`（`-e` は明示 `|| fallback` のため省略）。

```bash
set -uo pipefail
parent_number="{parent_number}"
owner="{owner}"
repo="{repo}"

# --- Placeholder sanity guard: Phase 4.6 は親検出時のみ到達。未置換/非数値は routing bug ---
case "$parent_number" in
  ''|'{parent_number}'|*[!0-9]*)
    echo "[DEBUG] p460: parent_number invalid ('$parent_number') — Phase 4.6 should not have been entered (routing bug)." >&2
    echo "[CONTEXT] P460_DECISION=skip_routing_bug"
    exit 0 ;;
esac

p46_err=""
trap 'rm -f "${p46_err:-}"' EXIT INT TERM HUP
p46_err=$(mktemp 2>/dev/null) || p46_err=""

# --- 4.6.0: Idempotency — 親が既に CLOSED なら no-op (close-side idempotency, extends AC-6 principle) ---
parent_state=""
if parent_state=$(gh issue view "$parent_number" --json state --jq '.state' 2>"${p46_err:-/dev/null}"); then
  echo "parent_state=$parent_state"
else
  echo "[DEBUG] p460: gh issue view failed (rc=$?)" >&2
  [ -n "$p46_err" ] && [ -s "$p46_err" ] && head -3 "$p46_err" | sed 's/^/  p460 stderr: /' >&2
  parent_state=""
fi

if [ -z "$parent_state" ]; then
  echo "警告: 親 Issue #${parent_number} の state 取得に失敗しました。自動クローズ判定をスキップします。" >&2
  echo "[CONTEXT] P460_DECISION=skip_retrieval_failed"
  exit 0
elif [ "$parent_state" = "CLOSED" ]; then
  echo "[DEBUG] parent #${parent_number} already closed — skipping Phase 4.6 (close-side idempotency)"
  echo "[CONTEXT] P460_DECISION=skip_already_closed"
  exit 0
fi
echo "[CONTEXT] P460_DECISION=proceed_to_enumeration"

# --- 4.6.1: Enumerate children (Method A: trackedIssues / Tasklists API → Method B: body parse) ---
# trackedIssues は Tasklists 機能 (body `- [ ] #N` parser)。GitHub Sub-Issues API (subIssues) とは別物。
children_json=""
if children_json=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) { trackedIssues(first: 100) { nodes { number state } } }
  }
}' -f owner="$owner" -f repo="$repo" -F number="$parent_number" \
  --jq '[.data.repository.issue.trackedIssues.nodes[]? | {number, state}]' 2>"${p46_err:-/dev/null}"); then
  echo "[DEBUG] method_a: $(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0) children via trackedIssues"
else
  echo "[DEBUG] method_a failed (rc=$?) — trying Method B" >&2
  [ -n "$p46_err" ] && [ -s "$p46_err" ] && head -3 "$p46_err" | sed 's/^/  method_a stderr: /' >&2
  children_json=""
fi

# Method B: 親 body の `## Sub-Issues` section parse (literal heading text — GitHub 機能ではない)
if [ -z "$children_json" ] || [ "$(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
  echo "[DEBUG] fallback to Method B (parent body '## Sub-Issues' parse)"
  parent_body=$(gh issue view "$parent_number" --json body --jq '.body' 2>/dev/null || echo "")
  child_numbers=$(awk '/^## Sub-Issues$/{flag=1;next} /^## /{flag=0} flag && /^- \[[ xX]\] #[0-9]+/{print}' <<< "$parent_body" | grep -oE '#[0-9]+' | tr -d '#')
  if [ -z "$child_numbers" ]; then
    children_json="[]"
  else
    children_json="["; first=1
    for n in $child_numbers; do
      # state 取得失敗は fail-closed (OPEN 扱い) で auto-close を抑止する
      child_state=$(gh issue view "$n" --json state --jq '.state' 2>/dev/null || echo "OPEN")
      [ -z "$child_state" ] && child_state="OPEN"
      [ "$first" -eq 1 ] && first=0 || children_json+=","
      children_json+="{\"number\":$n,\"state\":\"$child_state\"}"
    done
    children_json+="]"
  fi
fi

# --- all_closed 判定 (空配列は「判定不能」= auto-close 不可の safe default) ---
final_length=$(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0)
if [ "$final_length" -eq 0 ]; then
  echo "all_closed=false open_count=0 children_total=0"
  echo "[CONTEXT] P461_DECISION=skip_empty_children"
else
  all_closed=$(printf '%s' "$children_json" | jq -r 'all(.[]; .state == "CLOSED") | tostring' 2>/dev/null || echo "false")
  open_count=$(printf '%s' "$children_json" | jq -r '[.[] | select(.state != "CLOSED")] | length' 2>/dev/null || echo 0)
  echo "all_closed=$all_closed open_count=$open_count children_total=$final_length"
  if [ "$all_closed" = "true" ]; then
    echo "[CONTEXT] P461_DECISION=proceed_to_confirmation"
  else
    echo "[CONTEXT] P461_DECISION=skip_open_children; open_count=$open_count"
  fi
fi
```

**LLM routing**（stdout の `[CONTEXT] P460_DECISION=` / `P461_DECISION=` を prefix match で読む）:

| 値 | Next action |
|----|-------------|
| `P460_DECISION=skip_routing_bug` | routing bug（empty/literal/非数値）。Phase 4.6 を抜けて Phase 5 へ |
| `P460_DECISION=skip_retrieval_failed` | 親 state 取得失敗。Phase 4.6 を抜けて Phase 5 へ（non-blocking） |
| `P460_DECISION=skip_already_closed` | 親が既 closed の no-op。Phase 4.6 を抜けて Phase 5 へ |
| `P461_DECISION=skip_empty_children` | 子一覧取得不可。`親 Issue #{parent_number} の子 Issue 一覧が取得できませんでした。自動クローズをスキップします。` を表示し Phase 5 へ |
| `P461_DECISION=skip_open_children; open_count=N` | `親 Issue #{parent_number} にはまだ N 件の未完了子 Issue があります。自動クローズはスキップします。` を表示し Phase 5 へ |
| `P461_DECISION=proceed_to_confirmation` | 4.6.2 へ |

### 4.6.2 User Confirmation

`AskUserQuestion`:

```
親 Issue #{parent_number} のすべての子 Issue が完了しました。親 Issue もクローズしますか？

オプション:
- 親 Issue をクローズする（推奨）
- 親 Issue を開いたまま終了
```

「クローズする」→ 4.6.3。「開いたまま終了」→ `echo "[DEBUG] user declined parent auto-close for #{parent_number}"` し Phase 5 へ。

### 4.6.3 Update Parent Status to Done & Close

親の Projects Status → Done（[共通委譲パターン](#shared-projects-status--done-delegate-pattern)、`github.projects.enabled: false` ならスキップ）と `gh issue close` を **単一 block** で実行する。Step 3 の state-inconsistency summary を**必ず** emit し、片方成功/片方失敗の silent data corruption を可視化する。`{projects_enabled}` / `{project_number}` / `{owner}` / `{repo}` は `rite-config.yml` から、`{parent_number}` / `{issue_number}` は前 Phase から置換する。

```bash
set -uo pipefail
# drift-check-ignore: 親 Status→Done + close + 不整合サマリ (Step 1-3) を単一 atomic block に
#   保つのは意図的な設計 (#517 silent-corruption 可視化 / #658 substep 間 attention 喪失回避)。
#   phase 分割は両不変条件を壊すため不可。
parent_number="{parent_number}"
owner="{owner}"
repo="{repo}"
projects_enabled="{projects_enabled}"
project_number="{project_number}"
issue_number="{issue_number}"

status_update_result="projects_disabled"   # success | not_registered | update_failed | projects_disabled
status_warning_lines=""
issue_close_result="pending"                # success | failed | pending
script_item_id=""; script_project_id=""; script_status_field_id=""; script_option_id=""

p463_err_close=""; p463_err_status=""
trap 'rm -f "${p463_err_close:-}" "${p463_err_status:-}"' EXIT INT TERM HUP
_mktemp_or_warn() { mktemp 2>/dev/null || { echo "[DEBUG] p463 $1: mktemp failed — gh stderr not captured" >&2; printf ''; }; }

# --- Step 1: Parent Projects Status → Done (delegate) ---
if [ "$projects_enabled" = "true" ]; then
  status_json_args=$(jq -n \
    --argjson issue "$parent_number" --arg owner "$owner" --arg repo "$repo" \
    --argjson project_number "$project_number" --arg status "Done" \
    --argjson auto_add false --argjson non_blocking true \
    '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
  p463_err_status=$(_mktemp_or_warn "Step 1")
  status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args" 2>"${p463_err_status:-/dev/null}") || status_json=""
  status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null || echo "failed")
  status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
  # 失敗時 recovery one-liner 用に script JSON から 4 ID 抽出 (script は失敗時も emit する)
  script_item_id=$(printf '%s' "$status_json" | jq -r '.item_id // empty' 2>/dev/null)
  script_project_id=$(printf '%s' "$status_json" | jq -r '.project_id // empty' 2>/dev/null)
  script_status_field_id=$(printf '%s' "$status_json" | jq -r '.status_field_id // empty' 2>/dev/null)
  script_option_id=$(printf '%s' "$status_json" | jq -r '.option_id // empty' 2>/dev/null)
  if [ -z "$status_json" ] && [ -n "$p463_err_status" ] && [ -s "$p463_err_status" ]; then
    status_warning_lines=$(printf 'script invocation died before JSON emit: %s' "$(head -5 "$p463_err_status")")
  fi
  case "$status_result" in
    updated) status_update_result="success"; echo "親 Issue #${parent_number} の Status を 'Done' に更新しました" ;;
    skipped_not_in_project) status_update_result="not_registered"; echo "警告: 親 Issue #${parent_number} は Project #${project_number} に未登録。Status 更新をスキップします。" >&2 ;;
    *) status_update_result="update_failed"
       [ "$status_result" != "failed" ] && echo "[DEBUG] 未知の .result='$status_result' — update_failed 扱い" >&2
       echo "警告: 親 Issue #${parent_number} の Status 更新に失敗。後続の gh issue close は続行します。" >&2
       [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  p463 Step 1 warning: /' >&2 ;;
  esac
fi

# --- Step 2: Close the parent Issue ---
p463_err_close=$(_mktemp_or_warn "Step 2")
if gh issue close "$parent_number" --comment "子 Issue がすべて完了したため自動クローズします。(/rite:issue:close 経由、Issue #${issue_number} の close をトリガー)" >/dev/null 2>"${p463_err_close:-/dev/null}"; then
  issue_close_result="success"; echo "親 Issue #${parent_number} を自動クローズしました"
else
  issue_close_result="failed"
  echo "警告: 親 Issue #${parent_number} のクローズに失敗 (rc=$?)。手動: gh issue close ${parent_number}" >&2
  [ -n "$p463_err_close" ] && [ -s "$p463_err_close" ] && head -5 "$p463_err_close" | sed 's/^/  p463 Step 2 stderr: /' >&2
fi

# --- Step 3: State inconsistency summary (MUST always emit) ---
echo ""
echo "=== 親 Issue #${parent_number} 処理結果 ==="
echo "  Issue close: $issue_close_result"
echo "  Status update: $status_update_result"
case "${issue_close_result}:${status_update_result}" in
  "success:success"|"success:projects_disabled"|"success:not_registered") echo "  状態: 整合性 OK" ;;
  "success:update_failed")
    echo ""; echo "⚠️ state 不整合: 親 Issue は CLOSED ですが Projects Status が Done に更新されていません。"
    if [ -n "${script_item_id:-}" ] && [ -n "${script_project_id:-}" ] && [ -n "${script_status_field_id:-}" ] && [ -n "${script_option_id:-}" ]; then
      echo "  復旧コマンド: gh project item-edit --project-id ${script_project_id} --id ${script_item_id} --field-id ${script_status_field_id} --single-select-option-id ${script_option_id}"
    else
      echo "  手動更新例: gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <done_option_id>"
      echo "  診断: gh project field-list ${project_number} --owner ${owner} --format json (Status field と 'Done' option の id を確認)"
    fi ;;
  "failed:success") echo ""; echo "⚠️ state 不整合: Projects Status は Done ですが親 Issue が OPEN のままです。"; echo "  復旧コマンド: gh issue close ${parent_number}" >&2 ;;
  "failed:projects_disabled") echo ""; echo "⚠️ 親 Issue のクローズに失敗 (Projects は config で無効)。手動: gh issue close ${parent_number}" >&2 ;;
  "failed:not_registered") echo ""; echo "⚠️ 親 Issue のクローズに失敗 (Project 未登録)。手動: gh issue close ${parent_number}" >&2 ;;
  "failed:"*) echo ""; echo "⚠️ 親 Issue の処理が両方失敗 (close / status)。手動対応: gh issue close ${parent_number}" >&2 ;;
esac
trap - EXIT INT TERM HUP
```

いずれの結果でも Phase 5 へ（non-blocking — Step 3 summary が silent failure を不可能にする、Issue #517 invariant）。

---

## Phase 5: Delete Local Work Memory Files

**実行条件**: 既クローズ（Phase 1.2）/ 新規クローズ（Phase 4）を問わず最終 Phase として常に実行。`{issue_number}` のみ必要。

指定 Issue のローカル作業メモリファイルと lockdir を削除する（close mode: 指定 Issue のファイルのみ削除。flow state reset や stale sweep はしない）。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決:

```bash
bash {plugin_root}/hooks/cleanup-work-memory.sh --issue {issue_number}
```

`--issue` フラグは Issue 番号を直接渡し、スクリプトが内部でパスを構築する（LLM placeholder 置換をバイパス）。`.rite-work-memory/` ディレクトリ自体は削除しない（スクリプトが保持）。

**エラーハンドリング**（すべて non-blocking — 失敗時は警告して終了）:

| Error Case | Response |
|-----------|----------|
| ファイル不在 | エラーなし（スクリプトが gracefully 処理） |
| Permission / スクリプト失敗 | WARNING を表示して終了 |

失敗時の警告:

```
警告: ローカル作業メモリの削除に失敗しました
手動削除: rm -f ".rite-work-memory/issue-{issue_number}.md" && rm -rf ".rite-work-memory/issue-{issue_number}.md.lockdir"
```

### 5.1 Deletion Result Display

```
ローカル作業メモリ: {削除済み / 削除失敗（警告参照） / 該当なし}
```

| Script Output | Display Value |
|--------------|---------------|
| `削除: 1` 以上 | `削除済み` |
| `失敗: 1` 以上 | `削除失敗（警告参照）` |
| `削除: 0, 失敗: 0` | `該当なし` |

End processing.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
| Permission Error | See [common patterns](../../references/common-error-handling.md) |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
