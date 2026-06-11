# Configuration Reference

This document describes all configuration options for Claude Code Rite Workflow.

> 🇯🇵 日本語版: [CONFIGURATION.ja.md](./CONFIGURATION.ja.md)

## Configuration File

The configuration file should be named `rite-config.yml` and placed in:
- Project root (`./rite-config.yml`)
- Or `.claude/` directory (`./.claude/rite-config.yml`)

## Full Configuration Example

```yaml
# Claude Code Rite Workflow configuration file
schema_version: 2

# DEPRECATED: project.type preset feature was removed entirely.
# The `generic` / `webapp` / `library` / `cli` / `documentation` presets and
# `templates/project-types/*.yml` were dropped in #1118. Project-specific
# configuration is now expressed via the per-key YAML structure directly
# (e.g. configure `branch.pattern`, `commands.*`, `iteration.*` individually).
# Remove `project:` from rite-config.yml — the key has no effect.
# project:
#   type: webapp

# GitHub Projects integration
github:
  projects:
    enabled: true
    project_number: null  # Project number (null = auto-detect from repository)
    owner: null           # Project owner (null = use repository owner)
    fields:
      status:
        enabled: true
        options:
          - { name: "Todo", default: true }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
      priority:
        enabled: true
        options:
          - { name: "High" }
          - { name: "Medium", default: true }
          - { name: "Low" }
      complexity:
        enabled: true
        options:
          - { name: "XS" }
          - { name: "S" }
          - { name: "M", default: true }
          - { name: "L" }
          - { name: "XL" }
      # Custom fields (project-specific)
      # Any Single Select field from your GitHub Projects can be added here
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
          - { name: "Chore" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }
    # Explicit field IDs (optional, overrides auto-detection)
    # field_ids:
    #   status: "PVTSSF_..."      # Status field ID
    #   priority: "PVTSSF_..."    # Priority field ID
    #   complexity: "PVTSSF_..."  # Complexity field ID
    #   # Custom fields
    #   work_type: "PVTSSF_..."   # Custom Single Select field ID

# Branch naming rules
branch:
  base: "main"       # Base branch for feature branches (use "develop" for Git Flow)
  pattern: "{type}/issue-{number}-{slug}"

# Commit message
commit:
  contextual: true    # Contextual Commits action lines in commit body

# Build/test/lint commands
commands:
  build: null  # Auto-detect
  test: null   # Auto-detect
  lint: null   # Auto-detect

# Issue settings
issue:
  auto_decompose_threshold: M  # XS | S | M | L | XL | none (default: M)

# Review settings
review:
  min_reviewers: 1      # Fallback when no reviewers match
  criteria:
    - file_types
    - content_analysis
  loop:
    verification_mode: false    # Enable verification mode as supplement to full review (default: false)
    allow_new_findings_in_unchanged_code: false  # Block new findings in unchanged code (default: false)
    # Review-fix loop termination (post-#1136)
    # Cycle-count-based degradation (v0.4.0 #557 introduced 4 quality signals as the abnormal-exit
    # mechanism) was retired in #1136 along with the entire quality-signal escalation. The current
    # loop terminates only on (a) 0 findings remaining → [review:mergeable] (normal exit), or
    # (b) manual abort via Ctrl+C → /rite:resume (or fix.md AskUserQuestion "中止" → [fix:cancelled-by-user]).
    # The keys below remain as config scaffolding for historical compatibility but have no
    # runtime effect on loop termination — see commands/pr/iterate.md ループ仕様 and
    # commands/pr/references/fix-relaxation-rules.md "Loop Termination" for the live spec.
    convergence_monitoring: true          # (scaffolding only post-#1136 — see comment above)
    auto_propagation_scan: true           # Run similar-pattern propagation scan after fix (default: true)
    pre_commit_drift_check: true          # Run distributed-fix-drift-check before commit (default: true)
  doc_heavy:
    enabled: true                   # Enable Doc-Heavy PR detection and override (default: true)
    lines_ratio_threshold: 0.6      # doc_lines / total_diff_lines threshold (default: 0.6)
    count_ratio_threshold: 0.7      # doc_files / total_files threshold (default: 0.7)
    max_diff_lines_for_count: 2000  # Max diff lines where count ratio is used (default: 2000)
  security_reviewer:
    mandatory: false                          # Require security reviewer for all PRs (default: false)
    recommended_for_code_changes: true        # Recommend for executable code changes (default: true)
  debate:
    enabled: true            # Enable inter-reviewer debate phase (default: true)
    max_rounds: 1            # Maximum debate rounds for cost control (default: 1)
  confidence_threshold: 80   # Minimum confidence score for findings table (default: 80)
  fact_check:
    enabled: true                      # Enable fact-check phase for review findings (default: true)
    max_claims: 20                     # Maximum number of External claims to verify per review (default: 20). Internal Likelihood claims are Grep-based and counted outside this cap
    use_context7: true                 # Use context7 MCP tool for verification (default: true). Auto-falls back to WebSearch when context7 is unavailable
    verify_internal_likelihood: true   # Enable Sub-Phase B (Internal Likelihood Claim Verification) via Grep (default: true)
  # DEPRECATED: observed_likelihood_gate keys are ignored.
  # These keys were scaffolding that never got wired to conditional runtime logic.
  # The Observed Likelihood Gate behavior is hardcoded in `_reviewer-base.md` /
  # `fix.md` prose and cannot currently be disabled via config. Remove these keys
  # from rite-config.yml — they no longer have any effect.
  # observed_likelihood_gate:
  #   enabled: true
  #   security_exception: true
  #   hypothetical_exception_reviewers:
  #     - security
  #     - database
  #     - devops
  #     - dependencies
  #   minimum: "demonstrable"
  # DEPRECATED: fail_fast_first keys are ignored.
  # These keys were scaffolding that never got wired to conditional runtime logic.
  # The Fail-Fast First principle is hardcoded in `_reviewer-base.md` / `fix.md` prose
  # and cannot currently be disabled via config. Remove these keys from rite-config.yml
  # — they no longer have any effect.
  # fail_fast_first:
  #   enabled: true
  #   allow_skill_exceptions: true
  #   wiki_query_required: true
  # DEPRECATED: separate_issue_creation keys are ignored.
  # The "Automatic Separate Issue Creation" mechanism (fix.md Phase 4.3) and the
  # [fix:issues-created:N] sentinel were removed entirely. Reviewers' recommendations
  # are handled in-loop only (fix code / accept / reply); no automatic Issue creation
  # happens from review output. Remove these keys from rite-config.yml — they no
  # longer have any effect. The report_pre_existing_issues knob is kept only as a
  # historical reference and is similarly ignored.
  # separate_issue_creation:
  #   require_user_confirmation: true
  #   report_pre_existing_issues: false

# Fix settings
fix:
  fail_fast_response: true             # Enable Fail-Fast Response Principle in fix.md Phase 2 (default: true)
  # DEPRECATED: fix.severity_gating keys are ignored.
  # The severity_gating convergence strategy was removed entirely in #1118.
  # The review-fix loop now has no automatic non-convergence handling — it simply
  # continues until 0 findings remain (normal exit) or the user aborts via Ctrl+C
  # (manual exit, resume with /rite:resume). See commands/pr/iterate.md (loop spec)
  # and commands/pr/references/fix-relaxation-rules.md ("Loop Termination" section)
  # for exit conditions. Both the severity_gating strategy and the previous
  # Phase 4.3.3 AskUserQuestion (retry / separate issue / withdraw) mechanism were
  # removed in #1118 / #1136 — neither cycle counter, N-retry cap, nor
  # quality-signal escalation exists in the current loop.
  # Remove these keys from rite-config.yml — they no longer have any effect.
  # severity_gating:
  #   enabled: false

# Iteration/Sprint settings (optional)
iteration:
  enabled: false          # true to enable iteration features (default: false)
  field_name: "Sprint"    # Name of the iteration field in Projects (default: "Sprint")
  auto_assign: true       # Auto-assign to current iteration on /rite:pr:open (default: true)
  show_in_list: true      # Show iteration column in issue:list (default: true)

# Verification gate settings
verification:
  run_tests_before_pr: true          # Run tests before commit/PR (requires commands.test) (default: true)
  acceptance_criteria_check: true    # Check acceptance criteria from Issue body before PR (default: true)

# TDD Light mode settings
tdd:
  mode: "off"              # off | light (default: off)
  tag_prefix: "AC"         # Tag prefix for test skeleton markers (default: "AC")
  run_baseline: true       # Run baseline test before skeleton generation (default: true)
  max_skeletons: 20        # Maximum number of skeletons to generate per Issue (default: 20)

# Parallel implementation settings
parallel:
  enabled: true          # Enable parallel implementation (default: true)
  max_agents: 3          # Maximum concurrent agents (default: 3)
  mode: "shared"         # "shared" (default) or "worktree"
  worktree_base: ".worktrees"  # Base directory for worktrees when mode is "worktree" (default: ".worktrees")

# Team-based sprint execution settings
team:
  enabled: true              # Enable /rite:sprint:team-execute (default: true)
  max_concurrent_issues: 3   # Max Issues to process in parallel per batch (default: 3)
  teammate_model: "sonnet"   # Model for teammate agents (default: "sonnet")
  auto_review: true          # Auto-run /rite:pr:review after all PRs created (default: true)

# PR review result recording
# The `review:` section above configures PR review **execution** (reviewer selection, debate,
# fact_check, etc.), while this `pr_review:` section configures PR review **output** (post_comment).
# By default, review results are saved to timestamped local files
# (`.rite/review-results/{pr_number}-{timestamp}.json`) instead of being posted to PR comments.
# `/rite:pr:fix` auto-reads results in the priority order: conversation > local file > PR comment.
pr_review:
  post_comment: false   # true to enable PR comment recording (equivalent to --post-comment, default: false)

# Safety settings (fail-closed thresholds)
safety:
  max_implementation_rounds: 20    # implementation round hard limit per Issue (default: 20)
  # max_review_fix_loops was removed in v0.4.0; the 4-signal escalation that replaced it
  # was itself retired in #1136. Loop now exits only on 0 findings or manual Ctrl+C / /rite:resume.
  time_budget_minutes: 120         # time budget per Issue in minutes (advisory) (default: 120)
  auto_stop_on_repeated_failure: true   # stop when same failure class repeats (default: true)
  repeated_failure_threshold: 3         # consecutive same-class failure count to trigger stop (default: 3)

# Experience Wiki (opt-out, see wiki section below for full description)
wiki:
  enabled: true                        # Enable Wiki features (default: true, opt-out)
  branch_strategy: "separate_branch"   # "separate_branch" (recommended) or "same_branch"
  branch_name: "wiki"                  # Branch name for Wiki data (when branch_strategy is "separate_branch")
  auto_ingest: true                    # Auto-ingest on review/fix/close (default: true)
  auto_query: true                     # Auto-query on start/review/fix/implement (default: true)
  auto_lint: true                      # Auto-run /rite:wiki:lint --auto after ingest (default: true)

# Metrics settings
metrics:
  enabled: true            # Enable/disable metrics recording (default: true)
  baseline_issues: 3       # Number of Issues for baseline collection (default: 3)

# Language setting
language: auto  # auto | ja | en
```

## Configuration Sections

### ~~project~~ (DEPRECATED in #1118)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| ~~`project.type`~~ | — | — | **DEPRECATED**: removed entirely. The `generic` / `webapp` / `library` / `cli` / `documentation` presets and `templates/project-types/*.yml` were dropped in #1118. Project-specific configuration is now expressed via the per-key YAML structure directly (`branch.pattern`, `commands.*`, `iteration.*` etc.). Remove `project:` from `rite-config.yml` — the key has no effect |

### github.projects

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable GitHub Projects integration |
| `project_number` | integer | `null` | Project number (auto-detected from repository if null) |
| `owner` | string | `null` | Project owner - user or organization (uses repository owner if null) |
| `fields` | object | - | Custom field definitions |
| `field_ids` | object | - | Explicit field IDs (optional, overrides auto-detection) |

### github.projects.field_ids

When specified, these field IDs are used directly instead of auto-detecting via `gh project field-list`. This is useful when:
- API auto-detection is failing (e.g., permission issues, organization policy restrictions)
- You want consistent field IDs without relying on auto-detection

**Note:** Option IDs (e.g., "In Progress", "Done") are always fetched via API regardless of this setting.

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Field ID for Status field (e.g., `PVTSSF_...`) |
| `priority` | string | Field ID for Priority field |
| `complexity` | string | Field ID for Complexity field |
| *(any custom field)* | string | Field ID for custom Single Select fields (e.g., `work_type`, `category`) |

**Example:**

```yaml
github:
  projects:
    field_ids:
      status: "PVTSSF_your-status-field-id"      # Replace with your actual ID
      priority: "PVTSSF_your-priority-field-id"  # Replace with your actual ID
      # Custom fields
      category: "PVTSSF_your-category-field-id"  # Replace with your actual ID
```

**Behavior:**
- If a field ID is specified in `field_ids`, it is used directly (no API call to detect this field ID)
- If not specified, the field ID is auto-detected via `gh project field-list`
- Partial specification is supported: if only `status` is specified, `priority` and `complexity` will be auto-detected (if enabled in `fields`)

**Finding field IDs:**

Run the following command (replace `1` with your project number and `myorg` with your owner):

```bash
gh project field-list 1 --owner myorg --format json
```

Look for the `id` field in the output for each field.

### github.projects.fields

Each field can have:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Enable this field |
| `options` | array | List of options with `name` and optional `default: true` |

**Standard fields:**

These fields are commonly used in GitHub Projects and have built-in support:

| Field | Description |
|-------|-------------|
| `status` | Issue/PR status tracking (Todo, In Progress, etc.) |
| `priority` | Priority level (High, Medium, Low) |
| `complexity` | Estimated complexity (XS, S, M, L, XL) |

**Custom fields:**

You can add any project-specific Single Select fields by using the same field name as defined in your GitHub Projects. Common examples include `work_type`, `category`, `team`, etc.

```yaml
github:
  projects:
    fields:
      # Standard fields
      status: { enabled: true, options: [...] }
      priority: { enabled: true, options: [...] }

      # Custom fields (project-specific)
      # Field names must match your GitHub Projects field names (case-insensitive)
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }
```

**Requirements for custom fields:**
- The field name in `rite-config.yml` must match the field name in GitHub Projects (case-insensitive)
- The field must be a Single Select type in GitHub Projects
- Options should match the available options in GitHub Projects

### branch

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `base` | string | `main` | Base branch for feature branches (PR target). Use `develop` for Git Flow. |
| `pattern` | string | `{type}/issue-{number}-{slug}` | Branch name pattern |

**Git Flow Support:**

For Git Flow workflows, configure:

```yaml
branch:
  base: "develop"    # Feature branches are created from develop
```

This affects the following commands:
- `/rite:pr:open`: Creates the feature branch from `branch.base`
- `/rite:pr:create`: Sets `branch.base` as the PR target
- `/rite:pr:cleanup`: Switches back to `branch.base` after cleanup
- `/rite:lint`: Uses `origin/{branch.base}...HEAD` for diff detection (e.g., `origin/develop...HEAD`)

**Recognized Patterns (Non-standard branches):**

For migration projects or other scenarios where branches don't follow the standard `{type}/issue-{number}-{slug}` pattern, you can define additional patterns to recognize:

```yaml
branch:
  recognized_patterns:
    - "migration/phase{n}-{category}"
    - "i18n/{locale}"
    - "hotfix/{date}-{description}"
```

**Pattern variables for `recognized_patterns`:**

These variables are used exclusively in `recognized_patterns` to match existing non-standard branches:

| Variable | Description | Example Match |
|----------|-------------|---------------|
| `{n}` | Any number | `1`, `42`, `100` |
| `{category}` | Any string (alphanumeric + hyphen) | `admin-tutorials`, `api-docs` |
| `{locale}` | Locale code | `ja`, `zh-tw`, `en-us` |
| `{date}` | Date string (any format) | `20250109`, `2025-01-09` |
| `{description}` | Any descriptive string | `fix-login`, `update-deps` |
| `{*}` | Wildcard (any characters) | anything |

**Use cases:**

- Migration projects: `migration/phase4-admin-tutorials`
- Internationalization: `i18n/zh-tw`
- Hotfixes without Issues: `hotfix/20250109-critical-fix`

When `/rite:pr:open` detects an existing branch matching these patterns (Step 2.2 existing branch check), it will offer to use the branch even though it doesn't contain an Issue number.

**Pattern variables for `branch.pattern`:**

These variables are used in `branch.pattern` to generate new branch names:

| Variable | Description | Example |
|----------|-------------|---------|
| `{type}` | Work type prefix | `feat`, `fix`, `docs` |
| `{number}` | Issue number | `123` |
| `{slug}` | Slugified Issue title | `add-auth-feature` |
| `{date}` | Current date (YYYYMMDD) | `20250103` |
| `{user}` | GitHub username | `octocat` |

### commit

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `contextual` | boolean | `true` | Include Contextual Commits action lines in commit body |

### commands

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `build` | string | `null` | Build command (auto-detected if null) |
| `test` | string | `null` | Test command (auto-detected if null) |
| `lint` | string | `null` | Lint command (auto-detected if null) |

### issue

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `auto_decompose_threshold` | string | `M` | Complexity threshold for auto-skipping decomposition prompt |

**auto_decompose_threshold values:**

| Value | Behavior |
|-------|----------|
| `XS` | Analyze body at XS; show proposal for S and above |
| `S` | Skip XS; analyze body at S; show proposal for M and above |
| `M` | Skip XS/S; analyze body at M; show proposal for L and above (default) |
| `L` | Skip XS-M; analyze body at L; show proposal for XL |
| `XL` | Skip XS-L; analyze body at XL only (no proposal, as XL is maximum) |
| `none` | Always show decomposition prompt (legacy behavior) |

**Three-tier judgment logic:**

| Condition | Behavior |
|-----------|----------|
| Complexity < threshold | Skip decomposition (proceed directly to work) |
| Complexity == threshold | Analyze Issue body to estimate scope, then decide |
| Complexity > threshold | Show decomposition proposal |

When an Issue's complexity is below the threshold, `/rite:issue:create` skips the decomposition proposal and the Issue is created as-is; `/rite:pr:open` then begins work without an intermediate confirmation. When the complexity equals the threshold, the Issue body is analyzed to estimate the scope of changes (number of files mentioned). This reduces unnecessary prompts for simple Issues while still prompting for complex ones.

**Body analysis criteria:** When complexity equals the threshold, the Issue body is analyzed. If 1-2 files are mentioned, decomposition is skipped. If 3+ files are mentioned, decomposition proposal is shown.

**Example:**

```yaml
issue:
  auto_decompose_threshold: S  # Skip for XS, analyze body at S, prompt for M and above
```

### review

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `min_reviewers` | integer | `1` | Minimum number of reviewers (fallback when no reviewers match) |
| `criteria` | array | `[file_types, content_analysis]` | Review criteria |
| `loop.verification_mode` | boolean | `false` | Enable verification mode as supplement to full review. When enabled, reviews after the first cycle perform both full review and verification of previous fixes with incremental diff regression checks |
| `loop.allow_new_findings_in_unchanged_code` | boolean | `false` | Whether new findings in unchanged code should be blocking. When `false`, new MEDIUM/LOW findings in unchanged code are reported as "stability concerns" (non-blocking) |
| `loop.convergence_monitoring` | boolean | `true` | **Scaffolding only post-#1136** — the original fingerprint-based cycling detection (#557 Quality Signal 1) escalated via `AskUserQuestion`, but the entire quality-signal escalation mechanism was retired in #1136. The current review-fix loop only exits on 0 findings (normal) or manual abort (Ctrl+C → `/rite:resume`). Setting this key has no runtime effect — see `commands/pr/iterate.md` for the live spec |
| `loop.auto_propagation_scan` | boolean | `true` | After a fix is applied, automatically scan for similar patterns elsewhere in the codebase to catch propagation gaps |
| `loop.pre_commit_drift_check` | boolean | `true` | Run `distributed-fix-drift-check` before committing fix changes to catch inconsistent partial applications |
| `doc_heavy.enabled` | boolean | `true` | Enable Doc-Heavy PR detection. When a PR's diff is dominated by documentation changes, the `tech-writer` reviewer is boosted and verifies five doc-implementation consistency categories via Grep/Read/Glob |
| `doc_heavy.lines_ratio_threshold` | float | `0.6` | Threshold for `doc_lines / total_diff_lines` that marks a PR as doc-heavy |
| `doc_heavy.count_ratio_threshold` | float | `0.7` | Threshold for `doc_files / total_files` (used as fallback for small diffs) |
| `doc_heavy.max_diff_lines_for_count` | integer | `2000` | Maximum diff line count below which `count_ratio_threshold` is consulted |
| `security_reviewer.mandatory` | boolean | `false` | Require security reviewer for all PRs regardless of file types |
| `security_reviewer.recommended_for_code_changes` | boolean | `true` | Include security reviewer when executable code files are changed |
| `debate.enabled` | boolean | `true` | Enable inter-reviewer debate phase |
| `debate.max_rounds` | integer | `1` | Maximum debate rounds (cost control) |
| `confidence_threshold` | integer | `80` | Minimum confidence score for findings to be included in findings table |
| `fact_check.enabled` | boolean | `true` | Enable fact-check phase for review findings |
| `fact_check.max_claims` | integer | `20` | Maximum number of **External** claims to verify per review (Sub-Phase A). Internal Likelihood claims are Grep-based and counted outside this cap |
| `fact_check.use_context7` | boolean | `true` | Use context7 MCP tool for verification. Auto-falls back to WebSearch when context7 is unavailable |
| `fact_check.verify_internal_likelihood` | boolean | `true` | Enable Sub-Phase B (Internal Likelihood Claim Verification) via Grep-based call site / entry point checks |
| ~~`observed_likelihood_gate.*`~~ | — | — | **DEPRECATED**: removed entirely. These keys were scaffolding that never got wired to conditional runtime logic. The Observed Likelihood Gate behavior (Observed / Demonstrable / Hypothetical axis enforcement) is hardcoded in `_reviewer-base.md` / `fix.md` / `review.md` prose. Remove `observed_likelihood_gate:` from `rite-config.yml` — the keys have no effect |
| ~~`fail_fast_first.*`~~ | — | — | **DEPRECATED**: removed entirely. These keys were scaffolding that never got wired to conditional runtime logic. The Fail-Fast First principle (require throw/raise propagation consideration before fallback) is hardcoded in `_reviewer-base.md` / `fix.md` prose. Remove `fail_fast_first:` from `rite-config.yml` — the keys have no effect |
| ~~`separate_issue_creation.*`~~ | — | — | **DEPRECATED**: the **runtime mechanism** was removed entirely — the fix-side post-loop `fix.md` Phase 4.3 ("Automatic Separate Issue Creation") was deleted along with the `[fix:issues-created:N]` sentinel. **Note**: The review-side `pr/review.md` Phase 7 (Automatic Issue Creation with `source: pr_review`, gated by `AskUserQuestion` confirmation) remains live and is the canonical path for converting reviewer "別 Issue として作成" recommendations into tracked Issues. Inside the `/rite:pr:fix` review-fix loop, reviewer recommendations are handled per-finding via fix / accept / reply (Phase 2.1 menu) — no fix-side post-loop auto-creation. **Template state**: `templates/config/rite-config.yml` still contains the `separate_issue_creation:` scaffolding block as of v0.5.0 — it has no runtime effect and is scheduled for removal in a follow-up PR. Existing users may safely remove the block from their local `rite-config.yml` |

**Review-fix loop exit (post-#1136):**

The review-fix loop has two exit paths and no automatic abnormal-exit mechanism:

| Exit | Trigger |
|------|---------|
| Normal | 0 findings remaining → `[review:mergeable]` |
| Manual abort | User aborts via `Ctrl+C` → `/rite:resume` (or selects "中止" in `fix.md` AskUserQuestion → `[fix:cancelled-by-user]`) |

> **Historical note (#557 → #1136)**: v0.4.0 introduced "4 quality signals" as the abnormal-exit mechanism (fingerprint cycling / root-cause missing / cross-validation disagreement / reviewer self-degraded) with an `AskUserQuestion` that offered `本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション` options. #1136 retired this entire mechanism — the design rationale is "指摘ゼロになるまでループ" with manual abort only (see `commands/pr/iterate.md` 設計判断)。 The 4 underlying detection points still exist in code as reviewer-side heuristics: fingerprint cycling (`commands/issue/references/fingerprint-cycling.md`), root-cause-missing (`fix.md` Phase 3.2.1 commit body gate), cross-validation disagreement (`review.md` Phase 5.2 + debate phase), reviewer self-degraded (`_reviewer-base.md` Finding Quality Guardrail) — but they no longer escalate to `AskUserQuestion` or trigger early loop exit.

**Fix settings:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `fix.fail_fast_response` | boolean | `true` | Enable Fail-Fast Response Principle in `fix.md` Phase 2. Requires a 4-item checklist (throw/raise propagation / existing error boundaries / not hiding via null-check / fix the test instead) before adopting a fix approach. Fallback adoption requires a commit message justification. **⚠️ Known limitation**: config scaffolding only — not yet wired. The principle is enforced via prose in `fix.md` Phase 2; setting this to `false` currently has no effect |
| ~~`fix.severity_gating.*`~~ | — | — | **DEPRECATED**: removed entirely. The severity_gating convergence strategy was removed in #1118; non-convergence mitigation was handled by the 4 quality signals until #1136, which removed quality-signal escalation entirely. The current review-fix loop terminates only on 0 findings (normal exit) or manual `Ctrl+C` / `/rite:resume` (see `commands/pr/iterate.md` ループ仕様 and `commands/pr/references/fix-relaxation-rules.md` "Loop Termination"). Remove `fix.severity_gating:` from `rite-config.yml` — the keys have no effect |

**Doc-Heavy PR Mode** (`doc_heavy.enabled: true` by default): A PR is classified as doc-heavy when `doc_lines / total_diff_lines >= lines_ratio_threshold`, or — for small diffs (`total_diff_lines < max_diff_lines_for_count`) — when `doc_files / total_files >= count_ratio_threshold`. In doc-heavy mode, `tech-writer-reviewer` verifies the five consistency categories (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) against the actual implementation using Grep/Read/Glob. See `plugins/rite/commands/pr/references/internal-consistency.md` for the full protocol.

**Verification mode** (`verification_mode: false` by default): When explicitly set to `true`, from cycle 2+, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are classified as "stability concerns" (non-blocking). The default `false` performs full review only every cycle, maximizing review quality.

**Review execution:**

`/rite:pr:review` uses Claude Code's Task tool to spawn parallel subagents for each reviewer role. This improves context efficiency and enables parallel execution.

**Available reviewers:**

The following specialized reviewers are automatically selected based on the changed files:

| Reviewer | Focus Area |
|----------|------------|
| `security-reviewer` | Security vulnerabilities, authentication, data handling |
| `performance-reviewer` | N+1 queries, memory leaks, algorithm efficiency |
| `code-quality-reviewer` | Duplication, naming, error handling, structure |
| `api-reviewer` | API design, REST conventions, interface contracts |
| `database-reviewer` | Schema design, queries, migrations, data operations |
| `devops-reviewer` | Infrastructure, CI/CD pipelines, deployment configurations |
| `frontend-reviewer` | UI components, styling, accessibility, client-side code |
| `test-reviewer` | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | Claude Code skill, command, and agent definitions |
| `tech-writer-reviewer` | Documentation clarity, accuracy, completeness |
| `error-handling-reviewer` | Silent failures, error propagation, catch block quality |
| `type-design-reviewer` | Type encapsulation, invariant expression, enforcement |

**Reviewer selection:**

Reviewers are automatically selected based on:
1. File patterns (e.g., `*.test.*` triggers `test-reviewer`)
2. Content analysis (e.g., SQL queries trigger `database-reviewer`)
3. Change complexity and scope

**Fallback behavior:**

If a subagent fails or times out:
1. The review continues with remaining subagents
2. Failed subagent's results are marked as "incomplete"
3. User is notified of the failure in the review summary

### iteration

Settings for Sprint/Iteration integration with GitHub Projects.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable iteration features |
| `field_name` | string | `"Sprint"` | Name of the iteration field in GitHub Projects |
| `auto_assign` | boolean | `true` | Auto-assign Issues to current iteration on `/rite:pr:open` |
| `show_in_list` | boolean | `true` | Show iteration column in `/rite:issue:list` output |

**Example:**

```yaml
iteration:
  enabled: true
  field_name: "Sprint"
  auto_assign: true
  show_in_list: true
```

When enabled, `/rite:pr:open` will automatically assign the Issue to the current active iteration when starting work. Use `/rite:sprint:list` to view iterations and `/rite:sprint:current` to see the current sprint details.

### verification

Settings for quality verification gates before PR creation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `run_tests_before_pr` | boolean | `true` | Run tests before commit/PR (requires `commands.test` to be configured) |
| `acceptance_criteria_check` | boolean | `true` | Check acceptance criteria from Issue body before PR creation |

**Example:**

```yaml
verification:
  run_tests_before_pr: true
  acceptance_criteria_check: true
```

### tdd

Settings for TDD (Test-Driven Development) Light mode. When enabled, test skeletons are generated from acceptance criteria before implementation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | string | `"off"` | TDD mode: `"off"` (disabled) or `"light"` (generate test skeletons from acceptance criteria) |
| `tag_prefix` | string | `"AC"` | Tag prefix for test skeleton markers (e.g., `AC-1`, `AC-2`) |
| `run_baseline` | boolean | `true` | Run baseline test suite before generating skeletons to ensure existing tests pass |
| `max_skeletons` | integer | `20` | Maximum number of test skeletons to generate per Issue |

**Example:**

```yaml
tdd:
  mode: "light"
  tag_prefix: "AC"
  run_baseline: true
  max_skeletons: 20
```

**How TDD Light works:**

1. Acceptance criteria are extracted from the Issue body
2. Test skeletons are generated with markers (e.g., `// AC-1: User can log in`)
3. Implementation proceeds to make the skeleton tests pass
4. Test results are verified before PR creation

### parallel

Settings for parallel implementation using Task tool.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable parallel implementation |
| `max_agents` | integer | `3` | Maximum number of concurrent agents |
| `mode` | string | `"shared"` | Agent working mode: `"shared"` (all agents share working directory) or `"worktree"` (each agent gets independent git worktree) |
| `worktree_base` | string | `".worktrees"` | Base directory for worktrees when `mode` is `"worktree"` |

**When parallel implementation is used:**

Parallel implementation is automatically activated when ALL of the following conditions are met:
1. `parallel.enabled` is `true`
2. Issue complexity is M or higher
3. Multiple independent files/components are identified in the implementation plan

**How it works:**

1. During Phase 5.1 (Implementation), the implementation plan is analyzed
2. If independent tasks are identified (e.g., separate files that don't depend on each other), they are executed in parallel using Task tool
3. Each parallel task is assigned to a separate agent
4. Results are collected and integrated before proceeding to the next phase

**Agent modes:**

- `"shared"` (default): All agents share the same working directory. Simpler but requires careful coordination to avoid conflicts (e.g., simultaneous `git checkout` operations).
- `"worktree"`: Each agent gets an independent git worktree under the `worktree_base` directory. Provides full isolation but requires more disk space.

**Example:**

```yaml
parallel:
  enabled: true          # Enable parallel implementation (default)
  max_agents: 3          # Up to 3 agents can run concurrently
  mode: "worktree"       # Use independent worktrees for isolation
  worktree_base: ".worktrees"
```

To disable parallel implementation:

```yaml
parallel:
  enabled: false
```

**Error handling:**

- If one task fails, other tasks continue executing
- Failed task results are collected and reported at the end
- The main workflow proceeds with successful results
- Failed tasks can be retried manually or addressed in subsequent commits

### multi_session

Settings for per-session Git worktree isolation, letting multiple Claude Code sessions work different Issues in the same repository concurrently. See [docs/designs/multi-session-worktree.md](./designs/multi-session-worktree.md) for the full design.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable per-session worktrees (on by default since #1391). Set to `false` to restore single-session behavior (identical to pre-#1391, zero change). New projects get `enabled: true` from the `/rite:init` template; existing configs that predate the feature and omit the `multi_session` block fall back to `false` for backward compatibility |
| `worktree_base` | string | `".rite/worktrees"` | Base directory for session worktrees (each Issue gets an `issue-{N}` subdirectory) |

**Separate axis from `parallel`:** `parallel.*` governs per-Issue sub-agent fan-out *within a single session*; `multi_session.*` governs lifecycle isolation *across whole sessions*. The two are orthogonal and intentionally not merged — `parallel.mode: "worktree"` uses `.worktrees/{issue}/{task}`, while `multi_session` uses `.rite/worktrees/issue-{N}`.

**How it works (`enabled: true`):**

1. `/rite:pr:open N` creates a session worktree at `.rite/worktrees/issue-{N}` and enters it via Claude Code's `EnterWorktree(path)` tool, so each session keeps its own working tree and current branch.
2. rite state / locks / wiki worktree still resolve to the shared main checkout root (`state-path-resolve.sh` is worktree-aware), so cross-session exclusion stays intact.
3. `/rite:pr:cleanup` exits the worktree (`ExitWorktree`), removes it, and releases the Issue claim. Abnormally-orphaned worktrees are reaped lazily by `pr-cycle-cleanup.sh`.

**Example:**

```yaml
multi_session:
  enabled: true                    # on by default; set false to opt out
  worktree_base: ".rite/worktrees"
```

**`.gitignore` requirement:** add `.rite/worktrees/` so session worktrees do not leak into dev-branch diffs. `/rite:init` adds this automatically, and `/rite:lint` (via `gitignore-health-check.sh`) emits a non-blocking warning if it is missing while `multi_session.enabled: true`.

**Disk cost:** each session worktree is a full working-tree clone. Build artifacts (`node_modules`, etc.) may need rebuilding per worktree.

### team

Settings for team-based Sprint execution using `/rite:sprint:team-execute`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable `/rite:sprint:team-execute` command |
| `max_concurrent_issues` | integer | `3` | Maximum Issues to process in parallel per batch (falls back to `parallel.max_agents` if not set) |
| `teammate_model` | string | `"sonnet"` | Model for teammate agents: `"sonnet"`, `"opus"`, `"haiku"` |
| `auto_review` | boolean | `true` | Automatically run `/rite:pr:review` after all PRs are created |

**Example:**

```yaml
team:
  enabled: true
  max_concurrent_issues: 3
  teammate_model: "sonnet"
  auto_review: true
```

**How team execution works:**

1. `/rite:sprint:team-execute` spawns multiple teammate agents
2. Each teammate picks up an Issue from the Sprint and executes the new 3-command chain (`/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:ready`); the previous `/rite:issue:start` orchestrator was retired in #1136
3. Teammates work in parallel, each in their own worktree (if `parallel.mode` is `"worktree"`)
4. After all PRs are created, reviews are run automatically if `auto_review` is `true`

### safety

Fail-closed safety thresholds to prevent runaway workflows.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_implementation_rounds` | integer | `20` | Hard limit for implementation rounds per Issue (re-entries from checklist failures) |
| `time_budget_minutes` | integer | `120` | Advisory time budget per Issue in minutes (not enforced by timer) |
| `auto_stop_on_repeated_failure` | boolean | `true` | Stop workflow when the same failure class repeats consecutively |
| `repeated_failure_threshold` | integer | `3` | Number of consecutive same-class failures before triggering auto-stop |

**Example:**

```yaml
safety:
  max_implementation_rounds: 20
  time_budget_minutes: 120
  auto_stop_on_repeated_failure: true
  repeated_failure_threshold: 3
```

**When safety limits are hit:**

When a limit is exceeded, the workflow presents options:
1. Continue (raise the limit)
2. Abort (save state to work memory for later resumption)
3. Manual intervention (user handles directly)

### metrics

Settings for workflow execution metrics recording and threshold evaluation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable/disable metrics recording |
| `baseline_issues` | integer | `3` | Number of Issues to complete before threshold evaluation begins (measure-only period) |

> **Note**: Metric thresholds (`plan_deviation_rate`, `test_pass_rate`, `review_fix_loops`, etc.) are currently hardcoded in the implementation. Configurable thresholds via `rite-config.yml` are planned for a future release.

**Example:**

```yaml
metrics:
  enabled: true
  baseline_issues: 3
```

**How metrics work:**

1. **Baseline period**: During the first `baseline_issues` completed Issues, metrics are recorded but not evaluated against thresholds
2. **Post-baseline**: Metrics are evaluated against per-Issue thresholds and moving average (MA5) thresholds
3. **Failure classification**: When thresholds are exceeded, failures are classified (e.g., scope creep, quality regression) and corrective actions are suggested
4. **Repeated failure detection**: If `safety.auto_stop_on_repeated_failure` is enabled, consecutive same-class failures trigger auto-stop

### pr_review

Settings for PR review **output** recording. This section is intentionally separated from the `review:` section (which configures review **execution**) so that future output destinations (Slack notifications, etc.) can be added without a breaking change to `review:` child keys.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `post_comment` | boolean | `false` | When `true`, review results are posted as PR comments (equivalent to `--post-comment`). When `false` (default), results are saved to `.rite/review-results/{pr_number}-{timestamp}.json` only |

`/rite:pr:fix` automatically reads review results in the priority order: **conversation > local file > PR comment**. Most users should leave `post_comment: false` to keep PR comment history clean. Enable it only if you want an auditable review trail on the PR itself. See #443 for rationale.

### wiki

Settings for the Experience Wiki — an LLM-driven project knowledge base that persists experiential heuristics extracted from review/fix/Issue outcomes. Based on the LLM Wiki pattern (Karpathy). See `docs/designs/experience-heuristics-persistence-layer.md` for the full design.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable Wiki features (opt-out). Set `false` to skip all Wiki hooks and commands |
| `branch_strategy` | string | `"separate_branch"` | Where Wiki data lives: `"separate_branch"` (dedicated orphan-like branch, recommended) or `"same_branch"` (Wiki files committed alongside code on the working branch) |
| `branch_name` | string | `"wiki"` | Name of the Wiki branch (used only when `branch_strategy` is `"separate_branch"`) |
| `auto_ingest` | boolean | `true` | Automatically run `/rite:wiki:ingest` on review/fix/close events to extract heuristics from raw sources |
| `auto_query` | boolean | `true` | Automatically run `/rite:wiki:query` at the start of Issue work and at review/fix/implement phases to inject relevant heuristics into the conversation context |
| `auto_lint` | boolean | `true` | Automatically run `/rite:wiki:lint --auto` after each ingest to detect contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs |
| `growth_check.threshold_prs` | integer | `5` | Issue #524 layer 3 (lint growth check) — `/rite:lint` Phase 3.8 emits a non-blocking warning when this many merged PRs accumulate on the development base branch since the last commit on `branch_name` (signalling that Phase X.X.W may be silently skipped). Increase to relax the check; setting it to a very large number effectively disables the lint warning while preserving layers 1-2 |
| `growth_check.pr_raw_threshold` | integer | `3` | Issue #536 — warn when this many of the last `threshold_prs` merged PRs have no corresponding raw source on the wiki branch. Detects regressions where PRs are merged but Phase X.X.W never fires. Override at runtime with `--pr-raw-threshold N` |

**Example (opt out completely):**

```yaml
wiki:
  enabled: false
```

**Example (same-branch Wiki without auto-lint):**

```yaml
wiki:
  enabled: true
  branch_strategy: "same_branch"
  auto_ingest: true
  auto_query: true
  auto_lint: false
```

> **Note for `same_branch` users**: The project's `.gitignore` ships with `.rite/wiki/` excluded as a silent-leak defense line for the default `separate_branch` strategy. If you switch to `same_branch`, you MUST add negation entries so that Wiki files are not ignored. See the `.gitignore` comment block between the `# >>> gitignore-wiki-section-start` and `# <<< gitignore-wiki-section-end` anchor markers (`grep -n 'gitignore-wiki-section-start' .gitignore` to jump there) for the full verification-first setup: required negation entries (`!.rite/wiki/` and `!.rite/wiki/**`), the mandatory `mkdir -p .rite/wiki/raw && touch .rite/wiki/raw/.negation-probe && git add --dry-run .rite/wiki/raw/.negation-probe` sanity check, the idempotency note for already-tracked files, and the rationale for using `git add --dry-run` instead of `git check-ignore -v` as the canonical verification step.

**Example (loose growth-check threshold for slow-moving repos):**

```yaml
wiki:
  enabled: true
  growth_check:
    threshold_prs: 20   # warn only after 20 PRs have accumulated since the last wiki commit
    pr_raw_threshold: 5  # warn if 5+ of last 20 PRs have no raw source
```

**Related commands:** `/rite:wiki:init` (one-time setup), `/rite:wiki:ingest`, `/rite:wiki:query`, `/rite:wiki:lint`.

### language

| Value | Description |
|-------|-------------|
| `auto` | Auto-detect from user input |
| `ja` | Japanese |
| `en` | English |

## Minimal Configuration

For most projects, a minimal configuration is sufficient:

```yaml
schema_version: 2
```

All settings use sensible defaults or auto-detection. Override specific keys (`branch.pattern`, `commands.*`, `iteration.*` etc.) as needed.

## ~~Project Type Presets~~ (DEPRECATED in #1118 — historical reference only)

> **DEPRECATED**: The `project.type` preset feature (`generic` / `webapp` / `library` / `cli` / `documentation`) was retired in #1118. The `templates/project-types/*.yml` preset files and `templates/pr/{cli,library,webapp,documentation,fix-report}.md` PR templates were removed. Project-specific configuration is now expressed via the per-key YAML structure directly. The sections below are kept as a historical reference of the previously-supported preset behaviors.

### ~~webapp~~ (retired)

Optimized for web applications:
- Frontend/Backend/Database change tracking
- Screenshot requests in PR template
- E2E test checklist

### ~~library~~ (retired)

Optimized for OSS libraries:
- Breaking change tracking
- Migration guide prompts
- CHANGELOG reminders

### ~~cli~~ (retired)

Optimized for CLI tools:
- Command change tracking
- Backward compatibility checks
- Help/manual update reminders

### ~~documentation~~ (retired)

Optimized for documentation sites:
- Build verification
- Link checking
- Style guide compliance
