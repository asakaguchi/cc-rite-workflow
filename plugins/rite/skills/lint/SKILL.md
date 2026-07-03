---
name: lint
description: |
  rite workflow の品質チェックステップ: プロジェクト設定に基づく lint / 整合性チェックを実行する。
  /rite:open・/rite:ready から programmatic に呼ばれる sub-step、または手動 /rite:lint。汎用の
  「lint」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:lint
argument-hint: ""
---

# /rite:lint

## Contract
**Input**: rite-config.yml `commands` section (lint/test/typecheck commands), flow state (optional, e2e flow)
**Output**: `[lint:success]` | `[lint:skipped]` | `[lint:error]` | `[lint:aborted]`

品質チェック（lint）を実行し、結果を報告する

## E2E Output Minimization

When called from the `/rite:open` end-to-end flow, minimize output to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 3 (Execution) | Full output | Full output (needed for error diagnosis) |
| Phase 4.1 (Success) | Full report | `[lint:success]` + 1-line summary only |
| Phase 4.2 (Error) | Full output + suggestions | `[lint:error]` + error count + first 10 lines only |
| Phase 4.3 (Summary) | Full table | **Skip entirely** |
| Phase 4.4 (Work Memory) | Full update | Full update (no change) |

> **⚠️ "Skip entirely" は出力の話**: Phase 4.3 の "Skip entirely" は **人間向けサマリー表示を省く** ことを意味するのみで、Phase 3 の lint 実行や Phase 4.4 の work memory 更新など処理本体は常に実行する。時間・context を理由にした lint 処理そのものの省略は禁止。Identity: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md)。

**Detection**: See [Caller Context and End-to-End Flow](#caller-context-and-end-to-end-flow) determination method below.

---

Execute the following phases in order when this command is invoked.

## Caller Context and End-to-End Flow

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands in this file.

This command has two invocation cases: standalone execution and being called from the `/rite:open` end-to-end flow.

| Caller | Output Pattern | Subsequent Action |
|-----------|-------------|---------------|
| `/rite:open` (end-to-end flow) | Output (required) | `/rite:open` calls `rite:pr-create` at ステップ 6 after consuming the lint result at ステップ 5.1 |
| Standalone execution | Output (required) | Display "next steps" guidance |

**Determination method**: Claude determines the caller from conversation context:

| Condition | Result |
|------|---------|
| `rite:lint` was called via the `Skill` tool immediately prior within the same session | Within end-to-end flow |
| Otherwise (user directly typed `/rite:lint`) | Standalone execution |

**Note**: `skills/fix/SKILL.md` also uses conversation context for determination in the same manner.

**Output patterns (required regardless of caller):**
- `[lint:success]` - lint completed successfully
- `[lint:skipped]` - lint skipped
- `[lint:error]` - lint errors detected
- `[lint:aborted]` - user aborted

> **Important (flow continuation responsibility)**: When executed within the end-to-end flow, **this command does NOT directly call `rite:pr-create`; it returns control to the caller `/rite:open`**. `/rite:open` calls `rite:pr-create` at ステップ 6 after consuming the lint result at ステップ 5.1 (checklist completion confirmation happens earlier at ステップ 4.4).

---

## Arguments

| Argument | Description |
|------|------|
| `[path]` | File or directory to check (defaults to changed files if omitted) |

---

## Phase 0: Load Work Memory (End-to-End Flow)

When executed within the end-to-end flow, load necessary information from work memory (shared memory).

### 0.1 End-to-End Flow Determination

Determine the caller from conversation context:

| Condition | Result | Action |
|------|---------|------|
| Conversation history contains rich context from `/rite:open` | Within end-to-end flow | Work memory loading optional (information available in context) |
| `/rite:lint` was executed standalone | Standalone execution | Can identify Issue from branch name |

### 0.2 Load Work Memory

Extract the Issue number from the current branch and retrieve work memory:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得
owner=$(gh repo view --json owner --jq '.owner.login')
repo=$(gh repo view --json name --jq '.name')

# 作業メモリを取得
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
```

### 0.3 Information to Retrieve

Extract the following information from work memory and retain in context:

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `issue-(\d+)` from branch name | Phase 4.4 work memory update |
| Branch name | `- **ブランチ**: (.+)` | Verification |
| Phase | `- **フェーズ**: (.+)` | Flow position confirmation |
| Next steps | `### 次のステップ` section | Expected operation confirmation |

**If work memory is not found:**

If the Issue number cannot be obtained or the work memory comment does not exist:
- Display a warning and skip
- Continue with normal lint execution (proceed to Phase 1)

---

## Phase 1: Lint Command Detection

### 1.1 Check Explicit Configuration

Retrieve the lint command from `rite-config.yml`:

```yaml
commands:
  lint: "npm run lint"  # 明示的に設定されている場合
```

Read the configuration file:

```bash
# rite-config.yml を読み取り
cat rite-config.yml
```

If `commands.lint` has a configured value, use it.

### 1.2 Auto-Detection (When No Configuration Exists)

Detect project files and determine the lint command:

| File | Detection Condition | Lint Command |
|----------|----------|---------------|
| `package.json` | `scripts.lint` exists | `npm run lint` |
| `pyproject.toml` | File exists | `ruff check .` |
| `Cargo.toml` | File exists | `cargo clippy -- -D warnings` |
| `go.mod` | File exists | `golangci-lint run` |
| `Makefile` | `lint` target exists | `make lint` |

**Detection priority:**
1. `commands.lint` in `rite-config.yml` (explicit configuration)
2. `scripts.lint` in `package.json`
3. `pyproject.toml` -> `ruff check .`
4. `Cargo.toml` -> `cargo clippy -- -D warnings`
5. `go.mod` -> `golangci-lint run`
6. `lint` target in `Makefile`

```bash
# package.json の scripts を確認
cat package.json | jq -r '.scripts.lint // empty'

# または各言語のファイル存在確認
ls package.json pyproject.toml Cargo.toml go.mod Makefile 2>/dev/null
```

### 1.3 When Command Cannot Be Detected

If the lint command cannot be detected, use the `AskUserQuestion` tool to interactively confirm.

**Note**: `AskUserQuestion` is a standard Claude Code tool that presents choices to the user and retrieves their response.

```
lint コマンドを検出できませんでした

対応している自動検出:
- Node.js: package.json の scripts.lint
- Python: ruff check（pyproject.toml 検出時）
- Rust: cargo clippy（Cargo.toml 検出時）
- Go: golangci-lint run（go.mod 検出時）

オプション:
- スキップして続行（推奨）: lint をスキップし、次のステップに進みます
- コマンドを指定: lint コマンドを手動で入力します
- 中断: 処理を中断します
```

**Subsequent processing for each choice:**

| Choice | Subsequent Processing |
|--------|----------|
| **Skip and continue** | Record "lint skipped" in conversation context, skip Phase 2 onward, and complete normally. If called from `/rite:open`, proceed to the next step (PR creation) |
| **Specify command** | Follow up with `AskUserQuestion` to prompt for command input (see below), then execute Phase 2 onward with the entered command |
| **Abort** | Abort processing and display guidance to "configure lint and run again" |

**Output and recording when skipped:**

When lint is skipped, output the completion message in the following format:

**Standalone execution:**
```
[lint:skipped]
lint をスキップしました。
理由: lint コマンド未検出

次のステップ:
1. 必要に応じて `/rite:pr-create` で PR 作成
```

**When called from `/rite:open`:**
```
[lint:skipped]
lint をスキップしました。
理由: lint コマンド未検出

---
🔄 **フロー継続**: 呼び出し元の `/rite:open` が ステップ 6（PR 作成）を実行
```

> If `/rite:lint` continues to PR creation directly, it bypasses the checklist confirmation in the caller, potentially creating a PR with incomplete tasks.
> **CRITICAL**: When called from `/rite:open`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr-create` is made by `/rite:open` at ステップ 6 after the lint result is consumed at ステップ 5.1.

**Meaning of output patterns:**
- `[lint:skipped]`: Used by `/rite:open` ステップ 5.1 to detect this pattern and decide to proceed to ステップ 6 (PR creation)
- `[lint:success]`: When lint completed successfully (output in Phase 4.1)
- `[lint:error]`: When lint detected errors (output in Phase 4.2)
- `[lint:aborted]`: When the user selected "Abort"

**Clarification of responsibilities:**

Reflecting the lint skip in the PR body is the responsibility of `/rite:open` ステップ 5:
1. `/rite:lint` only outputs the above output patterns
2. When `/rite:open` detects `[lint:skipped]`, it prepares the PR body template before calling `/rite:pr-create`
3. The "Known Issues" section of the PR body includes the following:

```markdown
## Known Issues
- lint 未実行（lint コマンドが検出されませんでした）
```

**Processing when command is specified:**

When "Specify command" is selected, use `AskUserQuestion` to prompt for command input:

```
使用する lint コマンドを入力してください（例: npm run lint, ruff check .）

オプション:
- npm run lint
- ruff check .
- 他のコマンドを入力（Other を選択）
```

**Note**: Present representative commands as choices in `AskUserQuestion` `options`. The user can also select "Other" to enter a custom command.

When the user enters/selects a command:

1. Execute Phase 2 onward using the entered command
2. Do not save to `rite-config.yml` (temporary use only)
3. If saving to configuration is needed, guide the user to `/rite:init` or manual editing

---

## Phase 2: Determine Target Files

### 2.1 When Arguments Are Specified

Use the specified path as-is:

```
対象: {path}
```

If the path does not exist:

```
指定されたパス '{path}' が見つかりません

対処:
1. パスが正しいか確認
2. ファイル/ディレクトリが存在するか確認
```

### 2.2 When Arguments Are Omitted

Detect changed files (in priority order):

#### 2.2.1 Get Base Branch

Read `rite-config.yml` from the project root using the Read tool, and retrieve the `branch.base` value:

```
Read: rite-config.yml
```

**Retrieval logic:**
1. If `rite-config.yml` exists and `branch.base` is set -> Use that value as `{base_branch}`
2. If `rite-config.yml` does not exist (Read tool returns an error), or `branch.base` is not set -> Use `main` as the default

**Definition of "not set":**
- `branch.base` key does not exist
- `branch.base` key value is `null` or empty string
- `branch` section itself does not exist

**Placeholder interpretation:**

`{base_branch}` in this document is replaced with the actual branch name obtained by the above logic. For example, if `branch.base: "develop"` is configured, the subsequent bash command `git diff --name-only origin/{base_branch}...HEAD` is executed as `git diff --name-only origin/develop...HEAD`.

#### 2.2.2 Detect Changed Files

Use the `{base_branch}` value obtained above to detect diffs. Follow the fallback logic below, trying each in sequence:

**Fallback logic (sequential attempts):**

| Priority | Condition | Command to Execute |
|--------|------|-------------|
| 1 | `origin/{base_branch}` exists | `git diff --name-only origin/{base_branch}...HEAD` |
| 2 | Above fails and `{base_branch}` exists | `git diff --name-only {base_branch}...HEAD` |
| 3 | Both fail | Error with guidance |

**Execution example:**

```bash
# 優先度 1: リモートベースブランチからの差分（推奨）
git diff --name-only origin/{base_branch}...HEAD

# 優先度 2: ローカルベースブランチからの差分（優先度 1 が失敗した場合）
git diff --name-only {base_branch}...HEAD
```

**When both fail:**

```
エラー: 変更ファイルを特定できません

ベースブランチ '{base_branch}' が見つかりません。

対処:
1. 明示的にパスを指定して再実行: /rite:lint <path>
2. rite-config.yml で branch.base を確認
3. git fetch origin でリモート情報を更新
```

Terminate processing. Do not silently fall back to `HEAD` diff or targeting the entire project — this would change the lint scope without the user's knowledge.

**When there are no changed files:**

```
変更ファイルがありません。プロジェクト全体をチェックします

ベースブランチとの差分がないため、プロジェクト全体をチェックします。
特定のパスに限定するには /rite:lint <path> を指定してください。
```

Target the entire project (current directory) with a visible warning that the scope has expanded.

---

## Phase 3: Lint Execution

### 3.1 Pre-Execution Notice

```
品質チェックを実行しています...

コマンド: {lint_command}
対象: {target_path または "変更ファイル ({count} files)"}
```

### 3.2 Command Execution

```bash
# 検出されたコマンドを実行
{lint_command} {target_files}
```

**Notes:**
- The method for specifying target files varies by command
- `npm run lint` follows the project configuration
- `ruff check` accepts paths as arguments
- Display output even if there are errors (determine by exit code)

### 3.3 Capture Execution Results

Record the command's exit code and output:
- Exit code 0: No issues
- Exit code 1+: Errors or warnings present

### 3.4 Test Execution (Conditional)

Execute test commands as part of quality check when configured.

**Condition**: `commands.test` is set (non-null) in `rite-config.yml` AND `verification.run_tests_before_pr` is `true` (default: `true`).

**Skip conditions** (any match → skip to Phase 4):
- `commands.test` is `null` or not set
- `verification.run_tests_before_pr` is `false`

**Note**: When the `verification` section does not exist in `rite-config.yml`, treat defaults as enabled (`run_tests_before_pr: true`). The test execution condition still requires `commands.test` to be set.

**Duplicate execution avoidance**: When called from the `/rite:open` end-to-end flow and tests were already run and passed in `implement.md` Phase 5.1.0.6 (Test Verification Gate — implement.md retains its own internal phase numbering; test results available in conversation context), skip duplicate test execution and reuse previous results.

When skipped, no output needed (silent skip).

**Execution:**

```
テストを実行しています...

コマンド: {test_command}
```

```bash
# commands.test を実行
{test_command}
```

**Result handling:**

| Exit Code | Action |
|-----------|--------|
| 0 | Tests passed — record success, continue to Phase 4 |
| Non-zero | Tests failed — record as error, include in Phase 4 report |

**Record test results** alongside lint results for Phase 4 reporting:
- `test_status`: `success` / `error` / `skipped`
- `test_error_count`: Number of failed tests (0 if success)
- `test_output`: Test command output (truncated if >500 lines)

**Common contract for the plugin-specific checks (3.5–3.18)**: each check below runs its `{plugin_root}/hooks/scripts/*.sh` script when that script exists, is **independent of `commands.lint` configuration** (a rite-workflow internal quality check), and is **skipped silently** when the script file is absent (e.g., marketplace install without the `hooks/scripts/` directory). Unless a check states otherwise, its findings are recorded as **warnings** (they do NOT change the overall `[lint:success]` result). Each check's section below states only its script-specific execution and result handling.

### 3.5 Plugin-specific Checks (Distributed Fix Drift Detection)

Execute the distributed fix drift check script to detect documentation drift patterns in rite-workflow procedural markdown files.

**Condition**: Always execute when `{plugin_root}/hooks/scripts/distributed-fix-drift-check.sh` exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/distributed-fix-drift-check.sh ]; then
  drift_output=$(bash {plugin_root}/hooks/scripts/distributed-fix-drift-check.sh --all 2>&1)
  drift_exit_code=$?
else
  drift_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `drift_status` | Action |
|-----------|----------------|--------|
| 0 | `success` | No drift detected — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). Display drift findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Drift detection results are treated as **warnings**, not errors. A drift finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). This design choice reflects that drift findings are documentation consistency issues, not code quality blockers.

**Record drift results** for Phase 4 reporting:
- `drift_status`: `success` / `warning` / `error` / `skipped`
- `drift_finding_count`: Extract from `drift_output` by matching the line `==> Total drift findings: N` (regex: `/Total drift findings: (\d+)/`). If no match found, default to 0
- `drift_output`: Script output (truncated if >50 lines)

### 3.6 Plugin-specific Checks (Bang-Backtick Adjacency Detection)

Execute the bang-backtick check script to detect Skill loader triggering patterns (backtick + bang adjacency) in **`plugins/rite/skills/**/*.md`**, **`plugins/rite/agents/**/*.md`**, and **`plugins/rite/references/**/*.md`** (plugin-scoped; the script walks the rite plugin tree specifically and does not scan repository-root `skills/` or similar directories that may belong to other plugins). This is the static lint counterpart to the incident where inline-code bang adjacency broke Skill loading via bash history expansion. See the script header comment at `plugins/rite/hooks/scripts/bang-backtick-check.sh` for concrete detection patterns.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/bang-backtick-check.sh ]; then
  bang_backtick_output=$(bash {plugin_root}/hooks/scripts/bang-backtick-check.sh --all 2>&1)
  bang_backtick_exit_code=$?
else
  bang_backtick_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `bang_backtick_status` | Action |
|-----------|------------------------|--------|
| 0 | `success` | No bang-backtick adjacency — continue to Phase 4 |
| 1 | `warning` | Pattern detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Bang-backtick detection results are treated as **warnings**, not errors — same policy as Phase 3.5 drift check. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Reason: existing checks stay non-blocking during staged rollout, and Skill loader triggering is a correctness issue that should be fixed promptly but not gate CI until coverage is validated.

**Record bang-backtick results** for Phase 4 reporting:
- `bang_backtick_status`: `success` / `warning` / `error` / `skipped`
- `bang_backtick_finding_count`: Extract from `bang_backtick_output` by matching the line `==> Total bang-backtick findings: N` (regex: `/Total bang-backtick findings: (\d+)/`). If no match found, default to 0
- `bang_backtick_output`: Script output (truncated if >50 lines)

### 3.7 Plugin-specific Checks (Doc-Heavy Patterns Drift Detection)

Execute the doc-heavy patterns drift check script to detect divergence between the `doc_file_patterns` declared in 2 files that MUST stay in sync: `plugins/rite/skills/review/SKILL.md` (ステップ 1.2.7 `doc_file_patterns` pseudo-code block) and `plugins/rite/skills/reviewers/SKILL.md` (Reviewers table Technical Writer row). Drift between these files silently changes tech-writer activation and Doc-Heavy PR detection. See the script header at `plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh` for the extraction contract.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/doc-heavy-patterns-drift-check.sh ]; then
  doc_heavy_drift_output=$(bash {plugin_root}/hooks/scripts/doc-heavy-patterns-drift-check.sh --all 2>&1)
  doc_heavy_drift_exit_code=$?
else
  doc_heavy_drift_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `doc_heavy_drift_status` | Action |
|-----------|--------------------------|--------|
| 0 | `success` | No drift across the 2 files — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Drift detection results are treated as **warnings**, not errors — same policy as Phase 3.5 drift check and Phase 3.6 bang-backtick check. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Reason: existing checks stay non-blocking during staged rollout, and the 2-file invariant should be fixed promptly by the author of the diverging change but not gate CI until coverage is validated across the rite plugin's self-hosting workflow.

**Record drift results** for Phase 4 reporting:
- `doc_heavy_drift_status`: `success` / `warning` / `error` / `skipped`
- `doc_heavy_drift_finding_count`: Extract from `doc_heavy_drift_output` by matching the line `==> Total doc-heavy-patterns-drift findings: N` (regex: `/Total doc-heavy-patterns-drift findings: (\d+)/`). If no match found, default to 0
- `doc_heavy_drift_output`: Script output (truncated if >50 lines)

### 3.7.1 Plugin-specific Checks (Reviewer Registry Drift Detection)

Execute the reviewer registry drift check script to detect divergence across the 3 places that must stay in sync when a reviewer is added or removed: `plugins/rite/agents/*-reviewer.md` (profile files), and the `Available Reviewers` / `Reviewer Type Identifiers` tables in `plugins/rite/skills/reviewers/SKILL.md`. A half-registered reviewer either never spawns or spawns a nonexistent subagent. See the script header at `plugins/rite/hooks/scripts/reviewer-registry-drift-check.sh` for the invariant contract, and CONTRIBUTING.md "Adding a New Reviewer" for the full edit procedure.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/reviewer-registry-drift-check.sh ]; then
  reviewer_registry_drift_output=$(bash {plugin_root}/hooks/scripts/reviewer-registry-drift-check.sh --all 2>&1)
  reviewer_registry_drift_exit_code=$?
else
  reviewer_registry_drift_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `reviewer_registry_drift_status` | Action |
|-----------|----------------------------------|--------|
| 0 | `success` | Registry in sync across the 3 points — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Drift detection results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`).

**Record drift results** for Phase 4 reporting:
- `reviewer_registry_drift_status`: `success` / `warning` / `error` / `skipped`
- `reviewer_registry_drift_finding_count`: Extract from `reviewer_registry_drift_output` by matching the line `==> Total reviewer-registry-drift findings: N` (regex: `/Total reviewer-registry-drift findings: (\d+)/`). If no match found, default to 0
- `reviewer_registry_drift_output`: Script output (truncated if >50 lines)

### 3.8 Plugin-specific Checks (Wiki Growth Check)

Execute the Wiki growth check script to detect "Phase X.X.W silently skipped" regressions. The script warns (non-blocking) when the wiki branch has gone unchanged for `wiki.growth_check.threshold_prs` consecutive merged PRs on the development base branch — strong evidence that `skills/review/SKILL.md` ステップ 6.5.W / `skills/fix/SKILL.md` ステップ 4.6.W / `skills/issue-close/SKILL.md` Phase 4.4.W are being skipped silently. See `plugins/rite/hooks/scripts/wiki-growth-check.sh` header for the detection contract and the 3-layer defense rationale.

**Condition**: Always execute when the script exists.

**Skip condition**: Only the script's own absence (e.g., marketplace install without `hooks/scripts/` directory) makes lint.md skip the entire Phase 3.8. All other no-op cases (wiki disabled / wiki branch absent / `gh` CLI missing / `rite-config.yml` absent) are handled **inside** `wiki-growth-check.sh`, which still returns exit 0 → `wiki_growth_status=success` (with `findings_count=0`). lint.md does NOT need to detect these cases — the script's exit-0 contract takes care of them and the Phase 4 summary row will simply show `success (0 findings)` for any of these legitimate no-op states.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/wiki-growth-check.sh ]; then
  wiki_growth_output=$(bash {plugin_root}/hooks/scripts/wiki-growth-check.sh --quiet 2>&1)
  wiki_growth_exit_code=$?
else
  wiki_growth_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `wiki_growth_status` | Action |
|-----------|----------------------|--------|
| 0 | `success` | Wiki growing healthily, OR a legitimate no-op (wiki disabled / wiki branch absent / `gh` CLI missing / `rite-config.yml` absent — script handled internally and returned 0 with `findings: 0`) — continue to Phase 4 |
| 1 | `warning` | Growth threshold exceeded — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error (bad args, not in git repo) — record as warning, display error message |
| -1 | `skipped` | Script not found (marketplace install without `hooks/scripts/`) — skip silently |

**Important**: Wiki growth check results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). This contract is explicitly mandated — the check exists to surface awareness, not to block CI.

**Record growth check results** for Phase 4 reporting:
- `wiki_growth_status`: `success` / `warning` / `error` / `skipped`
- `wiki_growth_finding_count`: Extract from `wiki_growth_output` by matching the line `==> Total wiki-growth-check findings: N` (regex: `/Total wiki-growth-check findings: (\d+)/`). If no match found, default to 0
- `wiki_growth_output`: Script output (truncated if >50 lines)

### 3.9 Plugin-specific Checks (Gitignore Health Check)

Execute the gitignore health check script to detect regressions of the `.rite/wiki/` exclusion rule added as the last line of defense against wiki-ingest-trigger.sh silent leaks on the develop branch. If a future `.gitignore` cleanup PR removes the rule, this check surfaces the drift before the leak reaches production. See `plugins/rite/hooks/scripts/gitignore-health-check.sh` header for the strategy-aware detection contract (separate_branch uses `git check-ignore`; same_branch uses `git add --dry-run` because negation rules make `git check-ignore` non-deterministic per `.gitignore` L101-113 spec).

**Condition**: Always execute when the script exists.

**Skip condition**: Only the script's own absence (e.g., marketplace install without `hooks/scripts/` directory) makes lint.md skip the entire Phase 3.9. All other no-op cases (`wiki.enabled=false`, `rite-config.yml` absent, wiki section absent) are handled **inside** `gitignore-health-check.sh`, which returns exit 0 with `findings: 0`.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/gitignore-health-check.sh ]; then
  gitignore_health_output=$(bash {plugin_root}/hooks/scripts/gitignore-health-check.sh --quiet 2>&1)
  gitignore_health_exit_code=$?
else
  gitignore_health_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `gitignore_health_status` | Action |
|-----------|---------------------------|--------|
| 0 | `success` | `.rite/wiki/` rule healthy (or legitimate no-op: wiki disabled / `rite-config.yml` absent — script handled internally and returned 0 with `findings: 0`) — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). A `WARNING` is also emitted on stderr so the operator can triage the drift. Display findings and allow flow to continue |
| 2 | `error` | Invocation error (not in git repo, `git check-ignore` failure, `same_branch` 戦略で probe file 作成不能 — read-only filesystem / permission denied / disk full 等) — record as warning, display error message |
| -1 | `skipped` | Script not found (marketplace install without `hooks/scripts/`) — skip silently |

**Important**: Gitignore health check results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 / 3.8 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). This non-blocking contract is explicit — the check exists to detect regression immediately while not halting merges.

**Record gitignore health check results** for Phase 4 reporting:
- `gitignore_health_status`: `success` / `warning` / `error` / `skipped`
- `gitignore_health_finding_count`: Extract from `gitignore_health_output` by matching the line `==> Total gitignore-health-check findings: N` (regex: `/Total gitignore-health-check findings: (\d+)/`). If no match found, default to 0
- `gitignore_health_output`: Script output (truncated if >50 lines)

### 3.10 Plugin-specific Checks (Backlink Format Check)

Execute the backlink format check script to detect bidirectional backlink format invariant violations. Colon notation (file-path-colon-phase-number) is the canonical format for `Downstream reference:` backlink comments. This lint check detects regressions to two legacy dialects (a space-separated dialect and a parenthetical DRIFT-CHECK ANCHOR dialect). See `plugins/rite/hooks/scripts/backlink-format-check.sh` header and `.rite/wiki/pages/patterns/drift-check-anchor-semantic-name.md` for the canonical format specification.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/backlink-format-check.sh ]; then
  backlink_format_output=$(bash {plugin_root}/hooks/scripts/backlink-format-check.sh --all 2>&1)
  backlink_format_exit_code=$?
else
  backlink_format_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `backlink_format_status` | Action |
|-----------|--------------------------|--------|
| 0 | `success` | No dialect violations — continue to Phase 4 |
| 1 | `warning` | Dialect violation detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Backlink format check results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 / 3.8 / 3.9 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Warning-level non-blocking behaviour lets the canonical format guideline be enforced progressively without gating CI.

**Record backlink format check results** for Phase 4 reporting:
- `backlink_format_status`: `success` / `warning` / `error` / `skipped`
- `backlink_format_finding_count`: Extract from `backlink_format_output` by matching the line `==> Total backlink-format findings: N` (regex: `/Total backlink-format findings: (\d+)/`). If no match found, default to 0
- `backlink_format_output`: Script output (truncated if >50 lines)

### 3.11 Plugin-specific Checks (Hardcoded Line-Number Check)

Execute the hardcoded line-number check script to detect prose-level hardcoded line-number references in `plugins/rite/skills/**/*.md`. This complements the Phase 3.5 distributed fix drift check by catching three drift-prone patterns that the existing `(line N, M)`-only propagation scan missed:

- **P-A** parenthesized form `(line N)` / `(line N, M)`
- **P-B** Japanese prose form (qualifier `直前` / `直後` / `上記` / `下記` / `上方` / `下方` / `本セクション` near `line N`)
- **P-C** cross-file form `{file}.md:N` (single line, not range)

See the script header at `plugins/rite/hooks/scripts/hardcoded-line-number-check.sh` for the exact regex literals and exclusion rules (fenced code blocks, range form `:N-M`, backtick-quoted spans, self-exclusion).

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/hardcoded-line-number-check.sh ]; then
  hardcoded_line_output=$(bash {plugin_root}/hooks/scripts/hardcoded-line-number-check.sh --all 2>&1)
  hardcoded_line_exit_code=$?
else
  hardcoded_line_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `hardcoded_line_status` | Action |
|-----------|-------------------------|--------|
| 0 | `success` | No hardcoded line-number references — continue to Phase 4 |
| 1 | `warning` | Reference detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Hardcoded line-number check results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 / 3.8 / 3.9 / 3.10 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). This stays warning-level so the rule can be enforced progressively without gating CI; structural references are preferred over hardcoded line numbers because they self-document and survive content insertions/deletions.

**Record hardcoded line-number check results** for Phase 4 reporting:
- `hardcoded_line_status`: `success` / `warning` / `error` / `skipped`
- `hardcoded_line_finding_count`: Extract from `hardcoded_line_output` by matching the line `==> Total hardcoded line-number findings: N` (regex: `/Total hardcoded line-number findings: (\d+)/`). If no match found, default to 0
- `hardcoded_line_output`: Script output (truncated if >50 lines)

### 3.12 Plugin-specific Checks (Comment Journal Narration)

Execute the comment journal check to detect high-confidence narrative comment violations **and descriptive Issue/PR number references** in **`plugins/rite/**/*.{sh,md}`**, repo-root **`docs/**/*.md`**, and **`.rite/wiki/**/*.md`** (ドキュメント散文・Wiki ページまでスコープ拡張 — SoT [適用スコープ](../../skills/rite-workflow/references/comment-best-practices.md#適用スコープ) の永続成果物全般)。This is the fast-fail mechanical layer below the LLM reviewers — patterns that are 100%-mechanically detectable get killed here so the reviewer queue stays focused on WHY > WHAT semantic judgments. See the script header at `plugins/rite/hooks/scripts/comment-journal-check.sh` for the exact regex literals and whitelist rules.

Detected patterns:

- **P1** `verified-review cycle N` — leftover narration referring to a verified-review iteration
- **P2** `旧実装(は|では)` — comments explaining what the previous version did (belongs in commit/PR history)
- **P3** `PR #N cycle N fix` — comments tagging a fix to a specific PR review cycle
- **P4** `cycle N F-N で(導入|確立|集約)` — comments referencing review-finding identifiers
- **P5** descriptive Issue/PR ref `See / Refs / Related to / Closes / Fixes / Resolves #N` — Why の代替として貼られた説明的参照
- **P6** descriptive Issue/PR ref (ja) `#N で(別途)対応` / `詳細は #N` — 同上 (日本語)

Whitelist (line-level skip): `<!-- example:` / `# example:` / `// example:` markers, and **`TODO` / `FIXME` lines** (追跡番号は前方ポインタ=維持). ファイル名アンカー (`xxx.test.sh` 等) は `#N` を含まないため P5/P6 に該当せず自然に除外される。Self-exclude: the script itself, `comment-best-practices.md` SoT, and the parity test (禁止句を例示として保持するため)。

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/comment-journal-check.sh ]; then
  comment_journal_output=$(bash {plugin_root}/hooks/scripts/comment-journal-check.sh --all 2>&1)
  comment_journal_exit_code=$?
else
  comment_journal_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `comment_journal_status` | Action |
|-----------|--------------------------|--------|
| 0 | `success` | No journal narration — continue to Phase 4 |
| 1 | `warning` | Pattern detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Comment journal results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 / 3.8 / 3.9 / 3.10 / 3.11 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). The CI-only adoption keeps this warning-level so authors can clean up journal narration progressively; pre-commit integration is intentionally out of scope.

**Record comment journal check results** for Phase 4 reporting:
- `comment_journal_status`: `success` / `warning` / `error` / `skipped`
- `comment_journal_finding_count`: Extract from `comment_journal_output` by matching `==> Total comment-journal findings: N` (regex: `/Total comment-journal findings: (\d+)/`). If no match found, default to 0
- `comment_journal_output`: Script output (truncated if >50 lines)

### 3.13 Plugin-specific Checks (Comment Line-Number Reference)

Execute the comment line-number reference check to detect hardcoded `<file>.<ext>:<NN>` references inside shell comments under **`plugins/rite/**/*.sh`**. This complements the Phase 3.11 hardcoded line-number check (which targets prose in markdown) by closing the same drift gap inside shell-script comments. See the script header at `plugins/rite/hooks/scripts/comment-line-ref-check.sh` for the exact regex literal and exclusion rules.

Detected pattern (in shell comments only, with shebang excluded):

- `[A-Za-z][A-Za-z0-9_.-]*\.(sh|md|ts|py|js|tsx):[0-9]+`

Exclusions: shebang 「#!」, fenced code blocks, range form `:N-M`, backtick-quoted spans, whitelist markers (`# example:` / `<!-- example: -->` / `// example:`), self.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/comment-line-ref-check.sh ]; then
  comment_line_ref_output=$(bash {plugin_root}/hooks/scripts/comment-line-ref-check.sh --all 2>&1)
  comment_line_ref_exit_code=$?
else
  comment_line_ref_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `comment_line_ref_status` | Action |
|-----------|---------------------------|--------|
| 0 | `success` | No comment line-number references — continue to Phase 4 |
| 1 | `warning` | Reference detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Comment line-ref check results are treated as **warnings**, not errors — same policy as the rest of Phase 3.x. A finding does NOT change `[lint:success]`. Structural references (e.g., `lint.md Phase 3.11`) survive content insertions/deletions; raw `lint.md:742` references decay the moment a line is added above. The CI-only adoption keeps this warning-level so authors can migrate references progressively.

**Record comment line-ref check results** for Phase 4 reporting:
- `comment_line_ref_status`: `success` / `warning` / `error` / `skipped`
- `comment_line_ref_finding_count`: Extract from `comment_line_ref_output` by matching `==> Total comment-line-ref findings: N` (regex: `/Total comment-line-ref findings: (\d+)/`). If no match found, default to 0
- `comment_line_ref_output`: Script output (truncated if >50 lines)

### 3.14 Plugin-specific Checks (Direct gh issue create Invocation)

Execute the direct `gh issue create` invocation guard to detect Issue creation paths in `plugins/rite/skills/**/*.md` that bypass the `create-issue-with-projects.sh` helper. This complements the existing direct-invocation guard by extending its enforcement scope from the two original files (the retired `commands/issue/start.md` plus the now-deleted `commands/issue/parent-routing.md`) to every skill / sub-skill markdown file. The original incident showed that scope-creep follow-up Issue creation invoked at orchestration time — specifically the canonical Issue creation paths in `skills/review/SKILL.md` and `skills/fix/SKILL.md` — could regress to direct `gh issue create` shortcuts, leaving Issues unregistered in GitHub Projects. See the script header at `plugins/rite/scripts/check-no-direct-gh-issue-create.sh` for the exact detection pattern and false-positive avoidance rules (fenced code blocks, blockquotes, single-line and multi-line Markdown comments, inline backtick spans).

Detected pattern (after stripping fenced code blocks / blockquotes / Markdown comments / inline backticks):

- `gh issue create [-$"\047]` — literal `gh issue create ` followed by `-` (option flag), `$` (shell variable), `"` (double-quoted argument), or `'` (single-quoted argument)

Exclusions handled by the script: fenced code blocks (``` and ~~~), blockquote lines (`> ...`), Markdown comments (`<!-- ... -->` single-line and multi-line), inline backtick spans (`` `...` ``).

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/scripts/check-no-direct-gh-issue-create.sh ]; then
  direct_gh_issue_output=$(bash {plugin_root}/scripts/check-no-direct-gh-issue-create.sh --all 2>&1)
  direct_gh_issue_exit_code=$?
else
  direct_gh_issue_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `direct_gh_issue_status` | Action |
|-----------|--------------------------|--------|
| 0 | `success` | No direct invocations — continue to Phase 4 |
| 1 | `warning` | Direct invocation detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error (usage error / missing commands directory / empty `--all` expansion) — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Direct `gh issue create` invocation check results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 / 3.8 / 3.9 / 3.10 / 3.11 / 3.12 / 3.13 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Warning-level non-blocking behaviour lets the helper-script guideline be enforced progressively without gating CI; the structural enforcement (every command/sub-skill must call `create-issue-with-projects.sh`) is the long-term goal, and warning-level surfacing on each lint run is sufficient to redirect contributors to the helper before merge.

**Record direct gh issue create check results** for Phase 4 reporting:
- `direct_gh_issue_status`: `success` / `warning` / `error` / `skipped`
- `direct_gh_issue_finding_count`: Extract from `direct_gh_issue_output` by matching the line `Total files with violations: N` (regex: `/Total files with violations: (\d+)/`). If no match found, default to 0
- `direct_gh_issue_output`: Script output (truncated if >50 lines)

### 3.15 Plugin-specific Checks (Orphan Reference File Detection)

Execute the orphan reference lint guard to detect reference files (`plugins/rite/{references,skills,agents}/**/*.md`) that exist but have zero inbound references AND no test pin protection. The motivation comes from a real incident where `plugins/rite/commands/issue/references/projects-status-update-callsites.md` (146 lines) was found to be a complete orphan — no other file referenced it, no test pinned its content, and it survived multiple workflow refactorings undetected. This check catches the same class of orphan accumulation mechanically before it grows into a maintenance burden.

Detection logic (see `plugins/rite/hooks/scripts/orphan-reference-check.sh` for the exact algorithm):

- Inbound references searched in `plugins/rite/`, `docs/`, `.github/` (excluding self-references)
- Test pin searched in `plugins/rite/hooks/tests/` and `plugins/rite/scripts/tests/` (any `assert_grep` / `contains` containing the filename)
- Skip well-known static assets (`.gitkeep`, `__init__.py`, `LICENSE`, `CHANGELOG.md`)
- A file is flagged as **orphan** only when inbound count == 0 AND test pin count == 0

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/orphan-reference-check.sh ]; then
  orphan_check_output=$(bash {plugin_root}/hooks/scripts/orphan-reference-check.sh --all 2>&1)
  orphan_check_exit_code=$?
else
  orphan_check_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `orphan_check_status` | Action |
|-----------|------------------------|--------|
| 0 | `success` | No orphans — continue to Phase 4 |
| 1 | `warning` | Orphan(s) detected — record as **warning** (does NOT cause `[lint:error]`). Display orphan list but allow flow to continue |
| 2 | `error` | Invocation error (usage error / missing repo-root / empty `--all` expansion) — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Orphan reference check results are treated as **warnings**, not errors — same policy as Phase 3.5–3.14 checks. A finding does NOT change `[lint:success]`. Orphan files are not actively harmful (they don't break workflow execution), but their accumulation degrades plugin maintainability over time. Warning-level surfacing on each lint run is sufficient to redirect contributors to either remove the orphan or add an inbound reference / test pin before merge.

**Record orphan check results** for Phase 4 reporting:
- `orphan_check_status`: `success` / `warning` / `error` / `skipped`
- `orphan_check_finding_count`: Extract from `orphan_check_output` by matching the summary line `[orphan-reference-check] checked=N orphans=M` (regex: `/orphans=(\d+)/`). If no match found, default to 0
- `orphan_check_output`: Script output (truncated if >50 lines)

### 3.16 Plugin-specific Checks (Shell-prose Cross-file Step Reference)

Execute the shell-prose cross-file step reference check to detect `<file>.(md|sh) (ステップ|Phase) <number>` references inside echo strings and comments under **`plugins/rite/**/*.sh`** that are inconsistent with the referenced markdown file's actual headings. This complements the Phase 3.13 comment line-number check (which targets raw `<file>:<NN>` references) and the markdown-side anchor check in `distributed-fix-drift-check.sh` Pattern 4 (which only scans `.md` prose). A past review cycle surfaced `wiki-growth-check.sh` referencing a `close.md` step with the wrong keyword (`close.md` uses the `Phase` convention, but the prose said the in-scope `ステップ` convention) — a drift that escaped cycles 1-3 because they never scanned `.sh` prose. See the script header at `plugins/rite/hooks/scripts/sh-cross-ref-check.sh` for the heading-convention model and resolution rules.

Two independent checks per reference:

- **dangling number**: the referenced number is not present as a heading number in the target file
- **keyword mismatch**: the number exists, but the prose keyword (`ステップ` / `Phase`) conflicts with the target file's own convention (derived from its headings, not a hardcoded path map)

Exclusions: this script's own file (self), `plugins/rite/hooks/tests/` (fixtures), lines containing the `drift-check-ignore` marker, unresolvable file references (out of scope — tracked separately), and targets with no numbered step/phase headings.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/sh-cross-ref-check.sh ]; then
  sh_cross_ref_output=$(bash {plugin_root}/hooks/scripts/sh-cross-ref-check.sh --all 2>&1)
  sh_cross_ref_exit_code=$?
else
  sh_cross_ref_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `sh_cross_ref_status` | Action |
|-----------|------------------------|--------|
| 0 | `success` | No inconsistent references — continue to Phase 4 |
| 1 | `warning` | Inconsistency detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error (usage error / missing repo-root / empty `--all` expansion) — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Shell-prose cross-file step reference check results are treated as **warnings**, not errors — same policy as Phase 3.5–3.15 checks. A finding does NOT change `[lint:success]`. Pre-existing inconsistencies are surfaced for cleanup (tracked separately); intentional or historical references can be exempted with an inline `drift-check-ignore` marker.

**Record shell-prose cross-ref check results** for Phase 4 reporting:
- `sh_cross_ref_status`: `success` / `warning` / `error` / `skipped`
- `sh_cross_ref_finding_count`: Extract from `sh_cross_ref_output` by matching the summary line `==> Total sh-cross-ref findings: N` (regex: `/Total sh-cross-ref findings: (\d+)/`). If no match found, default to 0
- `sh_cross_ref_output`: Script output (truncated if >50 lines)

### 3.17 Plugin-specific Checks (Operational Bash Block Heaviness)

Execute the operational bash block heaviness check to detect "heavy" bash blocks in skill markdown under **`plugins/rite/skills/**/*.md`** that violate the "operational bash block heaviness convention" added to `skills/rite-workflow/references/coding-principles.md`. That convention's origin: large operational bash blocks (python inline / nested `$()` / multiple heredocs / long line counts) malformed Claude's tool-call parsing and silently ended the turn with no error. The convention was added as prose, but prose-only enforcement cannot stop new drift — this check surfaces it mechanically. See the script header at `plugins/rite/hooks/scripts/bash-heaviness-check.sh` for the heaviness model.

A block is flagged only when it exhibits **2 or more** of these signals (a single signal — e.g. a lone helper call passing one JSON heredoc, or one block writing a long template — is intentionally not flagged, keeping false positives low):

- **python-inline**: a line invokes python with inline code (`python3 -c ...` or a python heredoc)
- **nested-cmdsub**: a line nests command substitution, e.g. `$(cmd "$(inner)")`
- **multi-heredoc**: the block opens 2 or more heredocs
- **long-block**: the block body is >= 25 lines (the convention 目安)

Heredoc bodies are treated as data: the python-inline / nested-cmdsub signals are evaluated only on real shell lines, so a template heredoc containing `$(...)` or `python3 -c` example text does not produce a finding.

Exclusions: `plugins/rite/skills/**/tests/` fixtures, and any block containing the `drift-check-ignore` marker on one of its lines (exempts intentional / already-reviewed heavy blocks).

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/bash-heaviness-check.sh ]; then
  bash_heaviness_output=$(bash {plugin_root}/hooks/scripts/bash-heaviness-check.sh --all 2>&1)
  bash_heaviness_exit_code=$?
else
  bash_heaviness_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `bash_heaviness_status` | Action |
|-----------|-------------------------|--------|
| 0 | `success` | No heavy blocks — continue to Phase 4 |
| 1 | `warning` | Heavy block(s) detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error (usage error / missing repo-root / empty `--all` expansion) — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Operational bash block heaviness check results are treated as **warnings**, not errors — same policy as Phase 3.5–3.16 checks. A finding does NOT change `[lint:success]`. Pre-existing heavy blocks are surfaced for incremental cleanup (refactoring an existing heavy block to a helper call is separate work, out of scope for the block's owning change); intentional or already-reviewed heavy blocks can be exempted with an inline `drift-check-ignore` marker.

**Record bash heaviness check results** for Phase 4 reporting:
- `bash_heaviness_status`: `success` / `warning` / `error` / `skipped`
- `bash_heaviness_finding_count`: Extract from `bash_heaviness_output` by matching the summary line `==> Total bash-heaviness findings: N` (regex: `/Total bash-heaviness findings: (\d+)/`). If no match found, default to 0
- `bash_heaviness_output`: Script output (truncated if >50 lines)

### 3.18 Plugin-specific Checks (Projects Board "Done" Drift Detection)

Execute the projects board drift check to detect the "CLOSED+COMPLETED but board != Done" reconciliation gap. A `Done` transition is only wired into `/rite:cleanup` (ステップ8 → `skills/cleanup/references/archive-procedures.md` Phase 3.2) and `/rite:issue-close` (Shared: Projects Status → Done), but GitHub auto-closes an Issue the moment a PR carrying `Closes #N` merges. When `/rite:cleanup` is not run afterwards, the board freezes at its last value (In Review for a ready Issue, Todo for an untouched one) and no reconciler picks it back up. The check scans recently-updated CLOSED Issues whose `stateReason` is `COMPLETED` and reports those that are on the project board with Status != "Done". Closure reason `NOT_PLANNED` (wontfix / duplicate) is intentionally excluded, and Issues that are not on the board are not drift (no board Status to reconcile). See the script header at `plugins/rite/hooks/scripts/projects-board-drift-check.sh` for the detection and reconcile contract.

**Condition**: Always execute when the script exists.

**Skip condition**: Only the script's own absence (e.g., marketplace install without `hooks/scripts/` directory) makes lint.md skip the entire Phase 3.18. All other no-op cases (`github.projects.enabled: false` / `project_number` unset / `rite-config.yml` absent) are handled **inside** `projects-board-drift-check.sh`, which still returns exit 0 → `projects_board_drift_status=success` (with `findings: 0`). This satisfies the skip-when-Projects-disabled requirement without lint.md reading the config itself.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/projects-board-drift-check.sh ]; then
  projects_board_drift_output=$(bash {plugin_root}/hooks/scripts/projects-board-drift-check.sh --quiet 2>&1)
  projects_board_drift_exit_code=$?
else
  projects_board_drift_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `projects_board_drift_status` | Action |
|-----------|-------------------------------|--------|
| 0 | `success` | No drift, OR a legitimate no-op (projects disabled / `project_number` unset / `rite-config.yml` absent — script handled internally and returned 0 with `findings: 0`) — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). Enumerate the drifted Issues but allow flow to continue |
| 2 | `error` | Invocation error (bad args, gh/network failure, malformed API response) — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Projects board drift check results are treated as **warnings**, not errors — same policy as Phase 3.5–3.17 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). This check is **detect-and-enumerate only** — lint does NOT auto-reconcile. The `Done` transition stays the responsibility of `/rite:cleanup` / `/rite:issue-close`. On-demand reconciliation is available via `projects-board-drift-check.sh --reconcile`, which the appendix output points to.

**Record projects board drift results** for Phase 4 reporting:
- `projects_board_drift_status`: `success` / `warning` / `error` / `skipped`
- `projects_board_drift_finding_count`: Extract from `projects_board_drift_output` by matching the line `==> Total projects-board-drift findings: N` (regex: `/Total projects-board-drift findings: (\d+)/`). If no match found, default to 0
- `projects_board_drift_output`: Script output (truncated if >50 lines)

### 3.19 Plugin-specific Checks (Issue/PR Number Reference Detection)

Execute the number reference check to detect Issue/PR number references (`#NNN`, `Issue #NNN`, `PR #NNN`) that have crept back into the number-free documentation surface — `CHANGELOG.md`, `CHANGELOG.ja.md`, and this file (`plugins/rite/skills/lint/SKILL.md`). Project policy is to drop descriptive Issue/PR numbers and state the rationale directly as prose; release notes habitually re-add the merging PR (`(#NNNN)`) and command docs accrete `Issue #NNN` provenance over time, so a static check surfaces recurrence at lint time rather than at the next manual audit. The detected token is a 3-4 digit `#NNN` at a word boundary, which subsumes the `Issue #NNN` / `PR #NNN` prose forms. See the script header at `plugins/rite/hooks/scripts/number-reference-check.sh` for the grammar and scope contract.

Not matched (structural — no allowlist needed): functional code (`{issue_number}` placeholder, `issue-[0-9]+` branch-name extraction, `/issues/.../` API paths — none contain a literal `#NNN`) and markdown step/phase headings (`## 3.19`, where `#` is followed by `#` or a space, never a digit). 1-2 digit refs and 5+ digit tokens are outside the matched band.

Exclusions: this script's own file (self), `plugins/rite/hooks/tests/` (fixtures intentionally embed bad refs), and lines containing the `drift-check-ignore` marker.

**Scope (staged rollout)**: the `--all` surface is the number-free guarantee of this work — CHANGELOG (en/ja) and `lint.md`. The wider comment/doc cleanup is owned by sibling work; as those paths are cleaned, append them to `DEFAULT_TARGETS` in the script. **Operational rule**: do not reintroduce `#NNN` Issue/PR references into the scanned surface — cite the rationale in prose instead. CHANGELOG entries describe each change at the feature level and stand without the merging PR number.

**Condition**: Always execute when the script exists.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/number-reference-check.sh ]; then
  number_ref_output=$(bash {plugin_root}/hooks/scripts/number-reference-check.sh --all 2>&1)
  number_ref_exit_code=$?
else
  number_ref_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `number_ref_status` | Action |
|-----------|---------------------|--------|
| 0 | `success` | No number references — continue to Phase 4 |
| 1 | `warning` | Reference detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error (usage error / missing repo-root) — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Number reference check results are treated as **warnings**, not errors — same policy as Phase 3.5–3.18 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). The convention is enforced progressively, not by gating CI.

**Record number reference check results** for Phase 4 reporting:
- `number_ref_status`: `success` / `warning` / `error` / `skipped`
- `number_ref_finding_count`: Extract from `number_ref_output` by matching the line `==> Total number-ref findings: N` (regex: `/Total number-ref findings: (\d+)/`). If no match found, default to 0
- `number_ref_output`: Script output (truncated if >50 lines)

---

## Phase 4: Report Results

### 4.0 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting any result pattern (`[lint:success]`, `[lint:skipped]`, `[lint:error]`, `[lint:aborted]`), update flow state to reflect the post-lint phase (defense-in-depth). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when flow state file exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update by result**:

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[lint:success]` / `[lint:skipped]` | `lint` | `品質チェック完了` | `rite:lint completed successfully. Proceed to /rite:open ステップ 6 (PR 作成). Do NOT stop.` |
| `[lint:error]` | `lint` | `lint エラー検出` | `rite:lint found errors. Fix the errors and re-invoke rite:lint, or AskUserQuestion で 修正再実行 / 強制続行 / 中止 を選択. Do NOT stop.` |
| `[lint:aborted]` | `lint` | `品質チェック中断` | `rite:lint was aborted by user. Proceed to caller 完了レポート (orchestrator 経由なら caller へ復帰 / standalone なら開発者復帰 — abort 時は PR 作成スキップ). Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "{phase_value}" \
  --active true \
  --next "{next_action_value}" \
  --if-exists
```

Replace `{phase_value}` and `{next_action_value}` with the values from the table above based on the lint result.

**Note on `error_count`**: `flow-state.sh set` resets `error_count` to 0 by default on every phase transition, and preserves the existing value only when `--preserve-error-count` is passed. `error_count` is currently a reserved/legacy schema slot with no production reader; resetting on transition keeps the slot well-defined for future re-introduction without carrying stale counts.

**Also sync to local work memory** (`.rite-work-memory/issue-{n}.md`) when flow state file exists:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details and marketplace install notes.

```bash
WM_SOURCE="lint" \
  WM_PHASE="{phase_value}" \
  WM_PHASE_DETAIL="{phase_detail}" \
  WM_NEXT_ACTION="{next_action_value}" \
  WM_BODY_TEXT="Post-lint phase sync." \
  WM_REQUIRE_FLOW_STATE="true" \
  WM_READ_FROM_FLOW_STATE="true" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

Where `{phase_value}`, `{phase_detail}`, and `{next_action_value}` match the flow state update above. Claude substitutes these with the actual values based on the lint result before executing.

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

### 4.1 When No Issues Found

**Standalone execution:**
```
[lint:success]
品質チェック完了

問題は検出されませんでした

対象: {target_description}
コマンド: {lint_command}
```

**When called from `/rite:open` (E2E Output Minimization):**
```
[lint:success] — lint passed ({target_file_count} files)
```

**Drift check warning appendix** (both standalone and E2E): When `drift_status` is `warning`, append drift findings after the lint result output:

```
⚠️ Drift check: {drift_finding_count} findings detected (warning, non-blocking)
{drift_output}
```

**Bang-backtick warning appendix** (both standalone and E2E): When `bang_backtick_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Both statuses use the same appendix so that invocation failures (exit code 2) are never silently dropped. **Note**: Phase 3.5 drift check has the same observability gap (appendix fires only on `warning`, not `error`), but fixing drift check is **out of scope for this PR** — it is tracked as a follow-up item. Phase 3.7 (`Doc-heavy patterns drift check`, added in this PR) follows the same warning+error appendix policy as Phase 3.6, so only Phase 3.5 retains the legacy gap. The asymmetry here is intentional for this PR's narrow scope:

```
⚠️ Bang-backtick check: {bang_backtick_finding_count} findings detected ({bang_backtick_status}, non-blocking)
{bang_backtick_output}
```

**Doc-heavy patterns drift appendix** (both standalone and E2E): When `doc_heavy_drift_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Both statuses use the same appendix so that invocation failures (exit code 2) are never silently dropped — same policy as the bang-backtick appendix:

```
⚠️ Doc-heavy patterns drift check: {doc_heavy_drift_finding_count} findings detected ({doc_heavy_drift_status}, non-blocking)
{doc_heavy_drift_output}
```

**Reviewer registry drift appendix** (both standalone and E2E): When `reviewer_registry_drift_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as bang-backtick / doc-heavy:

```
⚠️ Reviewer registry drift check: {reviewer_registry_drift_finding_count} findings detected ({reviewer_registry_drift_status}, non-blocking)
{reviewer_registry_drift_output}
```

**Wiki growth check appendix** (both standalone and E2E): When `wiki_growth_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as bang-backtick / doc-heavy:

```
⚠️ Wiki growth check: {wiki_growth_finding_count} findings detected ({wiki_growth_status}, non-blocking)
{wiki_growth_output}
```

**Gitignore health check appendix** (both standalone and E2E): When `gitignore_health_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as bang-backtick / doc-heavy / wiki-growth. When status is `warning` (exit 1, drift detected), the appendix output includes the stderr WARNING describing the drift so the operator can triage it. When status is `error` (exit 2, invocation failure), the appendix contains the stderr ERROR diagnostic:

```
⚠️ Gitignore health check: {gitignore_health_finding_count} findings detected ({gitignore_health_status}, non-blocking)
{gitignore_health_output}
```

**Backlink format check appendix** (both standalone and E2E): When `backlink_format_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as bang-backtick / doc-heavy / wiki-growth / gitignore-health. When status is `warning` (exit 1, dialect violations detected), the appendix output includes each violation line (`[backlink-format][P1] file:NN: ...`) so reviewers can identify and fix the offending backlink format. When status is `error` (exit 2, invocation failure), the appendix contains the stderr diagnostic:

```
⚠️ Backlink format check: {backlink_format_finding_count} findings detected ({backlink_format_status}, non-blocking)
{backlink_format_output}
```

**Hardcoded line-number check appendix** (both standalone and E2E): When `hardcoded_line_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as the other Phase 3.x lint checks. When status is `warning` (exit 1, hardcoded reference detected), the appendix output includes each violation line (`[hardcoded-line-number][P-A|P-B|P-C] file:NN: ...`) so reviewers can identify and replace the hardcoded line number with a structural reference:

```
⚠️ Hardcoded line-number check: {hardcoded_line_finding_count} findings detected ({hardcoded_line_status}, non-blocking)
{hardcoded_line_output}
```

**Comment journal narration appendix** (both standalone and E2E): When `comment_journal_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as the rest of Phase 3.x. When status is `warning` (exit 1, journal narration detected), the appendix output includes each violation line (`[comment-journal][P1|P2|P3|P4] file:NN: ...`) so authors can move the narration into commit message / PR description / Wiki:

```
⚠️ Comment journal narration: {comment_journal_finding_count} findings detected ({comment_journal_status}, non-blocking)
{comment_journal_output}
```

**Comment line-ref check appendix** (both standalone and E2E): When `comment_line_ref_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as the rest of Phase 3.x. When status is `warning` (exit 1, comment line-number reference detected), the appendix output includes each violation line (`[comment-line-ref] file:NN: ...`) so authors can replace the raw `<file>.<ext>:<NN>` reference with a structural pointer:

```
⚠️ Comment line-ref check: {comment_line_ref_finding_count} findings detected ({comment_line_ref_status}, non-blocking)
{comment_line_ref_output}
```

**Direct gh issue create check appendix** (both standalone and E2E): When `direct_gh_issue_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as the rest of Phase 3.x. When status is `warning` (exit 1, direct invocation detected), the appendix output includes each violation line (`VIOLATION:` lines listing `file:line:content`) so contributors can switch to the `create-issue-with-projects.sh` helper:

```
⚠️ Direct gh issue create check: {direct_gh_issue_finding_count} findings detected ({direct_gh_issue_status}, non-blocking)
{direct_gh_issue_output}
```

**Orphan reference check appendix** (both standalone and E2E): When `orphan_check_status` is `warning` **or `error`**, append the orphan list (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as the rest of Phase 3.x. When status is `warning` (exit 1, orphan(s) detected), the appendix output includes each `ORPHAN:` line listing the orphan file path with `(inbound=0, test_pin=0)` annotation:

```
⚠️ Orphan reference check: {orphan_check_finding_count} findings detected ({orphan_check_status}, non-blocking)
{orphan_check_output}
```

**Shell-prose cross-ref check appendix** (both standalone and E2E): When `sh_cross_ref_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as Phase 3.5–3.15 checks. When status is `warning` (exit 1, inconsistency detected), the appendix output includes each finding line (`[sh-cross-ref] file:NN: dangling number ...` / `[sh-cross-ref] file:NN: keyword mismatch ...`) so reviewers can correct the reference or exempt an intentional/historical one with `drift-check-ignore`:

```
⚠️ Shell-prose cross-ref check: {sh_cross_ref_finding_count} findings detected ({sh_cross_ref_status}, non-blocking)
{sh_cross_ref_output}
```

**Operational bash block heaviness appendix** (both standalone and E2E): When `bash_heaviness_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as Phase 3.5–3.16 checks. When status is `warning` (exit 1, heavy block detected), the appendix output includes each finding line (`[bash-heaviness] file:NN: heavy operational bash block — N signals: ...`) so authors can refactor the heavy block to a helper call or exempt an intentional one with `drift-check-ignore`:

```
⚠️ Operational bash block heaviness check: {bash_heaviness_finding_count} findings detected ({bash_heaviness_status}, non-blocking)
{bash_heaviness_output}
```

**Projects board drift appendix** (both standalone and E2E): When `projects_board_drift_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as Phase 3.5–3.17 checks. When status is `warning` (exit 1, drift detected), the appendix output includes each `[projects-board-drift] #N "title" status="X" (expected Done)` line plus the `--reconcile` hint so the operator can reconcile the board (or run `/rite:cleanup` / `/rite:issue-close` on the Issue). When status is `error` (exit 2, invocation failure), the appendix contains the stderr diagnostic:

```
⚠️ Projects board drift check: {projects_board_drift_finding_count} findings detected ({projects_board_drift_status}, non-blocking)
{projects_board_drift_output}
```

**Number reference appendix** (both standalone and E2E): When `number_ref_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as Phase 3.5–3.18 checks. When status is `warning` (exit 1, reference detected), the appendix output includes each `[number-ref] file:NN: #NNN — Issue/PR number reference ...` line so the author can restate the rationale in prose or exempt an intentional one with `drift-check-ignore`:

```
⚠️ Number reference check: {number_ref_finding_count} findings detected ({number_ref_status}, non-blocking)
{number_ref_output}
```

These appendices do NOT change the result pattern — `[lint:success]` remains the pattern even with drift, bang-backtick, doc-heavy-patterns-drift, reviewer-registry-drift, wiki-growth, gitignore-health, backlink-format, hardcoded-line-number, comment-journal, comment-line-ref, direct-gh-issue-create, orphan-reference-check, sh-cross-ref, bash-heaviness, projects-board-drift, or number-reference warnings/invocation errors.

> **Context savings**: Omit target description, command details, and flow continuation text. The caller already knows the context.

> **CRITICAL**: When called from `/rite:open`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr-create` is made by `/rite:open` at ステップ 6 after the lint result is consumed at ステップ 5.1.

**Note**: `[lint:success]` is an output pattern used by `/rite:open` ステップ 5.1 to determine the lint result.

### 4.2 When Issues Found

**E2E flow (minimized output):**
```
[lint:error] — {error_count} errors, {warning_count} warnings
{first 10 lines of lint_output}
```

> **Context savings**: In e2e flow, omit fix suggestions (the caller returns to ステップ 4 implementation for fixes). Only include first 10 lines of lint output to identify the issue category.

**Standalone execution:**
```
[lint:error]
品質チェック完了

{error_count} 件のエラー、{warning_count} 件の警告が検出されました

{lint_output}

---

修正案:
```

**Note**: `[lint:error]` is an output pattern used by `/rite:open` ステップ 5.1 to determine the lint result.

**Presenting fix suggestions:**

Analyze the error content and present fix suggestions when possible:

1. **When auto-fix is available:**
   ```
   自動修正を実行しますか？

   コマンド: {fix_command}
   例:
       npm run lint -- --fix
       ruff check --fix
       cargo clippy --fix

   オプション:
   - はい、自動修正を実行
   - いいえ、手動で修正
   ```

2. **When manual fix is required:**
   Present specific fix suggestions for each error.

### 4.3 Summary Display

> **E2E flow**: Skip this phase entirely (context savings). The result pattern in 4.1/4.2 already contains sufficient information for the caller.

**Standalone execution only:**

```
品質チェック結果サマリー

| 項目 | 結果 |
|------|------|
| 対象 | {target} |
| エラー | {error_count} |
| 警告 | {warning_count} |
| テスト | {test_status} ({test_error_count} failures) |
| Drift チェック | {drift_status} ({drift_finding_count} findings) |
| Bang-backtick check | {bang_backtick_status} ({bang_backtick_finding_count} findings) |
| Doc-heavy patterns drift check | {doc_heavy_drift_status} ({doc_heavy_drift_finding_count} findings) |
| Reviewer registry drift check | {reviewer_registry_drift_status} ({reviewer_registry_drift_finding_count} findings) |
| Wiki growth check | {wiki_growth_status} ({wiki_growth_finding_count} findings) |
| Gitignore health check | {gitignore_health_status} ({gitignore_health_finding_count} findings) |
| Backlink format check | {backlink_format_status} ({backlink_format_finding_count} findings) |
| Hardcoded line-number check | {hardcoded_line_status} ({hardcoded_line_finding_count} findings) |
| Comment journal narration | {comment_journal_status} ({comment_journal_finding_count} findings) |
| Comment line-ref check | {comment_line_ref_status} ({comment_line_ref_finding_count} findings) |
| Direct gh issue create check | {direct_gh_issue_status} ({direct_gh_issue_finding_count} findings) |
| Orphan reference check | {orphan_check_status} ({orphan_check_finding_count} findings) |
| Shell-prose cross-ref check | {sh_cross_ref_status} ({sh_cross_ref_finding_count} findings) |
| Operational bash block heaviness check | {bash_heaviness_status} ({bash_heaviness_finding_count} findings) |
| Projects board drift check | {projects_board_drift_status} ({projects_board_drift_finding_count} findings) |
| Number reference check | {number_ref_status} ({number_ref_finding_count} findings) |
| 所要時間 | {duration} |

次のステップ:
1. エラーを修正
2. 再度 `/rite:lint` を実行
3. 問題がなければ `/rite:pr-create` で PR 作成

> **注**: `/rite:open` の一気通貫フローから呼び出された場合、この「次のステップ」案内は**スキップ**されます。呼び出し元が出力パターン（`[lint:success]` 等）を検出し、自動的に次のアクション（PR 作成）に進みます。**この案内は単独実行時のみ参照してください**。
```

**Note**: The `テスト` row is only shown when `commands.test` is configured. When tests were skipped, omit the row entirely. The `Drift チェック` row is only shown when the drift check script exists and was executed. When `drift_status` is `skipped`, omit the row. The `Bang-backtick check` row follows the same rule: omit when `bang_backtick_status` is `skipped`. When `bang_backtick_status` is `error` (exit code 2 invocation error), display the row with the `error` status so the failure is surfaced rather than silently dropped. The `Doc-heavy patterns drift check` row follows the same policy as `Bang-backtick check`: omit when `doc_heavy_drift_status` is `skipped`, and display with the `error` status when exit code 2 surfaces an invocation failure. The `Reviewer registry drift check` row follows the same policy: omit when `reviewer_registry_drift_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = registry in sync; `warning` = agents/ と reviewers/SKILL.md 2 表の間で drift 検出; `error` = invocation failure). The `Wiki growth check` row follows the same policy: omit when `wiki_growth_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` is the healthy state showing 0 findings; `warning` indicates threshold exceeded; `error` indicates exit code 2 invocation failure). The `Gitignore health check` row follows the same policy: omit when `gitignore_health_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = healthy rule / legitimate no-op; `warning` = drift detected; `error` = invocation failure). The `Backlink format check` row follows the same policy: omit when `backlink_format_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no dialect violations; `warning` = legacy dialect detected; `error` = invocation failure). The `Hardcoded line-number check` row follows the same policy: omit when `hardcoded_line_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no hardcoded references; `warning` = P-A/P-B/P-C reference detected; `error` = invocation failure). **Asymmetry note**: The `Drift チェック` row does NOT have an equivalent `error`-status display rule because Phase 3.5 drift check's observability gap is out of scope for this PR (tracked as a follow-up). This asymmetry is intentional and temporary — both rows should converge when drift check receives the same fix in a follow-up PR. The `Comment journal narration` row follows the same policy: omit when `comment_journal_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no journal narration; `warning` = P1/P2/P3/P4 pattern detected; `error` = invocation failure). The `Comment line-ref check` row follows the same policy: omit when `comment_line_ref_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no comment line-number references; `warning` = `<file>.<ext>:<NN>` pattern detected in shell comments; `error` = invocation failure). The `Direct gh issue create check` row follows the same policy: omit when `direct_gh_issue_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no direct invocations; `warning` = direct `gh issue create` invocation detected; `error` = invocation failure / usage error / missing commands directory). The `Orphan reference check` row follows the same policy: omit when `orphan_check_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no orphans; `warning` = orphan file(s) detected; `error` = invocation failure / usage error / missing repo-root / empty --all expansion). The `Shell-prose cross-ref check` row follows the same policy: omit when `sh_cross_ref_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no inconsistent references; `warning` = dangling number / keyword mismatch detected; `error` = invocation failure / usage error / missing repo-root / empty --all expansion). The `Operational bash block heaviness check` row follows the same policy: omit when `bash_heaviness_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no heavy blocks; `warning` = block with >= 2 heaviness signals detected; `error` = invocation failure / usage error / missing repo-root / empty --all expansion). The `Projects board drift check` row follows the same policy: omit when `projects_board_drift_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no drift / legitimate no-op when Projects is disabled; `warning` = CLOSED+COMPLETED Issue(s) on the board with Status != Done; `error` = invocation failure / gh / network / malformed API response). The `Number reference check` row follows the same policy: omit when `number_ref_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` = no Issue/PR number references; `warning` = `#NNN` reference detected on the number-free surface; `error` = invocation failure / usage error / missing repo-root). All Phase 3.x lint checks added after Phase 3.5 (3.7 `Doc-heavy patterns drift check`, 3.7.1 `Reviewer registry drift check`, 3.8 `Wiki growth check`, 3.9 `Gitignore health check`, 3.10 `Backlink format check`, 3.11 `Hardcoded line-number check`, 3.12 `Comment journal narration`, 3.13 `Comment line-ref check`, 3.14 `Direct gh issue create check`, 3.15 `Orphan reference check`, 3.16 `Shell-prose cross-ref check`, 3.17 `Operational bash block heaviness check`, 3.18 `Projects board drift check`, 3.19 `Number reference check`) were added with the fixed appendix + summary-row pattern from the start, so they match Phase 3.6 rather than Phase 3.5.

### 4.4 Automatic Work Memory Update (Conditional)

> **WARNING**: Work memory is published as Issue comments. In public repositories, it is visible to third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

Record the quality check results in work memory.

**Execution condition**: Automatically executed only when on a work branch linked to an Issue (branch containing the `issue-{number}` pattern). Not executed on main/master branches or branches that do not contain an Issue number.

#### 4.4.1 Identify Related Issue

Extract the Issue number from the branch name:

```bash
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

If no Issue number is found, skip the work memory update.

#### 4.4.2 Retrieve and Update Work Memory Comment

Write the lint result content (from 4.4.3 template) to a temp file, then append to the work memory comment:

```bash
lint_result_tmp=$(mktemp)
trap 'rm -f "$lint_result_tmp"' EXIT
cat > "$lint_result_tmp" << 'LINT_EOF'
{lint_result_content}
LINT_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "品質チェック履歴" --content-file "$lint_result_tmp" \
  2>/dev/null || true

rm -f "$lint_result_tmp"
```

**Note for Claude**: `{lint_result_content}` を 4.4.3 のテンプレートから生成した実際の追記内容で置換すること。

#### 4.4.3 Update Content

Automatically append the following to work memory:

```markdown
### 品質チェック履歴

#### {timestamp}: /rite:lint 実行
- **結果**: {status}（問題なし / エラーあり）
- **エラー**: {error_count}件
- **警告**: {warning_count}件
- **対象**: {target}
```

**Notes**:
- If the work memory comment is not found, skip the update
- If on the main/master branch, skip the update
- This update is performed automatically and does not require user confirmation

#### 4.4.4 Record "Next Steps"

After the quality check is complete, record "next steps" in work memory.

**Content to append (on lint success):**

```markdown
### 次のステップ
- **コマンド**: /rite:pr-create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
```

**Content to append (on lint skip):**

```markdown
### 次のステップ
- **コマンド**: /rite:pr-create
- **状態**: 待機中
- **備考**: lint スキップ（コマンド未検出）、PR 作成準備完了
```

**Content to append (on lint error):**

```markdown
### 次のステップ
- **コマンド**: /rite:lint
- **状態**: 待機中
- **備考**: lint エラー修正後、再度 lint を実行
```

**Notes**:
- If an existing `### 次のステップ` section exists, replace its content
- If the section does not exist, append to the end of work memory

**Specific replacement procedure:**

1. Retrieve the existing work memory body
2. Detect from `### 次のステップ` to the next `###` or EOF
3. Replace that section with the new "next steps" section
4. If the section is not found, append to the end of the body

```bash
# lint 結果に応じて次のステップの内容を選択し、一時ファイルに書き出す
next_steps_tmp=$(mktemp)
trap 'rm -f "$next_steps_tmp"' EXIT

# 例（lint success の場合）:
cat > "$next_steps_tmp" << 'NEXT_EOF'
- **コマンド**: /rite:pr-create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
NEXT_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform replace-section \
  --section "次のステップ" --content-file "$next_steps_tmp" \
  2>/dev/null || true

rm -f "$next_steps_tmp"
```

**Note for Claude**: lint 結果（success/skip/error）に応じて上記 3 ケースのいずれかを `NEXT_EOF` ヒアドキュメントに記述すること。

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

失敗パス (lint command 未検出で user skip / tool not found / work memory append 失敗) は plain `WARNING` を stderr に出力する。

| Error | Recovery |
|-------|----------|
| When the lint command fails | See error output for details |
| When the tool is not found | See [common patterns](../../references/common-error-handling.md) (WARNING を stderr に出力) |

## Language-Specific Details

### Node.js (package.json)

```bash
# scripts.lint を確認
npm run lint

# 自動修正（対応している場合）
npm run lint -- --fix
```

**Common lint tools:**
- ESLint: `eslint {files}`
- Prettier: `prettier --check {files}`
- Biome: `biome check {files}`

### Python (pyproject.toml)

```bash
# ruff を使用
ruff check {files}

# 自動修正
ruff check --fix {files}
```

**Other tools:**
- flake8: `flake8 {files}`
- mypy: `mypy {files}`
- black: `black --check {files}`

### Rust (Cargo.toml)

```bash
# clippy を使用
cargo clippy -- -D warnings

# フォーマットチェック
cargo fmt --check
```

### Go (go.mod)

```bash
# golangci-lint を使用
golangci-lint run {files}

# または go vet
go vet {files}
```
## Phase 5: End-to-End Flow Continuation (Automatic)

> **This phase is only executed within the end-to-end flow. Skipped during standalone execution.**

### 5.1 Flow Continuation Decision

Continue the end-to-end flow based on the output pattern from Phase 4.

| Output Pattern | Action in End-to-End Flow |
|-------------|---------------------------|
| `[lint:success]` | `/rite:lint` execution completes, and the caller `/rite:open` consumes the sentinel at ステップ 5.1 then proceeds to ステップ 6 (PR creation) |
| `[lint:skipped]` | `/rite:lint` execution completes, and the caller `/rite:open` consumes the sentinel at ステップ 5.1 then proceeds to ステップ 6 (PR creation) |
| `[lint:error]` | After fixing errors, run lint again (return to Phase 3) |
| `[lint:aborted]` | Flow ends (execution of `/rite:open` also ends) |

**Note**: During standalone execution (when the user directly executes `/rite:lint`), the ステップ 5.1 sentinel consumption and ステップ 6 PR creation are **not executed**. Lint sentinel consumption and PR creation are features only executed within the `/rite:open` end-to-end flow; standalone lint execution ends without flow continuation.

### 5.2 Processing After `/rite:lint` Completion

When `[lint:success]` or `[lint:skipped]` is output:

**`/rite:lint` execution completes**, and Claude returns to `/rite:open` ステップ 5.1 to consume the lint sentinel, then proceeds to ステップ 6 to call `rite:pr-create`.

**Important**:
- `/rite:lint` does **NOT directly call** `rite:pr-create`
- The caller `/rite:open` consumes the lint sentinel at ステップ 5.1 and proceeds to ステップ 6 (PR creation)
- After all checklist items are complete, `/rite:open` calls `rite:pr-create`

**Design intent**:
- Guard function to prevent proceeding to PR creation until all Issue checklist items are complete
- If there are incomplete items, return to ステップ 4 (implementation) to continue implementation

### 5.3 Standalone Execution Behavior

During standalone execution, Phase 5 is not executed; display the "next steps" guidance from Phase 4 and terminate.
