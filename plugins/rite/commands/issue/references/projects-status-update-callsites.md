# Projects Status Update — 4 Callsite Delegation SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` 内で `plugins/rite/scripts/projects-status-update.sh` を invoke する **4 callsite (Phase 2.4 / 5.5.1 / 5.7.2 / 1.5.5) の bash literal SoT** である。`start.md` 本体および sub-skill (`parent-routing.md`) の各 callsite は本ファイルへ semantic 参照する anchor stub のみ保持する。
>
> **抽出経緯**: 4 callsite はすべて同一の `bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n ...)"` 構造を持つが、`status_name` (In Progress / In Review / Done) と `auto_add` フラグ (true / false) のみ異なる。bash literal を 1 reference に集約することで drift を防止し、本体の認知負荷を下げる。Issue #901 (PR E — #896 親 Issue) で 3 callsite を抽出。Issue #1070 で Callsite 4 (Phase 1.5.5 Parent Auto-Close → Done) を追加。
>
> **API レベル仕様 SoT との役割分担**: `references/projects-integration.md` §2.4 は GraphQL projectItems / item-add / field-list / item-edit の **API 動作仕様** SoT。本ファイルは **caller bash literal** の SoT。両 reference は補完関係 (semantically orthogonal、重複契約なし)。
>
> **caller**: `start.md` の 3 sites (Phase 2.4 / 5.5.1 / 5.7.2) と sub-skill `parent-routing.md` の 1 site (Phase 1.5.5) すべてが本 reference の対応セクションへ delegate する。

## Common contract

すべての callsite は以下の共通 contract を満たす:

1. **Skip if `projects.enabled: false`** in rite-config.yml — non-blocking, continue workflow
2. **Delegate to `projects-status-update.sh`** via `bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n ...)"` (single source of truth for Projects Status updates)
3. **Inspect script stdout JSON**: `.result == "updated"` → success / `.result == "skipped_not_in_project"` or `"failed"` → display `.warnings[]` and continue (non-blocking)
4. **DO NOT inline GraphQL queries** — past incident (Issue #513) caused AC-1 failure when `trackedInIssues`-only inline simplification was introduced; `parent-child-sync-static.test.sh` Group 4 pins this regression guard
5. **MUST emit `workflow_incident` sentinel on `skipped_not_in_project` / `failed`** — silent skip 禁止。**timeless invariant**: caller 側で `.result` が `"skipped_not_in_project"` または `"failed"` の場合は必ず `bash {plugin_root}/hooks/workflow-incident-emit.sh --type projects_status_update_failed --details "..." --pr-number <pr>` で sentinel を emit する。本 SoT (callsites.md) は bash literal の delegate 構造のみを規定し、emit パターンは caller 側で inline 記述する委譲規約。emit 自体は `|| true` で non-blocking。caller (`start.md` Phase 5.4.4.1) の grep 検出経路で Issue として auto-register され、silent skip により observability が失われた事象を防ぐ。Per-Callsite implementation status の詳細 (どの Callsite で emit 実装済み / 未実装か、PR-specific rollout scope 等) は下記 blockquote `> **Issue #1003 AC-4 適用範囲と Callsite ごとの emit 実装責務**` を参照。

> **cycle 10 F-16 対応**: 旧 sub-bullet 「本 PR (Issue #1003) の scope 限定」は PR-specific 記述だったため timeless invariant section から削除し、直下 blockquote の section にロールアウト状況を集約。

詳細な API レベル動作 (GraphQL projectItems query / auto-add / field-list / item-edit) は [`projects-integration.md §2.4.2-2.4.5`](../../../references/projects-integration.md#242-check-issue-project-registration-status) を参照。

> **Issue #1003 AC-4 適用範囲と Callsite ごとの emit 実装責務**:
> - **Callsite 1 (Phase 2.4 In Progress)**: 本 SoT の bash literal には emit 例なし。`start.md` Phase 2.4 caller 側で `.result` が `failed` の場合に emit を inline 記述する責務がある。通常 `auto_add: true` で `skipped_not_in_project` は発火しにくいため failed 経路が主対象。
> - **Callsite 2 (Phase 5.5.1 In Review)**: `start-finalize.md` Phase 5.5.1 (defense-in-depth) と `pr/ready.md` Phase 4.2 (primary) の両 caller で emit を実装済み。`auto_add: false` のため `skipped_not_in_project` が発生しやすく、本契約の主対象。
> - **Callsite 3 (Phase 5.7.2 Done)**: 本 SoT の bash literal には emit 例なし。`start-finalize.md` Phase 5.7.2 caller および `close.md` Phase 4.6.3 (`status update` 経由) の caller 側で emit を inline 記述する責務がある。`auto_add: false` のため `skipped_not_in_project` が発生しやすい。
> - **Callsite 4 (Phase 1.5.5 Parent Auto-Close → Done)**: `parent-routing.md` Phase 1.5.5 caller 側で emit を実装済み (Issue #1070 で追加)。`auto_add: true` のため通常 `skipped_not_in_project` は発火しにくいが、Projects API 失敗 (5xx / 認証エラー等) で `failed` 経路が発火する場合に sentinel を emit する。
> - **最終 fallback**: emit 漏れがあった場合の最終 fallback は `start-finalize.md` Workflow Termination Step 0 (Issue #1003 AC-8) の状態 query 経路で surface される。

## Callsite 1 — Phase 2.4 (Issue Status → In Progress)

**Step 1** — Read config and emit a skip marker on stdout (the LLM reads the marker, not a bash variable; shell state does not persist across Bash tool invocations):

```bash
projects_enabled=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' rite-config.yml 2>/dev/null)
project_number=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' rite-config.yml 2>/dev/null)
project_owner=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    owner:/{gsub(/"/,"",$2); print $2; exit}' rite-config.yml 2>/dev/null)
if [ "$projects_enabled" != "true" ]; then
  echo "[CONTEXT] PHASE_2_4_STATE=skip; reason=projects_disabled"
else
  echo "[CONTEXT] PHASE_2_4_STATE=execute; project_number=$project_number owner=$project_owner"
fi
```

**LLM routing rule** (Bash tool shell state does not persist): the LLM reads the `[CONTEXT] PHASE_2_4_STATE=` marker from the bash block's stdout in the conversation context:

| `PHASE_2_4_STATE` value | LLM action |
|------------------------|-----------|
| `skip` | Skip Step 2 and Step 3 below. Go directly to Mandatory After 2.4. The post-projects marker is still written so the two whitelist transitions stay valid (the skip is recorded, not silent). |
| `execute` | Proceed to Step 2-3 using the emitted `project_number` / `owner` values. |

Do NOT rely on a bash variable (`SKIP_2_4=1`) that persists only within a single Bash tool call — each `echo`/`gh api` in the following steps is a separate invocation and the variable is lost. The `[CONTEXT]` marker travels via the conversation context and is authoritative.

**Step 2** — Update Issue Status to "In Progress" via the shared script:

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "In Progress" \
  --argjson auto_add true \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

The script executes: GraphQL `projectItems` query → auto-add if not registered → `field-list` retrieval → Status `item-edit`. Inspect its stdout JSON:

- `.result == "updated"` → success.
- `.result == "skipped_not_in_project"` or `"failed"` → display `.warnings[]` and continue (non-blocking). The scaffolding-failure itself is recorded by stop-guard via the whitelist on the next transition attempt.

The script is the single source of truth for Projects Status updates. See [projects-integration.md §2.4.2-2.4.5](../../../references/projects-integration.md#242-check-issue-project-registration-status) for API-level documentation.

**Step 3** — Parent Issue Status Update (2.4.7): **always execute** this substep regardless of whether the current Issue was identified as a parent in Phase 0.3 (Phase 0.3 detects children, not parents). **Execute the full 3-method detection and Status update procedure from [projects-integration.md §2.4.7](../../../references/projects-integration.md#247-parent-issue-status-update-for-child-issues)** (Method 1: `## 親 Issue` body meta PRIMARY → Method 2: Sub-Issues API → Method 3: tasklist search → 2.4.7.2 Retrieve → 2.4.7.3 Status Condition → 2.4.7.4 Update). When all three methods fail, the referenced procedure emits a debug log and skips silently — this is the normal path for standalone Issues (AC-4).

> **Issue #513 regression guard**: Do NOT replace this delegation with an inline simplification (e.g., querying only `trackedInIssues` or only one detection method). Past incident (Issue #513): a `trackedInIssues`-only inline version in this file caused AC-1 failure in repositories that manage parent-child links via body tasklist and `## 親 Issue` meta rather than GitHub's native Sub-Issues feature. `parent-child-sync-static.test.sh` pins this literal to prevent silent re-introduction.

## Callsite 2 — Phase 5.5.1 (Issue Status → In Review)

**Owner**: `/rite:issue:start` (defense-in-depth — `rite:pr:ready` Phase 4 also attempts this, but may not execute reliably within e2e flow).

**Note**: Delegates to `plugins/rite/scripts/projects-status-update.sh`. `ready.md` Phase 4.2 も同じく `projects-status-update.sh` delegate に統一済み。本 Phase 5.5.1 は defense-in-depth の二重実行であり、ready.md 失敗時の補完として機能する。

Skip if `projects.enabled: false` in rite-config.yml. Otherwise invoke the shared script to transition the Issue Status to **In Review**:

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "In Review" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

`auto_add: false` because at this point the Issue is already registered in the Project (Phase 2.4 auto-added it if missing).

Inspect the script's stdout JSON:

- `.result == "updated"` → success.
- `.result == "skipped_not_in_project"` → display `警告: Issue #{issue_number} は Project に登録されていません` and continue (non-blocking).
- `.result == "failed"` → display `.warnings[]` and continue (non-blocking).

See [projects-integration.md §2.4](../../../references/projects-integration.md#24-github-projects-status-update) for the underlying API calls.

## Callsite 3 — Phase 5.7.2 (Parent Issue Status → Done)

**Step 1**: Update parent Issue Status to "Done" via the shared script.

Skip if `projects.enabled: false` in rite-config.yml. Otherwise:

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {parent_issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "Done" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

Inspect the script's stdout JSON:

- `.result == "updated"` → success.
- `.result == "skipped_not_in_project"` → display `警告: Issue #{parent_issue_number} は Project に登録されていません` and proceed to Step 2 (non-blocking).
- `.result == "failed"` → display `.warnings[]` and proceed to Step 2 (non-blocking).

**Step 2** (Phase 5.7.2 specific): Close the parent Issue via `/rite:issue:close` Skill invocation — see `start.md` Phase 5.7.2 本体の Step 2 invocation block。本 reference は Step 1 (Status update) の bash literal SoT のみ提供する。

## Callsite 4 — Phase 1.5.5 (Parent Auto-Close → Done)

**Owner**: `/rite:issue:start` (via `parent-routing.md` Phase 1.5.5 sub-skill — auto-close path when all child Issues are CLOSED).

**Note**: `parent-routing.md` Phase 1.5.5 で「親 Issue をクローズする」が選択され `gh issue close` が成功した場合に呼ばれる。`auto_add: true` のため Projects 未登録の親 Epic でも自動追加 + Done 設定が行われる (`pr/cleanup.md` の通常 PR merge 経路 — Issue #658 で対応済 — とは異なる auto-close 経路を埋める)。

**Step 1** — Verify `gh issue close` succeeded; skip Status update if it failed (parent still OPEN — Done would be inconsistent):

```bash
gh issue close {issue_number} --comment "すべての子 Issue が完了したため、自動クローズします。"
close_status=$?
```

**Step 2** — Skip the Status update block if `projects.enabled: false`:

```bash
projects_enabled=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' rite-config.yml 2>/dev/null)
```

**Step 3** — Invoke the shared script to transition the Issue Status to **Done** (only when `close_status -eq 0` and `projects_enabled = true`):

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "Done" \
  --argjson auto_add true \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

`auto_add: true` because the parent Epic may not always be registered in the Project (defensive against unregistered parents). The script internally executes the GraphQL `projectItems` query → auto-add if missing → `field-list` → Status `item-edit`.

Inspect the script's stdout JSON:

- `.result == "updated"` → success.
- `.result == "skipped_not_in_project"` → display `警告: Issue #{issue_number} は Project に登録されていません` and continue (non-blocking). Emit `workflow_incident` sentinel.
- `.result == "failed"` → display `.warnings[]` and continue (non-blocking). Emit `workflow_incident` sentinel.

**Step 4** — Emit `workflow_incident` sentinel on `skipped_not_in_project` / `failed` (Common contract Item 5 / Issue #1003 AC-4). sibling Callsite 2/3 (`pr/ready.md` Phase 4.2 / `start-finalize.md` Phase 5.5.1 / 5.7.2) と observability 対称性を保つため `--root-cause-hint` を必ず付与する。`failed` arm は `failed|*)` combined (sibling 5 callsite と統一) で unknown schema 値も `details` 列に embed する:

```bash
# skipped_not_in_project arm
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type projects_status_update_failed \
  --details "Issue #{issue_number} parent auto-close (Phase 1.5.5): projects-status-update.sh returned skipped_not_in_project" \
  --root-cause-hint "issue_not_registered_in_project_at_parent_auto_close" \
  --pr-number 0 >&2 || true

# failed|*) combined arm (unknown schema 値は details に embed)
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type projects_status_update_failed \
  --details "Issue #{issue_number} parent auto-close (Phase 1.5.5): projects-status-update.sh returned failed or unrecognized result (\$status_result)" \
  --root-cause-hint "gh_api_or_graphql_failure_at_parent_auto_close" \
  --pr-number 0 >&2 || true
```

`--pr-number 0` because Phase 1.5.5 runs before any PR is created in the workflow.

> **Observability reach note (Issue #1070 review F-05)**: Phase 1.5.5 は **PR 作成前** に実行されるため、本 emit した sentinel は `start.md` Phase 5.4.4.1 grep 検出経路 (PR review-fix loop 内で動作) には **乗らない**。emit は observability log として stderr / conversation context に残り後追い debug に使えるが、auto-Issue-register 経路には乗らない (workflow 終了経路)。sibling Callsite 2/3 とは observability reach のレベルが異なる点に留意。

**Constraint** — Projects update failure MUST NOT roll back the `gh issue close` itself. The parent Issue remains CLOSED even when Status update fails (non-blocking design).

See [projects-integration.md §2.4](../../../references/projects-integration.md#24-github-projects-status-update) for the underlying API calls.

## 差分 summary (4 callsite 比較)

| Callsite | `status` | `auto_add` | `--argjson issue` 引数 | 補足 |
|----------|----------|------------|------------------------|------|
| Phase 2.4 | `In Progress` | `true` | `{issue_number}` | 当該 Issue 自身。未登録なら auto-add (true) |
| Phase 5.5.1 | `In Review` | `false` | `{issue_number}` | 既に Phase 2.4 で auto-add 済みのため `false` |
| Phase 5.7.2 | `Done` | `false` | `{parent_issue_number}` | 親 Issue 対象。auto-add 不要 |
| Phase 1.5.5 | `Done` | `true` | `{issue_number}` | 親 Epic auto-close 経路。未登録に備え auto-add (true) |

## 関連

- [`../../../references/projects-integration.md`](../../../references/projects-integration.md#24-github-projects-status-update) — API レベル動作仕様 SoT (GraphQL queries / item-add / field-list / item-edit)
- `plugins/rite/scripts/projects-status-update.sh` — Single source of truth (delegated by all 4 callsites)
- `plugins/rite/hooks/tests/parent-child-sync-static.test.sh` Group 4 — `Issue #513 regression guard` literal pin (本 reference の Callsite 1 Step 3 が grep 対象)
