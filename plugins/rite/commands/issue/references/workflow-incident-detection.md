# Workflow Incident Detection — Phase 5.4.4.1 SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` Phase 5.4.4.1 の **Workflow Incident Detection** (sentinel detection / parse / dedupe / AskUserQuestion / create-issue) と Phase 5.0 Step 6 の **`workflow_incident.enabled` parser** の SoT である。`start.md` 本体は anchor reference + sentinel `type` table のみに圧縮し、検出経路の全実装は本ファイルに集約する。
>
> **抽出経緯**: `start.md` の Phase 5.4.4.1 (旧 line 1309-1555、約 247 行) と Phase 5.0 Step 6 (旧 line 668-692、約 25 行) を本 reference へ移し、本体側の **Detection scope table** と **When to execute table** のみを残す。これにより workflow_incident 検出経路の全実装 (bash literal / 散文 rationale / 5 caller 用 emit pattern) を 1 ファイルへ集約し、本体の認知負荷を下げる。

## 概要

Phase 5.4.4.1 は **workflow blockers** (Skill load failure, hook abnormal exit, manual fallback adoption, Wiki ingest skip / failure, Gitignore drift) を sentinel として検出し、AskUserQuestion 経由でユーザー確認のうえ tracking Issue として自動登録する。silent loss を防ぎ、workflow continuation を保証する non-blocking 経路。

実行タイミングは `start.md` の **When to execute table** で 5 callers (lint / pr:create / pr:review / pr:fix / pr:ready) ごとに明示される。本 reference はその全 5 caller から呼び出される共通検出経路を定義する。

## Phase 5.0 Step 6 — `workflow_incident.enabled` parser

Phase 5.0 で `workflow_incident.enabled` を `rite-config.yml` から読み取り、Phase 5 全体でキャッシュする (Phase 5.4.4.1 で参照)。section 不在時は `true` (default-on)。

### Parser correctness

旧 `grep -A3` 実装は `workflow_incident:` の直後 3 行のみを読むため、コメント追加・キー追加・`enabled:` の行位置変更で silent fallback to default-on になり opt-out が壊れる経路があった (AC-8 違反)。修正版は `sed -n` の section 範囲抽出 (`/^workflow_incident:/,/^[a-zA-Z]/p`) でセクション全体を捕捉する。

加えて `case` 文に `tr '[:upper:]' '[:lower:]'` での正規化を追加し、`yes`/`no`/`1`/`0` などの boolean variant を受容する。`enabled: FALSE` のような大文字混在が silent fallback to default-on となる経路を遮断する。`[[:space:]]` は BSD/GNU grep 両対応の portable spec。

### Canonical bash literal

```bash
# 1) workflow_incident: section 全体を sed -n で範囲抽出（grep -A3 の固定行数制限を排除）
# 2) section 内の enabled: 行を取得
# 3) コメント除去 (sed 's/#.*//') を先行して trailing comment の : で誤 split を防ぐ
# 4) `enabled:` の右辺を抽出して空白除去
# 5) 大文字→小文字正規化で True/FALSE/Yes/No/1/0 等の variant を受容
workflow_incident_enabled=$(sed -n '/^workflow_incident:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/#.*//' \
  | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
workflow_incident_enabled=$(echo "$workflow_incident_enabled" | tr '[:upper:]' '[:lower:]')
case "$workflow_incident_enabled" in
  true|yes|1)  workflow_incident_enabled="true" ;;
  false|no|0)  workflow_incident_enabled="false" ;;
  *) workflow_incident_enabled="true" ;;  # 不明値 / 空 → default-on
esac
echo "workflow_incident_enabled=$workflow_incident_enabled"
```

Retain `workflow_incident_enabled` in conversation context. Phase 5.4.4.1 reads this value and skips its entire processing if `false`.

> **Note on non-blocking / dedupe behavior**: The implementation always behaves as non-blocking (registration failure does not halt the workflow) and deduplicates incidents per session (same type is only prompted once). Only `enabled` is a configurable key.

## Phase 5.4.4.1 — Workflow Incident Detection

### Sentinel `type` の意味

本体側 (`start.md`) は 7 sentinel type の Detection scope table を保持する。本 reference は各 type のソースと recommended action を再掲しない (本体テーブルが SoT)。検出ロジックは type に対して uniform であり、per-type branching は table を超えて存在しない。

### Sub-case routing note for `wiki_ingest_skipped`

`wiki_ingest_skipped` with `reason=commit_branch_missing` の場合: sentinel の `details` フィールドまたは付随する `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing` status line が operational fresh-clone sub-case を示す。この場合、AskUserQuestion の default は **「skip」** (tracking Issue を作らない) とし、recovery hint (`git fetch origin wiki:wiki` または `/rite:wiki:init` の後に enclosing phase を再実行) を primary option として表示する。

`commit_branch_missing` で tracking Issue を作るのは anti-pattern。状態は transient で秒単位で user-resolvable。

configuration-disable sub-case (`wiki.enabled=false` / `auto_ingest=false`) は既存挙動 (prompt で状態可視化、user は通常 skip 選択) を維持する。

## Workflow Incident Sentinel Visibility Rule

Sub-skills (`lint.md`, `pr/create.md`, `pr/fix.md`, `pr/review.md`) は orchestrator の conversation context 内で inline 実行される (forked execution が `AskUserQuestion` を e2e フローで失敗させる経路の修正後)。Bash tool call の stdout は orchestrator の conversation context に直接可視。

**防御的実践**: sub-skills は emitted sentinel 行を final response text にも含めるべきである。これにより future の execution context 変更下でも sentinel detection の堅牢性を確保する。

### Concrete pattern for sub-skills

```bash
# Step 1: emit sentinel via hook script (silent capture)
sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type {sentinel_type} \
  --details "{specific failure description}" \
  --pr-number {pr_number} 2>/dev/null) || true

# Step 2: also echo to stderr for human-visible debugging
[ -n "$sentinel_line" ] && echo "$sentinel_line" >&2
```

**Step 3 (LLM responsibility)**: sub-skill LLM は捕捉した `sentinel_line` の値 (非空時) を **final response message text に verbatim 含める**:

```
[lint:error] — 3 errors detected
[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=rite:lint tool not found: ruff; iteration_id=0-1775650793
```

inline 実行下では sentinel は既に bash stdout で orchestrator context に流入している。response text への明示的 inclusion は defense-in-depth。

### Orchestrator-direct emit

Phase 5.2 (`lint:aborted`), Phase 5.3 (`pr:create-failed`), Phase 5.4.4 (`fix:error`), Phase 5.5 (`ready:error`) では orchestrator 自身が bash を実行するため、sentinel stdout は既に conversation context にある。それでも orchestrator は sentinel line を response text に含め、後続 cycle の context grep self-detection を可能にする。

## Processing flow

### Skip condition

`workflow_incident.enabled: false` in `rite-config.yml` の場合、本 phase 全体を skip する。値は Phase 5.0 で 1 回読み rest of flow にキャッシュする。

### Step 1 — Sentinel detection (context grep)

直近の conversation context を以下 pattern で grep:

```
[CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; (root_cause_hint=<hint>; )?iteration_id=<pr>-<epoch>
```

emit source:
- `plugins/rite/hooks/workflow-incident-emit.sh` (skill internal failure paths / orchestrator fallback prompts)
- orchestrator 自身が expected result pattern の missing を検出した時 (Skill load failure post-condition check)

sentinel 未発見時は **silent skip** (rest of phase を実行しない)。

### Step 2 — Parse sentinel fields

`type`, `details`, `root_cause_hint` (optional), `iteration_id` を抽出。`iteration_id` は `{pr_number}-{epoch_seconds}` 形式。

### Step 3 — Duplicate suppression (session-local)

conversation-context-local set `workflow_incident_processed_types` を維持 (flow state field 不使用、Phase 5.4.3 Step 2.8 re-invoke tracking と同手法)。各 detected sentinel:

| Condition | Action |
|-----------|--------|
| `type` not in processed set | Continue to step 4 |
| `type` already in processed set | Log `incident type={type} suppressed (2nd occurrence)` to context, do NOT present `AskUserQuestion`, return |

### Step 4 — User confirmation via `AskUserQuestion`

```
⚠️ Workflow incident を検出しました
Type: {type}
Details: {details}
Root cause hint: {root_cause_hint or "(none)"}

この incident を別 Issue として登録しますか？

オプション:
- はい、Issue として登録（推奨）
- skip（context に retain して完了レポートで言及）
```

### Step 5 — Branch on user choice

- **「はい」**: Step 6 (create Issue) へ進む
- **「skip」**: `type` を `workflow_incident_processed_types` に追加 (本 session で再質問しない)、`{type, details, root_cause_hint, iteration_id}` を context-local `workflow_incident_skipped` list へ append (Phase 5.6 reporting 用)。成功 skip / step 6 fallthrough 失敗の両経路で本 list へ append し silent loss を防ぐ。

### Step 6 — Create Issue via common script

> **Reference**: `start.md` Phase 5.2.0.1 (out-of-scope warnings) と同じ Issue Creation pattern を適用。

```bash
# trap + cleanup パターンの canonical 説明は commands/pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)

# 1. パス先行宣言 (mktemp 前に空文字列で初期化)
tmpfile=""
jq_err=""

# 2. cleanup 関数定義
_rite_start_wi_cleanup() {
  rm -f "${tmpfile:-}" "${jq_err:-}"
}

# 3. signal 別 trap (4 行): EXIT は元 exit code を保持、INT/TERM/HUP は明示的 exit code を返す
trap 'rc=$?; _rite_start_wi_cleanup; exit $rc' EXIT
trap '_rite_start_wi_cleanup; exit 130' INT
trap '_rite_start_wi_cleanup; exit 143' TERM
trap '_rite_start_wi_cleanup; exit 129' HUP

# 4. mktemp 実行 (trap 武装後)
tmpfile=$(mktemp /tmp/rite-start-wi-body-XXXXXX) || {
  echo "WARNING: mktemp failed for tmpfile. Skipping incident registration. Adding to workflow_incident_skipped for Phase 5.6 reporting." >&2
  # workflow_incident_skipped に {type, details, root_cause_hint, iteration_id} を追加
  exit 0  # non-blocking guarantee
}

cat <<'BODY_EOF' > "$tmpfile"
## Workflow Incident (auto-registered)

- **Type**: {type}
- **Details**: {details}
- **Root cause hint**: {root_cause_hint or "(none)"}
- **Detected during**: Issue #{issue_number} / PR #{pr_number}
- **iteration_id**: {iteration_id}

### Reproduction context

{context_excerpt — recent conversation lines around the sentinel for triage}

### Next steps

このIncidentは `/rite:issue:start` の一気通貫フロー実行中に自動検出されました。手動 fallback / Edit 修正で workflow は継続済みです。
BODY_EOF

# AC-10 non-blocking guarantee: Issue body が空 (HEREDOC 失敗 / disk full / inode 枯渇) でも
# workflow を halt せず、warning + workflow_incident_skipped 追加で fallthrough する。
# 旧実装の `exit 1` は AC-10 と論理矛盾するため除去
if [ ! -s "$tmpfile" ]; then
  echo "WARNING: Issue body is empty (HEREDOC failure?). Skipping incident registration. Adding to workflow_incident_skipped for Phase 5.6 reporting." >&2
  # context-local list に追加して Phase 5.6.1 で表示する (fallthrough、exit しない)
  # workflow_incident_skipped に {type, details, root_cause_hint, iteration_id} を追加
  # その後 step 7 (processed_types に追加) を実行してから本 step を抜ける
else
  # jq -n を別変数に切り出して exit code をチェック
  # 旧実装は jq parse error を silent に握りつぶしていた
  jq_err=$(mktemp /tmp/rite-start-wi-jqerr-XXXXXX) || {
    echo "WARNING: mktemp failed for jq_err. Proceeding without jq stderr capture." >&2
    jq_err=""
  }
  if json_args=$(jq -n \
    --arg title "incident: {type} - {details_truncated_60chars}" \
    --arg body_file "$tmpfile" \
    --argjson projects_enabled {projects_enabled} \
    --argjson project_number {project_number} \
    --arg owner "{owner}" \
    --arg priority "High" \
    --arg complexity "S" \
    '{
      issue: { title: $title, body_file: $body_file },
      projects: {
        enabled: $projects_enabled,
        project_number: $project_number,
        owner: $owner,
        status: "Todo",
        priority: $priority,
        complexity: $complexity,
        iteration: { mode: "none" }
      },
      options: { source: "workflow_incident", non_blocking_projects: true }
    }' 2>"${jq_err:-/dev/null}"); then
    # || result="" で AC-10 non-blocking 保証
    # 旧実装は `result=$(bash ...)` のみで、create-issue-with-projects.sh の非ゼロ exit が
    # set -e 環境下で bash プロセス自体を kill する経路があった
    result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$json_args") || result=""
  else
    echo "WARNING: jq -n failed to build JSON args (placeholder unsubstituted? --argjson type mismatch?): $(cat "$jq_err" 2>/dev/null || echo '(stderr empty)')" >&2
    echo "WARNING: Skipping incident registration. Adding to workflow_incident_skipped for Phase 5.6 reporting." >&2
    result=""
  fi
  # 統合 trap が EXIT で削除するため、明示的 rm は不要

  if [ -z "$result" ]; then
    echo "WARNING: create-issue-with-projects.sh returned empty result. Incident retained for Phase 5.6 reporting." >&2
    # Fallthrough — non-blocking, do NOT exit
  else
    new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url // empty')
    new_issue_number=$(printf '%s' "$result" | jq -r '.issue_number // empty')
    if [ -n "$new_issue_url" ]; then
      echo "✅ Workflow incident auto-registered: #${new_issue_number} (${new_issue_url})"
    else
      echo "WARNING: Issue creation failed (no URL returned). Incident retained for Phase 5.6 reporting." >&2
    fi
  fi
fi
```

**After the bash block** (orchestrator が tracking すべき context-local list):

| Outcome | List update |
|---------|------------|
| **Issue body empty** (`tmpfile` 未生成、HEREDOC 失敗) | `{type, details, root_cause_hint, iteration_id}` を `workflow_incident_skipped` へ append |
| **jq -n failed** (`json_args` 未構築) | 同上 |
| **`result` is empty** (script exec 失敗) | 同上 |
| **`new_issue_url` is empty** (script return 但し URL なし) | 同上 |
| **Issue creation succeeded** (`new_issue_url` 非空) | `{new_issue_number, new_issue_url, type, details}` を `workflow_incident_registered` へ append |

両 list は conversation-context-local (flow state 非永続化、`workflow_incident_processed_types` と同手法)。Phase 5.6.1 で「未処理 incident」/「自動登録された incident」 section の source として参照される。

### Step 7 — Mark processed

成功/失敗にかかわらず `type` を `workflow_incident_processed_types` に追加 (registration が失敗しても本 session で再質問されないようにする)。

## 不変条件

### Non-blocking guarantee

`create-issue-with-projects.sh` が失敗 (network error / API error 等) しても workflow は halt しない。warning を stderr 表示し continue する。incident は `workflow_incident_skipped` に retain され Phase 5.6 で reporting される。**The workflow MUST NOT halt** because incident registration failed.

### Phase 7 non-interference

本 Phase 5.4.4.1 codepath は Phase 7 (Issue creation from review recommendations) と独立。両者は同 flow 内で動作し別 Issue を作りうる。共通の helper として `create-issue-with-projects.sh` のみを共有し、ロジック merge はない。

### Default-on behavior

`workflow_incident:` section が `rite-config.yml` に不在の場合 `enabled: true` (default) として扱う。`enabled: false` のみが opt-out。
