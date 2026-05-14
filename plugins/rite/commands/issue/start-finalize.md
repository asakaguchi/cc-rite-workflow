---
description: |
  (Internal sub-skill — invoked by /rite:issue:start only. Do NOT invoke directly.)
  Issue 完結フェーズの実行 sub-skill。
  Phase 5.5 (Ready for Review) + 5.5.1 (Status In Review) + 5.5.2 (Metrics) + 5.6 (Completion Report) + 5.7 (Parent Issue Completion) + Workflow Termination を担当。
---

# /rite:issue:start-finalize

Execute the finalize phase for an Issue. This sub-skill is invoked from `start.md` after Phase 5.3-5.4 (`rite:issue:start-publish`) has completed with `[start:publish:completed]` sentinel.

**Prerequisites**: Phase 0-5.4 of `start.md` and `start-publish` sub-skill have completed. The following information is available in conversation context:
- `{issue_number}` — target Issue number
- `{branch_name}` — created/checked-out branch
- `{pr_number}` — populated from Phase 5.3 `[pr:created:{N}]`
- `{plugin_root}` — resolved per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version)
- `{owner}`, `{repo}` — from `gh repo view`
- `{parent_issue_number}` — from flow-state via `state-read.sh` (Phase 5.7)
- Review-fix loop converged (mergeable / replied-only)

---

## 🚨 MANDATORY Pre-flight: Flow State Update (MUST execute FIRST)

> 本 Pre-flight は sub-skill の **先頭** で実行し finalize scope に関係なく flow-state write を保証する。Return Output Format 到達前に LLM stop / context truncation / interrupt が発生した場合でも、`phase5_finalize_running` phase + sub-skill 由来の `next_action` が必ず記録されるよう (caller の delegation pre-write を上書きせず timestamp / `next_action` を refresh)、sub-skill 先頭で Pre-flight write を保証する。terminal `completed, active=false` への遷移は本 sub-skill 末尾の Workflow Termination section が担う。

**MUST run before any finalize logic** (Phase 5.5 ready / 5.5.1 status / 5.5.2 metrics / 5.6 completion / 5.7 parent close / Workflow Termination / return-output emission)。**not optional**:

```bash
# 4 引数 symmetry (--phase / --active / --next / --preserve-error-count) は
# plugins/rite/hooks/tests/4-site-symmetry.test.sh で test 担保。state-path-resolve.sh
# + _resolve-flow-state-path.sh で per-session (schema_version=2) / legacy 両形式に対応。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "phase5_finalize_running" \
      --active true \
      --next "rite:issue:start-finalize Pre-flight completed. Proceed to Phase 5.5 (Ready for Review) → 5.5.1 → 5.5.2 → 5.6 → 5.7 → Workflow Termination, then return to caller. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_PATCH_FAILED=1" >&2
    # 非 blocking: start.md delegation pre-write が safety net。
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "phase5_finalize_running" --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
      --next "rite:issue:start-finalize Pre-flight completed. Proceed to Phase 5.5 (Ready for Review) → 5.5.1 → 5.5.2 → 5.6 → 5.7 → Workflow Termination, then return to caller. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_CREATE_FAILED=1" >&2
  fi
fi
```

**Why `phase5_finalize_running`**: caller (`start.md` Phase 5.5-Termination Delegation Pre-write) は既に `phase5_finalize_running` を書込済 (delegation in flight signal)。本 Pre-flight は patch mode で timestamp / `next_action` を refresh し、re-entry / interrupt 時にも sub-skill scope を識別できるようにする。`phase-transition-whitelist.sh` が `phase5_finalize_running → phase5_ready` (forward) / `phase5_finalize_running → completed` (terminal abort direct) を whitelist 化する。success path は `phase5_finalize_running → phase5_ready → ... → phase5_completion → phase5_parent_completion → phase5_post_parent_completion → completed` の間接経路を辿り、direct edge `phase5_finalize_running → completed` は abort path の direct terminal write 用。`[start:finalize:completed]` IS the workflow terminal sentinel (design doc SPEC-TECH-DECISIONS #3)、別 `phase5_post_finalize` 間接層は意図的に作らない。

**Idempotence**: 単一 sub-skill invocation 内で複数回実行されても safe — patch mode は pre-update `.phase` から `previous_phase` を設定し、re-entry で `phase5_finalize_running` のまま phase regression しない。

---

## Phase 5.5: Ready for Review

> **⚠️ MANDATORY**: The following `AskUserQuestion` confirmation MUST be executed. Do NOT skip this step for context optimization or any other reason. The user must always confirm before changing the PR to Ready for review.

When loop completes, confirm via `AskUserQuestion`:

```
レビューが完了しました（一気通貫フロー）
総合評価: {assessment}
指摘件数: {total_findings}
オプション: Ready for review に変更（推奨）/ ドラフトのまま完了 / 追加の修正を行う
```

> **Data Handoff**: When invoking `rite:pr:ready`, PR number is passed as an argument. Issue information from Phase 0.1 is available in work memory (loaded by `rite:pr:ready` Phase 0), avoiding redundant `gh issue view` calls.

**Ready**→invoke `rite:pr:ready`→5.5.1. **Draft**→5.6 (no Ready, but completion report still required). **More fixes**→emit `[start:finalize:aborted]` and return to caller (user explicitly chose to continue iterating).

On user selecting "Ready for review", invoke `skill: "rite:pr:ready", args: "{pr_number}"`.

**Immediate after ready returns**: When `rite:pr:ready` outputs `[ready:completed]` and returns control, do **NOT** churn or pause — **immediately** proceed to 5.5.0.1 Mandatory After 5.5 below. The ready sub-skill has already updated flow state to `phase5_post_ready` via Phase 4.6 (defense-in-depth, fixes #17); execute the 5.5.0.1 steps without delay. The completion report (Phase 5.6) has NOT been output yet — `ready.md` intentionally skips it in e2e flow. You MUST continue to Phase 5.5.1, 5.5.2, and 5.6.

**Results**: `[ready:completed]`→5.5.0.1→5.5.1→5.5.2→5.6. `[ready:error]`→**emit sentinel and ask user** (#366).

> **Emit canonical literal**: See [§D — Phase 5.5 `[ready:error]`](./references/workflow-incident-emit-pattern.md#d--phase-55-readyerror) (SoT) for both emit steps (Step 1 `skill_load_failure` + Step 2 `manual_fallback_adopted` after user selects 「Edit ツールで手動 Ready 化」 in the `AskUserQuestion`), `|| true` non-blocking guarantee, and `--pr-number {pr_number}` semantics. The response-text-inclusion requirement that caller Phase 5.4.4.1 grep detection depends on is documented in [§不変条件](./references/workflow-incident-emit-pattern.md#不変条件). Do NOT inline the bash literals here.

**On `[ready:error]` — routing**: After emitting §D canonical literal, present `AskUserQuestion` (3 options: `再試行` / `Edit ツールで手動 Ready 化 (incident 記録)` / `terminate`):
- **「再試行」**: re-invoke `rite:pr:ready` (loop within Phase 5.5).
- **「Edit ツールで手動 Ready 化 (incident 記録)」**: emit §D Step 2 (`manual_fallback_adopted`), then proceed to 5.5.0.1 (treat as `[ready:completed]`).
- **「terminate」**: emit `[start:finalize:aborted]` abort return block and return to caller. Workflow Termination is skipped — caller's Mandatory After patches terminal state.

### 5.5.0.1 🚨 Mandatory After 5.5

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Verify**: `[ready:completed]` pattern confirmed. `rite:pr:ready` returned successfully. Status update, metrics recording, and completion report are still pending — these are the **primary deliverables** of the e2e flow that the user expects to see.

**Step 1**: Update flow state to post-ready phase (atomic). This write transitions from `phase5_post_review`/`phase5_post_fix` to `phase5_post_ready`, ensuring stop-guard routes to Status update rather than re-invoking ready (fixes #781):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_ready" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Phase 5.5.1: Update Issue Status to In Review, then Phase 5.5.2 metrics, then Phase 5.6 completion report. Do NOT stop."
```

**Step 2**: Sync to local work memory:

```bash
WM_SOURCE="ready" \
  WM_PHASE="phase5_post_ready" \
  WM_PHASE_DETAIL="Ready処理後" \
  WM_NEXT_ACTION="Issue Status を In Review に更新後、メトリクス記録、完了レポートを実行" \
  WM_BODY_TEXT="Post-ready sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  WM_READ_FROM_FLOW_STATE="true" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 3**: 本 sub-skill は Workflow Incident Detection 自体を実行しない (caller `start.md` Mandatory After 5.5-Termination に委譲)。sub-skill 内部で emit された `[CONTEXT] WORKFLOW_INCIDENT=1` sentinel (`[ready:error]` 経路の §D canonical bash literal、または `ready.md` sub-skill の Sentinel Visibility Rule 経由) は会話コンテキストに残り、caller の Phase 5.4.4.1 が grep 検出・処理する責務を負う。

**Step 4**: **→ Proceed to 5.5.1 now**.

## Phase 5.5.1: Update Issue Status to "In Review"

**Pre-condition check** (#490 AC-5): See [Pre-condition Gate](./references/pre-condition-gate.md). Expected `.phase`: `phase5_post_ready`.

```bash
if curr=$(bash {plugin_root}/hooks/state-read.sh --field phase --default ""); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field phase in Phase 5.5.1 pre-condition" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_5_1_pre_condition; rc=$rc" >&2
  exit 1
fi
if [ "$curr" != "phase5_post_ready" ]; then
  echo "ERROR: Phase 5.5.1 pre-condition failed. .phase=$curr (expected: phase5_post_ready)" >&2
  echo "ACTION: Return to Phase 5.5 (Ready for Review) and execute its Pre-write + rite:pr:ready invocation + Mandatory After 5.5 before entering Phase 5.5.1." >&2
  echo "⚠️ LLM MUST NOT proceed to Phase 5.5.1 Pre-write below. Re-invoke Phase 5.5 first." >&2
  exit 1
fi
```

**Pre-write**:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_status_in_review" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Execute Phase 5.5.1 (Issue Status → In Review). Skipping to Phase 5.5.2/5.6 without running the Status update is PROHIBITED. Do NOT stop."
```

> **Module**: [Projects Status Update Callsites](./references/projects-status-update-callsites.md#callsite-2--phase-551-issue-status--in-review) — Callsite 2 (Phase 5.5.1) bash literal SoT。Skip if `projects.enabled: false` in rite-config.yml. Otherwise execute the Module procedure (Status update to "In Review", `auto_add: false` since Phase 2.4 already auto-added if missing). Defense-in-depth — `rite:pr:ready` Phase 4 also attempts this, but may not execute reliably within e2e flow. API レベル動作は [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update) を参照。

### 🚨 Mandatory After 5.5.1

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-status-in-review phase:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_status_in_review" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Phase 5.5.1 completed (Issue Status → In Review). Proceed to Phase 5.5.2 (Metrics Recording). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 5.5.2 now**.

## Phase 5.5.2: Metrics Recording

**Pre-write**:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_metrics" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Execute Phase 5.5.2 (Metrics Recording). Skipping to Phase 5.6 without running metrics is PROHIBITED. Do NOT stop."
```

> **Reference**: [Execution Metrics](../../references/execution-metrics.md). **Module**: [Metrics Recording](./references/metrics-recording.md) — Phase 5.5.2 全体 (Step 1-5 + `implementation_round` inline metrics capture + METRICS_SKIPPED 経路 + heredoc PATCH 本体) の SoT。

**Skip Steps note** (referenced by Phase 5.6 pre-condition): When `metrics.enabled: false` in rite-config.yml, skip Steps 1-5 (per Module) **but unconditionally execute Mandatory After 5.5.2**. The `phase5_post_metrics` marker is required for Phase 5.6 pre-condition to pass. Skipping the Mandatory After would leave `.phase = phase5_post_status_in_review` and trip the Phase 5.6 ERROR gate.

Otherwise: execute the Module procedure (Step 1 collect → Step 2 thresholds → Step 3 failure classification → Step 4 PATCH → Step 5 repeated failure check). On `[CONTEXT] METRICS_SKIPPED=1` sentinel emission (state-read.sh failure), skip Steps 2-4 but still execute Mandatory After 5.5.2 unconditionally (per Module's "Claude への指示" section).

### 🚨 Mandatory After 5.5.2

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-metrics phase:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_metrics" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Phase 5.5.2 completed (metrics recorded). Proceed to Phase 5.6 (Completion Report). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 5.6 now**.

## Phase 5.6: Completion Report

**Pre-condition check** (#490 AC-5): See [Pre-condition Gate](./references/pre-condition-gate.md). Expected `.phase`: `phase5_post_metrics`. When `metrics.enabled: false`, Phase 5.5.2 must still write the `phase5_post_metrics` marker via its Mandatory After block (body skip allowed; marker required).

```bash
if curr=$(bash {plugin_root}/hooks/state-read.sh --field phase --default ""); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field phase in Phase 5.6 pre-condition" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_6_pre_condition; rc=$rc" >&2
  exit 1
fi
if [ "$curr" != "phase5_post_metrics" ] && [ "$curr" != "phase5_finalize_running" ]; then
  echo "ERROR: Phase 5.6 pre-condition failed. .phase=$curr (expected: phase5_post_metrics or phase5_finalize_running for abort path)" >&2
  echo "ACTION: Return to the missing phase (5.5.1 Status Update → 5.5.2 Metrics) and execute each Pre-write + main procedure + Mandatory After before entering Phase 5.6." >&2
  echo "⚠️ LLM MUST NOT proceed to Phase 5.6 Pre-write below. Re-invoke the missing phase first." >&2
  exit 1
fi
# Note: phase5_finalize_running は abort path (Draft 化 or [ready:error] terminate 経路で
# Phase 5.5.1/5.5.2 を skip して直接 Phase 5.6 へ進むケース) を accept する。
# success path は phase5_post_metrics 経由が正規路。
```

**Pre-write**:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_completion" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Execute Phase 5.6 (Completion Report). Determine parent_issue_number routing in Phase 5.7. If parent_issue_number is non-zero, proceed to Phase 5.7; otherwise jump directly to the Workflow Termination block (bypass 5.7). Do NOT stop."
```

> See [completion-report.md](./completion-report.md) for the full procedure (template read, placeholder substitution, output cases, self-verification, and inline fallbacks).

### 5.6.1 Workflow Incident Reporting (#366)

> **Output ordering** (must match `completion-report.md` Step 3.5): Phase 5.6.1 is appended **after Phase 5.6.2 (Wiki Ingest Status Reporting)**, not directly after the standard completion report sections. The runtime sequence is: standard completion sections → Phase 5.6.2 (Wiki ingest 状況) → Phase 5.6.1 (workflow incidents). The section numbers (5.6.1 / 5.6.2) reflect introduction order (#366 first, #524 second) and are intentionally NOT in execution order — see Phase 5.6.2 ordering note for the canonical execution order.

After Phase 5.6.2 (Wiki Ingest Status Reporting) is appended, append a "未処理 incident" section listing any workflow incidents that were skipped (user chose "skip" in Phase 5.4.4.1) or whose Issue creation failed (`create-issue-with-projects.sh` returned empty).

**Source**: The context-local `workflow_incident_skipped` list maintained by caller's Phase 5.4.4.1. Each entry is `{type, details, root_cause_hint, iteration_id}`.

**Output format** (only when the list is non-empty):

```markdown
### ⚠️ 未処理の workflow incident

| # | Type | Details | Root cause hint | iteration_id |
|---|------|---------|-----------------|--------------|
| 1 | {type} | {details} | {root_cause_hint or "(none)"} | {iteration_id} |

> これらの incident は workflow 実行中に検出されましたが、Issue として登録されませんでした (user skipped or registration failed)。手動で `/rite:issue:create` で記録することを推奨します。
```

**When the list is empty**: Skip this section entirely (do not display "no incidents" placeholder — minimize output).

**Also report registered incidents** when `workflow_incident_registered` list is non-empty (auto-registered Issues from Phase 5.4.4.1 step 6):

```markdown
### ✅ 自動登録された workflow incident

| # | Issue | Type | Details |
|---|-------|------|---------|
| 1 | #{new_issue_number} | {type} | {details} |
```

### 5.6.2 Wiki Ingest Status Reporting (#524)

> **Source of truth**: `[CONTEXT] WIKI_INGEST_DONE=1` / `WIKI_INGEST_SKIPPED=1; reason=...` / `WIKI_INGEST_FAILED=1; reason=...` / `WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4` lines emitted by `pr/review.md` Phase 6.5.W.2, `pr/fix.md` Phase 4.6.W.2, and `issue/close.md` Phase 4.4.W.2 throughout this `/rite:issue:start` invocation. These lines flow into the conversation context the same way caller's Phase 5.4.4.1 sentinels do.

> **Output ordering** (must match `completion-report.md` Step 3.5): This section is appended **immediately after the case-specific sections (項目テーブル + フェーズ進捗 + 次のステップ)** of the completion report, **before** the workflow incident sections (5.6.1). Both 5.6.2 and 5.6.1 then together form the trailing report sections.

Append a "Wiki ingest 状況" section so the user can confirm at a glance whether the Experience Wiki growth path actually executed during this Issue. This addresses Issue #524 AC-5 — the regression where Phase X.X.W was silently skipped and the user had no visibility into the missing growth.

**Step 1 — Aggregate signals from conversation context**:

Scan the recent conversation context for these patterns (the same context the caller's Phase 5.4.4.1 grep operates on):

| Pattern | Counter |
|---------|---------|
| `[CONTEXT] WIKI_INGEST_DONE=1; ...` | `done_count` |
| `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=disabled` | `skipped_disabled_count` |
| `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=auto_ingest_off` | `skipped_auto_off_count` |
| `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing` | `skipped_commit_branch_missing_count` |
| `[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_*` or `reason=trigger_exit_*` | `failed_count` (all `commit_rc_*` values fold into `failed_count` except `commit_rc_4` which is segregated into `push_failed_count`) |
| `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4` | `push_failed_count` |

Also retrieve the current wiki branch state (best-effort — never block on this):

```bash
wiki_branch=$(awk '/^wiki:/{h=1;next} h && /^[[:space:]]+branch_name:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"
last_wiki_commit=""
if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then
  last_wiki_commit=$(git log -1 --format='%aI' "$wiki_branch" 2>/dev/null)
elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
  last_wiki_commit=$(git log -1 --format='%aI' "origin/$wiki_branch" 2>/dev/null)
fi
echo "[CONTEXT] WIKI_LAST_COMMIT=${last_wiki_commit:-}"
```

**Step 2 — Output format** (always render, even when all counters are 0 — the absence is itself a signal worth reporting per AC-5):

```markdown
### 📚 Wiki ingest 状況

| シグナル | 件数 |
|----------|------|
| ✅ DONE (trigger + ingest 完了) | {done_count} |
| ⚠️ SKIPPED (disabled) | {skipped_disabled_count} |
| ⚠️ SKIPPED (auto_ingest_off) | {skipped_auto_off_count} |
| ⚠️ SKIPPED (commit_branch_missing) | {skipped_commit_branch_missing_count} |
| ❌ FAILED (trigger / commit エラー) | {failed_count} |
| ❌ PUSH_FAILED (commit は成功、push が失敗) | {push_failed_count} |

- **wiki branch 最終 commit**: {last_wiki_commit or "(wiki branch 未作成)"}
```

**Step 3 — Conditional warnings** (append below the table only when applicable):

| Condition | Warning to append |
|-----------|------------------|
| All counters == 0 | `> ⚠️ Phase X.X.W が一度も実行されていません。silent skip の可能性があります。/rite:wiki:ingest を手動実行するか、caller の Phase 5.4.4.1 の sentinel を確認してください。` |
| `failed_count >= 1` | `> ❌ Wiki ingest trigger が {failed_count} 回失敗しました。caller の Phase 5.4.4.1 で workflow incident として登録されているか確認してください。` |
| `push_failed_count >= 1` | `> ❌ wiki-ingest-commit.sh が commit 成功後の push に {push_failed_count} 回失敗しました。local wiki branch に commit は保持されています。手動 recovery: \`git push origin wiki\` を実行してください。` |
| `skipped_disabled_count >= 1` | `> ℹ️ wiki.enabled=false により Wiki 機能全体が無効化されています。意図的でない場合は rite-config.yml を確認してください。` |
| `skipped_auto_off_count >= 1` | `> ℹ️ wiki.auto_ingest が無効化されています。意図的でない場合は rite-config.yml を確認してください。` |
| `skipped_commit_branch_missing_count >= 1` | `> ℹ️ wiki-ingest-commit.sh が wiki ブランチ未作成により skip されました。/rite:wiki:init を実行するか、git fetch origin wiki を実行してください。` |
| `done_count >= 1` AND no failures | `> ✅ Wiki branch が成長しました（{done_count} cycle 分の raw source が ingest されました）。` |

> **Skip condition**: This section is **NEVER** skipped. AC-5 requires it to always be present in the completion report so the user has a definitive answer about whether the Wiki grew during this Issue.

## Phase 5.7: Parent Issue Completion

**Condition**: `parent_issue_number` is non-zero in flow-state. Read deterministically via `state-read.sh` so per-session state is consulted instead of the legacy state file snapshot:

```bash
# `if ! var=$(cmd); then rc=$?` は bash 仕様上 `$?` が常に 0 になるため、capture と exit code を
# 両方取る場合は if/else 形式にする (capture-less `if ! cmd; then ...` は対象外)。
if parent_issue_number=$(bash {plugin_root}/hooks/state-read.sh --field parent_issue_number --default 0); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field parent_issue_number in Phase 5.7" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_7_parent_issue; rc=$rc" >&2
  exit 1
fi
# state-read.sh は jq の `// $default` で null/false → default 置換するが値の型は validate しない。
# 攻撃者が `.rite/sessions/*.flow-state` を書き換えて parent_issue_number に non-numeric
# (例: "true" / "../etc") を注入した場合、後続の `gh` 呼び出しに literal が流入する経路がある。
# numeric pattern check で fail-safe に default 0 (parent なし扱い) に降格する。
case "$parent_issue_number" in
  ''|*[!0-9]*)
    echo "WARNING: parent_issue_number is not numeric ('$parent_issue_number'), defaulting to 0 (no parent)" >&2
    parent_issue_number=0
    ;;
esac
if [ "$parent_issue_number" -eq 0 ] 2>/dev/null; then
  echo "[CONTEXT] PARENT_ISSUE=none — skip Phase 5.7, proceed to Workflow Termination"
else
  echo "[CONTEXT] PARENT_ISSUE=$parent_issue_number — execute Phase 5.7"
fi
```

Execute after 5.6. When `PARENT_ISSUE=none`, skip directly to Workflow Termination block.

**Pre-write** (only when a parent was identified — otherwise skip directly to terminate):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_parent_completion" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "Execute Phase 5.7 (Parent Issue Completion). Ending the workflow without processing the parent is PROHIBITED when a parent was identified. Do NOT stop."
```

### 5.7.1 Child Check

Use [Basic Query](../../references/epic-detection.md#basic-query). All `CLOSED`→5.7.2. Some `OPEN`→5.7.3.

### 5.7.2 Auto-Close

Confirm via `AskUserQuestion`. If "No", display message and proceed to 5.7.3 (no auto-close). If yes, update Projects Status to "Done" and then close the Issue.

**Step 1**: Update parent Issue Status to "Done".

> **Module**: [Projects Status Update Callsites](./references/projects-status-update-callsites.md#callsite-3--phase-572-parent-issue-status--done) — Callsite 3 (Phase 5.7.2) bash literal SoT。Skip if `projects.enabled: false` in rite-config.yml. Otherwise execute the Module procedure (Status update to "Done" for `{parent_issue_number}`, `auto_add: false` for parent Issue). On `skipped_not_in_project` / `failed` result, display `.warnings[]` and proceed to Step 2 (non-blocking).

**Step 2**: Close the parent Issue via `/rite:issue:close` Skill invocation.

> **Why Skill invoke (not `gh issue close`)**: `close.md` Phase 4.4.W.2 で Wiki raw source の蓄積（`wiki-ingest-commit.sh`）が発火する。直接 `gh issue close` を実行すると close.md を経由しないため、Wiki 経路が 100% silent skip になる。

**Pre-write** (before invoking `rite:issue:close`):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_parent_close" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "After rite:issue:close returns: proceed to Mandatory After 5.7.2, then 5.7.3 (Next Child). Do NOT stop."
```

Invoke `skill: "rite:issue:close", args: "{parent_issue_number}"`.

> **Note**: `close.md` receives `{parent_issue_number}` as its `{issue_number}` argument. Phase 4.1 executes `gh issue close`, Phase 4.4.W triggers Wiki ingest. The close.md `AskUserQuestion` (Phase 3) will present options to the user — since the user already confirmed "Close parent Issue" in Phase 5.7.2's own `AskUserQuestion`, they should select the manual close option when prompted by close.md.

> **Note**: `close.md` does NOT output a machine-readable result pattern (unlike `[review:mergeable]` etc.). When it returns control, immediately proceed to Mandatory After 5.7.2.

### 🚨 Mandatory After 5.7.2

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-parent-close phase:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_parent_close" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "rite:issue:close completed. Proceed to 5.7.3 (Next Child display). Do NOT stop."
```

**Step 2**: **→ Proceed to 5.7.3** (display remaining children if any).

### 5.7.3 Next Child

Display remaining children, guide `/rite:issue:start`. No auto-start.

### 🚨 Mandatory After 5.7

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-parent-completion phase. Use **patch mode** — patch preserves `previous_phase` automatically from the outgoing `.phase` field, whereas `create` mode would overwrite the entire state and risk tripping the session-ownership check:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase5_post_parent_completion" --active true \
  --next "Phase 5.7 completed. Proceed to Workflow Termination block. Do NOT stop."
```

**Step 2**: Proceed to the "Workflow Termination" block below.

## Workflow Termination

> **Placement**: This block runs **after** Phase 5.7 completes **or after Phase 5.6** when no parent Issue was identified (the Phase 5.7 skip branch). Both paths converge here so the terminal `phase="completed", active: false` state is set exactly once, with `previous_phase` pointing at a whitelist-valid source (`phase5_post_parent_completion` or `phase5_completion`).

**Parent-skip routing**: When `parent_issue_number` is `0` in flow-state (determined in Phase 5.7 via `state-read.sh`), Phase 5.7 is skipped entirely. In that case, jump from the end of Phase 5.6 directly to this block (bypassing 5.7.1-5.7.3 and Mandatory After 5.7) — do **not** leave the workflow in `phase5_completion, active: true`, which would cause the next stop attempt to block indefinitely.

> **Why this routing relies on Phase 5.7 emit, not state re-read**: Phase 5.7 が `parent_issue_number` の **single source of truth for the read** であり、本 Workflow Termination block は state を re-read しない。本 sub-skill 内の branching decision は Phase 5.7 の `[CONTEXT] PARENT_ISSUE=none` echo (LLM-level routing signal、会話履歴で観測可能) で駆動され、bash 変数経由ではない (Bash tool invocation は shell state を境界を跨いで共有しない)。

**Step 1**: Update flow state to the terminal state (patch mode, preserves `previous_phase`):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "completed" \
  --next "none" --active false
```

**Step 2**: Clean up `.rite-compact-state` to prevent stale blocked state from affecting the next session (#756):

```bash
rm -f .rite-compact-state 2>/dev/null || true
rm -rf .rite-compact-state.lockdir 2>/dev/null || true
```

**Note**: This cleanup is non-blocking. Failure to delete is silently ignored.

---

## Return Output Format (Before Return)

> **Reference**: `start-execute.md` / `start-publish.md` Return Output Format と異なり、本 sub-skill は **workflow terminal**。flow-state の terminal write (`phase="completed", active=false`) は Workflow Termination section が既に実行済みのため、Return Output Format では state file への re-patch は **不要**。sentinel 出力のみで caller に handoff する。abort path では Workflow Termination をスキップして本 sub-skill 内で直接 `completed, active=false` を patch する (下記 abort 経路で実行)。

> **Why no defense-in-depth re-patch here**: start-execute.md / start-publish.md は中間 sub-skill のため `phase5_post_execute` / `phase5_post_publish` への遷移を defense-in-depth で保証する必要があるが、start-finalize.md は terminal sub-skill で `completed` は既に書込済。再度 `completed` を patch する idempotent 操作は意味がなく、`phase5_post_finalize` 等の間接 phase は design doc SPEC-TECH-DECISIONS #3 で否定された (`[start:finalize:completed]` IS the terminal sentinel)。**Abort path のみ** Workflow Termination 未実行のため、abort 経路では本 section 直前に terminal `completed, active=false` を direct patch する (下記 bash block)。

**Abort path terminal write** (only when abort path: Phase 5.5 user selects 「More fixes」or `[ready:error]` AskUserQuestion → 「terminate」):

```bash
# abort path のみ実行 — success path は Workflow Termination が既に terminal を書き込み済み
# `phase5_finalize_running → completed` direct edge を whitelist が許可している (phase-transition-whitelist.sh)
if [ "${FINALIZE_ABORT:-0}" = "1" ]; then
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "completed" \
    --next "none" --active false
  rm -f .rite-compact-state 2>/dev/null || true
  rm -rf .rite-compact-state.lockdir 2>/dev/null || true
fi
```

After the flow-state update, output the result pattern. Caller-continuation reminder を **immediately before** result pattern に emit。Return block は **4 line** 構成: (1) `[CONTEXT] FINALIZE_DONE=1` grep marker / (2) plain-text blockquote continuation reminder / (3) HTML-commented caller instructions / (4) HTML-commented result sentinel。全 4 行が sub-skill の **last visible lines**。

> **Return block design rationale**:
> - caller continuation hint を plain-text line + HTML comment の **dual form** で emit
> - result pattern を HTML comment 化 (`<!-- [start:finalize:completed] -->` / `<!-- [start:finalize:aborted] -->`) — sentinel は grep-matchable (`grep -F '[start:finalize:'`) のまま AC 保持し、user-visible terminal token としての sentinel 出力を抑止して LLM turn-boundary heuristic 起因の `continue` 要求 stop を防ぐ
> - `[CONTEXT] FINALIZE_DONE=1` marker を return block の **FIRST line** に追加（not last）— orchestrator が consume する grep signal、HTML strip rendering でも検出可能な plain-text 形式

**Output format example (success — `[start:finalize:completed]`)**:

```
[CONTEXT] FINALIZE_DONE=1; next=workflow_terminal
> ⏭ MUST continue (turn を閉じない): caller Mandatory After 5.5-Termination → workflow terminal — finalize 完了 完了レポート出力済みのため caller 側は終端 cleanup のみ。
<!-- caller: workflow terminal state ("completed", active=false) is ALREADY set by Workflow Termination section. As your VERY FIRST tool call BEFORE any text output, narrative, or response generation, idempotently confirm via `bash plugins/rite/hooks/flow-state-update.sh patch --phase completed --active false --next none --if-exists --preserve-error-count` (idempotent; no-op if already terminal). IMMEDIATELY AFTER bash success, output the final completion handoff message to the user in the SAME response turn. DO NOT end the turn before the user-visible completion message is displayed. No further phase work remains. -->
<!-- [start:finalize:completed] -->
```

**Output format example (abort — `[start:finalize:aborted]`)**:

abort path (Phase 5.5 `[ready:error]` user-terminate or "More fixes" selection) では `next=workflow_terminal_abort` marker に切替え、caller-instruction HTML comment 内の次フェーズ指示を terminal cleanup へ変更する:

```
[CONTEXT] FINALIZE_DONE=1; next=workflow_terminal_abort
> ⏭ MUST continue (turn を閉じない): caller Mandatory After 5.5-Termination → workflow terminal — finalize aborted ([ready:error] user-terminate or "More fixes") Ready 化未完了 完了レポート省略。
<!-- caller: workflow terminal state ("completed", active=false) was patched by sub-skill's Return Output Format abort-path block. As your VERY FIRST tool call BEFORE any text output, narrative, or response generation, idempotently confirm via `bash plugins/rite/hooks/flow-state-update.sh patch --phase completed --active false --next none --if-exists --preserve-error-count` (idempotent; no-op if already terminal). IMMEDIATELY AFTER bash success, output a short abort handoff message to the user explaining the aborted reason in the SAME response turn. DO NOT end the turn before the user-visible abort message is displayed. -->
<!-- [start:finalize:aborted] -->
```

> **Plain-text form rationale**: 短く user-friendly な Markdown blockquote (`> ⏭ MUST continue (turn を閉じない):`) にすることで (a) rendered Markdown で視覚的に「停止禁止・継続必須」の文脈が明確、(b) HTML コメント (LLM 向け詳細) との責任分担が明確。詳細な caller 向け instruction は HTML コメント側に残し、plain-text 行は user 向けの短い imperative status indicator として機能する。user-visible な最終コンテンツは `⏭ MUST continue` blockquote となり、sentinel token は HTML コメント化されレンダリング時に不可視。

Result pattern (grep-matchable string inside HTML comment):

- **Finalize completed (success)**: `<!-- [start:finalize:completed] -->` (matches `grep -F '[start:finalize:completed]'`) — emitted when Phase 5.5/5.5.1/5.5.2/5.6/5.7/Workflow Termination all complete successfully. This is the **workflow terminal sentinel**: caller does no further phase work.
- **Finalize aborted**: `<!-- [start:finalize:aborted] -->` (matches `grep -F '[start:finalize:aborted]'`) — emitted when Phase 5.5 user selects 「More fixes」(continue iterating, skip Ready) or `[ready:error]` AskUserQuestion → 「terminate」. Workflow Termination Step 1 (terminal `completed` write) is still executed by the sub-skill so the workflow does not remain in a half-finalized state.

Both patterns are consumed by the orchestrator (`start.md` Mandatory After 5.5-Termination) to determine the next action — but since this is the **workflow terminal sub-skill**, caller routing is limited to the post-state cleanup and completion handoff display.

---

## 🚨 Caller Return Protocol

Sub-skill 完了時、control は **MUST** caller (`start.md`) へ戻る。caller は **同 response turn で MUST immediately** 🚨 Mandatory After 5.5-Termination を実行し、user-visible completion handoff message を出力する。

**WARNING (success path)**: Success path で本セクションで停止すると user は workflow 完了を認識できず「stalled」状態に見える。Workflow Termination が terminal state を書き込んでいても、user-facing handoff message が表示されないと UX が壊れる。

**WARNING (abort path)**: Abort path で abort 理由を user に伝えないと、何が起きて workflow が中断したのか分からない。emitted sentinel に応じて caller は abort 理由を短く要約して user に表示する。

**Output rules**:

0. **FIRST**: `[CONTEXT] FINALIZE_DONE=1; next=workflow_terminal` (success) または `[CONTEXT] FINALIZE_DONE=1; next=workflow_terminal_abort` (abort) を **plain-text line** で出力（HTML-commented 不可）。位置規定:
   - **0b (構造保証、canonical)**: Rules 0-1 の相対順序が **4-line return block** を pin する: Rule 0 (FIRST) → plain-text continuation reminder → HTML-commented caller instructions → Rule 1 (absolute LAST)
   - **0a (絶対位置、0b から導出)**: 4-line block 構造より、本 marker は **4th-to-last visible line**（`<!-- [start:finalize:completed] -->` / `<!-- [start:finalize:aborted] -->` absolute-last sentinel の 3 行前）
   - **0c (目的)**: grep marker for orchestrator (workflow terminal detection) and for Mandatory After 5.5-Termination bash block comment reference; LLM turn-boundary heuristic 対策の defense-in-depth
1. Result pattern を HTML comment (`<!-- [start:finalize:completed] -->` または `<!-- [start:finalize:aborted] -->`) で **absolute last line** に出力 (sentinel は grep-matchable だが user-visible でない)
2. Bare `[start:finalize:completed]` / `[start:finalize:aborted]` 形式（HTML comment wrap なし）は **禁止**（user-visible terminal token として regressed）
3. Result pattern の **後ろに narrative text を出さない**（`→ Return to start.md` 等）— LLM の natural stopping point を生む
4. Caller は HTML comment 内の grep-matchable 文字列 (`grep -F '[start:finalize:completed]'` / `grep -F '[start:finalize:aborted]'`) と plain-text `[CONTEXT] FINALIZE_DONE=1` marker を grep で読取り、workflow terminal handoff を実行

> **Caller responsibility note**: 上記 Rules 0-3 は本 sub-skill (`start-finalize.md`) の出力に関する MUST/MUST NOT 制約。Rule 4 は subject = Caller の **Caller-side expectation** (本 sub-skill が caller に期待する後続動作の documentation)。本 sub-skill が emit する return block の構造健全性は必要条件であって十分条件ではなく、caller (`start.md`) 側の 🚨 Mandatory After 5.5-Termination が sub-skill return 直後の **VERY FIRST tool call** として bash literal を fire することが MUST。
