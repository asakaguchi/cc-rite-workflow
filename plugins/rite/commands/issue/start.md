---
description: Issue の作業を開始（ブランチ作成 → 実装 → PR 作成まで一気通貫）
---

# /rite:issue:start

> **Charter**: This command and its `references/` are subject to the [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述・cycle 番号引用・重複 confirmation は書かない。

## Contract
**Input**: Issue number (required), optionally a flow state record from a previous interrupted session
**Output**: `## 完了報告` (completion report with Issue/PR details and phase progress table)

End-to-end Issue workflow: branch → implementation → quality check → PR → review/fix loop.

**Flow:** Branch setup → plan → implementation → `/rite:lint` → `/rite:pr:create` → `/rite:pr:review` + `/rite:pr:fix` loop. Skills output machine-readable patterns; `/rite:issue:start` orchestrates next actions. See Phase 5.

---

## Responsibility Matrix

This table clarifies responsibility boundaries between `start.md`, `create.md`, and `implementation-plan.md`.

| Responsibility | `start.md` | `create.md` | `implementation-plan.md` |
|----------------|:----------:|:-----------:|:------------------------:|
| **Issue quality validation** | ✅ Primary (Phase 1) | — | — |
| **Parent Issue detection** | ✅ Phase 0.3 | — | — |
| **Duplicate detection** | — | ✅ Phase 0.3 | — |
| **Issue specification (What/Why/Where)** | — | ✅ Primary (Phase 0-0.7) | — |
| **Specification document generation** | — | ✅ Phase 0.7 (high-level design) | — |
| **Detailed implementation plan (How)** | — | — | ✅ Phase 3 (step-by-step) |
| **Branch creation + work start** | ✅ Phase 2-5 | — | — |
| **Issue creation + Projects registration** | — | ✅ Phase 2 | — |

**Key distinction — Phase 0.3 overlap resolution:**
- `start.md` Phase 0.3: **Parent Issue Auto-Detection** — trackedIssues, body tasklist, label-based parent detection
- `create.md` Phase 0.3: **Similar Issue Search** — duplicate detection, context gathering, extension opportunity detection

---

Execute phases sequentially. **Do NOT stop between phases unless the user explicitly selects a "cancel" or "later" option.**

---

## Phase Flow Quick Reference

> Stopping between phases leaves the workflow in an inconsistent state (e.g., branch created but no PR), requiring manual recovery via `/rite:resume`.
> **CRITICAL**: After every sub-skill invocation returns, **immediately** proceed to the next phase. Do NOT stop, do NOT re-invoke the completed skill.
>
> Every phase that writes to flow state is subject to the Pre-write + Mandatory After scaffolding contract (#490). Phases that only read state (0.x Detection, 1 Quality, 2.1/2.2 Branch-pattern detection, 4 User Guidance, 5.6.1 Incident Reporting, etc.) do not write markers and are therefore excluded from whitelist verification — they run inline and their transitions are verified indirectly by the surrounding write-phases. Every state-writing transition is tracked via flow state and verified by the stop-guard phase-transition whitelist (`plugins/rite/hooks/phase-transition-whitelist.sh`).
>
> The "Stop Allowed?" column marks whether the **user** may cancel at that phase (e.g., Phase 4 Guidance where the user chooses to work later, Phase 5.6/5.7 where the workflow naturally terminates after the completion handoff is displayed). Even for "Yes" rows, the scaffolding contract still applies — the user's stop action must be explicit, not a silent skip by the LLM.

| Phase | Sub-skill Invoked | Next Phase | Stop Allowed? |
|-------|-------------------|------------|---------------|
| 0 (Detection) | — | 1 | No |
| 1 (Quality) | — | 1.5 | No |
| 1.5 (Parent Routing) | `rite:issue:parent-routing` | 1.6 or 2 | **No** |
| 1.6 (Child Selection) | `rite:issue:child-issue-selection` | 2 | **No** |
| 2.3 (Branch) | `rite:issue:branch-setup` | 2.4 | **No** |
| 2.4 (Projects Status) | — | 2.5 or 2.6 | **No** |
| 2.5 (Iteration) | — | 2.6 | **No** |
| 2.6 (Work Memory) | `rite:issue:work-memory-init` | 3 | **No** |
| 3 (Plan) | `rite:issue:implementation-plan` | 4 | **No** |
| 4 (Guidance) | — | 5 or terminate | Yes (user choice) |
| 5.0-5.2.1 (Execute) | `rite:issue:start-execute` | 5.3-5.4 or 5.5-Termination | **No** |
| 5.3-5.4 (Publish) | `rite:issue:start-publish` | 5.5-Termination | **No** |
| 5.5-Termination (Finalize) | `rite:issue:start-finalize` | Workflow Termination | Yes (only after completion handoff is displayed) |

---

## Sub-skill Return Protocol (Global)

> **CRITICAL — AUTOMATIC CONTINUATION REQUIREMENT**: This is the single most important rule in this document. When a sub-skill returns, you MUST continue responding in the same turn. Ending your response after a sub-skill returns is a **bug** that forces the user to type "continue" manually.

This protocol applies to **every** sub-skill invocation in this document. Each Mandatory After section enforces it at specific transition points.

**When a sub-skill outputs a result pattern (e.g., `[review:mergeable]`, `[fix:pushed]`, `[pr:created:123]`) and returns control to you:**

1. **DO NOT end your response.** You are still in the middle of the e2e flow. Ending your response here is equivalent to crashing mid-workflow.
2. **DO NOT re-invoke the completed skill.** It already finished. Re-invoking wastes time and may cause errors.
3. **IMMEDIATELY** locate the Mandatory After section for the current phase and execute its steps — starting with the flow state update, then proceeding to the next phase.
4. If the stop-guard hook blocks a stop attempt (exit 2), follow the `ACTION:` instructions in its stderr message.

**Self-check**: After every sub-skill returns, ask yourself: "Have I output the completion report (Phase 5.6)?" If not, you are NOT done — keep going.

---

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

---

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | From the argument |
| `{owner}`, `{repo}` | `gh repo view --json owner,name` (retrieve before Phase 0.1) |
| `{base_branch}` | `branch.base` in `rite-config.yml` (default: `main`). Phase 2.3.1 |
| `{fallback_branch}` | Phase 2.3.2.3 only (`main` preferred, else default branch) |
| `{default_branch}` | `gh repo view --json defaultBranchRef` (Phase 2.3.2.3 only) |
| `{project_number}` | `github.projects.project_number` in `rite-config.yml` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{parent_issue_number}` | Write: Phase 1.6 / Phase 2.4 で flow-state に書き込み (`flow-state-update.sh create/patch`)。Read: [Phase 5.1.2 (implement.md)](./implement.md) / Phase 5.7 で `state-read.sh` 経由 (per-session state)。Workflow Termination は Phase 5.7 の `[CONTEXT] PARENT_ISSUE=...` emit を LLM-routing signal として使い state を re-read しない。歴史的経緯と fix context は [`references/state-read-evolution.md`](../../references/state-read-evolution.md) を参照 |

---

## Phase 0: Epic/Sub-Issues Detection

### 0.1 Fetch Issue Information

```bash
gh issue view {issue_number} --json number,title,body,state,labels,milestone,projectItems
```

### 0.2 Milestone Check

If Milestone associated, display: `この Issue は Milestone "{milestone_name}" に含まれています。Milestone には他に {count} 件の Issue があります。この Issue から作業を開始しますか？`

### 0.3 Parent Issue Auto-Detection

> **Reference**: [Epic/Parent Issue Detection](../../references/epic-detection.md) for complete logic/queries.

Determine parent Issue via: (1) trackedIssues API (GraphQL), (2) Body tasklist (`- [ ] #XX`), (3) Labels (`epic`/`parent`/`umbrella`). If **any** match, it's a parent (OR).

Follow [Complete Detection Flow](../../references/epic-detection.md#complete-detection-flow) with [Basic Query](../../references/epic-detection.md#basic-query).

**Save context**: `is_parent_issue` (true/false), `has_sub_issues`, `parent_issue_reason` (trackedIssues/tasklist/label:{name}/null). Retain `trackedIssues.nodes` for Phase 1.5/1.6.

**Display when children exist**:
```
この Issue には {count} 件の子 Issue があります:
| # | タイトル | 状態 |
| #{number} | {title} | {state} |
```

Phase 0.3 detects only; selection in Phase 1.5.

---

## Phase 1: Issue Quality Validation

> **Reference**: Apply `confusion_management` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

### 1.1 Quality Score

| Score | Conditions |
|-------|------------|
| **A** | What/Why/Where/Scope all specified |
| **B** | What/Why clear, Where/Scope inferable |
| **C** | Only What clear, details lacking |
| **D** | <20 words body OR What/Why/Where all unclear |

### 1.2 Check Items

What (required), Why/Where/Scope/Acceptance (recommended).

### 1.3 Score C/D Handling

Use `AskUserQuestion`:
```
Issue #{number} の情報を補完してください。
現在の情報: {title}, {body_preview}
不足: {missing_items}
質問: この Issue で具体的に何を達成しますか？
オプション: 既存の情報で作業開始（自分で判断）/ 情報を追加してから開始 / Issue を編集してから再度実行
```

---

## Phase 1.5: Parent Issue Routing

Execute after Phase 1.1-1.3.

**Pre-write** (before invoking `rite:issue:parent-routing`): Update flow state so stop-guard can resume flow if interrupted:

```bash
# branch is empty here — not yet created; populated after rite:issue:branch-setup completes in Phase 2.3
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_5_parent" --issue {issue_number} --branch "" \
  --pr 0 \
  --next "After rite:issue:parent-routing returns: proceed to Phase 1.6 (child issue selection) if applicable, then Phase 2. Do NOT stop."
```

> **Module**: [Parent Issue Routing](./parent-routing.md) - Handles: detection (1.5.1), child state/Projects retrieval (1.5.2-1.5.3), decomposition (1.5.4.1-1.5.4.6), auto-close (1.5.5).

Invoke `skill: "rite:issue:parent-routing"`.

### 🚨 Mandatory After 1.5

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-parent-routing phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_5_post_parent" --issue {issue_number} --branch "" \
  --pr 0 \
  --next "rite:issue:parent-routing completed. Proceed to Phase 1.6 (child issue selection) if applicable, then Phase 2. Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 1.6 (if child issues exist) or Phase 2 now**.

## Phase 1.6: Child Issue Selection

**Pre-write** (before invoking `rite:issue:child-issue-selection`): Update flow state so stop-guard can resume flow if interrupted:

```bash
# branch is empty here — not yet created; populated after rite:issue:branch-setup completes in Phase 2.3
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_6_child" --issue {issue_number} --branch "" \
  --pr 0 \
  --next "After rite:issue:child-issue-selection returns: proceed to Phase 2 (work preparation). Do NOT stop."
```

> **Module**: [Child Issue Selection](./child-issue-selection.md) - Automatic child selection with priority logic, dependencies, user confirmation.

Invoke `skill: "rite:issue:child-issue-selection"`.

### 🚨 Mandatory After 1.6

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-child-selection phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_6_post_child" --issue {issue_number} --branch "" \
  --pr 0 \
  --next "rite:issue:child-issue-selection completed. Proceed to Phase 2 (work preparation). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 2 now**.

---

## Phase 2: Work Preparation

### 2.1 Branch Name Generation

Follow `rite-config.yml` pattern `{type}/issue-{number}-{slug}`. Type from labels/title: `bug`/`bugfix`→`fix`, `docs`→`docs`, `refactor`→`refactor`, `chore`/`maintenance`→`chore`, else→`feat`. Slug: lowercase title, spaces→hyphens, max 30 chars.

### 2.2 Existing Branch Check

```bash
local_match=$(git branch --list "{branch_name}")
remote_match=$(git branch -r --list "origin/{branch_name}")
```

> **DO NOT** use exit code (`&&`, `||`, `$?`) to determine branch existence. `git branch --list` always returns exit code 0 regardless of whether a match is found.

**Determination**: If `local_match` or `remote_match` is non-empty, the branch exists.

```bash
# 判定ロジック（出力文字列の空チェック）
if [ -n "$local_match" ] || [ -n "$remote_match" ]; then
  echo "BRANCH_EXISTS"
else
  echo "BRANCH_NOT_FOUND"
fi
```

If exists: `ブランチ {branch_name} は既に存在します。オプション: 既存ブランチに切り替え / 別名でブランチを作成（サフィックス追加）/ キャンセル`

#### 2.2.1 Recognized Patterns

If `branch.recognized_patterns` in rite-config.yml, detect non-Issue-numbered branches. Execute 2.2.1 only after 2.2 finds nothing.

**Pattern→regex**: `{n}`→`[0-9]+`, `{category}`/`{description}`→`[a-z0-9-]+`, `{locale}`→`[a-z]{2}(-[a-z]{2})?`, `{date}`→`[0-9-]+`, `{*}`→`.+`. Add `^...$` anchors.

**On match**: Display `既存ブランチ {branch_name} を検出しました。（パターン: {matched_pattern}）このブランチは Issue 番号を含まないため、Issue #{issue_number} との紐付けは手動で行う必要があります。オプション: このブランチで作業を開始（Issue との紐付けなし）/ 標準パターンで新しいブランチを作成 / キャンセル`

Skip Phase 2.4/2.5/2.6 (no Issue number). User manually links. Phase 3+ normal.

### 2.3 Branch Creation

**Pre-write** (before invoking `rite:issue:branch-setup`): Update flow state so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_branch" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:issue:branch-setup returns: proceed to Phase 2.4 (Projects Status update to In Progress). Do NOT stop."
```

> **Module**: [Branch Setup](./branch-setup.md) - Creates branch from `branch.base`, handles fallback when base doesn't exist.

Invoke `skill: "rite:issue:branch-setup"`.

### 🚨 Mandatory After 2.3

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-branch phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_post_branch" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "rite:issue:branch-setup completed. Proceed to Phase 2.4 (Projects Status update to In Progress). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 2.4 now**.

### 2.4 GitHub Projects Status Update

**Pre-write** (before executing Projects Status update): Update flow state so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_projects" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "Execute Phase 2.4 (Projects Status → In Progress). Skipping to Phase 2.5/2.6/3 without running Projects update is PROHIBITED. Do NOT stop."
```

> **Module**: [Projects Status Update Callsites](./references/projects-status-update-callsites.md#callsite-1--phase-24-issue-status--in-progress) — Phase 2.4 / 5.5.1 / 5.7.2 共通 delegation の bash literal SoT (Callsite 1 = Phase 2.4)。Runtime execution delegates to `plugins/rite/scripts/projects-status-update.sh`. API レベル動作仕様は [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update) を参照。

> **Issue #513 regression guard**: Step 3 (Parent Issue Status Update via 3-method detection) は本 Module 内 Callsite 1 Step 3 に SoT として移管。inline `trackedInIssues`-only simplification (Issue #513 incident で AC-1 失敗を引き起こした anti-pattern) への revert は禁止。詳細な 3-method procedure と regression guard 全文は Module を参照。`parent-child-sync-static.test.sh` Group 4 が両ファイル ([projects-integration.md#247](../../references/projects-integration.md#247-parent-issue-status-update-for-child-issues) リンク + Issue #513 literal) を pin する。

Execute the Module procedure: Callsite 1 Step 1 (config read + skip marker emit) → Callsite 1 Step 2 (Status In Progress update) → Callsite 1 Step 3 (parent Issue Status update via 3-method detection)。On `[CONTEXT] PHASE_2_4_STATE=skip`, skip Step 2-3 but still execute Mandatory After 2.4 unconditionally。

### 🚨 Mandatory After 2.4

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-projects phase. If Phase 2.4.7 detected a parent Issue (`{parent_issue_number}` is non-empty and non-zero), persist it via `--parent-issue` so it survives context compaction and session restarts (#497):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_post_projects" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 --parent-issue {parent_issue_number} \
  --next "Phase 2.4 completed. Proceed to Phase 2.5 (Iteration) if iteration.enabled, else Phase 2.6 (Work Memory). Do NOT stop."
```

> **Note**: When Phase 2.4.7 detected no parent (standalone Issue), `{parent_issue_number}` is `0` (the default). The `--parent-issue 0` is harmless and explicitly records that no parent was found.

**Step 2**: **→ Proceed to Phase 2.5 now**. Phase 2.5 handles its own skip conditions internally (iteration disabled / projects disabled) — do NOT skip Phase 2.5 at this level (prompt-engineer cycle-2 MEDIUM #3). The Phase 2.5 Pre-write + Mandatory After blocks always run so `phase2_post_iteration` is recorded even when the assignment body is skipped.

### 2.5 Iteration Assignment

**Pre-write** (before executing Iteration assignment):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_iteration" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "Execute Phase 2.5 (Iteration assignment). Skipping to Phase 2.6/3 without running Iteration assignment is PROHIBITED when iteration.enabled. Do NOT stop."
```

> **Module**: [Projects Integration](../../references/projects-integration.md#25-iteration-assignment-optional)

**Skip conditions** — if any of the following are true, skip the Module procedure and go directly to Mandatory After 2.5:

- `projects.enabled: false` in rite-config.yml
- `iteration.enabled: false` in rite-config.yml
- `iteration.auto_assign: false` in rite-config.yml

Otherwise, execute the Module procedure: field info (2.5.1), current iteration determination (2.5.2), assignment (2.5.3), result/warning (2.5.4). On any failure, display warning and continue (non-blocking).

### 🚨 Mandatory After 2.5

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-iteration phase:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_post_iteration" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "Phase 2.5 completed (or skipped). Proceed to Phase 2.6 (Work Memory initialization). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 2.6 now**.

### 2.6 Work Memory Initialization

**Pre-write** (before invoking `rite:issue:work-memory-init`): Update flow state so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_work_memory" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:issue:work-memory-init returns: proceed to Phase 3 (implementation plan). Do NOT stop."
```

> **Module**: [Work Memory Initialization](./work-memory-init.md) - Initializes Issue comment with progress summary, confirmation items, session info. Format: [Work Memory Format](../../skills/rite-workflow/references/work-memory-format.md).

Invoke `skill: "rite:issue:work-memory-init"`.

### 🚨 Mandatory After 2.6

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-work-memory phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_post_work_memory" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "rite:issue:work-memory-init completed. Proceed to Phase 3 (implementation plan). Do NOT stop."
```

**Step 2**: Defense-in-depth: verify local work memory was created. If the sub-skill skipped it, create via fallback:

```bash
if [ ! -f ".rite-work-memory/issue-{issue_number}.md" ]; then
  WM_SOURCE="init" WM_PHASE="phase2" WM_PHASE_DETAIL="ブランチ作成・準備" \
    WM_NEXT_ACTION="実装計画を生成" \
    WM_BODY_TEXT="Work memory initialized (fallback). Issue #{issue_number} の作業を開始しました。" \
    WM_ISSUE_NUMBER="{issue_number}" \
    bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
fi
```

> **Note**: `{plugin_root}` が未解決の場合は、[Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) に従い事前に解決すること。このコードブロックは Phase 4.1 よりも前に実行されるため、Phase 4.1 での解決に依存できない。相対パス `plugins/rite/hooks/` は、マーケットプレイスインストール環境ではスクリプトが見つからないため使用不可。

**Step 3**: **→ Proceed to Phase 3 now**.

## Phase 3: Implementation Plan

**Pre-condition check** (#490 AC-5): See [Pre-condition Gate](./references/pre-condition-gate.md). Expected `.phase`: `phase2_post_work_memory` (resume re-entry also accepts `phase3_post_plan`).

```bash
if curr=$(bash {plugin_root}/hooks/state-read.sh --field phase --default ""); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field phase in Phase 3 pre-condition" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase3_pre_condition; rc=$rc" >&2
  exit 1
fi
if [ "$curr" != "phase2_post_work_memory" ] && [ "$curr" != "phase3_post_plan" ]; then
  echo "ERROR: Phase 3 pre-condition failed. .phase=$curr (expected: phase2_post_work_memory)" >&2
  echo "ACTION: Return to the missing Phase 2 step (2.4 Projects / 2.5 Iteration / 2.6 Work Memory) and execute its Pre-write + main procedure + Mandatory After before entering Phase 3." >&2
  echo "⚠️ LLM MUST NOT proceed to Phase 3 Pre-write below. Re-invoke the missing phase first." >&2
  exit 1
fi
```

**Pre-write** (before invoking `rite:issue:implementation-plan`): Update flow state so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase3_plan" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:issue:implementation-plan returns: proceed to Phase 4 (work start guidance). Do NOT stop."
```

> **Module**: [Implementation Plan Generation](./implementation-plan.md) - Analyzes Issue, identifies files, generates plan, gets user confirmation, records to work memory, updates Issue body checklist.

Invoke `skill: "rite:issue:implementation-plan"`.

### 🚨 Mandatory After 3

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-plan phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase3_post_plan" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "rite:issue:implementation-plan completed. Proceed to Phase 4 (work start guidance). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 4 now**.

---

## Phase 4: Work Start Guidance

### 4.1 Completion Report

Read `{plugin_root}/templates/completion-report.md` with Read tool. Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version). Use "Work start format (for Phase 4.1)" section as-is. Fallback: inline equivalent (Issue info, branch, progress table).

### 4.2 Project-Specific Guidance

Based on `project.type` in rite-config.yml: webapp→Frontend/backend/DB areas, library→Breaking changes/API impact, cli→Command interface/compatibility, documentation→Structure/links, generic→none.

### 4.3 Continuation

Use `AskUserQuestion`: `作業の準備が整いました。どうしますか？ オプション: 実装を開始する（推奨）/ 後で作業する`

Start→Phase 5 (end-to-end). Later→terminate, resume via Phase 2.2.

---

## Phase 5: End-to-End Execution

### Context Budget & Output Minimization (#80)

The e2e flow must minimize context consumption to complete within a single session. Each sub-skill has an **E2E Output Minimization** section that reduces output when called from this flow.

> **⚠️ Output minimization ≠ step omission**: "minimize output" とは中間テキストの冗長な説明を削減することであり、**phase / step / MUST 処理を skip することではない**。時間・context を理由にワークフロー step を省略する誘惑は強いが、それは identity 違反である。context が実際に枯渇した場合の正規経路は `/clear` + `/rite:resume` であり、LLM が自己判断で step を短縮・省略する経路は存在しない。
>
> **Identity reference**: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` / `quality_over_expediency` principle を参照。

**Orchestrator rules** (apply throughout Phase 5):

1. **Minimize intermediate text output**: Between tool calls, output only essential status updates (1-2 lines max). Skip explanations, summaries, and guidance text that the user doesn't need during automated flow.
2. **Trust result patterns**: When a sub-skill returns a result pattern (e.g., `[lint:success]`), do NOT re-summarize what happened. Immediately proceed to the next phase.
3. **Avoid redundant reads**: Information from Phase 0.1 (Issue details) is retained in context. Do NOT re-fetch Issue body, title, or labels in later phases.
4. **Batch bash operations**: Combine related bash commands into single tool calls where possible. Examples: `flow-state-update.sh create ... && WM_SOURCE=... bash local-wm-update.sh` (flow-state + work memory sync in one call), `gh api graphql ... && gh project item-edit ...` (Projects query + update in one call).

**Sub-skill output expectations** (e2e flow):

| Sub-skill | Expected Output | Max Lines |
|-----------|-----------------|-----------|
| `rite:lint` | `[lint:success/error]` + 1-line summary | 2 |
| `rite:pr:create` | `[pr:created:{n}]` + PR URL | 2 |
| `rite:pr:review` | `[review:mergeable]` or `[review:fix-needed:{n}]` etc. | 2 |
| `rite:pr:fix` | `[fix:{result}]` + change summary | 2 |
| `rite:pr:ready` | `[ready:completed]` | 1 | <!-- ready.md の出力は元々1行程度のため E2E Output Minimization セクション不要 -->

### Flow

```
5.0-5.2.1 rite:issue:start-execute (sub-skill: Stop Hook + 実装 + lint + checklist)
  → [start:execute:completed]→5.3-5.4 / [start:execute:aborted]→5.5-Termination
5.3-5.4 rite:issue:start-publish (sub-skill: PR create + review-fix loop)
  → [start:publish:completed]→5.5-Termination / [start:publish:aborted]→5.5-Termination
5.5-Termination rite:issue:start-finalize (sub-skill: ready + status + metrics + completion + parent close + termination)
  → [start:finalize:completed] (workflow 終端) / [start:finalize:aborted] (User-terminate during finalize)
```

### Preflight Protocol

Each major Phase 5 sub-phase runs a preflight check before execution. The check detects compact-blocked state and prevents execution when recovery is needed:

```bash
bash {plugin_root}/hooks/preflight-check.sh --command-id "/rite:issue:start" --cwd "$(pwd)"
```

If exit code is `1` (blocked), stop execution and display the preflight output. Do NOT proceed.

**Orchestration**: `/rite:issue:start` controls all. Skills output patterns: lint (`[lint:success/skipped/error/aborted]`), create (`[pr:created:{n}/create-failed]`), review (`[review:mergeable/fix-needed:{n}]`), fix (`[fix:pushed/issues-created/replied-only/error]`), ready (`[ready:completed/error]`).

**Sub-skill return protocol**: See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global). Each Mandatory After section below enforces it at specific transition points.

Invocation: `skill: "rite:lint"` or `skill: "rite:pr:review", args: "67"`

### 5.0-5.2.1 Execute Phase (delegated to start-execute sub-skill)

**Pre-write** (before invoking `rite:issue:start-execute`):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_execute_running" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:issue:start-execute returns: proceed to Phase 5.3-5.4 (Publish Phase) via rite:issue:start-publish. Do NOT stop."
```

> **Module**: [Execute Phase](./start-execute.md) - Handles Phase 5.0 (Stop Hook Verification), 5.1 (Implementation invoking implement.md), 5.2 (Lint via rite:lint), 5.2.1 (Checklist Confirmation).

Invoke `skill: "rite:issue:start-execute"`.

**Immediate after start-execute returns**: When `start-execute` outputs `<!-- [start:execute:completed] -->` (success) or `<!-- [start:execute:aborted] -->` (abort — Phase 5.1.3 中止 or `[lint:aborted]`) sentinel and returns control, do **NOT** stop — **immediately** proceed to Mandatory After 5.0-5.2.1 below.

### 🚨 Mandatory After 5.0-5.2.1

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-execute phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_execute" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "rite:issue:start-execute completed. Proceed to Phase 5.3-5.4 (Publish Phase via rite:issue:start-publish) on [start:execute:completed]. Skip to Phase 5.6 on [start:execute:aborted]. Do NOT stop."
```

**Step 2 (Workflow Incident Detection)**: Run Phase 5.4.4.1 (Workflow Incident Detection). Grep the recent conversation context for `[CONTEXT] WORKFLOW_INCIDENT=1` lines (emitted by `start-execute` sub-skill — e.g., `[lint:aborted]` orchestrator-direct emit per §A, or by `lint.md` sub-skill via Sentinel Visibility Rule). If found, execute Phase 5.4.4.1 step 2-7. Phase 5.4.4.1 is **non-blocking** — continue to Step 3 regardless of detection result.

**Step 3 (Sentinel-based routing)**: Grep the recent conversation context for `<!-- [start:execute:completed] -->` or `<!-- [start:execute:aborted] -->`:

- `[start:execute:completed]` detected → **→ Proceed to Phase 5.3-5.4 (Publish Phase) now** (invoke `rite:issue:start-publish` sub-skill).
- `[start:execute:aborted]` detected → **→ Skip to Phase 5.6 (Completion Report) now**. PR creation is intentionally skipped because the execute phase was aborted by user choice (5.1.3 Safety Check) or `[lint:aborted]`. The completion report MUST display the abort reason to the user.
- Neither detected → fail-safe: treat as `[start:execute:completed]` (proceed to Phase 5.3-5.4); the sub-skill SHOULD always emit one of the two sentinels per its Return Output Format contract.

### 5.3-5.4 Publish Phase (delegated to start-publish sub-skill)

**Pre-write** (before invoking `rite:issue:start-publish`):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_publish_running" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:issue:start-publish returns: proceed to Phase 5.5 (Ready for Review) on [start:publish:completed]. Skip to Phase 5.6 (Completion Report) on [start:publish:aborted]. Do NOT stop."
```

> **Module**: [Publish Phase](./start-publish.md) - Handles Phase 5.3 (PR creation via rite:pr:create), 5.4 (Review-Fix Loop with internal 5.4.1/5.4.1.0/5.4.4/5.4.6 routing, fingerprint cycling dispatcher).

Invoke `skill: "rite:issue:start-publish"`.

**Immediate after start-publish returns**: When `start-publish` outputs `<!-- [start:publish:completed] -->` (success — review-fix loop converged via `[review:mergeable]` or `[fix:replied-only]`) or `<!-- [start:publish:aborted] -->` (abort — `[pr:create-failed]` or `[fix:error]` user-terminate) sentinel and returns control, do **NOT** stop — **immediately** proceed to Mandatory After 5.3-5.4 below.

### 🚨 Mandatory After 5.3-5.4

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Update flow state to post-publish phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_publish" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "rite:issue:start-publish completed. Proceed to Phase 5.5 (Ready for Review) on [start:publish:completed]. Skip to Phase 5.6 on [start:publish:aborted]. Do NOT stop."
```

**Step 2 (Workflow Incident Detection)**: Run Phase 5.4.4.1 (Workflow Incident Detection). Grep the recent conversation context for `[CONTEXT] WORKFLOW_INCIDENT=1` lines (emitted by `start-publish` sub-skill — e.g., `[pr:create-failed]` / `[fix:error]` orchestrator-direct emit per §B/§C, or by `pr/create.md` / `pr/review.md` / `pr/fix.md` sub-skill via Sentinel Visibility Rule). If found, execute Phase 5.4.4.1 step 2-7. Phase 5.4.4.1 is **non-blocking** — continue to Step 3 regardless of detection result.

**Step 3 (Sentinel-based routing)**: Grep the recent conversation context for `<!-- [start:publish:completed] -->` or `<!-- [start:publish:aborted] -->`:

- `[start:publish:completed]` detected → **→ Proceed to Phase 5.5 (Ready for Review) now**.
- `[start:publish:aborted]` detected → **→ Skip to Phase 5.6 (Completion Report) now**. Ready for Review is intentionally skipped because the publish phase was aborted by `[pr:create-failed]` (PR was never created) or `[fix:error]` user-terminate (review-fix loop did not converge). The completion report MUST display the abort reason to the user.
- Neither detected → fail-safe: treat as `[start:publish:completed]` (proceed to Phase 5.5); the sub-skill SHOULD always emit one of the two sentinels per its Return Output Format contract.

### 5.4.4.1 Workflow Incident Detection (Contract Summary)

> **Reference**: This section documents the **本体 contract** for workflow incident detection. The detailed Step 1-7 processing flow lives in [Workflow Incident Detection](./references/workflow-incident-detection.md); emit pattern canonical bash literals live in [Workflow Incident Emit Pattern](./references/workflow-incident-emit-pattern.md) (the response-text-inclusion requirement that grep detection below depends on is documented in [§不変条件](./references/workflow-incident-emit-pattern.md#不変条件)); fingerprint cycling / Quality Signal 3 & 4 detail lives in [Fingerprint Cycling Detection](./references/fingerprint-cycling.md). The orchestrator (`/rite:issue:start`) invokes detection at three boundaries (Mandatory After 5.0-5.2.1 / 5.3-5.4 / 5.5-Termination — see "When to execute" table below).

**Detection scope** — recognised sentinel `type` values:

| Type | Source | Default action when detected |
|------|--------|------------------------------|
| `skill_load_failure` | Orchestrator post-condition check | AskUserQuestion → register Issue / skip |
| `hook_abnormal_exit` | Skill internal failure paths | AskUserQuestion → register Issue / skip |
| `manual_fallback_adopted` | Orchestrator fallback prompts | AskUserQuestion → register Issue / skip |
| `wiki_ingest_skipped` | review/fix/close Phase X.X.W when `wiki.enabled=false` / `wiki.auto_ingest=false`, **OR** `wiki-ingest-commit.sh` exits 2 (wiki branch missing locally — fresh clone) | AskUserQuestion → register Issue / skip. Two sub-cases — see reference §1 for `commit_branch_missing` sub-case routing |
| `wiki_ingest_failed` | review/fix/close Phase X.X.W when `wiki-ingest-trigger.sh` exits non-zero / non-2, **OR** `wiki-ingest-commit.sh` exits non-0/2/4 (git stash/checkout/commit failure) | AskUserQuestion → register Issue / skip — recommended to register |
| `wiki_ingest_push_failed` | review/fix/close Phase X.X.W when `wiki-ingest-commit.sh` exits 4 — commit landed locally on the wiki branch but origin push failed | AskUserQuestion → register Issue / skip — recommended to **register**. Manual recovery: `git push origin wiki` |
| `gitignore_drift` | `/rite:lint` Phase 3.9 when `gitignore-health-check.sh` detects missing `.rite/wiki/` rule (last-line-of-defense) | AskUserQuestion → register Issue / skip — recommended to **register**. Manual recovery: restore `.rite/wiki/` to `.gitignore` |

**When to execute** (explicit routing):

This phase runs **after every Skill invocation in Phase 5** at the following explicit invocation points. With PR F/G1/G2 sub-skill extraction, the orchestrator's Skill boundaries are 3 — `start-execute` (5.0-5.2.1) / `start-publish` (5.3-5.4) / `start-finalize` (5.5-Termination). Internal `pr:create` / `pr:review` / `pr:fix` invocations happen inside `start-publish` and are detected by the same context-grep at the publish delegation boundary. Internal `pr:ready` / `issue:close` invocations happen inside `start-finalize` and are detected at the finalize delegation boundary.

| Caller | Invocation point | Trigger |
|--------|------------------|---------|
| Phase 5.0-5.2.1 (execute) | Mandatory After 5.0-5.2.1 — Step 2 | Always after `[start:execute:*]` pattern |
| Phase 5.3-5.4 (publish) | Mandatory After 5.3-5.4 — Step 2 | Always after `[start:publish:*]` pattern (covers internal `[pr:created:{N}]` / `[pr:create-failed]` / `[review:*]` / `[fix:*]` emits via context grep) |
| Phase 5.5-Termination (finalize) | Mandatory After 5.5-Termination — Step 2 | Always after `[start:finalize:*]` pattern (covers internal `[ready:*]` emit via context grep) |

Each Mandatory After section MUST include a **"Run Phase 5.4.4.1 detection"** step that directs the orchestrator to grep the recent conversation context for sentinel lines BEFORE proceeding to the next phase.

**Skip condition**: If `workflow_incident.enabled: false` is set in `rite-config.yml`, skip this entire phase. Read the value once at Phase 5.0 (delegated to `start-execute`) and cache for the rest of the flow.

**Invariants**: Issue creation failure is non-blocking (workflow MUST NOT halt). The codepath is independent of Phase 7 (Issue creation from review recommendations). Default-on behavior: when `workflow_incident:` section is absent from `rite-config.yml`, treat as `enabled: true`.

### 5.5-Termination Finalize Phase (delegated to start-finalize sub-skill)

**Pre-write** (before invoking `rite:issue:start-finalize`):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_finalize_running" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "After rite:issue:start-finalize returns: workflow terminates (terminal state already written by sub-skill). Caller MUST output completion handoff message. Do NOT stop."
```

> **Module**: [Finalize Phase](./start-finalize.md) - Handles Phase 5.5 (Ready for Review via `rite:pr:ready`), 5.5.1 (Issue Status In Review), 5.5.2 (Metrics Recording), 5.6 (Completion Report incl. 5.6.1 Workflow Incident Reporting + 5.6.2 Wiki Ingest Status Reporting), 5.7 (Parent Issue Completion via `rite:issue:close`), Workflow Termination.

Invoke `skill: "rite:issue:start-finalize"`.

**Immediate after start-finalize returns**: When `start-finalize` outputs `<!-- [start:finalize:completed] -->` (success — workflow terminated normally) or `<!-- [start:finalize:aborted] -->` (abort — Phase 5.5 user selects 「More fixes」or `[ready:error]` user-terminate) sentinel and returns control, do **NOT** stop — **immediately** proceed to Mandatory After 5.5-Termination below.

### 🚨 Mandatory After 5.5-Termination

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Step 1**: Idempotent terminal state confirmation. Workflow terminal state (`phase="completed", active=false`) is already written by the sub-skill (Workflow Termination block in `start-finalize.md` for success path, or the abort-path terminal write in its Return Output Format for abort path). Re-patch idempotently to refresh timestamp and guard against the rare case where sub-skill terminal write was skipped due to interrupt:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "completed" --active false --next "none" \
  --if-exists --preserve-error-count
rm -f .rite-compact-state 2>/dev/null || true
rm -rf .rite-compact-state.lockdir 2>/dev/null || true
```

**Step 2 (Workflow Incident Detection)**: Run Phase 5.4.4.1 (Workflow Incident Detection). Grep the recent conversation context for `[CONTEXT] WORKFLOW_INCIDENT=1` lines (emitted by `start-finalize` sub-skill — e.g., `[ready:error]` orchestrator-direct emit per §D, or by `ready.md` sub-skill via Sentinel Visibility Rule). If found, execute Phase 5.4.4.1 step 2-7. Phase 5.4.4.1 is **non-blocking** — continue to Step 3 regardless of detection result.

**Step 3 (Sentinel-based completion handoff)**: Grep the recent conversation context for `<!-- [start:finalize:completed] -->` or `<!-- [start:finalize:aborted] -->` and display a short user-facing completion handoff message:

- `[start:finalize:completed]` detected → workflow terminated normally. The completion report was output by the sub-skill (Phase 5.6). Display a short user-facing confirmation summarizing PR URL, Issue URL, and next-step guidance (e.g., 「✅ Issue #{N} の作業が完了しました。 PR: {url}」).
- `[start:finalize:aborted]` detected → workflow aborted during finalize. Display a short abort summary explaining the abort reason (Phase 5.5 user-terminate during ready confirmation or `[ready:error]` AskUserQuestion → terminate) and next-step guidance (e.g., 「⚠️ Phase 5.5 で中断されました。 PR: {url} は draft のままです」).
- Neither detected → fail-safe: treat as `[start:finalize:completed]` (display normal completion); the sub-skill SHOULD always emit one of the two sentinels per its Return Output Format contract.

## Interruption/Resumption

**Retention**: Branch (Git), work memory (Issue comment), Status (Projects), plan (work memory).

**Resume** via `/rite:issue:start {number}`: Phase 2.2 detects branch. "Switch"→skip 2.3/2.4/2.5/2.6→Phase 3 (show plan)→continue from work memory. On resume, the Phase 3 pre-condition accepts `.phase=phase3_post_plan` (already-completed plan) in addition to `phase2_post_work_memory` — the `phase3_post_plan → phase3_plan` whitelist entry covers the retry edge.

**If PR exists**: After 2.2, check `gh pr list --head {branch_name}`. OPEN→`rite:pr:review`, MERGED→`rite:pr:cleanup`, CLOSED→confirm (reopen/new/cancel).

## Standalone Usage

Auto-invoked in end-to-end, usable standalone:

| Command | Standalone Use |
|---------|---------------|
| `/rite:issue:update` | Progress recording, handover |
| `/rite:lint` | Quality check |
| `/rite:pr:create` | PR without Issue, from existing branch |
| `/rite:pr:review` | Existing PR, others' PRs |
| `/rite:pr:fix` | Resume feedback |

## Error Handling

Issue not found→error, prompt `gh issue list`. Closed→confirm reopen/cancel. Branch fail→check `git status`. Projects unconfigured→warn, skip. API error→retry 3x (exponential backoff), skip Projects. See [GraphQL Helpers](../../references/graphql-helpers.md#error-handling).
