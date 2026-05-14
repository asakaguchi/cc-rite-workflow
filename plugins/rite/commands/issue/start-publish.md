---
description: |
  (Internal sub-skill — invoked by /rite:issue:start only. Do NOT invoke directly.)
  Issue 公開フェーズの実行 sub-skill。
  Phase 5.3 (PR Creation) + 5.4 (Review-Fix Loop: 5.4.1 review / 5.4.1.0 fingerprint dispatcher / 5.4.4 fix / 5.4.6 routing) を担当。
---

# /rite:issue:start-publish

Execute the publish phase for an Issue. This sub-skill is invoked from `start.md` after Phase 5.0-5.2.1 (`rite:issue:start-execute`) has completed with `[start:execute:completed]` sentinel.

**Prerequisites**: Phase 0-5.2.1 of `start.md` and `start-execute` sub-skill have completed. The following information is available in conversation context:
- `{issue_number}` — target Issue number
- `{branch_name}` — created/checked-out branch
- `{pr_number}` — initialized to `0`; populated after Phase 5.3 `[pr:created:{N}]`
- `{plugin_root}` — resolved per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version)
- `{owner}`, `{repo}` — from `gh repo view`
- Implementation completed + linted

---

## 🚨 MANDATORY Pre-flight: Flow State Update (MUST execute FIRST)

> 本 Pre-flight は sub-skill の **先頭** で実行し publish scope に関係なく flow-state write を保証する。Return Output Format 到達前に LLM stop / context truncation / interrupt が発生した場合でも、`phase5_publish_running` phase + sub-skill 由来の `next_action` が必ず記録されるよう (caller の delegation pre-write を上書きせず timestamp / `next_action` を refresh)、sub-skill 先頭で Pre-flight write を保証する。`phase5_post_publish` への遷移は本 sub-skill 末尾の [Return Output Format](#return-output-format-before-return) section の re-patch が担う。

**MUST run before any publish logic** (Phase 5.3 PR creation / Phase 5.4 review-fix loop / return-output emission)。**not optional**:

```bash
# 4 引数 symmetry (--phase / --active / --next / --preserve-error-count) は
# plugins/rite/hooks/tests/4-site-symmetry.test.sh で test 担保。state-path-resolve.sh
# + _resolve-flow-state-path.sh で per-session (schema_version=2) / legacy 両形式に対応。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "phase5_publish_running" \
      --active true \
      --next "rite:issue:start-publish Pre-flight completed. Proceed to Phase 5.3 (PR creation) → 5.4 (Review-Fix Loop), then return to caller. Caller MUST proceed to Phase 5.5 (Ready for Review). Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_PATCH_FAILED=1" >&2
    # 非 blocking: start.md delegation pre-write が safety net。
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "phase5_publish_running" --issue {issue_number} --branch "{branch_name}" --pr 0 \
      --next "rite:issue:start-publish Pre-flight completed. Proceed to Phase 5.3 (PR creation) → 5.4 (Review-Fix Loop), then return to caller. Caller MUST proceed to Phase 5.5 (Ready for Review). Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_CREATE_FAILED=1" >&2
  fi
fi
```

**Why `phase5_publish_running`**: caller (`start.md` Phase 5.3-5.4 Delegation Pre-write) は既に `phase5_publish_running` を書込済 (delegation in flight signal)。本 Pre-flight は patch mode で timestamp / `next_action` を refresh し、re-entry / interrupt 時にも sub-skill scope を識別できるようにする。`phase-transition-whitelist.sh` が `phase5_publish_running → phase5_pr` (forward) / `phase5_publish_running → phase5_post_publish` (terminal) を whitelist 化する。success path は `phase5_publish_running → phase5_pr → ... → phase5_post_publish` の間接経路を辿り、direct edge `phase5_publish_running → phase5_post_publish` は sub-skill 早期 stop / abort 時の direct return path として使われる。

**Idempotence**: 単一 sub-skill invocation 内で複数回実行されても safe — patch mode は pre-update `.phase` から `previous_phase` を設定し、re-entry で `phase5_publish_running` のまま phase regression しない。

---

## Phase 5.3: PR Creation

Run [Preflight Protocol](./start.md#preflight-protocol) before creating PR.

**Pre-write** (before invoking `rite:pr:create`):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_pr" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --next "After rite:pr:create returns: [pr:created:{N}]->save pr_number, Phase 5.4 (review loop). [pr:create-failed]->ask user via AskUserQuestion (3 options: 再試行 / Edit ツールで PR 作成して continue (incident 記録) / Phase 5.6 へ); 再試行 と continue は sub-skill 内 loop、Phase 5.6 へ のみ emit aborted sentinel and return to caller. Do NOT stop."
```

> **Data Handoff**: When invoking `rite:pr:create`, include the Issue information retrieved in Phase 0.1 (`number`, `title`, `body`, `labels`) in the Skill prompt to avoid redundant `gh issue view` calls in the child command.

Invoke `skill: "rite:pr:create"`.

**Immediate after pr:create returns**: When `rite:pr:create` outputs a result pattern (`[pr:created:{N}]` or `[pr:create-failed]`) and returns control, do **NOT** churn or pause — **immediately** proceed to the routing below. The review-fix loop has NOT started yet — you MUST continue to Phase 5.4.

**Patterns**:

- `[pr:created:{number}]` → extract `{pr_number}`, proceed to Phase 5.4 (Review-Fix Loop).
- `[pr:create-failed]` → **emit WORKFLOW_INCIDENT sentinel and ask user via `AskUserQuestion`** with 3 options (`再試行` / `Edit ツールで PR 作成して continue (incident 記録)` / `Phase 5.6 へ`):
  - **「再試行」**: Phase 5.3 (rite:pr:create) を再呼出する (network blip / 一時的な auth エラー等の transient failure 回復用)。
  - **「Edit ツールで PR 作成して continue (incident 記録)」**: §B SoT Step 2 (`manual_fallback_adopted`) を emit し、ユーザーが手動で PR を作成した後 `{pr_number}` を context に確認してから Phase 5.4 (Review-Fix Loop) へ進む。
  - **「Phase 5.6 へ」**: emit `[start:publish:aborted]` and return to caller (caller routes to Phase 5.6)。

> **Emit canonical literal**: See [§B — Phase 5.3 `[pr:create-failed]`](./references/workflow-incident-emit-pattern.md#b--phase-53-prcreate-failed) (SoT) for both emit steps (Step 1 `skill_load_failure` is emitted **before** the AskUserQuestion; Step 2 `manual_fallback_adopted` is emitted **only when** user selects 「Edit ツールで PR 作成して continue」), `|| true` non-blocking guarantee, and `--pr-number 0` semantics. The response-text-inclusion requirement that Phase 5.4.4.1 grep detection depends on is documented in [§不変条件](./references/workflow-incident-emit-pattern.md#不変条件). Do NOT inline the bash literals here.

**On `[pr:create-failed]` — abort routing**: After the AskUserQuestion completes, route per the user's selection: 再試行 → re-invoke `rite:pr:create` (loop within Phase 5.3) / continue → §B Step 2 emit + Phase 5.4 progression / Phase 5.6 へ → emit `[start:publish:aborted]` abort return block (see [Return Output Format](#return-output-format-before-return) — abort variant) and return control to caller. Only the 「Phase 5.6 へ」 path triggers the abort return; the other two paths continue within the sub-skill scope. The caller (`start.md` Mandatory After 5.3-5.4 — Step 3) detects `[start:publish:aborted]` sentinel and routes directly to Phase 5.6.

---

## Phase 5.4: Review-Fix Loop

`rite:issue:start-publish` orchestrates the review-fix loop. The loop is **internal** to this sub-skill — re-invocations of `rite:pr:review` / `rite:pr:fix` happen within this sub-skill's execution scope and do NOT return control to the caller until the loop converges (mergeable / replied-only) or aborts (fix:error user-terminate).

**Local work memory sync rule**: At each phase transition within the review-fix loop (5.4.1, 5.4.3, 5.4.4, 5.4.6), after updating flow state, also sync phase to the local work memory file (`.rite-work-memory/issue-{n}.md`). Use the self-resolving wrapper `local-wm-update.sh` with appropriate `WM_*` env vars. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for the recommended pattern.

**Issue comment backup sync rule**: After each review cycle completes (at 5.4.3 and 5.4.6), sync local work memory to the Issue comment as a backup. Use `issue-comment-wm-sync.sh` which handles owner/repo resolution internally, backup creation, safety checks, and PATCH atomically (#204).

### 5.4.1 Review

Run [Preflight Protocol](./start.md#preflight-protocol) before each review cycle.

**Pre-write** (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_review" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "After rite:pr:review returns: [review:mergeable]->emit [start:publish:completed] and return to caller. [review:fix-needed:{N}]->Phase 5.4.4 (fix). Do NOT stop."
```

> **Data Handoff**: When invoking `rite:pr:review`, the PR number is passed as an argument. Issue information from Phase 0.1 is available in work memory (loaded by `rite:pr:review` Phase 0), avoiding additional `gh issue view` calls.

#### 5.4.1.0 Fingerprint Cycling Detection

When `review.loop.convergence_monitoring` is enabled (default: `true`) and a prior `📜 rite レビュー結果` comment exists on the PR, compute finding fingerprints and detect the "same-finding cycling" quality signal (Signal 1 of 4).

> **Reference**: [Fingerprint Cycling Detection](./references/fingerprint-cycling.md) for the full procedure — Step 1 (fetch 2 most recent review comments via `gh api --paginate --slurp`), Step 2 (fingerprint specification + similarity matching + portable SHA-1 helper), Step 3 (fingerprint-set intersection signal), Step 4 (escalate via the **common 4-option `AskUserQuestion`** shared with Quality Signal 3 / 4), and Step 5 (proceed to `rite:pr:review` invocation when routing is "本 PR 内で再試行" or "別 Issue として切り出す").

When Step 4 routes to `rite:pr:review` invocation, invoke `skill: "rite:pr:review"` from here.

**Immediate after review returns**: When `rite:pr:review` outputs a result pattern and returns control, do **NOT** churn or pause — **immediately** proceed to 5.4.3 After Review below. The review sub-skill has already updated flow state to `phase5_post_review` via Phase 8.0 (defense-in-depth); execute the 5.4.3 steps without delay.

### 5.4.2 Review Patterns

`[review:mergeable]` → emit `[start:publish:completed]` and return to caller (caller routes to Phase 5.5). `[review:fix-needed:{n}]` → 5.4.4.

### 5.4.3 🚨 After Review

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Verify**: Pattern confirmed, parsed.

**Step 1**: Update flow state to post-review phase (atomic). This second write (after the Phase 5.4.1 pre-write) transitions from `phase5_review` to `phase5_post_review`, ensuring stop-guard routes to the correct next branch rather than repeatedly blocking and incrementing `error_count`:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_review" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "rite:pr:review completed. Check recent result pattern in context: [review:mergeable]->emit [start:publish:completed] and return to caller. [review:fix-needed:{N}]->Phase 5.4.4 (fix). Do NOT stop."
```

**Step 2**: Sync to local work memory:

```bash
WM_SOURCE="review" \
  WM_PHASE="phase5_post_review" \
  WM_PHASE_DETAIL="レビュー完了" \
  WM_NEXT_ACTION="レビュー結果に基づき次アクションを実行" \
  WM_BODY_TEXT="Post-review sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  WM_READ_FROM_FLOW_STATE="true" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 2.5**: Sync local work memory to Issue comment (backup):

```bash
# ⚠️ このパターンは 5.4.6 (After Fix) と同一構造。変更時は両方を更新すること
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "phase5_post_review" --phase-detail "レビュー完了" \
  2>/dev/null || true
```

**Step 2.8: Review Quality Verification (defense-in-depth)**

After the review result is received, verify that the review was properly executed with sub-agents by checking the PR comment structure:

1. Retrieve the latest review comment:
   ```bash
   latest_review=$(gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
     --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body')
   ```

2. Check for per-reviewer sections (`#### ` under `### 全指摘事項`):
   ```bash
   has_reviewer_sections=$(echo "$latest_review" | grep -c '^#### ' || true)
   echo "reviewer_sections=$has_reviewer_sections"
   ```

3. **When `reviewer_sections == 0`**: The review was performed inline without sub-agents (rubber-stamp review detected).

   **Circuit breaker guard** (check FIRST, before re-invoke): If this is already a re-invoked review cycle (i.e., Step 2.8 has already triggered a re-invoke earlier in this conversation turn), do NOT re-invoke again. Instead, display the fallback message and proceed to Step 3:

   ```
   ⚠️ 再試行後もサブエージェント未使用のレビューが検出されました。
   現在のレビュー結果をそのまま使用して続行します。
   ```

   **Note**: Track re-invocation in conversation context, NOT via flow state fields (flow-state fields are destroyed by `create` mode in Phase 5.4.3 Step 1). The LLM executing this step retains conversation history and can determine whether it already performed a Step 2.8 re-invoke in the current review cycle.

   **Re-invoke** (only when circuit breaker guard passes — first occurrence):

   ```
   ⚠️ レビュー品質検証: サブエージェント未使用のレビューを検出しました。
   PR コメントにレビュアー別セクション（#### {Reviewer Type}）が含まれていません。
   サブエージェントによるフルレビューを再実行します。
   ```

   Invoke `skill: "rite:pr:review", args: "{pr_number}"`. This re-invocation counts as a new review cycle and is allowed **at most once** per review cycle.

4. **When `reviewer_sections >= 1`**: Review quality verified. Proceed to Step 3.

**Step 3**: 本 sub-skill は Workflow Incident Detection 自体を実行しない (caller `start.md` Mandatory After 5.3-5.4 に委譲)。sub-skill 内部で emit された `[CONTEXT] WORKFLOW_INCIDENT=1` sentinel (`[pr:create-failed]` / `[fix:error]` 経路の §B/§C canonical bash literal、または `review.md` sub-skill の Sentinel Visibility Rule 経由) は会話コンテキストに残り、caller の Phase 5.4.4.1 が grep 検出・処理 (parse → dedupe → AskUserQuestion → create-issue / skip → mark processed) する責務を負う。

**Step 3.1 (Quality Signal 3 & 4 Detection)**: After review returns, detect Quality Signal 3 (cross-validation disagreement) and Signal 4 (reviewer self-degraded).

> **Reference**: [Fingerprint Cycling Detection §2](./references/fingerprint-cycling.md#2--phase-543-step-31-quality-signal-3--4-detection) for the canonical marker list (`[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement` for Signal 3, `### Reviewer self-assessment` + `Status: degraded` for Signal 4), the detection bash for Signal 4, and the **common 4-option `AskUserQuestion`** shared with Phase 5.4.1.0 Signal 1. When neither signal fires, proceed directly to Step 4.

**Step 4**: Based on the review result pattern from `rite:pr:review`, execute the corresponding action **immediately**. Do **NOT** use the Edit tool to fix code directly — always invoke the appropriate Skill tool.

| Result Pattern | Action |
|----------------|--------|
| `[review:mergeable]` | **→ Emit `[start:publish:completed]` and return to caller** (caller routes to Phase 5.5 Ready for Review). Skip fix entirely. |
| `[review:fix-needed:{n}]` | **Invoke `skill: "rite:pr:fix"`** via the Skill tool (Phase 5.4.4). After it returns, proceed to After Fix (5.4.6). |

> **禁止**: Edit ツールや Bash ツールでコードを直接修正してはならない。修正は必ず `skill: "rite:pr:fix"` を Skill ツールで呼び出して実行すること。

### 5.4.4 Fix

**Pre-write** (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_fix" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "After rite:pr:fix returns: [fix:pushed]->Phase 5.4.1 (re-review). [fix:pushed-wm-stale]->Phase 5.4.1 with WM stale warning (AskUserQuestion). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->emit [start:publish:completed] and return to caller. [fix:error]->ask user. Do NOT stop."
```

> **Data Handoff**: When invoking `rite:pr:fix`, PR number and review results are passed via work memory. Issue information from Phase 0.1 is available in work memory, avoiding redundant `gh issue view` calls.

Invoke `skill: "rite:pr:fix"`.

**Immediate after fix returns**: When `rite:pr:fix` outputs a result pattern (`[fix:pushed]`, `[fix:pushed-wm-stale]`, `[fix:issues-created:{N}]`, `[fix:replied-only]`, or `[fix:error]`) and returns control, do **NOT** churn or pause — **immediately** proceed to 5.4.6 After Fix below.

### 5.4.5 Fix Patterns

`[fix:pushed]` → 5.4.1. `[fix:pushed-wm-stale]` → AskUserQuestion (WM stale warning) → 5.4.1. `[fix:issues-created:{n}]` → 5.4.1. `[fix:replied-only]` → emit `[start:publish:completed]` and return to caller. `[fix:error]` → error, ask user.

### 5.4.6 🚨 After Fix

> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.

**Verify**: Pattern confirmed, parsed.

**Step 1**: Update flow state to post-fix phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_fix" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --next "rite:pr:fix completed. Check recent result pattern in context: [fix:pushed]->Phase 5.4.1 (re-review). [fix:pushed-wm-stale]->Phase 5.4.1 with WM stale warning. [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->emit [start:publish:completed] and return to caller. Do NOT stop."
```

**Step 2**: Sync to local work memory:

```bash
WM_SOURCE="fix" \
  WM_PHASE="phase5_post_fix" \
  WM_PHASE_DETAIL="修正完了" \
  WM_NEXT_ACTION="修正結果に基づき次アクションを実行" \
  WM_BODY_TEXT="Post-fix sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 2.5**: Sync local work memory to Issue comment (backup):

```bash
# ⚠️ このパターンは 5.4.3 (After Review) と同一構造。変更時は両方を更新すること
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "phase5_post_fix" --phase-detail "修正完了" \
  2>/dev/null || true
```

**Step 3**: 本 sub-skill は Workflow Incident Detection 自体を実行しない (caller `start.md` Mandatory After 5.3-5.4 に委譲)。

> **Note (v0.4.0 #557)**: The review-fix loop has no cycle-count-based hard limit. Non-convergence is detected exclusively via the four quality signals (see `commands/pr/references/fix-relaxation-rules.md#four-quality-signals-for-escalation`):
> 1. Fingerprint cycling → Phase 5.4.1.0 (before every re-review)
> 2. Root-cause-missing fix → `fix.md` Phase 3.2.1 (before every commit)
> 3. Cross-validation disagreement → `review.md` Phase 5.2 + debate (during every review)
> 4. Finding quality gate failure → `_reviewer-base.md` Finding Quality Guardrail (during every reviewer run)

**Step 4**: Based on the fix result pattern from `rite:pr:fix`, execute the corresponding action **immediately**. Do **NOT** use the Edit tool to fix code directly.

| Fix Result Pattern | Action |
|--------------------|--------|
| `[fix:pushed]` | **Invoke `skill: "rite:pr:review", args: "{pr_number}"`** via the Skill tool (re-review, Phase 5.4.1). |
| `[fix:pushed-wm-stale]` | **Work memory が stale です。手動介入が必要かを `AskUserQuestion` でユーザーに確認** (推奨: stale 警告ログを残した上で `skill: "rite:pr:review", args: "{pr_number}"` を起動して再レビューに進む / 中断して手動で work memory を修復する)。silent に `[fix:pushed]` 扱いしてはならない (fix.md Phase 8.1 caller semantics 参照)。 |
| `[fix:issues-created:{n}]` | **Invoke `skill: "rite:pr:review", args: "{pr_number}"`** via the Skill tool (re-review, Phase 5.4.1). |
| `[fix:replied-only]` | **→ Emit `[start:publish:completed]` and return to caller** (caller routes to Phase 5.5 Ready for Review). |
| `[fix:error]` | Ask the user how to proceed via `AskUserQuestion` with 4 options and execute the corresponding action: <br>**「再試行」**: Phase 5.4.4 に戻り `skill: "rite:pr:fix"` を再呼出 (fix.md 内の error 詳細を踏まえて再試行)。<br>**「Edit ツールで手動 fallback (incident 記録)」**: **emit sentinel** per [§C — Phase 5.4.4 `[fix:error]`](./references/workflow-incident-emit-pattern.md#c--phase-544-fixerror) (SoT) then emit `[start:publish:aborted]` and return to caller (caller routes to Phase 5.6)。<br>**「Phase 5.6 にスキップ」**: emit `[start:publish:aborted]` and return to caller (caller routes to Phase 5.6)。<br>**「terminate」**: emit `[start:publish:aborted]` and return to caller (caller routes to Phase 5.6)。The response-text-inclusion requirement that Phase 5.4.4.1 grep detection depends on is documented in [§不変条件](./references/workflow-incident-emit-pattern.md#不変条件). Do NOT inline the bash literal here. |

> **禁止**: Edit ツールや Bash ツールでコードを直接修正してはならない。修正は必ず `skill: "rite:pr:fix"` を Skill ツールで呼び出して実行すること。再レビューは必ず `skill: "rite:pr:review"` を Skill ツールで呼び出すこと。

---

## Return Output Format (Before Return)

> **Reference**: `start-execute.md` Return Output Format と対称な設計。flow-state write は 🚨 MANDATORY Pre-flight (本ファイル冒頭) で publish scope に関係なく `phase5_publish_running` phase + sub-skill 由来の `next_action` を記録。本 re-patch は defense-in-depth second write として `phase5_post_publish` への遷移と timestamp / `next_action` の refresh を担う。

Immediately before emitting the four-line return block, re-patch flow state (idempotent with Pre-flight write):

```bash
# 4 引数 symmetry (--phase / --active / --next / --preserve-error-count) は
# plugins/rite/hooks/tests/4-site-symmetry.test.sh で test 担保。Pre-flight 後の
# self-patch のため file 存在は保証済み。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "phase5_post_publish" \
      --active true \
      --next "rite:issue:start-publish completed. Proceed to Phase 5.5 (Ready for Review). Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PUBLISH_RETURN_PATCH_FAILED=1" >&2
    # 非 blocking: start.md Mandatory After 5.3-5.4 の redundant patch が続行する。
  fi
fi
```

> **Why patch mode only (no create fallback)**: Pre-flight が "file missing" branch (`create` mode) を処理済。本 section 到達時は flow state file 存在 + `.phase = phase5_publish_running` (Pre-flight 書込後の base) または内部 phase (`phase5_pr` / `phase5_post_review` / `phase5_post_fix` 等) が保証済。ここで `create` 呼出は `previous_phase` を空文字列にリセットし `phase-transition-whitelist.sh` whitelist transition check を defeat するため不可。patch mode で transition chain を preserve する。

After the flow-state update, output the result pattern. Caller-continuation reminder を **immediately before** result pattern に emit。Return block は **4 line** 構成: (1) `[CONTEXT] PUBLISH_DONE=1` grep marker / (2) plain-text blockquote continuation reminder / (3) HTML-commented caller instructions / (4) HTML-commented result sentinel。全 4 行が sub-skill の **last visible lines**。

> **Return block design rationale**:
> - caller continuation hint を plain-text line + HTML comment の **dual form** で emit（HTML comment が rendering で strip される場合への defense）
> - result pattern を HTML comment 化 (`<!-- [start:publish:completed] -->` / `<!-- [start:publish:aborted] -->`) — sentinel は grep-matchable (`grep -F '[start:publish:'`) のまま AC 保持し、user-visible terminal token としての sentinel 出力を抑止して LLM turn-boundary heuristic 起因の `continue` 要求 stop を防ぐ
> - `[CONTEXT] PUBLISH_DONE=1` marker を return block の **FIRST line** に追加（not last）— orchestrator Pre-check Item 0 と Mandatory After 5.3-5.4 Step 0 が consume する grep signal、HTML strip rendering でも検出可能な plain-text 形式

**Output format example (success — `[start:publish:completed]`)**:

```
[CONTEXT] PUBLISH_DONE=1; next=phase_5_5
> ⏭ MUST continue (turn を閉じない): Phase 5.5 Ready for Review → terminal — review-fix loop は収束 (mergeable または replied-only) Ready 化未起動のため停止禁止。
<!-- caller: MUST execute the following bash command as your VERY FIRST tool call BEFORE any text output, narrative, or response generation (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase phase5_post_publish --active true --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 5.5. Do NOT stop.' --if-exists --preserve-error-count` IMMEDIATELY AFTER bash success, continue with Phase 5.5 (Ready for Review) in the SAME response turn. DO NOT end the turn. DO NOT output any narrative text before this bash call. The PR is created and review-fix loop converged — Ready for Review has not yet been confirmed. -->
<!-- [start:publish:completed] -->
```

**Output format example (abort — `[start:publish:aborted]`)**:

abort path (Phase 5.3 `[pr:create-failed]` / Phase 5.4.6 `[fix:error]` user-terminate) では `next=phase_5_6` marker に切替え、caller-instruction HTML comment 内の next-phase 指示を Phase 5.6 へ変更する:

```
[CONTEXT] PUBLISH_DONE=1; next=phase_5_6
> ⏭ MUST continue (turn を閉じない): Phase 5.6 Completion Report → terminal — publish aborted ([pr:create-failed] または [fix:error] user-terminate) Ready 化は skip、完了報告のみ。
<!-- caller: MUST execute the following bash command as your VERY FIRST tool call BEFORE any text output, narrative, or response generation (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase phase5_post_publish --active true --next 'Publish aborted; routing to Phase 5.6 (Completion Report). Skip Ready for Review.' --if-exists --preserve-error-count` IMMEDIATELY AFTER bash success, route to Phase 5.6 (Completion Report) in the SAME response turn — skip Phase 5.5 (Ready for Review) entirely. DO NOT end the turn. DO NOT output any narrative text before this bash call. -->
<!-- [start:publish:aborted] -->
```

> **Plain-text form rationale**: 短く user-friendly な Markdown blockquote (`> ⏭ MUST continue (turn を閉じない):`) にすることで (a) rendered Markdown で視覚的に「停止禁止・継続必須」の文脈が明確、(b) HTML コメント (LLM 向け詳細) との責任分担が明確。詳細な caller 向け instruction は HTML コメント側に残し、plain-text 行は user 向けの短い imperative status indicator として機能する。user-visible な最終コンテンツは `⏭ MUST continue` blockquote となり、sentinel token は HTML コメント化されレンダリング時に不可視。`継続中` (現状報告) ではなく `MUST continue` (命令形) を採用するのは、reminder 文言が現状報告的に解釈されると LLM の turn-boundary heuristic implicit stop を防げない事象への対策。

Result pattern (grep-matchable string inside HTML comment):

- **Publish completed (success)**: `<!-- [start:publish:completed] -->` (matches `grep -F '[start:publish:completed]'`) — emitted when review-fix loop converges via `[review:mergeable]` or `[fix:replied-only]`. Caller routes to Phase 5.5 (Ready for Review).
- **Publish aborted**: `<!-- [start:publish:aborted] -->` (matches `grep -F '[start:publish:aborted]'`) — emitted when `rite:pr:create` returns `[pr:create-failed]` **and user selects 「Phase 5.6 へ」** (3-option AskUserQuestion 経由、「再試行」「Edit ツールで PR 作成して continue (incident 記録)」 を選択した場合は abort されず sub-skill 内 loop 継続)、または `rite:pr:fix` returns `[fix:error]` and user selects 「Phase 5.6 にスキップ」/「Edit ツールで手動 fallback (incident 記録)」/「terminate」. Caller routes to Phase 5.6 (Completion Report), **skipping** Phase 5.5.

Both patterns are consumed by the orchestrator (`start.md` Mandatory After 5.3-5.4 — Step 3) to determine the next action.

---

## 🚨 Caller Return Protocol

Sub-skill 完了時、control は **MUST** caller (`start.md`) へ戻る。caller は **同 response turn で MUST immediately** 🚨 Mandatory After 5.3-5.4 を実行し、sentinel に応じて Phase 5.5 (Ready for Review — success path) または Phase 5.6 (Completion Report — abort path) へ進む。

**WARNING (success path)**: Success path で本セクションで停止すると Ready for Review 化されず PR が draft のまま放置される。

**WARNING (abort path)**: Abort path で Phase 5.5 へ誤進すると、PR 未作成 (pr:create-failed) または review 未収束 (fix:error) の状態で Ready 化を試みて gh CLI が失敗する。caller 側 sentinel routing が誤動作した場合の最終 fallback は user による手動介入。

**Output rules**:

0. **FIRST**: `[CONTEXT] PUBLISH_DONE=1; next=phase_5_5` (success) または `[CONTEXT] PUBLISH_DONE=1; next=phase_5_6` (abort) を **plain-text line** で出力（HTML-commented 不可）。位置規定:
   - **0b (構造保証、canonical)**: Rules 0-1 の相対順序が **4-line return block** を pin する: Rule 0 (FIRST) → plain-text continuation reminder → HTML-commented caller instructions → Rule 1 (absolute LAST)。この 4-line invariant が canonical で、他の位置記述はここから導出
   - **0a (絶対位置、0b から導出)**: 4-line block 構造より、本 marker は **4th-to-last visible line**（`<!-- [start:publish:completed] -->` / `<!-- [start:publish:aborted] -->` absolute-last sentinel の 3 行前）
   - **0c (目的)**: grep marker for orchestrator Pre-check Item 0 (routing dispatcher) and for Mandatory After 5.3-5.4 Step 0 bash block comment reference (informational — Step 0 は unconditional idempotent `flow-state-update.sh patch` であり marker 分岐なし); LLM turn-boundary heuristic 対策の defense-in-depth
1. Result pattern を HTML comment (`<!-- [start:publish:completed] -->` または `<!-- [start:publish:aborted] -->`) で **absolute last line** に出力 (sentinel は grep-matchable だが user-visible でない)
2. Bare `[start:publish:completed]` / `[start:publish:aborted]` 形式（HTML comment wrap なし）は **禁止**（user-visible terminal token として regressed）
3. Result pattern の **後ろに narrative text を出さない**（`→ Return to start.md` 等）— LLM の natural stopping point を生む
4. Caller は HTML comment 内の grep-matchable 文字列 (`grep -F '[start:publish:completed]'` / `grep -F '[start:publish:aborted]'`) と plain-text `[CONTEXT] PUBLISH_DONE=1` marker を grep で読取り、success path は即 Phase 5.5 へ、abort path は即 Phase 5.6 へ継続

> **Caller responsibility note**: 上記 Rules 0-3 は本 sub-skill (`start-publish.md`) の出力に関する MUST/MUST NOT 制約。Rule 4 は subject = Caller の **Caller-side expectation** (本 sub-skill が caller に期待する後続動作の documentation)。本 sub-skill が emit する return block の構造健全性は必要条件であって十分条件ではなく、caller (`start.md`) 側の 🚨 Mandatory After 5.3-5.4 Step 0 が sub-skill return 直後の **VERY FIRST tool call** として bash literal を fire することが MUST。
