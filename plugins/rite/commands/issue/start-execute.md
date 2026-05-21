---
description: |
  (Internal sub-skill — invoked by /rite:issue:start only. Do NOT invoke directly.)
  Issue 実装フェーズの実行 sub-skill。
  Phase 5.0 (Stop Hook Verification) + 5.1 (Implementation) + 5.2 (Lint) + 5.2.1 (Checklist) を担当。
---

# /rite:issue:start-execute

Execute the implementation phase for an Issue. This sub-skill is invoked from `start.md` after Phase 0-4 (Preconditions, Issue context, parent routing, branch setup, projects/iteration, work memory, implementation plan) have completed.

**Prerequisites**: Phase 0-4 of `start.md` have completed. The following information is available in conversation context:
- `{issue_number}` — target Issue number
- `{branch_name}` — created/checked-out branch
- `{plugin_root}` — resolved per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version)
- Implementation plan (from Phase 3)
- Issue body checklist (retained from Phase 3.6 if applicable)

---

## 🚨 MANDATORY Pre-flight: Flow State Update (MUST execute FIRST)

> 本 Pre-flight は sub-skill の **先頭** で実行し execute scope に関係なく flow-state write を保証する。末尾配置だと Phase 5.0/5.1 で早期 return した場合に flow-state write が抜けるため、先頭配置が必須。

**MUST run before any execute logic** (Phase 5.0 stop-hook verification / Phase 5.1 implementation / Phase 5.2 lint / Phase 5.2.1 checklist / return-output emission)。**not optional**:

```bash
# 4 引数 (--phase / --active / --next / --preserve-error-count) は本 sub-skill での
# Pre-flight pattern (同 pattern は他 sub-skill / create-interview workflow でも使用される
# 共有 pattern)。plugins/rite/hooks/tests/4-site-symmetry.test.sh は create-interview
# workflow (create.md / create-interview.md) 専用で本 sub-skill は対象外。
# state-path-resolve.sh + _resolve-flow-state-path.sh で per-session (schema_version=2) /
# legacy 両形式に対応。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "phase5_execute_running" \
      --active true \
      --next "rite:issue:start-execute Pre-flight completed. Proceed to Phase 5.0 (Stop Hook) → 5.1 (Implementation) → 5.2 (Lint) → 5.2.1 (Checklist), then return to caller. Caller MUST proceed to Phase 5.3 (PR creation). Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_PATCH_FAILED=1" >&2
    # 非 blocking: start.md delegation pre-write が safety net。
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "phase5_execute_running" --issue {issue_number} --branch "{branch_name}" --pr 0 \
      --next "rite:issue:start-execute Pre-flight completed. Proceed to Phase 5.0 (Stop Hook) → 5.1 (Implementation) → 5.2 (Lint) → 5.2.1 (Checklist), then return to caller. Caller MUST proceed to Phase 5.3 (PR creation). Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_CREATE_FAILED=1" >&2
  fi
fi
```

**Why `phase5_execute_running`**: caller (`start.md` Phase 5.0-5.2.1 Delegation Pre-write) は既に `phase5_execute_running` を書込済 (delegation in flight signal)。本 Pre-flight は patch mode で timestamp / `next_action` を refresh し、re-entry / interrupt 時にも sub-skill scope を識別できるようにする。`phase-transition-whitelist.sh` が `phase5_execute_running → phase5_stop_hook` (forward) / `phase5_execute_running → phase5_post_execute` (terminal) を whitelist 化する。

**Idempotence**: 単一 sub-skill invocation 内で複数回実行されても safe — patch mode は pre-update `.phase` から `previous_phase` を設定し、re-entry で `phase5_execute_running` のまま phase regression しない。

---

## Phase 5.0: Stop Hook Verification

**Pre-write** (before executing stop-hook verification):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_stop_hook" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "Execute Phase 5.0 (Stop Hook Verification). Skipping to Phase 5.1/5.2 without verifying the stop-guard hook is PROHIBITED. Do NOT stop."
```

Before entering the end-to-end flow, verify that the stop-guard hook is active to prevent flow interruptions when sub-skills return.

**Step 1**: Resolve `{plugin_root}` (if not already resolved in Phase 4.1) per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version).

**Step 2**: Check if `{plugin_root}/hooks/hooks.json` exists.

- If **hooks.json exists** (native hook management): hooks are managed by Claude Code's plugin system via `${CLAUDE_PLUGIN_ROOT}`. No `settings.local.json` registration is needed. Optionally clean up stale rite hooks from `settings.local.json` if present (same cleanup logic as [init.md Phase 4.5.0.2](../init.md)). **Skip Step 3** and proceed to Step 4.
- If **hooks.json does not exist**: Proceed to Step 3 (legacy registration).

**Step 3** (legacy fallback — only when hooks.json does not exist):

Read `.claude/settings.local.json` with Read tool. Check if `.hooks.Stop` exists and contains a command matching `bash {plugin_root}/hooks/stop-guard.sh` (full path match to avoid stale path false positives).

If stop-guard.sh is NOT registered (missing or stale path), register all rite hooks by merging the following into `.claude/settings.local.json` (preserve existing non-rite hooks and all other top-level keys like `permissions`):

| Hook Event | Command | Matcher |
|------------|---------|---------|
| Stop | `bash {plugin_root}/hooks/stop-guard.sh` | `""` |
| PreCompact | `bash {plugin_root}/hooks/pre-compact.sh` | `""` |
| PostCompact | `bash {plugin_root}/hooks/post-compact.sh` | `""` |
| SessionStart | `bash {plugin_root}/hooks/session-start.sh` | `""` |
| SessionEnd | `bash {plugin_root}/hooks/session-end.sh` | `""` |
| PreToolUse | `bash {plugin_root}/hooks/pre-tool-bash-guard.sh` | `"Bash"` |
| PostToolUse | `bash {plugin_root}/hooks/post-tool-wm-sync.sh` | `"Bash"` |

Each hook entry uses the format: `{"matcher": "", "hooks": [{"type": "command", "command": "bash {plugin_root}/hooks/{script}"}]}`. For hooks with `"Bash"` matcher, use `{"matcher": "Bash", ...}`. See [init.md Phase 4.5.2](../init.md) for full reference.

**Step 4**: Ensure scripts are executable:

```bash
chmod +x {plugin_root}/hooks/stop-guard.sh {plugin_root}/hooks/pre-compact.sh {plugin_root}/hooks/post-compact.sh {plugin_root}/hooks/session-start.sh {plugin_root}/hooks/session-end.sh {plugin_root}/hooks/pre-tool-bash-guard.sh {plugin_root}/hooks/post-tool-wm-sync.sh 2>/dev/null || true
```

If `chmod` fails, display `⚠️ Hook scripts may not be executable. Flow may require manual continuation after sub-skill returns.` If hook registration fails (e.g., file permission error), display the same warning and continue — Mandatory After instructions provide textual fallback.

**Step 5**: Update version marker after hook registration:

```bash
VERSION=$(jq -r '.version' "{plugin_root}/.claude-plugin/plugin.json" 2>/dev/null)
if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
  echo "$VERSION" > "$STATE_ROOT/.rite-initialized-version"
fi
```

**Step 6**: Read `workflow_incident.enabled` from `rite-config.yml` and cache for the rest of Phase 5. Default to `true` when the section is absent.

> **Reference**: [Workflow Incident Detection](./references/workflow-incident-detection.md#phase-50-step-6--workflow_incidentenabled-parser) for the canonical `sed -n` section-range parser bash literal, normalization rules (case-insensitive, `yes`/`no`/`1`/`0` variants), and the rationale for replacing the previous `grep -A3` implementation.

Retain `workflow_incident_enabled` in conversation context. Phase 5.4.4.1 reads this value and skips its entire processing if `false`.

### 🚨 Mandatory After 5.0

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-stop-hook phase:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_stop_hook" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "Phase 5.0 completed (stop-guard verified, workflow_incident_enabled cached). Proceed to Phase 5.1 (Implementation). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 5.1 now**.

## Phase 5.1: Implementation

Run [Preflight Protocol](./start.md#preflight-protocol) before starting implementation.

> **Module**: [Implementation Guidance](./implement.md) - Follow Phase 3 plan. Handles: Read/Edit/Bash, parallel (5.1.0), commit message (5.1.1), checklist update (5.1.1.1), parent progress (5.1.2), flow state updates, mandatory `rite:lint` invocation.

> **Issue body checklist update**: `implement.md` Phase 5.1.1.1 が per-task update を強制 (SoT)。大量残存は `checklist-auto-check.md` Phase 5.2.1 Step 0 / `cleanup.md` Phase 1.6.5.2 で警告される。

Skipping lint risks merging code that violates project quality standards, creating technical debt that compounds across subsequent Issues.
**Critical**: After 5.1.1, **immediately** invoke `rite:lint`. Do NOT stop.

### 5.1.3 Safety Check (Implementation Rounds)

> **Reference**: [Execution Metrics](../../references/execution-metrics.md#safety-thresholds)

Read `safety.max_implementation_rounds` from rite-config.yml (default: 20). Track implementation round count in flow state via the `implementation_round` field (incremented each time Phase 5.1 is re-entered from 5.2.1 checklist failure).

**Round count tracking**: When re-entering Phase 5.1, update flow state atomically:

```bash
bash {plugin_root}/hooks/flow-state-update.sh increment --field "implementation_round"
```

**When round count exceeds limit**:

```
⚠️ 安全装置が発動しました
原因: max_implementation_rounds 超過 ({current_round} > {limit})
```

Present options via `AskUserQuestion`:
- 続行（制限を引き上げ）
- 中止（作業メモリに状態保存）→ Phase 5.6
- 手動介入（ユーザーが直接対応）→ terminate

**When 中止 is selected (5.1.3 Abort path)**: Emit the abort return block (see [Return Output Format](#return-output-format-before-return) — abort variant) and return control to caller. The caller (`start.md` Mandatory After 5.0-5.2.1 — Step 3) detects `[start:execute:aborted]` sentinel and routes directly to Phase 5.6 (skipping PR creation).

## Phase 5.2: Quality Check

Run [Preflight Protocol](./start.md#preflight-protocol) before invoking lint.

**Pre-check** (defense-in-depth): Always update flow state before invoking lint to ensure the stop-guard has correct phase and fresh timestamp. This unconditional write prevents stale state from causing intermittent flow stops:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_lint" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:lint returns: [lint:success/skipped]->Phase 5.2.1 (checklist). [lint:error]->fix and re-invoke. [lint:aborted]->Phase 5.6. Do NOT stop."
```

Invoke `skill: "rite:lint"` after 5.1.

**Immediate after lint returns**: When `rite:lint` outputs a result pattern and returns control, do **NOT** churn or pause — **immediately** proceed to Mandatory After 5.2 below. The lint sub-skill has already updated flow state to `phase5_post_lint` via Phase 4.0 (defense-in-depth); execute the Mandatory After 5.2 steps without delay.

**Results**: `[lint:success/skipped]`→5.2.1→return-to-caller, `[lint:error]`→fix→5.2, `[lint:aborted]`→**emit WORKFLOW_INCIDENT sentinel + abort return block, then return to caller** (caller orchestrator routes to Phase 5.6).

> **Emit canonical literal**: See [§A — Phase 5.2 `[lint:aborted]`](./references/workflow-incident-emit-pattern.md#a--phase-52-lintaborted) (SoT) for the canonical bash literal and `|| true` non-blocking guarantee, plus the [§不変条件](./references/workflow-incident-emit-pattern.md#不変条件) section for the response-text-inclusion requirement that Phase 5.4.4.1 grep detection depends on. `--pr-number 0` (no PR yet at lint time) is documented in §A. Do NOT inline the bash literal here.

**On `[lint:aborted]` — abort return**: After emitting the §A canonical bash literal (WORKFLOW_INCIDENT sentinel), emit the abort return block (see [Return Output Format](#return-output-format-before-return) — abort variant) and return control to caller. Do NOT proceed to Phase 5.2.1 (checklist confirmation). The caller (`start.md` Mandatory After 5.0-5.2.1 — Step 3) detects `[start:execute:aborted]` sentinel and routes directly to Phase 5.6.

### 5.2.0.1 Out-of-Scope Warnings

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

Auto-register lint warnings outside change scope as Issues. Determine via `git diff --unified=0 HEAD` + AI judgment. Group by file, create via the common script (Status: Todo, Priority: Medium, Complexity: S). On failure, add to PR "Known Issues".

**Per-Issue procedure** (execute for each grouped warning):

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{warning_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{type}: {summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
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
    options: { source: "lint", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
new_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**On script failure** (`issue_url` is empty): Skip and add to PR "Known Issues" section.

**Embed in PR context**: Ignored errors/skip status retained before Phase 5.3 invocation for PR body "Known Issues" section (`lint エラーが未解決（{error_count}件）...`). See `/rite:lint` "Clarification of responsibilities".

### 🚨 Mandatory After 5.2

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Ignore** `/rite:lint` "Next steps" (standalone only). **Immediately** update flow state and execute Phase 5.2.1.

**Step 1**: Update flow state to post-lint phase (atomic). This second write (after the Phase 5.2 pre-check write) transitions from `phase5_lint` to `phase5_post_lint`, ensuring stop-guard routes to checklist confirmation rather than re-invoking lint:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_lint" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "Phase 5.2.1: Check Issue checklist completion. All complete->return to caller (start.md) for Phase 5.3 PR creation. Incomplete->return to Phase 5.1 implementation. Do NOT stop."
```

**Step 2**: 本 sub-skill は Workflow Incident Detection 自体を実行しない (caller `start.md` Mandatory After 5.0-5.2.1 に委譲)。sub-skill 内部で emit された `[CONTEXT] WORKFLOW_INCIDENT=1` sentinel (`[lint:aborted]` 経路の §A canonical bash literal、または `lint.md` sub-skill の Sentinel Visibility Rule 経由) は会話コンテキストに残り、caller の Phase 5.4.4.1 が grep 検出・処理 (parse → dedupe → AskUserQuestion → create-issue / skip → mark processed) する責務を負う。

**Step 3**: **→ Proceed to Phase 5.2.1 now**.

## Phase 5.2.1: Checklist Confirmation

> **Module**: [Checklist Auto-Check](./references/checklist-auto-check.md) — Phase 5.2.1 (grep ベースの完了確認) + Phase 5.2.1.1 (Auto-Check Evaluation: evidence collection / per-item assessment / Issue body update / re-check / uncertain handling) の SoT。

**Owner**: `/rite:issue:start-execute` after `/rite:lint` returns. **Condition**: Execute only if checklist retained in Phase 3.6. **Purpose**: Block PR until all items complete.

Execute the Module procedure: grep `- [ ]` pattern (Phase 5.2.1) → if `≥1` incomplete, run Auto-Check Evaluation (Phase 5.2.1.1) → re-check → all complete → return to caller for Phase 5.3, otherwise return to Phase 5.1. **Mandatory**, cannot skip.

---

## Return Output Format (Before Return)

> **Reference**: `start.md` の sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0) に追従。flow-state write は 🚨 MANDATORY Pre-flight (本ファイル冒頭) で execute scope に関係なく post-execute phase を記録。本 re-patch は defense-in-depth second write として timestamp / `next_action` を refresh する。

Immediately before emitting the four-line return block, re-patch flow state (idempotent with Pre-flight write):

```bash
# 4 引数 (--phase / --active / --next / --preserve-error-count) は本 sub-skill での
# Pre-flight pattern (共有 pattern)。Pre-flight 後の self-patch のため file 存在は保証済み。
# 4-site-symmetry.test.sh は create-interview workflow 専用で本 sub-skill は対象外。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "phase5_post_execute" \
      --active true \
      --next "rite:issue:start-execute completed. Proceed to Phase 5.3 (PR creation). Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] EXECUTE_RETURN_PATCH_FAILED=1" >&2
    # 非 blocking: start.md Mandatory After 5.0-5.2.1 の redundant patch が続行する。
  fi
fi
```

> **Why patch mode only (no create fallback)**: Pre-flight が "file missing" branch (`create` mode) を処理済。本 section 到達時は flow state file 存在 + `.phase = phase5_execute_running` (Pre-flight 書込後の base) または内部 phase (`phase5_stop_hook` / `phase5_post_lint` 等) が保証済。ここで `create` 呼出は `previous_phase` を空文字列にリセットし `phase-transition-whitelist.sh` whitelist transition check を defeat するため不可。patch mode で transition chain を preserve する。

After the flow-state update, output the result pattern. Caller-continuation reminder を **immediately before** result pattern に emit。Return block は **4 line** 構成: (1) `[CONTEXT] EXECUTE_DONE=1` grep marker / (2) plain-text blockquote continuation reminder / (3) HTML-commented caller instructions / (4) HTML-commented result sentinel。全 4 行が sub-skill の **last visible lines**。

> **Return block design rationale**:
> - caller continuation hint を plain-text line + HTML comment の **dual form** で emit（HTML comment が rendering で strip される場合への defense）
> - result pattern を HTML comment 化 (`<!-- [start:execute:completed] -->` / `<!-- [start:execute:aborted] -->`) — sentinel は grep-matchable (`grep -F '[start:execute:'`) のまま AC 保持し、user-visible terminal token としての sentinel 出力を抑止して LLM turn-boundary heuristic 起因の `continue` 要求 stop を防ぐ
> - `[CONTEXT] EXECUTE_DONE=1` marker を return block の **FIRST line** に追加（not last）— orchestrator Pre-check Item 0 と Mandatory After 5.0-5.2.1 Step 0 が consume する grep signal、HTML strip rendering でも検出可能な plain-text 形式

**Output format example (success — `[start:execute:completed]`)**:

```
[CONTEXT] EXECUTE_DONE=1; next=phase_5_3
> ⏭ MUST continue (turn を閉じない): Phase 5.3 PR creation → terminal — 実装は完了 review-fix loop 未起動のため停止禁止。
<!-- caller: MUST execute the following bash command as your VERY FIRST tool call BEFORE any text output, narrative, or response generation (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase phase5_post_execute --active true --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 5.3. Do NOT stop.' --if-exists --preserve-error-count` IMMEDIATELY AFTER bash success, continue with Phase 5.3 (PR creation) in the SAME response turn. DO NOT end the turn. DO NOT output any narrative text before this bash call. No PR has been created yet. -->
<!-- [start:execute:completed] -->
```

**Output format example (abort — `[start:execute:aborted]`)**:

abort path (Phase 5.1.3 中止 / `[lint:aborted]`) では `next=phase_5_6` marker に切替え、caller-instruction HTML comment 内の next-phase 指示を Phase 5.6 へ変更する:

```
[CONTEXT] EXECUTE_DONE=1; next=phase_5_6
> ⏭ MUST continue (turn を閉じない): Phase 5.6 Completion Report → terminal — execute aborted (user 中止 or [lint:aborted]) PR creation は skip、完了報告のみ。
<!-- caller: MUST execute the following bash command as your VERY FIRST tool call BEFORE any text output, narrative, or response generation (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase phase5_post_execute --active true --next 'Execute aborted; routing to Phase 5.6 (Completion Report). Skip PR creation.' --if-exists --preserve-error-count` IMMEDIATELY AFTER bash success, route to Phase 5.6 (Completion Report) in the SAME response turn — skip Phase 5.3 (PR creation) entirely. DO NOT end the turn. DO NOT output any narrative text before this bash call. No PR exists. -->
<!-- [start:execute:aborted] -->
```

> **Plain-text form rationale**: 短く user-friendly な Markdown blockquote (`> ⏭ MUST continue (turn を閉じない):`) にすることで (a) rendered Markdown で視覚的に「停止禁止・継続必須」の文脈が明確、(b) HTML コメント (LLM 向け詳細) との責任分担が明確。詳細な caller 向け instruction は HTML コメント側に残し、plain-text 行は user 向けの短い imperative status indicator として機能する。user-visible な最終コンテンツは `⏭ MUST continue` blockquote となり、sentinel token は HTML コメント化されレンダリング時に不可視。`継続中` (現状報告) ではなく `MUST continue` (命令形) を採用するのは、reminder 文言が現状報告的に解釈されると LLM の turn-boundary heuristic implicit stop を防げない事象への対策。

Result pattern (grep-matchable string inside HTML comment):

- **Execute completed (success)**: `<!-- [start:execute:completed] -->` (matches `grep -F '[start:execute:completed]'`) — emitted when Phase 5.0/5.1/5.2/5.2.1 all complete successfully. Caller routes to Phase 5.3 (PR creation).
- **Execute aborted**: `<!-- [start:execute:aborted] -->` (matches `grep -F '[start:execute:aborted]'`) — emitted when Phase 5.1.3 Safety Check user selects 中止, or when `rite:lint` returns `[lint:aborted]`. Caller routes to Phase 5.6 (Completion Report), **skipping** Phase 5.3.

Both patterns are consumed by the orchestrator (`start.md` Mandatory After 5.0-5.2.1 — Step 3) to determine the next action. The plain-text reminder is visible to both the LLM and the human user; the HTML comments hide the caller instructions and sentinel token from the user-visible rendered view while keeping them available to LLM-side grep / context inspection.

---

## 🚨 Caller Return Protocol

Sub-skill 完了時、control は **MUST** caller (`start.md`) へ戻る。caller は **同 response turn で MUST immediately** 🚨 Mandatory After 5.0-5.2.1 を実行し、sentinel に応じて Phase 5.3 (PR creation — success path) または Phase 5.6 (Completion Report — abort path) へ進む。

**WARNING (success path)**: Success path で本セクションで停止すると implement / lint 成果物が PR 化されず workflow が放棄される。

**WARNING (abort path)**: Abort path で Phase 5.3 へ誤進すると、中止された変更 (incomplete implementation / lint failure) で PR を作ってしまい review noise を生む。caller 側 sentinel routing が誤動作した場合の最終 fallback は user による手動介入。

**Output rules**:

0. **FIRST**: `[CONTEXT] EXECUTE_DONE=1; next=phase_5_3` (success) または `[CONTEXT] EXECUTE_DONE=1; next=phase_5_6` (abort) を **plain-text line** で出力（HTML-commented 不可）。位置規定:
   - **0b (構造保証、canonical)**: Rules 0-1 の相対順序が **4-line return block** を pin する: Rule 0 (FIRST) → plain-text continuation reminder → HTML-commented caller instructions → Rule 1 (absolute LAST)。この 4-line invariant が canonical で、他の位置記述はここから導出
   - **0a (絶対位置、0b から導出)**: 4-line block 構造より、本 marker は **4th-to-last visible line**（`<!-- [start:execute:completed] -->` / `<!-- [start:execute:aborted] -->` absolute-last sentinel の 3 行前）
   - **0c (目的)**: grep marker for orchestrator Pre-check Item 0 (routing dispatcher) and for Mandatory After 5.0-5.2.1 Step 0 bash block comment reference (informational — Step 0 は unconditional idempotent `flow-state-update.sh patch` であり marker 分岐なし); LLM turn-boundary heuristic 対策の defense-in-depth
1. Result pattern を HTML comment (`<!-- [start:execute:completed] -->` または `<!-- [start:execute:aborted] -->`) で **absolute last line** に出力 (sentinel は grep-matchable だが user-visible でない)
2. Bare `[start:execute:completed]` / `[start:execute:aborted]` 形式（HTML comment wrap なし）は **禁止**（user-visible terminal token として regressed）
3. Result pattern の **後ろに narrative text を出さない**（`→ Return to start.md` 等）— LLM の natural stopping point を生む
4. Caller は HTML comment 内の grep-matchable 文字列 (`grep -F '[start:execute:completed]'` / `grep -F '[start:execute:aborted]'`) と plain-text `[CONTEXT] EXECUTE_DONE=1` marker を grep で読取り、success path は即 Phase 5.3 へ、abort path は即 Phase 5.6 へ継続

> **Caller responsibility note**: 上記 Rules 0-3 は本 sub-skill (`start-execute.md`) の出力に関する MUST/MUST NOT 制約。Rule 4 は subject = Caller の **Caller-side expectation** (本 sub-skill が caller に期待する後続動作の documentation)。本 sub-skill が emit する return block の構造健全性は必要条件であって十分条件ではなく、caller (`start.md`) 側の 🚨 Mandatory After 5.0-5.2.1 Step 0 が sub-skill return 直後の **VERY FIRST tool call** として bash literal を fire することが MUST。
