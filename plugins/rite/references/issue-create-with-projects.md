---
description: Issue 作成 + GitHub Projects 統合の共通シェルスクリプト呼び出しガイド
---

# Issue Creation with Projects Integration

Guide for using the common shell script that creates a GitHub Issue and registers it in GitHub Projects with field configuration (Status, Priority, Complexity, Iteration).

**Script location**: `{plugin_root}/scripts/create-issue-with-projects.sh`

Referenced from:
- `commands/pr/fix.md` Phase 4.3.4 Step 2
- `commands/pr/review.md` Phase 7.4.2
- `commands/pr/create.md` Phase 2.5.5
- `commands/pr/cleanup.md` Phase 1.7.2
- `commands/issue/create.md` ステップ 4.3 (Single Issue creation)
- `commands/issue/create.md` ステップ 5.3 (parent Issue creation in XL decomposition)
- `commands/issue/create.md` ステップ 5.4 (Sub-Issue bulk creation in XL decomposition)

Related documents:
- [projects-integration.md](./projects-integration.md) - Existing Issue Status update / Iteration assignment (this document covers new Issue creation with Projects registration)

---

## Usage

### Step 1: Prepare Issue Body

Write the Issue body to a temporary file:

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{issue_body_markdown}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
 echo "ERROR: Issue body is empty" >&2
 exit 1
fi
```

### Step 2: Invoke the Script

```bash
result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
 --arg title "{title}" \
 --arg body_file "$tmpfile" \
 --argjson labels '["label1"]' \
 --argjson enabled true \
 --argjson project_number 2 \
 --arg owner "B16B1RD" \
 --arg status "Todo" \
 --arg priority "Medium" \
 --arg complexity "S" \
 --arg iter_mode "none" \
 --arg source "pr_review" \
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
 }'
)")
```

### Step 3: Parse the Result

**Note**: When the script exits with non-zero (`exit 1`), the `result=$(bash ...)` assignment still captures stdout, but `$?` will be non-zero. Always check the exit code or validate that `result` is non-empty before parsing.

```bash
# Check if the script succeeded (result may be empty if the script crashed)
if [ -z "$result" ]; then
 echo "ERROR: Script returned no output" >&2
 # handle error...
fi

issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "WARNING: $w"; done
```

---

## Input JSON Schema

```yaml
issue:
 title: string # Issue title (required)
 body_file: string # Path to tmpfile with body markdown (optional)
 labels: [string] # Labels to apply (optional)
 assignees: [string] # Assignees (optional)
projects:
 enabled: true|false # From rite-config.yml github.projects.enabled
 project_number: number # From rite-config.yml github.projects.project_number
 owner: string # From rite-config.yml github.projects.owner
 status: "Todo" # Default: "Todo"
 priority: "High|Medium|Low" # Determined by caller
 complexity: "XS|S|M|L|XL" # Determined by caller
 iteration:
 mode: "none|auto" # Default: "none". "auto" assigns to current iteration
 field_name: "Sprint" # Default: "Sprint"
options:
 source: string # Caller identifier (pr_review|pr_fix|pr_create|cleanup|lint|interactive|parent_routing|xl_decomposition)
 non_blocking_projects: true # Default: true. Projects failure doesn't block Issue creation
```

---

## Output JSON Contract

```json
{
 "issue_url": "https://github.com/.../issues/123",
 "issue_number": 123,
 "project_id": "PVT_...",
 "item_id": "PVTI_...",
 "project_registration": "skipped|ok|partial|failed",
 "warnings": ["string"]
}
```

| `project_registration` | Description |
|------------------------|-------------|
| `ok` | All fields set successfully |
| `partial` | Issue added to Project but some fields failed |
| `skipped` | Projects disabled or not configured |
| `failed` | `gh project item-add` failed entirely |

---

## Caller-Specific Priority Mapping

Each caller determines Priority using its own logic before passing it to the script.

### fix.md (Phase 4.3.4): Skip Reason Keyword Matching

| Skip Reason Keyword | Issue Priority | Reason |
|---------------------|----------------|--------|
| `緊急`, `重大`, `urgent`, `critical` | High | Requires priority attention |
| All others | Medium | Normal priority (default) |

### review.md (Phase 7.4): Severity-Based Mapping

| Finding Severity | Issue Priority | Reason |
|-----------------|----------------|--------|
| CRITICAL | High | Requires immediate attention |
| HIGH | Medium | Normal priority |
| MEDIUM | Low | Lower priority |

### create.md (Phase 2.5.5): Default Medium

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Unresolved issues detected during PR creation | Medium | Default for detected problems |

### cleanup.md (Phase 1.7): Default Medium

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Incomplete tasks from merged PR | Medium | Default for remaining work |

### create.md ステップ 5.3-5.4 (XL Decomposition, 旧 `create-decompose.md` Phase 3.3 を flat workflow に統合)

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Parent Issue creation (ステップ 5.3 — Create the Parent Issue) | Determined in interview phase | Use Priority value decided during Issue creation |
| Sub-Issue bulk creation (ステップ 5.4 — Bulk Creation of Sub-Issues) | Inherited from parent | Use parent Issue's Priority value |

### 旧 caller (retired)

- `parent-routing.md` Phase 1.5.4 (Child Issue creation, Inherited from Parent) — flat 化に伴い child issue 自動作成経路自体が廃止された
- `start.md` ステップ 8.5 (Workflow Incident Detection の auto-Issue 起票経路) — workflow-incident 機構ごと PR 2b / #1088 で廃止された

---

## Error Handling

The script handles errors internally with the following behavior:

| Error Case | Response |
|------------|----------|
| `gh issue create` failure | Output JSON with `project_registration: "failed"` + `exit 1`. Caller's `result=$(bash ...)` captures stdout but gets non-zero exit code |
| `gh project item-add` failure (after 3 retries) | Output JSON with `project_registration: "failed"` + `exit 0` (non-blocking) or `exit 1`. **stderr emit**: `ERROR: Projects registration failed: ...` |
| `item_id` retrieval failure (after fallback to last: 20 + 3 retries) | Output JSON with `project_registration: "partial"` + `exit 0`. **stderr emit** on each failure |
| Field setup failure (after 3 retries) | Output JSON with `project_registration: "partial"` + `exit 0`. **stderr emit** on each failure |
| Iteration assignment failure (after 3 retries) | `project_registration` becomes `partial`, **stderr emit** on each failure. Issue still created with status set |
| Projects not configured | Output JSON with `project_registration: "skipped"` + `exit 0`. **No stderr emit** (intentional skip, not failure) |

**Exit code convention:**
- `exit 0`: Success or non-blocking failure (Projects-related issues when `non_blocking_projects: true`)
- `exit 1`: Fatal error (Issue creation itself failed, or blocking failure when `non_blocking_projects: false`)

**Behavior on error:**
- All output (success and error) is written to **stdout** as JSON. The caller captures stdout via `result=$(bash ...)` and checks the exit code
- Projects registration failure does not block Issue creation when `non_blocking_projects: true` (default)
- Warnings are collected in the `warnings` array for caller to display
- If `result` is empty (script crashed), callers should check `$?` and handle gracefully

### Silent Fail Prohibition (#669)

Issue #669 strengthens the script so that **Projects registration failures are never silently absorbed** by the warnings array alone. Two reinforcement layers are in place:

1. **stderr emit on every registration failure** — `add_warning_with_stderr` writes `ERROR: Projects registration failed: <reason>` to stderr in addition to appending to the warnings array. The early `enabled=false` skip path uses plain `add_warning` so it stays silent (intentional skip, not failure).
2. **3-attempt exponential backoff on transient API errors** — `gh project item-add`, all GraphQL queries (`fields`, `items`, mutations), and `gh project item-edit` are wrapped in `retry_with_backoff 3 ...` (sleeps `RETRY_DELAY * 2^(n-1)` seconds — defaults to 1s, 2s between attempts; tests set `RETRY_DELAY=0`). This satisfies the MUST 2 / MUST NOT 2 requirements:
 - MUST: stderr surfaces root cause
 - MUST NOT: failures are not confined to the warnings array under exit code 0

### Static Guard for Direct `gh issue create` Invocations (#669 AC-3 / #958)

`plugins/rite/scripts/check-no-direct-gh-issue-create.sh` provides a mechanical check: every Issue creation path under `plugins/rite/commands/**/*.md` must go through this script. Two invocation modes are supported:

```bash
# Mode 1: explicit file list (original #669 form)
bash plugins/rite/scripts/check-no-direct-gh-issue-create.sh \
 plugins/rite/commands/issue/start.md \
 plugins/rite/commands/issue/create.md

# Mode 2: --all auto-expansion (#958)
# Scans every plugins/rite/commands/**/*.md file under the resolved repository root.
# Used by /rite:lint Phase 3.14 to enforce the guard across every command/sub-skill.
bash plugins/rite/scripts/check-no-direct-gh-issue-create.sh --all
```

Exit 0 = no violations. Exit 1 = direct `gh issue create -...` / `gh issue create $...` / `gh issue create "..."` / `gh issue create '...'` invocation found (after stripping fenced code blocks, blockquotes, Markdown comments, and inline backticks). Exit 2 = usage error (no arguments, missing file, `--all` expansion empty / commands directory absent, or `--repo-root` argument missing / non-existent directory). Tests live at `plugins/rite/scripts/tests/check-no-direct-gh-issue-create.test.sh` and include positive, negative, false-positive-avoidance, `--all` mode, and `--repo-root` override cases (happy path / missing argument / non-existent directory) (TC-001 through TC-015). `/rite:lint` Phase 3.14 invokes the script with `--all` on every lint run and records findings as warning-level (does not change `[lint:success]`); see [lint.md Phase 3.14](../commands/lint.md#314-plugin-specific-checks-direct-gh-issue-create-invocation--issue-958) for the lint integration details.

---

## Script Internal Details

The script automatically handles:
- Owner type detection (User vs Organization) for GraphQL queries
- Item ID retrieval with fallback (last: 10 → last: 20)
- Field ID and option ID resolution from project field metadata
- Iteration auto-assignment when `iteration.mode: "auto"`
- 3-attempt exponential backoff retry on transient API failures (#669)
- stderr emit for every Projects registration failure (#669)
