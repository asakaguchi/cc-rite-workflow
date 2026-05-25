# Claude Code Rite Workflow Specification

> Universal Issue-Driven Development Workflow Claude Code Plugin

## Overview

**Claude Code Rite Workflow** is a universal Claude Code plugin that provides an Issue-driven development workflow.
It works with any software development project regardless of language or framework.

### Design Principles

- **Rite**: Structured process that ensures consistent, repeatable workflows
- **Universality**: No dependency on specific tech stacks
- **Automation**: Auto-detection and auto-configuration where possible
- **Customizability**: Flexible adjustment via configuration files

### Naming Origin

The command prefix `rite` was chosen for:

1. **Meaning**: A rite is a structured ceremony or process - representing consistent, repeatable workflows
2. **Practicality**: Short (4 characters), easy to type, and distinctive as a command prefix
3. **Trademark**: Low trademark risk as it's a common English word

---

## Table of Contents

1. [Command List](#command-list)
2. [Workflow Overview](#workflow-overview)
3. [Plugin Structure](#plugin-structure)
4. [Configuration File Specification](#configuration-file-specification)
5. [Command Specifications](#command-specifications)
6. [Iteration/Sprint Management (Optional)](#iterationsprint-management-optional)
7. [Hook Specification](#hook-specification)
8. [Features](#features)
9. [Notification Integration](#notification-integration)
10. [Build/Test/Lint Auto-Detection](#buildtestlint-auto-detection)
11. [Dynamic Reviewer Generation](#dynamic-reviewer-generation)
12. [Sub-skill Return Auto-Continuation Contract](#sub-skill-return-auto-continuation-contract)
13. [Error Handling](#error-handling)
14. [Migration](#migration)
15. [Internationalization](#internationalization)
16. [Dependencies](#dependencies)
17. [Distribution](#distribution)
18. [Project Types](#project-types)

---

## Command List

| Command | Description | Arguments |
|---------|-------------|-----------|
| `/rite:init` | Initial setup wizard | `[--upgrade]` (upgrade existing `rite-config.yml` schema to the latest version) |
| `/rite:getting-started` | Interactive onboarding guide | None |
| `/rite:workflow` | Show workflow guide | None |
| `/rite:investigate` | Structured code investigation | `<topic or question>` |
| `/rite:issue:list` | List Issues | `[filter]` |
| `/rite:issue:create` | Create new Issue | `<title or description>` |
| `/rite:issue:update` | Update work memory | `[memo]` |
| `/rite:issue:close` | Check Issue completion | `<Issue number>` |
| `/rite:issue:edit` | Interactively edit existing Issue | `<Issue number>` |
| `/rite:issue:recall` | Search Contextual Commit history for past decisions | `[{scope}\|{action}({scope})]` |
| `/rite:pr:open` | Start work end-to-end (branch → plan → implement → lint → draft PR) | `<Issue number>` |
| `/rite:pr:iterate` | Loop review ⇄ fix until mergeable | `<PR number>` |
| `/rite:pr:merge` | Squash-merge the PR | `<PR number>` |
| `/rite:pr:create` | Create draft PR | `[PR title]` |
| `/rite:pr:ready` | Mark as Ready for review | `[PR number]` |
| `/rite:pr:review` | Multi-reviewer review | `[PR number]` |
| `/rite:pr:fix` | Address review feedback | `[PR number]` |
| `/rite:pr:cleanup` | Post-merge cleanup | `[branch name]` |
| `/rite:lint` | Run quality checks | `[file path]` |
| `/rite:template:reset` | Regenerate templates | `[--force]` |
| `/rite:sprint:list` | List Sprints/Iterations | `[--all\|--current\|--past]` |
| `/rite:sprint:current` | Show current sprint details | None |
| `/rite:sprint:plan` | Execute sprint planning | `[current\|next\|"Sprint name"]` |
| `/rite:sprint:execute` | Sequentially execute Todo Issues in Sprint | `[Sprint name]` |
| `/rite:sprint:team-execute` | Parallel team execution of Todo Issues in Sprint | `[Sprint name]` |
| `/rite:wiki:init` | Initialize Experience Wiki (branch, directories, templates) | None |
| `/rite:wiki:query` | Search Wiki pages for heuristics by keyword and inject into context | `<keywords>` |
| `/rite:wiki:ingest` | Extract heuristics from raw sources and update Wiki pages | `[source]` |
| `/rite:wiki:lint` | Lint Wiki pages for contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs | `[--auto] [--stale-days <N>]` |
| `/rite:resume` | Resume interrupted work | `[issue_number]` |
| `/rite:skill:suggest` | Analyze context and suggest applicable skills | `[--verbose\|--filter]` |

---

## Workflow Overview

```
/rite:init (Initial Setup)
 │
 ▼
/rite:issue:list (Check Issues)
 │
 ▼
/rite:issue:create (Create New Issue)
 │ Status: Todo
 ▼
/rite:pr:open <issue> (Start Work)
 │ Status: In Progress
 │
 ├── Branch Creation
 ├── Implementation Planning
 ├── Implementation Work (rite:issue:implement)
 ├── /rite:lint (Quality Check, autonomous)
 └── /rite:pr:create (Create Draft PR)
 ▼
/rite:pr:iterate <pr> (Review ⇄ Fix loop)
 │ Internally invokes /rite:pr:review and /rite:pr:fix repeatedly
 │ until [review:mergeable] or [fix:replied-only]
 ▼
/rite:pr:ready <pr> (Ready for Review)
 │ Status: In Review
 ▼
/rite:pr:merge <pr> (Squash-Merge)
 │
 ▼
/rite:pr:cleanup <pr> (Post-Merge Cleanup)
 │ Status: Done
 ▼
Issue Auto-Close
```

**Note:** The end-to-end flow is split across four single-responsibility commands (#1136). `/rite:pr:open <issue>` handles branch creation, implementation, autonomous lint, and draft PR creation. `/rite:pr:iterate <pr>` loops review and fix until convergence (no cycle-count cap; manual abort via `Ctrl+C` + `/rite:resume`). `/rite:pr:ready <pr>` flips the PR to Ready for review. `/rite:pr:merge <pr>` runs `gh pr merge --squash`. See [Phase 5: End-to-End Execution](#phase-5-end-to-end-execution) for details.

**Status Transitions:**
```
Todo → In Progress → In Review → Done
```

---

## Plugin Structure

> **Architecture**: The `/rite:issue:create` lifecycle is a single-file flat workflow. The previous `/rite:issue:start` flat workflow was decomposed in #1136 into four single-responsibility commands (`/rite:pr:open` / `/rite:pr:iterate` / `/rite:pr:ready` / `/rite:pr:merge`); the source file `commands/issue/start.md` was deleted. Older sub-skill files (`commands/issue/start-execute`, `start-publish`, `start-finalize`, `create-interview`, `create-register`, `create-decompose`, `parent-routing`, etc.) and implicit-stop guard hooks (`auto-fire-step0.sh`, `verify-terminal-output.sh`, `stop-create-interview-block.sh`) were earlier consolidated into the flat workflow (#1079) before the start.md decomposition. Sections referencing those retired components remain only as migration anchors.

```
rite-workflow/
├── .claude-plugin/
│ └── plugin.json # Plugin metadata
├── commands/ # Skill-invoked command files (Markdown)
│ ├── init.md # /rite:init (+ --upgrade)
│ ├── getting-started.md # /rite:getting-started
│ ├── workflow.md # /rite:workflow
│ ├── investigate.md # /rite:investigate
│ ├── lint.md # /rite:lint
│ ├── resume.md # /rite:resume
│ ├── issue/
│ │ ├── list.md # /rite:issue:list
│ │ ├── create.md # /rite:issue:create
│ │ ├── update.md # /rite:issue:update
│ │ ├── close.md # /rite:issue:close
│ │ ├── edit.md # /rite:issue:edit
│ │ ├── recall.md # /rite:issue:recall
│ │ ├── implement.md # /rite:issue:implement (sub-skill, invoked from /rite:pr:open)
│ │ └── references/ # Edge cases, complexity gates, bulk-create patterns
│ ├── pr/
│ │ ├── open.md # /rite:pr:open (start work end-to-end)
│ │ ├── iterate.md # /rite:pr:iterate (review ⇄ fix loop)
│ │ ├── merge.md # /rite:pr:merge (squash merge)
│ │ ├── ready.md # /rite:pr:ready
│ │ ├── create.md # /rite:pr:create
│ │ ├── review.md # /rite:pr:review
│ │ ├── fix.md # /rite:pr:fix
│ │ ├── cleanup.md # /rite:pr:cleanup
│ │ └── references/ # Protocol documents referenced by pr/ commands
│ │ ├── assessment-rules.md # Review assessment rules
│ │ ├── archive-procedures.md # Archive procedures
│ │ ├── bash-trap-patterns.md # Bash trap patterns for review/fix
│ │ ├── change-intelligence.md # Change intelligence
│ │ ├── fact-check.md # External fact-checking protocol
│ │ ├── fix-relaxation-rules.md # Fix relaxation / 4 quality signals
│ │ ├── internal-consistency.md # Doc-implementation consistency protocol
│ │ ├── review-context-optimization.md # Review context optimization
│ │ └── reviewer-fallbacks.md # Reviewer fallback profiles
│ ├── sprint/
│ │ ├── list.md # /rite:sprint:list
│ │ ├── current.md # /rite:sprint:current
│ │ ├── plan.md # /rite:sprint:plan
│ │ ├── execute.md # /rite:sprint:execute
│ │ └── team-execute.md # /rite:sprint:team-execute
│ ├── wiki/
│ │ ├── init.md # /rite:wiki:init
│ │ ├── query.md # /rite:wiki:query
│ │ ├── ingest.md # /rite:wiki:ingest
│ │ ├── lint.md # /rite:wiki:lint
│ │ └── references/
│ │ └── bash-cross-boundary-state-transfer.md
│ ├── skill/
│ │ └── suggest.md # /rite:skill:suggest
│ └── template/
│ └── reset.md # /rite:template:reset
├── agents/ # Subagent definitions for /rite:pr:review
│ ├── _reviewer-base.md # Shared reviewer principles (not a subagent)
│ ├── security-reviewer.md
│ ├── performance-reviewer.md
│ ├── code-quality-reviewer.md
│ ├── api-reviewer.md
│ ├── database-reviewer.md
│ ├── devops-reviewer.md
│ ├── frontend-reviewer.md
│ ├── test-reviewer.md
│ ├── dependencies-reviewer.md
│ ├── prompt-engineer-reviewer.md
│ ├── tech-writer-reviewer.md
│ ├── error-handling-reviewer.md
│ ├── type-design-reviewer.md
│ └── sprint-teammate.md # /rite:sprint:team-execute teammate agent
├── skills/ # Claude Code auto-discovered skills
│ ├── rite-workflow/
│ │ ├── SKILL.md # Main workflow skill (auto-activated)
│ │ └── references/ # Coding principles, context management, etc.
│ ├── reviewers/
│ │ ├── SKILL.md # Reviewer skill (auto-activated)
│ │ ├── {api,code-quality,database,dependencies,devops,error-handling,
│ │ │ frontend,performance,prompt-engineer,security,tech-writer,
│ │ │ test,type-design}.md # Per-reviewer criteria
│ │ └── references/ # Shared reviewer references
│ ├── investigate/
│ │ └── SKILL.md # Structured code investigation skill
│ └── wiki/
│ └── SKILL.md # Experience Wiki skill (opt-out)
├── hooks/ # Claude Code lifecycle hooks + helpers
│ ├── hooks.json # Hook registration manifest
│ ├── session-start.sh / session-end.sh / session-ownership.sh
│ ├── pre-compact.sh / post-compact.sh # #133
│ ├── preflight-check.sh
│ ├── pre-tool-bash-guard.sh / post-tool-wm-sync.sh
│ ├── hook-preamble.sh / state-path-resolve.sh # Shared helpers
│ ├── flow-state.sh / local-wm-update.sh
│ ├── work-memory-lock.sh / work-memory-update.sh / work-memory-parse.py
│ ├── cleanup-work-memory.sh
│ ├── issue-body-safe-update.sh / issue-comment-wm-sync.sh / issue-comment-wm-update.py
│ ├── notification.sh # External notification dispatcher (not a Claude hook)
│ ├── wiki-ingest-trigger.sh / wiki-query-inject.sh # Wiki auto-integration
│ ├── scripts/ # Helper scripts invoked by hooks
│ │ ├── wiki-ingest-commit.sh / wiki-worktree-commit.sh / wiki-worktree-setup.sh
│ │ ├── wiki-growth-check.sh # #524 lint layer-3
│ │ ├── backlink-format-check.sh / bang-backtick-check.sh
│ │ ├── distributed-fix-drift-check.sh / doc-heavy-patterns-drift-check.sh
│ │ └── gitignore-health-check.sh # #567
│ └── tests/ # Hook-level test suite (shell-based)
├── templates/
│ ├── README.md
│ ├── config/
│ │ └── rite-config.yml # Minimal default distributed by /rite:init
│ ├── project-types/
│ │ ├── generic.yml / webapp.yml / library.yml / cli.yml / documentation.yml
│ ├── issue/
│ │ ├── default.md / decomposition-spec.md
│ │ ├── interview-perspectives.md / template-structure.md
│ ├── pr/
│ │ ├── generic.md / webapp.md / library.md / cli.md / documentation.md
│ │ └── fix-report.md # Fix loop summary format
│ ├── review/
│ │ └── comment.md # PR review comment format
│ └── wiki/
│ ├── index-template.md / log-template.md
│ ├── page-template.md / schema-template.md
├── scripts/ # Projects integration / Sub-Issue / review metrics
│ ├── create-issue-with-projects.sh
│ ├── backfill-sub-issues.sh / link-sub-issue.sh
│ ├── extract-verified-review-findings.sh / measure-review-findings.sh
│ ├── projects-status-update.sh
│ └── tests/ # Script-level test suite
├── references/ # Cross-cutting references used by commands/skills
│ ├── gh-cli-patterns.md / gh-cli-commands.md / gh-cli-error-catalog.md
│ ├── graphql-helpers.md / projects-integration.md
│ ├── priority-markers.md / severity-levels.md / epic-detection.md
│ ├── review-result-schema.md / investigation-protocol.md
│ ├── wiki-patterns.md
│ ├── bash-compat-guard.md / bash-defensive-patterns.md
│ ├── sub-issue-link-handler.md / issue-create-with-projects.md
│ ├── output-patterns.md / execution-metrics.md
│ ├── plugin-path-resolution.md / git-worktree-patterns.md
│ ├── common-error-handling.md / error-codes.md
│ ├── i18n-usage.md / tdd-light.md
│ └── bottleneck-detection.md
├── i18n/
│ ├── ja.yml / en.yml # Legacy monolithic files (kept for back-compat)
│ ├── ja/ # Japanese split files
│ │ └── {common,issue,pr,other}.yml
│ └── en/ # English split files
│ └── {common,issue,pr,other}.yml
└── README.md
```

### plugin.json

Plugin metadata file format:

```json
{
 "name": "rite",
 "version": "0.4.0",
 "description": "Universal Issue-driven development workflow for Claude Code",
 "author": { "name": "B16B1RD" },
 "license": "MIT"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Plugin name (used as command prefix) |
| `version` | Yes | Semantic version |
| `description` | Yes | Short description |
| `author` | Yes | Author object with `name` field |
| `license` | No | License identifier |

### Command File Format

Each command file in `commands/` must include YAML frontmatter:

```markdown
---
description: Short description of the command
context: fork # Optional: run in isolated context
---

# /rite:command-name

Command documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `description` | Yes | Short description used for command discovery |
| `context` | No | Set to `fork` for commands that don't need main conversation context |

**context: fork Usage:**

Commands that display information without modifying state use `context: fork` for better context efficiency:

| Command | context: fork | Reason |
|---------|---------------|--------|
| `/rite:issue:list` | ✅ | Information display only |
| `/rite:sprint:list` | ✅ | Information display only |
| `/rite:sprint:current` | ✅ | Information display only |
| `/rite:skill:suggest` | ✅ | Independent analysis |
| Others | ❌ | Require user interaction or state changes |

### Skill File Format

Skill files (`skills/*/SKILL.md`) use YAML frontmatter for auto-activation:

```markdown
---
name: skill-name
description: |
 Multi-line description of the skill's purpose.
 Include auto-activation conditions.
---

# Skill Name

Skill documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique skill identifier |
| `description` | Yes | Detailed description with activation conditions |

**Skill Classification:**

| Classification | Purpose | Example |
|----------------|---------|---------|
| Reference Contents | Always-available knowledge | `rite-workflow` (workflow rules) |
| Task Contents | Active execution tasks | `reviewers` (review criteria) |

### Agent File Format

Agent files (`agents/*.md`) define subagents for specialized tasks:

```markdown
---
name: agent-name
description: Short purpose description
model: opus # opus | sonnet | haiku (optional; omit to inherit from parent session)
---

# Agent Name

Agent documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique agent identifier |
| `description` | Yes | Short description for Task tool |
| `model` | No | Model selection (default: inherit from parent session) |
| `tools` | No | List of available tools (default: inherit all tools from parent; omit to enable all tools) |

**Note on `tools`**: Reviewer agents are invoked via named subagents (`rite:{reviewer_type}-reviewer`, e.g. `rite:security-reviewer`), introduced in v0.3 (#358). The previous `subagent_type: general-purpose` invocation is no longer used. Under named subagent invocation, both `model` and `tools` frontmatter are honored by the runtime. The `tools` field is optional — reviewer agents omit it to inherit all parent-session tools by default. See [`docs/migration-guides/review-named-subagent.md`](migration-guides/review-named-subagent.md) for the full rationale, opus recommendation, and rollback scenarios.

**Current Agents:**

| Agent | Model | Purpose |
|-------|-------|---------|
| `security-reviewer` | opus | Security vulnerabilities, authentication, data handling |
| `performance-reviewer` | inherit | N+1 queries, memory leaks, algorithm efficiency |
| `code-quality-reviewer` | inherit | Duplication, naming, error handling, structure |
| `api-reviewer` | opus | API design, REST conventions, interface contracts |
| `database-reviewer` | opus | Schema design, queries, migrations, data operations |
| `devops-reviewer` | opus | Infrastructure, CI/CD pipelines, deployment configurations |
| `frontend-reviewer` | opus | UI components, styling, accessibility, client-side code |
| `test-reviewer` | opus | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | opus | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | opus | Claude Code skill, command, and agent definitions |
| `tech-writer-reviewer` | opus | Documentation clarity, accuracy, completeness |
| `error-handling-reviewer` | inherit | Error handling patterns, silent failures, recovery logic |
| `type-design-reviewer` | inherit | Type design, encapsulation, invariant expression |

---

## Configuration File Specification

### rite-config.yml

Place in project root or `.claude/` directory. Uses YAML format for readability and comment support.

Full schema reference lives in **[docs/CONFIGURATION.md](./CONFIGURATION.md)**, which is kept in sync with `plugins/rite/templates/config/rite-config.yml` — the minimal default that `/rite:init` distributes. The template intentionally omits advanced keys; enable them by copying the key declarations from CONFIGURATION.md as needed.

**Top-level sections** (see CONFIGURATION.md for per-key details):

| Section | Purpose |
|---------|---------|
| `project.type` | Project preset (`generic` / `webapp` / `library` / `cli` / `documentation`) |
| `github.projects.*` | GitHub Projects integration (`field_ids`, `fields`, `project_number`, `owner`) |
| `branch.*` | `base`, `pattern`, `recognized_patterns` |
| `commit.contextual` | Contextual Commits action lines in commit body |
| `commands.{build,test,lint}` | Build/test/lint auto-detection overrides |
| `issue.auto_decompose_threshold` | Threshold for skipping the decomposition prompt |
| `review.*` | `loop.*` (convergence_monitoring / auto_propagation_scan / pre_commit_drift_check), `doc_heavy.*`, `fact_check.*` (incl. `use_context7`), `debate.*`, `security_reviewer.*`, `confidence_threshold`, `observed_likelihood_gate.*` / `fail_fast_first.*` (all #506). The `separate_issue_creation.*` keys were removed entirely in #1136 along with the `[fix:issues-created:N]` sentinel and `fix.md` Phase 4.3 — see CONFIGURATION.md for the deprecation note |
| `fix.*` | `fail_fast_response` (#506), `severity_gating` (deprecated #557, pinned `false`) |
| `verification.*` | `run_tests_before_pr`, `acceptance_criteria_check` |
| `tdd.*` | TDD Light mode (`off` / `light`) |
| `parallel.*`, `team.*` | Parallel implementation and Sprint team execution |
| `iteration.*` | GitHub Projects Iteration field integration |
| `safety.*` | Fail-closed thresholds (`max_implementation_rounds`, `time_budget_minutes`, etc.) |
| `pr_review.post_comment` | PR review output destination (#443) |
| `wiki.*` | Experience Wiki — `enabled` (opt-out), `branch_strategy`, `auto_ingest`, `auto_query`, `auto_lint`, `growth_check.*` |
| `metrics.*` | Execution metrics recording |
| `notifications.{slack,discord,teams}` | External notifications |
| `language` | `auto` / `ja` / `en` |

**Migration**: `schema_version` (currently `2`) is bumped when breaking schema changes ship. `/rite:init --upgrade` performs a non-destructive merge for compatible upgrades, and `/rite:lint` emits deprecation warnings for removed keys — see the [CHANGELOG](../CHANGELOG.md) for the current deprecation set (v0.4.0 removed `review.loop.severity_gating_cycle_threshold`, `review.loop.scope_lock_cycle_threshold`, and `safety.max_review_fix_loops` per #557).

---

## Command Specifications

### /rite:init

**Description:** Initial setup of rite workflow for a project

**Arguments:** `[--upgrade]` (optional)

| Argument | Description |
|----------|-------------|
| (none) | Run fresh setup (executes Phases 1–5 sequentially) |
| `--upgrade` | Upgrade the schema of an existing `rite-config.yml` to the latest version (skips Phases 1–3 and 5, and executes Phase 4.1.3; Phase 4.1.3 invokes Phase 4.7 (Wiki initialization) at its Step 7, so the effective execution is Phase 4.1.3 + Phase 4.7) |

**Process Flow:**

#### Phase 1: Environment Check
1. Verify gh CLI installation
2. Check GitHub authentication status
3. Get repository information

#### Phase 2: Project Type Detection
1. Auto-detect from file structure
 - `package.json` + frontend framework → webapp
 - `package.json` + `main`/`exports` → library
 - `pyproject.toml` + `[project.scripts]` → cli
 - SSG config file → documentation
 - Other → generic
2. Confirm/select with user (AskUserQuestion)

#### Phase 3: GitHub Projects Setup
1. Detect existing Projects
2. Present options:
 - Link to existing Projects
 - Create new Projects
3. Auto-configure fields

#### Phase 4: Template Generation
1. Check `.github/ISSUE_TEMPLATE/`
 - Recognize if exists
 - Auto-generate if not
2. Generate `rite-config.yml`
3. If an existing `rite-config.yml` is present, check its `schema_version`; if out of date, display guidance to run `/rite:init --upgrade`

#### Phase 5: Completion Report
1. Display settings summary
2. Guide next steps

---

#### --upgrade Option (Existing Configuration Schema Upgrade)

**Purpose:** Bring an existing project's `rite-config.yml` up to the latest schema while preserving user-customized values (`project_number`, `owner`, `branch.base`, `language`, and so on). The upgrade applies the additions (new sections), removals (deprecated keys), and `schema_version` bump in a single confirmed batch.

**When to use:**

- When a warning that `rite-config.yml` schema is outdated appears after upgrading the rite workflow plugin and running `/rite:init` or starting a session. The exact Japanese message emitted by `/rite:init` is: `rite-config.yml のスキーマが古くなっています (v{current} → v{latest})。/rite:init --upgrade でアップグレードできます。` The session-start hook emits a slightly different variant ending in `/rite:init --upgrade を実行してください。` ("run `/rite:init --upgrade`")
- When release notes (`CHANGELOG.md`, or migration notes referenced from the release notes — e.g., `docs/migration-guides/` when present) announce new configuration sections (e.g., `wiki:`, `review.debate:`) that are missing from your local `rite-config.yml`
- When the `schema_version` at the top of your `rite-config.yml` diverges from the `schema_version` in the bundled template (`plugins/rite/templates/config/rite-config.yml`)

**Example:**

```bash
/rite:init --upgrade
```

**Phase 4.1.3 Behavior (runs only with `--upgrade`):**

1. **Read current config and compare versions**
 Read `schema_version` from both the existing `rite-config.yml` and the bundled template. Missing values are treated as v1.
2. **Create a backup**
 Copy the existing file to `rite-config.yml.bak.YYYYMMDD-HHMMSS` for rollback.
3. **Branching**
 - `current < latest`: Run Step 4–6 (identify changes → preview → apply after approval), then Step 7 (Phase 4.7 Wiki initialization).
 - `current == latest` and `wiki:` section absent: After backup, append the `wiki:` block from the template and run Phase 4.7.
 - `current == latest` and `wiki:` section present: No-op; display "configuration is up to date" and run Phase 4.7 (idempotent — no-op if Wiki is already initialized).
4. **Identify and classify changes** (Step 4, only on the `current < latest` path)
 Each key is classified as one of:
 - **User-customized value** (preserve): `project_number`, `owner`, `iteration` settings, `branch.base`, `language`, etc.
 - **Deprecated key** (remove): `project.name`, `commit.style`, `commit.enforce`, `branch.release`, `branch.types`, `version`
 - **Missing section** (add with template defaults): `review.debate`, `review.fact_check`, `verification`, etc.
 - **Advanced section** (add as commented-out block): `tdd`, `parallel`, `team`, `metrics`, `safety`, `investigate`
 - **Unknown key** (preserve with warning): user-added keys not present in the template
5. **Preview and confirm** (Step 5)
 Display deprecated keys to be removed, sections to be added, and preserved existing settings; ask via `AskUserQuestion` to either apply or cancel.
6. **Apply** (Step 6)
 On approval, update `schema_version` to the latest value, remove deprecated keys, add missing sections (including commented-out Advanced sections), and append the `wiki:` section if it was absent. All user-customized values are preserved.
7. **Run Phase 4.7 (Wiki initialization)** (Step 7)
 Invoke Phase 4.7 to bring existing users up to the Wiki-initialized state. If Wiki is already initialized, the phase is an idempotent no-op. Phase 4.7 is non-blocking: its failure does not affect `--upgrade` success. A final Wiki status line is displayed before the command exits.

**Relationship with `schema_version`:**

- The `schema_version` key at the top of `rite-config.yml` is an integer that identifies the configuration schema version (e.g., `schema_version: 2`). It is incremented whenever the rite workflow introduces a backward-incompatible schema change.
- `--upgrade` compares the `schema_version` in the current file against the one in the bundled template and runs the Phase 4.1.3 flow above when the current file is behind.
- Configuration files without a `schema_version` key are implicitly treated as v1 and can be brought up to date via `--upgrade`.

**Relationship with Phase 5 (new-install completion report):**

- `--upgrade` skips Phases 1–3 and the Phase 5 new-install completion report; only the Wiki status line is displayed at the end.
- It does not merge with the fresh-install completion report (`--upgrade` is a dedicated path for updating existing configurations).

---

### /rite:issue:create

**Description:** Create new Issue and add to GitHub Projects

**Arguments:** `<Issue title or work description>` (required)

#### Phase 0: Input Analysis

1. Extract from user input:
 - **What:** What to do
 - **Why:** Why it's needed
 - **Where:** What to change
 - **Scope:** Impact range
 - **Constraints:** Limitations

2. Detect ambiguous expressions

3. Search similar Issues for context

4. Clarify with `AskUserQuestion` if needed

5. Deep-dive interview (Phase 0.5) for implementation details

#### Phase 0.6-0.9: Task Decomposition (Conditional)

**Trigger Conditions:**
- Preliminary complexity is XL
- AND contains inclusive expressions like "build ~ system", "create ~ platform", "implement ~ infrastructure"
 - Simple expressions like "add ~ feature", "fix ~" are excluded

**Decomposition Flow:**

1. **Phase 0.6**: Decomposition trigger detection
 - If conditions are met, propose decomposition to user

2. **Phase 0.7**: Specification document generation
 - Generate design document based on deep-dive interview results
 - Save to `docs/designs/{slug}.md`

3. **Phase 0.8**: Sub-Issue decomposition
 - Extract Sub-Issue candidates from specification
 - Analyze dependencies and propose implementation order

4. **Phase 0.9**: Bulk Sub-Issue creation
 - Create parent Issue and Sub-Issues
 - Set parent-child relationship via Tasklist format
 - Use GitHub Sub-Issues API (beta) if available

**Sub-Issue Granularity:**
- Each Sub-Issue should be 1 Issue = 1 PR in size
- Estimated complexity: S-L (split to avoid XL)
- Can be completed independently

#### Phase 1: Classification

**Complexity Estimation:**

| Complexity | Criteria |
|------------|----------|
| XS | Single line change, typo fix |
| S | Single file content update |
| M | Multiple files (up to 5) |
| L | Multiple files (10+), requires judgment |
| XL | Large-scale changes, design decisions |

#### Phase 2: Confirmation & Creation

1. Create Issue with `gh issue create`
2. Add to Projects with `gh project item-add`
3. Set fields (Status/Priority/Complexity/Work Type)

---

### /rite:issue:start (Retired in #1136)

> **Status**: Decomposed into four single-responsibility commands. The 783-line `commands/issue/start.md` orchestrator was deleted; the live specification now lives in `/rite:pr:open` / `/rite:pr:iterate` / `/rite:pr:ready` / `/rite:pr:merge`. This section is preserved as a migration anchor so that the historical Phase numbering (Phase 0 / 1 / 1.5 / 1.6 / 2 / 3 / 4 / 5) can still be traced when reading older PRs, design docs, and CHANGELOG entries.

**Mapping from old phases to new commands:**

| Old Phase (start.md) | New command + step |
|----------------------|--------------------|
| Phase 0 (Epic / Sub-Issues detection) | `/rite:pr:open` Step 1 (Issue fetch + parent detection) |
| Phase 1 (Issue quality verification) | `/rite:pr:open` Step 1.3 |
| Phase 1.5 / 1.6 (Parent routing / Child selection) | `/rite:pr:open` Step 1.2 |
| Phase 2 (Branch creation, Projects Status, Iteration) | `/rite:pr:open` Step 2 |
| Phase 3 (Implementation planning) | `/rite:pr:open` Step 3 |
| Phase 4 (Guidance / "Work later" pause) | Removed — `/rite:pr:open` always proceeds to implementation |
| Phase 5.1 (Implementation work) | `/rite:pr:open` Step 4 → delegates to `/rite:issue:implement` |
| Phase 5.2 (Quality checks) | `/rite:pr:open` Step 5 (`/rite:issue:implement` autonomously invokes `/rite:lint`) |
| Phase 5.3 (Draft PR creation) | `/rite:pr:open` Step 6 (invokes `/rite:pr:create` sub-skill) |
| Phase 5.4 / 5.5 (Review + fix loop) | `/rite:pr:iterate <pr>` (loops `/rite:pr:review` ⇄ `/rite:pr:fix` until convergence) |
| Phase 5.6 (Set Ready) | `/rite:pr:ready <pr>` |
| Phase 5.7 (Merge) | `/rite:pr:merge <pr>` |
| Phase 6 (Cleanup) | `/rite:pr:cleanup <pr>` (unchanged, decoupled from merge in #1136) |

The four new commands maintain the same flow-state phases (`init` / `branch` / `plan` / `implement` / `lint` / `pr` / `review` / `fix` / `ready` / `cleanup` / `ingest` / `completed` — see `hooks/flow-state.sh`), so `/rite:resume` can recover from interruptions regardless of which command was running. See [commands/resume.md](../plugins/rite/commands/resume.md) Phase 5.3 (Phase enum → Step mapping (SoT)) for the routing table.

> **Historical Phase Description (pre-#1136)**: The remainder of this section describes the previous `start.md` orchestrator's Phase 0 / 1 / 1.5 / 1.6 / 2 / 3 / 4 / 5 internals. Use it only for archaeological / migration cross-reference; the live specification is in the new pr/ commands above.

#### Phase 0: Epic/Sub-issues Detection

Uses GitHub standard features:
- Recognize Milestone feature
- Recognize Sub-issues (beta) if available
- List child Issues and prompt user selection

**Parent Issue Status Synchronization:**

When working on a child Issue, the parent Issue's status is automatically synchronized:

| Trigger | Parent Issue Status Update |
|---------|---------------------------|
| First child Issue becomes In Progress | Parent Issue → In Progress |
| All child Issues become Done | Parent Issue → Done |
| Some completed, some pending | Parent Issue stays In Progress |

This ensures the parent Issue accurately reflects the overall progress of its child Issues.

#### Phase 1: Issue Quality Verification

**Quality Score:**

| Score | Criteria |
|-------|----------|
| A | All items clear |
| B | Main items clear, some inferable |
| C | Basic info only, needs completion |
| D | Insufficient info, must complete before starting |

For C/D scores:
1. Attempt auto-completion
2. Ask user with `AskUserQuestion` if unable

#### Phase 1.5: Parent Issue Routing

Detects whether the target Issue is a parent (epic) Issue via:
1. `trackedIssues` API (GraphQL)
2. Body tasklist (`- [ ] #XX`)
3. Labels (`epic`/`parent`/`umbrella`)

If the Issue is a parent, routing logic determines the appropriate action: work on the parent directly, select a child Issue, or decompose into sub-Issues.

#### Phase 1.6: Child Issue Selection

When a parent Issue is detected, automatically selects the most appropriate child Issue to work on based on:
- Priority and dependency ordering
- Current status (skip completed/in-progress children)
- User confirmation before proceeding

#### Phase 2: Work Preparation

1. Generate branch name (per config pattern)
2. Check for existing branch (including recognized patterns from `branch.recognized_patterns` config)
3. Create branch with `git checkout -b`
4. Update GitHub Projects Status to "In Progress"
5. Assign to current Iteration (if `iteration.enabled: true` and `iteration.auto_assign: true`)
6. Initialize work memory comment

##### Phase 2.2.1: Recognized Branch Patterns

If `branch.recognized_patterns` is configured in rite-config.yml, detect existing non-Issue-numbered branches matching those patterns. When matched, the user can choose to use the existing branch or create a standard-pattern branch.

##### Phase 2.5: Iteration Assignment (Optional)

When `iteration.enabled: true` and `iteration.auto_assign: true` in rite-config.yml, automatically assigns the Issue to the current active Iteration/Sprint in GitHub Projects.

**Work Memory Comment Format:**

Add a dedicated comment to Issue, update that same comment thereafter:

```markdown
## 📜 rite Work Memory

### Session Info
- **Started**: 2025-01-03T10:00:00+09:00
- **Branch**: feat/issue-123-add-feature
- **Last Updated**: 2025-01-03T10:00:00+09:00
- **Command**: rite:issue:start
- **Phase**: phase2
- **Phase Detail**: Branch creation & setup

### Progress
- [ ] Task 1
- [ ] Task 2

### Confirmation Items
<!-- Accumulate pending questions during work. Confirm collectively at session end -->
_No confirmation items_

### Changed Files
<!-- Auto-updated -->

### Decisions & Notes
<!-- Important decisions and findings -->

### Plan Deviation Log
<!-- Record when deviating from the implementation plan -->
_No plan deviations_

### Bottleneck Detection Log
<!-- Bottleneck detection → Oracle discovery → Re-decomposition history -->
_No bottlenecks detected_

### Review Response History
<!-- Auto-recorded during review response -->
_No review responses_

### Next Steps
1. ...
```

**Phase Information:**

The Session Info section of the work memory includes phase information indicating the current work state. This information is used by `/rite:resume` for resuming work.

**Flat workflow phase (current / 11 values):**

| Phase | Phase Detail | start.md step |
|-------|--------------|---------------|
| `init` | Workflow initialised (Issue identified) | 1 |
| `branch` | Branch created, ready for plan | 2 |
| `plan` | Implementation planning in progress | 3 |
| `implement` | Implementation in progress | 4 |
| `lint` | Quality check in progress | 5 |
| `pr` | PR creation in progress | 6 |
| `review` | Review in progress | 7.1 |
| `fix` | Review-fix loop in progress | 7.2 |
| `ready` | `/rite:pr:ready` succeeded; awaiting Projects Status In Review → 完了レポート | 8.3 |
| `ready_error` | `/rite:pr:ready` failed inside e2e flow; resume routes back to ステップ 8 for retry | 8 |
| `completed` | Workflow finished | 8 終端 |

Lifecycle sub-rings (legacy granular phases — lifecycle-incomplete detection now lives in `session-end.sh`'s inline glob; see the retired Phase Transition Whitelist note below):

| Ring | Phase values |
|------|--------------|
| `/rite:pr:cleanup` | `cleanup` / `cleanup_pre_ingest` / `cleanup_post_ingest` / `cleanup_completed` |
| `/rite:wiki:ingest` | `ingest_pre_lint` / `ingest_post_lint` / `ingest_completed` |

**Legacy phase (forward-compat acceptance only — never newly written):**

Older state files may contain these names from the pre-flat sub-skill chain architecture. `commands/resume.md` Phase 3.5 整合性判定 (cross-check) resolves them to v3 enum values, then Phase 5.3 (Phase enum → Step mapping (SoT)) maps them to flat step numbers.

| Phase | Phase Detail |
|-------|--------------|
| `phase0` | Epic/Sub-Issues detection |
| `phase1` | Quality verification |
| `phase1_5_parent` | Parent Issue routing |
| `phase1_6_child` | Child Issue selection |
| `phase2` | Branch creation & setup |
| `phase2_branch` | Branch creation in progress |
| `phase2_work_memory` | Work memory initialization |
| `phase5_implementation` / `phase5_lint` / `phase5_pr` / `phase5_review` / `phase5_fix` / `phase5_post_ready` | sub-skill chain working phases (mapped to `implement` / `lint` / `pr` / `review` / `fix` / `ready` respectively) |

#### Phase 3: Implementation Planning

1. Analyze Issue content and identify target files
2. Generate implementation plan
3. User confirmation: Approve / Modify / Skip

#### Phase 4: Guidance and Continuation

After preparation, user selects:
- **Start implementation (Recommended)**: Proceed to Phase 5 for end-to-end execution from implementation to PR creation and review
- **Work later** (Removed in #1136 — pre-decomposition behavior): Pause here and resume later with `/rite:issue:start` (now `/rite:pr:open <issue_number>` followed by `/rite:resume` to recover from any stop)

#### Phase 5: End-to-End Execution

Starts when "Start implementation" is selected. The following steps are executed **continuously without interruption**:

**Flow Continuation Principle:** After each step completes, proceed to the next step without waiting for user confirmation (except where confirmation is explicitly required).

| Step | Content | Called Command |
|------|---------|----------------|
| 5.1 | Implementation work (including commit & push) | - |
| 5.2 | Quality checks | `/rite:lint` |
| 5.3 | Draft PR creation | `/rite:pr:create` |
| 5.4 | Self review | `/rite:pr:review` |
| 5.5 | Continuation based on review results | `/rite:pr:fix` (if needed) |
| 5.6 | Completion report | - |

**5.2 Quality Check Result Branching:**

| Result | Next Action |
|--------|-------------|
| Success | → Proceed to 5.3 |
| Warnings only | → Proceed to 5.3 |
| Errors found | Fix errors → Re-run 5.2 |
| Skipped | → Proceed to 5.3 (recorded in PR) |

**5.5 Review Result Branching:**

| Result | Next Action |
|--------|-------------|
| Approve | Confirm `/rite:pr:ready` execution → Proceed to 5.6 |
| Approve with conditions | Fix with `/rite:pr:fix` → Return to 5.4 |
| Request changes | Fix with `/rite:pr:fix` → Return to 5.4 |

**Review-Fix Cycle Continuation:** The `/rite:pr:review` → `/rite:pr:fix` → `/rite:pr:review` cycle continues automatically until the overall assessment is "Approve" (zero blocking findings). The loop exits only when all findings are resolved — there is no iteration limit or progressive relaxation.

**Verification mode** (`review.loop.verification_mode`, default: `false`): When explicitly enabled, from the second iteration onward, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are reported as non-blocking "stability concerns". The default `false` performs full review every iteration, maximizing review quality.

**Definition of "Approve":** Zero blocking findings.

### Automatic Work Memory Updates

Work memory is automatically updated when executing the following commands:

| Command | Auto-Update Content |
|---------|---------------------|
| `/rite:pr:open` | Initialize work memory, record implementation plan |
| `/rite:pr:create` | Record changed files, commit history, PR info |
| `/rite:pr:iterate` / `/rite:pr:fix` | Record review response history (loop counter, fix history) |
| `/rite:pr:cleanup` | Record completion info |
| `/rite:lint` | Record quality check results (conditional: only on issue branches) |

**Manual Update:**

`/rite:issue:update` remains available for manual updates when:
- Recording important design decisions
- Adding supplementary information
- Manually updating progress at specific timing
- Preparing handoff for next session

### Interruption and Resumption

If "Work later" is selected or work is interrupted:
- Branch and work memory are preserved
- Phase information (`Command`, `Phase`, `Phase Detail`) is recorded in work memory
- Use `/rite:resume` to resume work from the interrupted phase

**How to Resume:**

```
/rite:resume
```

Or specify Issue number:

```
/rite:resume <issue_number>
```

**Session Start Auto-Detection:**

When starting a session on a feature branch, the system automatically detects phase information from work memory and notifies if there is interrupted work.

**If PR Already Exists:**
- After detecting existing branch, check for PR existence
- If PR exists, option to continue review response with `/rite:pr:fix`

**Note:** `/rite:pr:create` can also be used independently for:
- Resuming after interruption
- Creating PR from existing branch
- Creating PR without linked Issue

---

### /rite:pr:review

**Description:** Dynamic multi-reviewer PR review

**Arguments:** `[PR number or branch name]` (optional, defaults to current branch)

#### Parallel Subagent Review

`/rite:pr:review` uses Claude Code's Task tool to spawn parallel subagents for each reviewer role:

```
/rite:pr:review start
 ↓
Get changed files list
 ↓
Analyze files and select appropriate reviewers
 ↓
Spawn subagents in parallel (Task tool)
 ├─ security-reviewer: Security perspective
 ├─ performance-reviewer: Performance perspective
 ├─ code-quality-reviewer: Code quality perspective
 ├─ api-reviewer: API design perspective
 ├─ database-reviewer: Database perspective
 ├─ devops-reviewer: DevOps perspective
 ├─ frontend-reviewer: Frontend perspective
 ├─ test-reviewer: Test quality perspective
 ├─ dependencies-reviewer: Dependencies perspective
 ├─ prompt-engineer-reviewer: Prompt quality perspective
 ├─ tech-writer-reviewer: Documentation perspective
 ├─ error-handling-reviewer: Error handling perspective
 └─ type-design-reviewer: Type design perspective
 ↓
Collect results from each subagent
 ↓
Integrate results for overall assessment
 ↓
Output review results
```

**Benefits:**
- Improved context efficiency (each subagent has focused context)
- Parallel execution for faster reviews
- Specialized expertise per review area
- Automatic reviewer selection based on changed files

**Reviewer Selection:**

Reviewers are automatically selected based on file patterns and content analysis. Not all reviewers are invoked for every PR - only relevant ones are selected.

**Fallback:** If a subagent fails or times out, the review continues with remaining subagents, and the failure is noted in the summary.

See "[Dynamic Reviewer Generation](#dynamic-reviewer-generation)" section for additional details.

---

### /rite:pr:fix

**Description:** Address review feedback on PR

**Arguments:** `[PR number]` (optional, defaults to current branch's PR)

#### Phase 1: Review Comment Retrieval

1. Identify PR (from argument or current branch)
2. Fetch review comments using GitHub API
3. Classify comments:
 - **Changes Requested**: From `CHANGES_REQUESTED` reviews or unresolved threads
 - **Suggestions/Questions**: Improvement proposals or unanswered questions
 - **Resolved**: Already resolved threads
4. Display organized list of unresolved comments

#### Phase 2: Response Support

For each unresolved comment:

1. Show comment details (file, line, content, reviewer)
2. Prompt user for response type:
 - Fix the code
 - Reply only (no changes needed)
 - Skip (address later)
3. If fixing code:
 - Read affected file
 - Suggest fix based on comment
 - Apply fix with Edit tool
4. Optionally create reply to reviewer

#### Phase 3: Fix Commit

1. Review all changes made
2. Generate commit message based on addressed comments
3. Commit changes with appropriate message
4. Optionally push to remote

#### Phase 4: Completion Report

1. Optionally resolve addressed threads (GraphQL mutation)
2. Optionally post summary comment on PR
3. Update work memory with fix history
4. Display completion summary with next steps

---

### /rite:pr:cleanup

**Description:** Automate post-PR-merge cleanup tasks

**Arguments:** `[branch name]` (optional, defaults to current branch)

#### Phase 1: State Verification

1. Check current branch
2. Find related PR and verify merge status
3. Identify related Issue from PR body or branch name

**If PR is not merged:**
- Warn user about potential data loss
- Offer options: Cancel (recommended) or Force cleanup

#### Phase 2: Cleanup Execution

1. Switch to main branch
2. Pull latest main
3. Delete local branch (`git branch -d`)
4. Delete remote branch if exists (`git push origin --delete`)

**On uncommitted changes:**
- Offer to stash changes before cleanup

#### Phase 3: Projects Status Update

1. Get Project configuration from `rite-config.yml`
2. Find Issue's Project item
3. Update Status to "Done"
4. Add completion record to work memory comment

#### Phase 4: Completion Report

```
Cleanup completed

PR: #{pr_number} - {pr_title}
Related Issue: #{issue_number}
Status: Done

Completed tasks:
- [x] Switched to main branch
- [x] Pulled latest main
- [x] Deleted local branch {branch_name}
- [x] Deleted remote branch
- [x] Updated Projects Status to Done
- [x] Finalized work memory

Next steps:
1. `/rite:issue:list` to check next Issue
2. `/rite:pr:open <issue_number>` to start new work
```

---

## Iteration/Sprint Management (Optional)

Sprint management feature using GitHub Projects Iteration field.

### Overview

- **Optional Feature**: Disabled by default (`iteration.enabled: false`)
- **Manual Setup**: Iteration field must be created manually in GitHub Web UI (gh CLI not supported)
- **Graceful Degradation**: Other features work normally when Iteration is disabled

### Feature Comparison

| Aspect | Iteration Disabled | Iteration Enabled |
|--------|-------------------|-------------------|
| Issue Creation | Status/Priority/Complexity fields | + Sprint assignment option |
| Issue Start | Branch creation, Status update | + Auto-assign to current Sprint |
| Issue List | Filter by Status/Priority | + Sprint/Backlog filters |
| Available Commands | 12 core commands | + 3 Sprint commands |
| Planning Style | Ad-hoc | Sprint-based planning |
| Progress Visibility | By Status only | + By Sprint progress |

### Configuration

```yaml
# rite-config.yml
iteration:
 enabled: false # Set true to enable
 field_name: "Sprint" # Iteration field name
 auto_assign: true # Auto-assign on /rite:pr:open
 show_in_list: true # Show Iteration column in issue:list
```

### Sprint Commands

| Command | Description |
|---------|-------------|
| `/rite:sprint:list` | List all Iterations |
| `/rite:sprint:current` | Current sprint details |
| `/rite:sprint:plan` | Sprint planning (assign Issues from backlog) |

### Iteration Support in Existing Commands

| Command | Iteration Feature |
|---------|-------------------|
| `/rite:init` | Iteration field detection & setup guide |
| `/rite:pr:open` | Auto-assign to current iteration when starting work |
| `/rite:issue:create` | Iteration assignment option on creation |
| `/rite:issue:list` | `--sprint current`, `--backlog` filters |

### Current Iteration Detection

```
1. Get today's date
2. For each iteration:
 - endDate = startDate + duration (days)
 - startDate <= today < endDate → "current"
3. No match → next iteration (or null)
```

### Technical Constraints

- **Iteration field auto-creation**: Not possible (gh CLI doesn't support ITERATION data type)
- **Iteration field operations**: Available via GraphQL API

---

## Hook Specification

### Supported Hook Types

> **Canonical SoT**: The authoritative list of registered hook events lives in [`plugins/rite/hooks/hooks.json`](../plugins/rite/hooks/hooks.json). This table mirrors that registration; if the two diverge, `hooks.json` wins. The table below is enumerated for reader convenience but MUST be regenerated from `hooks.json` keys (`jq '.hooks | keys[]' plugins/rite/hooks/hooks.json`) whenever the registration changes.

| Type | Timing | Purpose |
|------|--------|---------|
| SessionStart | Session start | Load work memory, detect interrupted work |
| PreCompact | Before compact | Save work memory, record compact state |
| PostCompact | After compact | Restore work memory, clean compact state |
| SessionEnd | Session end | Save final state |
| PreToolUse | Before tool execution | Block tool usage after compact, detect dangerous command patterns |
| PostToolUse | After tool execution | Auto-recover local work memory |

> **Note:** `notification.sh` is not a Claude Code hook type but a utility script called directly from within commands. It is invoked by command scripts during events such as PR creation, Ready status change, and Issue close to send external notifications. See the [Notification Integration](#notification-integration) section for details.
>
> **Note:** The Stop hook (`stop-guard.sh`) has been removed. Workflow stop prevention is now handled by the per-session state structure (`.rite/sessions/{session_id}.flow-state`) and the orchestrator-level scaffolding contract (Pre-write + 🚨 Mandatory After). See the [Multi-Session State Management](#multi-session-state-management) section for details.

### Hook Execution Order

```
SessionStart
 ↓
PreToolUse → Tool Execution → PostToolUse
 ↓
PreCompact (on compact)
 ↓
SessionEnd
```

> **Note:** PreToolUse and PostToolUse fire on every Claude Code tool invocation. PreCommand/PostCommand have been deprecated and replaced by the Preflight check system integrated into command execution.

### Preflight Check (`preflight-check.sh`)

Pre-validation script called before every `/rite:*` command execution. Detects blocked state after compact and controls command execution.

**Behavior:**

1. Reads `.rite-compact-state` (if file doesn't exist, allows execution)
2. If `compact_state` is `normal` or `resuming`, allows execution
3. If the command is `/rite:resume`, always allows execution
4. All other commands are blocked (exit 1)

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Allowed (continue command execution) |
| 1 | Blocked (do not execute command) |

**Usage:**

```bash
bash plugins/rite/hooks/preflight-check.sh --command-id "/rite:pr:open" --cwd "$PWD"
```

### Post-Compact Recovery (`post-compact.sh`) (#133)

Registered as a PostCompact hook. After a compact event, restores workflow context by outputting the current per-session flow state (`.rite/sessions/{session_id}.flow-state`) and work-memory state to stdout, which Claude Code injects into the model's context so the workflow can auto-continue without user intervention.

**Behavior:**

1. Reads `.rite-compact-state` and the per-session flow state file under the resolved state root (delegates resolution to `state-path-resolve.sh`; see [Multi-Session State Management](#multi-session-state-management))
2. If no flow state exists, cleans `.rite-compact-state` and exits 0 (self-healing for orphaned compact markers)
3. Otherwise, emits a recovery block to stdout containing Issue number, phase, and next-action hints so the orchestrator can resume from the compact boundary
4. Double-execution is guarded via `_RITE_HOOK_RUNNING_POSTCOMPACT` (hooks.json + legacy `settings.local.json` migration safety)

**Self-Healing Mechanism:**

If the workflow has ended but `.rite-compact-state` remains (e.g., due to crash), the hook cleans it up and exits silently so that a fresh session is not blocked.

### Pre-Tool Bash Guard (`pre-tool-bash-guard.sh`)

Registered as a PreToolUse hook. Blocks known incorrect Bash command patterns that the LLM repeatedly generates before execution.

**Blocked Patterns:**

| Pattern | Reason | Alternative |
|---------|--------|-------------|
| `gh pr diff --stat` | `--stat` flag is unsupported | `gh pr view {n} --json files --jq '.files[]'` |
| `gh pr diff -- <path>` | File filter is unsupported | `gh pr diff {n} \| awk` for filtering |
| 「!= null」 (in jq/awk) | Bash history expansion interprets 「!」 | `select(.field)` or `select(.field == null \| not)` |

**Heredoc Safety:**

To prevent false positives from text in heredocs (commit messages, PR descriptions, etc.), only the command portion before `<<` is inspected.

### Post-Tool WM Sync (`post-tool-wm-sync.sh`)

Registered as a PostToolUse hook. Automatically creates local work memory files when they are missing during an active workflow.

**Behavior:**

1. Fires after Bash tool usage (with recursion guard)
2. Retrieves active workflow and Issue number from the per-session flow state file (`.rite/sessions/{session_id}.flow-state`)
3. Only creates `.rite-work-memory/issue-{n}.md` if it doesn't exist

**Purpose:** Guarantees auto-recovery of local work memory during `/rite:resume` after compact or session restart.

### Local WM Update (`local-wm-update.sh`)

Standalone wrapper script for updating local work memory files. Automatically resolves the plugin root via `BASH_SOURCE`.

**Usage:**

```bash
WM_SOURCE="implement" WM_PHASE="lint" \
 WM_PHASE_DETAIL="Quality check prep" \
 WM_NEXT_ACTION="Run rite:lint" \
 WM_BODY_TEXT="Post-implementation." \
 WM_ISSUE_NUMBER="866" \
 bash plugins/rite/hooks/local-wm-update.sh
```

**Environment Variables:**

| Variable | Required | Description |
|----------|----------|-------------|
| `WM_SOURCE` | Yes | Update source identifier (`init`, `implement`, `lint`, etc.) |
| `WM_PHASE` | Yes | Current phase (`lint`, `implement`, `pr`, etc.; see `PHASE_ENUM_V3` in `flow-state.sh`) |
| `WM_PHASE_DETAIL` | Yes | Detailed phase description |
| `WM_NEXT_ACTION` | Yes | Next action |
| `WM_BODY_TEXT` | Yes | Update content text |
| `WM_ISSUE_NUMBER` | Yes | Issue number |

### Work Memory Lock (`work-memory-lock.sh`)

Shared library script providing `mkdir`-based lock/unlock functionality. Used by sourcing from other scripts.

**Provided Functions:**

| Function | Description |
|----------|-------------|
| `acquire_wm_lock <lockdir> [timeout]` | Acquire lock (with timeout, default: 50 iterations × 100ms = 5 seconds) |
| `release_wm_lock <lockdir>` | Release lock |
| `is_wm_locked <lockdir>` | Check lock status |

**Stale Lock Detection:**

If a lock's `mtime` exceeds the threshold (default: 120 seconds), the PID file is checked to verify process liveness. If the process has terminated, the lock is automatically released.

### Phase Transition Whitelist (retired)

> **Status: Retired**. The `phase-transition-whitelist.sh` library (and its `phase-transition-whitelist.test.sh` suite) were removed in the v2→v3 migration (see [`docs/migration-guides/v2-to-v3.md`](migration-guides/v2-to-v3.md)). The canonical phase enum is now `PHASE_ENUM_V3` in `flow-state.sh` (`init branch plan implement lint pr review fix ready ready_error cleanup ingest completed`), validated by its `_phase_is_valid` helper; legacy phase names are resolved by `_phase_migrate` plus the `/rite:resume` cross-check rather than a transition graph.

Lifecycle-incomplete detection for the legacy `create_*` / `cleanup_*` phases now lives inline in `session-end.sh` (the `[[ "$_state_phase" == create_* ]]` / `cleanup_*` glob branches). The former `rite_phase_is_create_lifecycle_in_progress` / `rite_phase_is_cleanup_lifecycle_in_progress` predicates no longer exist, so the `type … >/dev/null` guard in that hook always falls through to the inline glob, which is the sole active path (pinned by `session-end.test.sh` TC-475-WARN-A〜D / TC-608-WARN-A〜E). The `rite_phase_transition_allowed` / `rite_phase_expected_next` / `rite_phase_is_known` functions and the `hooks.stop_guard.phase_transitions` override merging they backed are gone — no current hook, script, or template reads that config key.

### Verify Terminal Output (retired)

> **Status: Retired**. The standalone `verify-terminal-output.sh` check was removed when `/rite:issue:create` was flattened into a single file. The Terminal Completion HTML-comment wrap contract is still required (`<!-- [create:completed:{…}] -->`), but enforcement now lives inline in `commands/issue/create.md` ステップ 4.4 / ステップ 5.6 and is exercised via `start-md-sentinel-coverage.test.sh` / `create-md-invocation-symmetry.test.sh` rather than a standalone hook.

### Session Ownership (`session-ownership.sh`) (#174–#179)

Shared library sourced by the lifecycle hooks for multi-session conflict prevention. With the per-session state structure (#672 / Issue #685 / PR #686 + #747 + #748 + #750 + #751 + #756 + #757 + #759), ownership is **structurally guaranteed** by the file naming (`.rite/sessions/{session_id}.flow-state`); this library now serves as a path/entry resolution layer rather than a runtime guard.

> **Canonical SoT for sourcing callers**: actual `source` directives in `plugins/rite/hooks/*.sh` (verify with `grep -rn "source.*session-ownership.sh" plugins/rite/hooks/ --include='*.sh' | grep -v tests/`). At present this resolves to: `session-start.sh` / `session-end.sh` / `pre-compact.sh` / `post-tool-wm-sync.sh`. (`flow-state.sh` is NOT a `source` caller of this library — it sources only `state-path-resolve.sh`. `stop-guard.sh` has been removed; `post-compact.sh` does not source this library directly. `pre-tool-bash-guard.sh` resolves `STATE_FILE_PATH` via `_resolve-flow-state-path.sh` and has never been a `source` caller of this library.)

**Provided Functions:**

| Function | Purpose |
|----------|---------|
| `extract_session_id <hook_json>` | Pulls `session_id` from a hook's JSON stdin payload |
| `get_state_session_id <file>` | Reads `session_id` from a per-session flow state file |
| `check_session_ownership <hook_json> <state_file>` | Returns `own` / `legacy` / `other` / `stale` (legacy / other / stale are now mostly unreachable in steady-state operation because file naming structurally enforces `own`; retained for migration compatibility and crash-recovery scenarios) |
| `parse_iso8601_to_epoch <timestamp>` | Cross-platform ISO 8601 → epoch parser |

### Issue Comment WM Sync (`issue-comment-wm-sync.sh`) (#161 / #167)

Registered as a PostToolUse hook. Synchronizes work-memory updates into the Issue comment when a phase change is detected. Delegates deterministic JSON/body construction to `issue-comment-wm-update.py` to avoid fragile inline jq + atomic-write patterns.

### Wiki Ingest Trigger (`wiki-ingest-trigger.sh`) and Wiki Query Inject (`wiki-query-inject.sh`)

A pair of hooks that automate Experience Wiki integration (opt-out via `wiki.enabled: false`).

| Hook | Trigger | Action |
|------|---------|--------|
| `wiki-ingest-trigger.sh` | `pr/review.md` Phase 5.4.3 (post review), `pr/fix.md` Phase 5.4.6 (post fix), `commands/issue/close.md` (Issue close) | Writes a raw-source file under `.rite/wiki/raw/{type}/` on the dev branch working tree. Pure file writer, no git operations. |
| `wiki-query-inject.sh` | start.md ステップ 2.6 (work memory init), `implement.md` Phase 5.0.W, `pr/review.md` Phase 4.0.W, `pr/fix.md` Phase 0.5.W | Runs `/rite:wiki:query` against the current Issue title/body and injects matching heuristics. Reads via `origin/{wiki_branch}` when the local wiki branch is absent (fresh clone / separate worktree). |

See [Experience Wiki](#experience-wiki) for the full Phase X.X.W contract and the separate `wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` helpers that actually commit + push raw sources onto the wiki branch.

### Hook Preamble (`hook-preamble.sh`)

Sourced at the top of most hooks to perform shared pre-processing: plugin-root resolution via `.rite-plugin-root`, `RITE_DEBUG` log setup, and double-execution guard bookkeeping. Hooks that need to read stdin must source it *after* capturing stdin to avoid consumption conflicts.

### Helper Scripts (`hooks/scripts/`)

Non-hook helper scripts invoked either directly from orchestrator commands or by other hooks:

| Script | Purpose | Related Issue |
|--------|---------|---------------|
| `wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` / `wiki-worktree-setup.sh` | Stash-based single-process commit + push of raw sources onto the `wiki` branch | #524 refactor |
| `wiki-growth-check.sh` | `/rite:lint` Phase 3.8 layer-3 warn when `wiki.growth_check.threshold_prs` PRs accumulate without a wiki commit | #524 / #536 |
| `backlink-format-check.sh` | Bidirectional backlink format verification for Wiki pages | #627 |
| `bang-backtick-check.sh` | Detect bash history-expansion pitfalls in generated content | — |
| `distributed-fix-drift-check.sh` | Catch inconsistent partial application of the same fix across files | `review.loop.pre_commit_drift_check` |
| `doc-heavy-patterns-drift-check.sh` | Detect Doc-Heavy PR Mode drift signals | #349 |
| `gitignore-health-check.sh` | Verify the `.rite/wiki/` last-line-of-defense `.gitignore` rule, emit `gitignore_drift` sentinel on mismatch | #564 / #567 |

---

## Features

### TDD Light Mode

A lightweight TDD mode that auto-generates test skeletons from acceptance criteria, preparing test structure before implementation.

**Configuration:**

```yaml
# rite-config.yml
tdd:
 mode: "off" # off | light (default: off)
 tag_prefix: "AC" # Tag prefix for test markers
 run_baseline: true # Run baseline tests before skeleton generation
 max_skeletons: 20 # Maximum skeletons per Issue
```

**Workflow:**

1. Analyze Issue acceptance criteria
2. Assign hashtags (`AC[a1b2c3d4]`) to each criterion
3. Generate test skeletons (with `skip` / `pending` / `todo` markers)
4. Fill in skeletons sequentially during implementation

### Preflight Check System

A system that performs unified pre-validation before every `/rite:*` command execution. Prevents command execution in invalid states after compact.

**How It Works:**

- Each command calls `preflight-check.sh` at its start
- Compact state is managed via the `.rite-compact-state` file
- In `blocked` state, all commands except `/rite:resume` are blocked
- Normal state is restored via `/clear` → `/rite:resume`

### Multi-Session State Management

> **Design rationale**: See [`docs/designs/multi-session-state.md`](designs/multi-session-state.md) for the full design selection (6-axis trade-off comparison, Option A vs B Decision Log, and Phase 2 implementation retrospective). This section is the canonical **runtime specification**; the design doc is the canonical **rationale** record.

The flow state for `/rite:*` workflows uses a **per-session file** structure (`.rite/sessions/{session_id}.flow-state`) introduced by Issue #672 and landed across PR #686 / #747 / #748 + #756 / #750 / #751 / #757 / #759. Each Claude Code session writes only to its own file, so concurrent sessions on the same repository are structurally race-free without lock acquisition.

**File path:**

```
.rite/
└── sessions/
 ├── 34eadf04-8f13-4ce3-adcd-8dc6668a5b9f.flow-state
 ├── 9a8b7c6d-...flow-state
 └── ...
```

The `session_id` is the same UUID stored in `.rite-session-id` and propagated to every hook via the JSON stdin payload.

**Schema (`schema_version: 3`):**

| Category | Field | Source / Writer | Notes |
|----------|-------|-----------------|-------|
| Required (10) | `active` | `flow-state.sh set` | `true` while a workflow is in flight |
| Required | `issue_number` | `flow-state.sh set` | The Issue under work |
| Required | `branch` | `flow-state.sh set` | Feature branch name |
| Required | `phase` | `flow-state.sh set` | Current orchestrator phase (flat enum: `init` / `branch` / `plan` / `implement` / `lint` / `pr` / `review` / `fix` / `ready` / `ready_error` / `cleanup` / `ingest` / `completed`) |
| Required | `pr_number` | `flow-state.sh set` | `0` until the PR is opened |
| Required | `parent_issue_number` | `flow-state.sh set` | `0` when the Issue is standalone |
| Required | `next_action` | `flow-state.sh set` | Free-text continuation hint surfaced via post-compact recovery |
| Required | `updated_at` | `flow-state.sh set` (every write) | ISO 8601 UTC with `Z` suffix; generated by `date -u +"%Y-%m-%dT%H:%M:%SZ"` (cross-platform deterministic). Note: human-facing logs elsewhere may be JST; the persisted state field is UTC |
| Required | `session_id` | `flow-state.sh set` | Mirrors `.rite-session-id`, used as filename |
| Required | `last_synced_phase` | `flow-state.sh set` (merge-preserves existing value) / `post-tool-wm-sync.sh` (actual writer on phase diff via `jq '.last_synced_phase = $p'`) | Tracks the last work-memory sync point. `flow-state.sh set` merge-preserves but does not author this field — only the per-tool sync hook does (verify with `grep -n last_synced_phase plugins/rite/hooks/*.sh`) |
| Optional | `wm_comment_id` | `issue-comment-wm-sync.sh` (cache write) | GitHub comment ID for the work memory backup |
| Optional | `loop_count` | **Reader-only legacy field** — no production writer in `flow-state.sh` (verify with `grep -n loop_count plugins/rite/hooks/flow-state.sh` → 0 hits). Consumers (`post-compact.sh` / `session-start.sh` / `state-read.sh`) read it as best-effort; `work-memory-update.sh` increments the work-memory document copy, not the flow-state field. Schema slot retained for forward compatibility | Review-fix loop counter |
| Optional | `error_count` | `flow-state.sh set` (resets to `0` on phase transition; `--preserve-error-count` retains the existing value) | Half-legacy field — incrementer was removed with `stop-guard.sh`; writer is reset-only. Schema retained for forward compatibility |
| Optional | `schema_version` | `flow-state.sh set` | `3` for the per-session structure; absent or `!= 3` triggers migration |

> **`needs_clear` field**: Removed. The previous compact-recovery design discussed `needs_clear` as a flag, but production code never had a writer or non-test reader. Test fixtures (`pre-compact.test.sh` TC-014 / TC-014b) actively assert that `pre-compact does NOT set needs_clear`. The new schema does not include this field.

> **`previous_phase` field**: Removed in the v2→v3 migration. The v2 schema auto-populated it from the outgoing `phase` value, but v3 discriminates resume routing by step-name mapping (`commands/resume.md`) instead. `cmd_set` no longer writes it (verify with `grep -n previous_phase plugins/rite/hooks/flow-state.sh`), and `_migrate_file` strips it from migrated files via `del(.previous_phase)`.

**Migration from legacy single-file format:**

Legacy state files (flat JSON without `schema_version`, or any file with `schema_version != 3`) are auto-migrated to v3 on session start by [`flow-state.sh migrate`](../plugins/rite/hooks/flow-state.sh) — the `cmd_migrate` / `_migrate_file` path — invoked from [`session-start.sh`](../plugins/rite/hooks/session-start.sh). `_migrate_file` rewrites each file **in place** via `mktemp + flock + atomic mv` (`_atomic_write`): it strips the legacy `previous_phase` field, normalizes `branch_name` → `branch`, reduces the legacy `phase` value to the v3 enum, bumps `schema_version` to `3`, and refreshes `updated_at`, while preserving `last_synced_phase`. There is no separate `.rite-flow-state.legacy.{timestamp}` backup — the rewrite is in place. A performed migration always prints an explicit `migrated:` line to stderr (unconditional, not gated on `--verbose`, so the session-start auto path surfaces it — silent skip is forbidden, AC-8); the no-op already-v3 case stays quiet unless `--verbose`. The `--dry-run` preview (`would migrate:`) also goes to stderr for symmetry with the `migrated:` announcement, so dry-run output surfaces alongside real migrations under the session-start stdout-only silence policy. The phase reduction matrix and the manual `--dry-run` fallback are documented in [`docs/migration-guides/v2-to-v3.md`](migration-guides/v2-to-v3.md); the multi-session atomicity / glob-collision rationale is in [`docs/designs/multi-session-state.md`](designs/multi-session-state.md#migration-戦略).

**Rollback strategy:**

`rite-config.yml` accepts `flow_state.schema_version: 1` to force the legacy code path (adapter pattern). The dual logic is intended to be removed after a soak period (target: v0.5.0).

**Sub-Issues API parent-child structure:**

The Issue series that delivered this feature (#672 epic with children #678 / #679 / #680 / #681 / #682 / #683 / #684 / #685 + follow-up #749) used GitHub's native Sub-Issues API to maintain the parent-child relation. `/rite:pr:open` Step 1.2 (previously `start.md` Phase 0.3 before the #1136 decomposition) detects parent Issues via three OR-combined methods (trackedIssues API → body tasklist `- [ ] #N` → label-based `epic`/`parent`/`umbrella`), and the child→parent Status promotion (Todo → In Progress) is propagated in the same OR-combined order (`## 親 Issue` body meta → Sub-Issues API `trackedInIssues` → tasklist search) from the same step.

> **Hook list canonical SoT**: The hooks that read or write per-session state are registered in [`plugins/rite/hooks/hooks.json`](../plugins/rite/hooks/hooks.json) — currently 6 events (`SessionStart` / `SessionEnd` / `PreCompact` / `PostCompact` / `PreToolUse` / `PostToolUse`). To re-enumerate the live registration, run `jq '.hooks | keys[]' plugins/rite/hooks/hooks.json`. The `Stop` event has been removed and is not part of the current registration. The library script `session-ownership.sh` is sourced (not registered) and therefore does not appear in `hooks.json`.

### Local Work Memory + Compact Resilience

In addition to Issue comment backups, work memory is maintained on the local filesystem. This ensures resilience against context compaction.

**Architecture:**

| Component | Role | Location |
|-----------|------|----------|
| Local work memory (SoT) | Source of truth | `.rite-work-memory/issue-{n}.md` |
| Issue comment (backup) | Cross-session backup | GitHub Issue comment |
| Flow state | Workflow control | `.rite/sessions/{session_id}.flow-state` (per-session; see [Multi-Session State Management](#multi-session-state-management)) |
| Compact state | Post-compact state management | `.rite-compact-state` |

**Local Work Memory Features:**

- Exclusive access control via `mkdir`-based locking
- Auto-recovery through PostToolUse hook
- State restoration from the per-session flow state file possible even after compact

### Implementation Contract Issue Format

A format that includes an Implementation Contract section in Issues generated by `/rite:issue:create`. Separates high-level design from specification and detailed implementation steps.

**Structure:**

- **Phase 0.7 (Specification generation)**: Generates high-level What/Why/Where design in `docs/designs/`
- **Phase 3 (Implementation plan)**: Generates detailed How steps as a dependency graph
- Issue body checklist tracks progress

### Complexity-Based Question Filtering

A mechanism that dynamically adjusts the number of questions based on Issue complexity during `/rite:issue:create`'s deep-dive interview (Phase 0.5).

**Filtering Rules:**

| Complexity | Questions | Scope |
|------------|-----------|-------|
| XS-S | Minimal (1-2) | What/Why only |
| M | Standard (3-4) | What/Why/Where/Scope |
| L-XL | Detailed (5+) | All items + decomposition proposal |

### Shell Script Test Framework

A test framework for ensuring Hook script quality. Located in `plugins/rite/hooks/tests/`.

**Test Targets (excerpt — see `hooks/tests/` for the full suite):**

| Script | Test Content |
|--------|-------------|
| `preflight-check.sh` | Command blocking by compact state |
| `post-compact.sh` | Recovery context emission, `.rite-compact-state` self-healing |
| `pre-compact.sh` | State capture before compact |
| `pre-tool-bash-guard.sh` | Dangerous pattern detection, heredoc safety |
| `post-tool-wm-sync.sh` | Work memory auto-recovery after Bash tool calls |
| `session-start.sh` / `session-end.sh` | Session lifecycle + ownership transitions |
| `work-memory-lock.sh` | Lock acquire/release + stale detection |
| `wiki-ingest-trigger.sh` | Raw-source write contract |
| `parent-child-sync-static` | Parent/child Issue state synchronization |
| `notification.sh` | Notification dispatcher contract |

**Execution:**

```bash
bash plugins/rite/hooks/tests/run-tests.sh
```

---

## Notification Integration

### Slack

```yaml
notifications:
 slack:
 enabled: true
 webhook_url: "https://hooks.slack.com/services/..."
```

### Discord

```yaml
notifications:
 discord:
 enabled: true
 webhook_url: "https://discord.com/api/webhooks/..."
```

### Microsoft Teams

```yaml
notifications:
 teams:
 enabled: true
 webhook_url: "https://outlook.office.com/webhook/..."
```

### Notification Events

| Event | Description |
|-------|-------------|
| `pr_created` | When PR created |
| `pr_ready` | When Ready for review |
| `issue_closed` | When Issue closed |

---

## Build/Test/Lint Auto-Detection

### Detection Priority

1. **Explicit specification in rite-config.yml**
2. **package.json scripts**
 - Detect `build`, `test`, `lint`
3. **Makefile targets**
4. **Standard file structure inference**

### Language/Framework Detection

| File | Language/FW | Build | Test | Lint |
|------|-------------|-------|------|------|
| `package.json` | Node.js | `npm run build` | `npm test` | `npm run lint` |
| `pyproject.toml` | Python | `python -m build` | `pytest` | `ruff check` |
| `Cargo.toml` | Rust | `cargo build` | `cargo test` | `cargo clippy` |
| `go.mod` | Go | `go build` | `go test` | `golangci-lint` |
| `pom.xml` | Java | `mvn package` | `mvn test` | `mvn checkstyle:check` |

### Fallback Behavior When Commands Not Detected

When build/test/lint commands cannot be detected, the workflow provides interactive options instead of terminating:

**Options presented via `AskUserQuestion`:**

| Option | Description |
|--------|-------------|
| **Skip and continue (Recommended)** | Skip the command and proceed to the next step. Record the skip in PR body under "Known Issues" |
| **Specify command** | User manually enters the command to execute |
| **Abort** | Terminate the process and guide user to configure settings |

**Skip behavior:**
- The skip is recorded in the conversation context
- When `/rite:pr:create` is called, the "Known Issues" section includes the skipped command
- The end-to-end flow (`/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:ready` → `/rite:pr:merge`) continues without interruption

**Command specification behavior:**
- The specified command is used for the current execution only
- Configuration is not automatically saved to `rite-config.yml`
- User is guided to use `/rite:init` or manual editing for permanent configuration

---

## Dynamic Reviewer Generation

### Overview

Analyze PR changes and dynamically generate appropriate reviewers.

### Reviewer Selection Logic

#### Step 1: File Type Analysis

| File Pattern | Recommended Reviewer |
|--------------|---------------------|
| `**/security/**`, `auth*`, `crypto*` | Security Expert |
| `.github/**`, `Dockerfile`, `*.yml` (CI) | DevOps Expert |
| `**/*.md`, `docs/**` | Technical Writer |
| `**/*.test.*`, `**/*.spec.*` | Test Expert |
| `**/api/**`, `**/routes/**` | API Design Expert |

#### Step 2: Content Analysis

LLM analyzes diff content to determine:
- Change complexity
- Required expertise
- Potential risk areas

#### Step 3: Dynamic Reviewer Count

| Condition | Reviewers |
|-----------|-----------|
| Single file, <10 lines | 1 |
| Multiple files, <100 lines | 2-3 |
| Large changes, security-related | 4-5 |

### Dynamically Generated Reviewer Profiles

- **Security Expert**: Vulnerabilities, authentication, encryption
- **Performance Expert**: Optimization, memory usage
- **Accessibility Expert**: WCAG compliance, screen reader support
- **Technical Writer**: Documentation quality, consistency
- **Architect**: Design patterns, dependencies
- **DevOps Expert**: CI/CD, infrastructure, deployment

### Review Result Format

```markdown
## 📜 rite Review Results

### Overall Assessment
- **Recommendation**: Approve / Approve with conditions / Request changes

### Individual Reviewer Assessments

#### Security Expert
- **Assessment**: Approve
- **Comments**: No issues with authentication logic

#### Performance Expert
- **Assessment**: Approve with conditions
- **Comments**: Potential N+1 query (L45-52)

...
```

---

## Workflow Failure Surfacing

### Overview

When a step of the end-to-end flow (`/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:ready` → `/rite:pr:merge`) fails or is skipped (Skill load failure, hook abnormal exit, Wiki ingest skip/failure, `.gitignore` drift, etc.), the relevant script or hook emits a plain `WARNING` / `ERROR` line to **stderr**. The orchestrator LLM surfaces these in the conversation context, and the user resolves them by re-running the affected step via `/rite:resume`.

> **History (PR 2b, #1088)**: An earlier design (#366) auto-detected these as "workflow incidents" — each failure path emitted a `[CONTEXT] WORKFLOW_INCIDENT=1; ...` sentinel via a dedicated `workflow-incident-emit.sh` hook, which the (then-current) `/rite:issue:start` orchestrator's ステップ 8.5 grepped from the conversation context to auto-register the blocker as a Todo Issue (`AskUserQuestion` confirmation, per-session dedupe, `workflow_incident.enabled` opt-out). The entire mechanism — the emit hook, the ステップ 8.5 detection logic, the `workflow_incident:` config key, and the sentinel format — was removed in favor of the single-layer plain-stderr design described above. The `/rite:issue:start` orchestrator itself was subsequently decomposed in #1136 (see the [Retired section](#riteissuestart-retired-in-1136) above). Failures are now visible but no longer auto-registered; the user decides whether to file an Issue.

### Reviewer-Triggered Issue Creation (Removed in #1136)

A previous "Phase 7" mechanism in `fix.md` Phase 4.3 ("Automatic Separate Issue Creation") used to call `plugins/rite/scripts/create-issue-with-projects.sh` directly on user-approved reviewer "別 Issue として作成" recommendations (`source: pr_review`). The entire mechanism (Phase 4.3, the `[fix:issues-created:N]` sentinel, the `review.separate_issue_creation.*` config keys) was removed in #1136. Reviewer recommendations are now handled in-loop only — the user picks one of `fix code` / `accept (acknowledge only)` / `reply only` from the Phase 2.1 menu, and any concerns that warrant a separate Issue must be filed manually via `/rite:issue:create` (use `/rite:investigate` first if a fact-check is needed). The `scripts/create-issue-with-projects.sh` helper is still the canonical Issue-creation path for manual invocations.

## Experience Wiki

### Overview

The Experience Wiki is an LLM-driven project knowledge base that persists **experiential heuristics** — the "what we learned the hard way" lessons that usually live only in reviewer heads or scattered across Issue/PR comments. It is based on the LLM Wiki pattern (Karpathy). The full design rationale lives in `docs/designs/experience-heuristics-persistence-layer.md`.

Wiki is **opt-out** by default (`wiki.enabled: true`). Configuration lives under the `wiki:` section of `rite-config.yml` — see [Configuration Reference → wiki](CONFIGURATION.md#wiki).

### Architecture

Wiki data is stored in a dedicated branch (default: `wiki`) or inline on the working branch, controlled by `wiki.branch_strategy`. Each Wiki page is a Markdown file keyed by topic (e.g., `review-quality.md`, `fix-cycle-convergence.md`). Pages are built up incrementally from raw sources (review comments, fix outcomes, Issue discussions) through an ingest pipeline that deduplicates and merges overlapping heuristics.

### Commands

| Command | Purpose |
|---------|---------|
| `/rite:wiki:init` | One-time setup: create the Wiki branch (if `branch_strategy: "separate_branch"`), scaffold directory structure, and install page templates |
| `/rite:wiki:ingest` | Parse raw sources (review results, fix outcomes, closed Issues) and update or create Wiki pages. Invoked manually or automatically by the `wiki-ingest-trigger.sh` hook |
| `/rite:wiki:query` | Search Wiki pages by keyword and inject matching heuristics into the conversation context. Invoked manually or automatically by the `wiki-query-inject.sh` hook at Issue start / review / fix / implement phases |
| `/rite:wiki:lint` | Check Wiki pages for contradictions, staleness, orphans (pages with no cross-refs), missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs. Supports `--auto` mode for CI-style batch runs |

### Automatic Hook Integration

When `wiki.auto_ingest`, `wiki.auto_query`, or `wiki.auto_lint` are enabled, the following hooks fire without user action:

| Hook | Trigger | Action |
|------|---------|--------|
| `wiki-query-inject.sh` | start.md ステップ 2.6 (work memory init), `implement.md` Phase 5.0.W, `pr/review.md` Phase 4.0.W, `pr/fix.md` Phase 0.5.W | Run `/rite:wiki:query` against the current Issue title/body and inject matching heuristics |
| `wiki-ingest-trigger.sh` | `pr/review.md` Phase 5.4.3 (post review), `pr/fix.md` Phase 5.4.6 (post fix), `commands/issue/close.md` (Issue close) | Write a raw source file into `.rite/wiki/raw/{type}/` on the dev branch working tree (pure file writer, no git operations) |
| `wiki-ingest-commit.sh` | Phase 6.5.W.2 (review), Phase 4.6.W.2 (fix), Phase 4.4.W.2 (close) — immediately after the trigger | Move pending raw sources onto the `wiki` branch and commit + push them **in a single shell process** with no dependency on Claude multi-step orchestration |
| `/rite:wiki:ingest` | Manual or optional post-commit invocation | LLM-driven page integration: read accumulated raw sources, produce/update wiki pages, refresh `index.md` / `log.md` |
| `/rite:wiki:lint --auto` | After each successful page integration (when `auto_lint: true`) | Validate Wiki consistency; surface warnings without blocking the workflow |

### Phase X.X.W Mandatory Execution (#524 + shell commit refactor)

`pr/review.md` Phase 6.5.W / 6.5.W.2, `pr/fix.md` Phase 4.6.W / 4.6.W.2, and `issue/close.md` Phase 4.4.W / 4.4.W.2 collectively form the **Wiki growth path**. Issue #524 hardened this path against silent skip with a 3-layer defense; the subsequent shell-commit refactor added a deterministic foundation underneath layers 1-3.

| Layer | Mechanism | Files |
|-------|-----------|-------|
| **0. Deterministic raw-commit path** | Phase X.X.W.2 invokes `wiki-ingest-commit.sh` directly as a single shell process. The script stashes raw sources into `/tmp`, removes them from the dev working tree, stashes any remaining unrelated changes, checks out the wiki branch, replays the staged raw sources, commits, pushes, checks out the original branch again, and pops the stash — all within one `bash` invocation. This eliminates dependency on Claude multi-step orchestration (the root cause of the pre-refactor regression where the `wiki` branch never grew despite multiple rounds of layer 1-3 defence — Issues #515, #518, #524). | `hooks/scripts/wiki-ingest-commit.sh`, `pr/review.md`, `pr/fix.md`, `issue/close.md` |
| **1. Mandatory execution** | Each Phase X.X.W explicitly states "**NEVER** skipped under E2E Output Minimization" and emits an observable `[CONTEXT] WIKI_INGEST_DONE=1` / `WIKI_INGEST_SKIPPED=1; reason=...` / `WIKI_INGEST_FAILED=1; reason=...` line at completion (success / config-skip / commit-failure) | `pr/review.md`, `pr/fix.md`, `issue/close.md` |
| **2. stderr observability** | Both legitimate skip (`wiki_ingest_skipped`) and commit failure (`wiki_ingest_failed`) emit a plain `WARNING` / `ERROR` line to stderr alongside the `[CONTEXT] WIKI_INGEST_SKIPPED=1` / `WIKI_INGEST_FAILED=1` status line. The orchestrator surfaces these in the conversation context; the user re-runs the affected step via `/rite:resume` if action is needed. | `pr/review.md`, `pr/fix.md`, `issue/close.md` Phase X.X.W |
| **3. Lint growth check** | `lint.md` Phase 3.8 runs `wiki-growth-check.sh` which warns (non-blocking, `[lint:success]` retained) when `wiki.growth_check.threshold_prs` consecutive merged PRs land without a corresponding wiki branch commit. With layer 0 in place, a growth stall is a genuine regression signal (no longer confounded by fragile orchestration), and the warning is worth investigating promptly even though the contract remains non-blocking. | `wiki-growth-check.sh`, `lint.md` Phase 3.8 |

**Responsibility split after the refactor**: `wiki-ingest-commit.sh` commits **raw sources only**. LLM-driven Wiki **page** integration (reading raw sources, deciding create/update/skip, writing `.rite/wiki/pages/*`) is **deferred** to `/rite:wiki:ingest`, which is idempotent over accumulated raw sources and can be invoked at a later, independent time (manually or in a separate session). This separation guarantees that raw sources are never lost even when page integration is skipped or fails.

Layer 3's threshold is configurable via `wiki.growth_check.threshold_prs` (default: 5). Setting it to a very large number effectively disables the lint check while preserving layers 0-2.

The completion report (now emitted by `/rite:pr:cleanup` after merge) **always** includes a "Wiki ingest 状況" section that aggregates these signals so the user has a definitive answer about whether the Wiki branch grew during each end-to-end flow (`/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:ready` → `/rite:pr:merge` → `/rite:pr:cleanup`). This section is rendered even when all counters are zero — its absence would itself be a regression signal.

### Relationship to workflow failure surfacing

The two paths address distinct concerns:

| Concern | Destination |
|---------|-------------|
| **Recurring quality/process heuristics** (e.g., "review-fix loops should not skip LOW findings", "use dotenvx not dotenv") | Wiki pages via `/rite:wiki:ingest` |
| **One-time platform defects** (e.g., "hook X exited abnormally in iteration Y") | Surfaced as a plain `WARNING` / `ERROR` on stderr; the user files an Issue manually if it warrants follow-up (see [Workflow Failure Surfacing](#workflow-failure-surfacing)) |

They share no code paths.

## Sub-skill Return Auto-Continuation Contract

### Overview (#525)

When an orchestrator command (e.g., `/rite:pr:open`, `/rite:pr:iterate`, `/rite:issue:create`) invokes a sub-skill via the Skill tool and the sub-skill outputs its result pattern (e.g., `[lint:success]`, `[review:mergeable]`, `[ready:completed]`, `[ingest:completed]`), control returns to the orchestrator LLM. The orchestrator **MUST** continue executing the next phase in the **same response turn** — the sub-skill return is a continuation trigger, not a turn boundary.

Violating this contract leaves the workflow partially executed: no Issue created, `.rite-flow-state` stuck in `active: true`, stale timestamps, and the user forced to type `continue` manually to recover. Issue #525 was filed after multiple instances of this failure in `/rite:issue:create` with the Bug Fix preset.

### The defense-in-depth layers

| Layer | Mechanism | Enforced by |
|-------|-----------|------------|
| **1. Prompt contract** | Anti-pattern / correct-pattern examples + "same response turn" / "DO NOT stop" phrases + Mandatory After prose | `commands/pr/cleanup.md` Sub-skill Return Protocol + Mandatory After Wiki Ingest, `commands/wiki/ingest.md` Mandatory After Auto-Lint. (Layer 1 enforcement is required only where a sub-skill chain still hands off across turn boundaries; the flat `commands/issue/create.md` workflow and the four `commands/pr/{open,iterate,ready,merge}.md` orchestrators each invoke sub-skills within a single file and do not rely on this layer for cross-orchestrator hand-off. The legacy reference `plugins/rite/skills/rite-workflow/references/sub-skill-return-protocol.md` is retired. The former `commands/issue/start.md` orchestrator was deleted in #1136.) |
| ~~**2. Flow state hard gate**~~ (retired) | (Historical) Sub-skills write `*_post_*` phase markers with `active: true` before return; `stop-guard.sh` blocked stop attempts until terminal phase. flow-state still records phase markers for observability but no longer enforces stops. | (historical: `hooks/stop-guard.sh`) |
| **3. Caller-continuation hints** (3 sub-layers 3a/3b/3c) | Plain-text reminder + HTML comment immediately before the sub-skill's result pattern. The plain-text line renders in user-facing output; the HTML comment is visible to the LLM via conversation context but does NOT render in Markdown. Dual form ensures robustness against rendering modes that strip comments. 3a = plain-text caller line, 3b = HTML comment caller mirror, 3c = sub-skill terminal sentinel comment. | Defense-in-Depth sections in `commands/issue/create.md` (flat workflow ステップ 4.4 / 5.6), `commands/wiki/ingest.md`, `commands/pr/cleanup.md`. |
| **4a. Pre-check list (#552)** | 4-item self-check the orchestrator runs before ending any response turn: (a) `[create:completed:{N}]` output? (b) `✅ Issue #{N} を作成しました` shown? (c) `.rite-flow-state` deactivated? (d) last sub-skill tag handled as continuation trigger? A single `NO` means the workflow is mid-flight. Renamed from "Layer 4" to "Layer 4a" by Issue #923 to avoid numbering collision with the new mechanical enforcement layer (4b below). | `commands/issue/create.md` "Pre-check list" section |
| **4b. Completion message (#552)** | Terminal completion emits an explicit `✅ Issue #{N} を作成しました: {url}` line **before** the `<!-- [create:completed:{N}] -->` sentinel (HTML-comment wrap form, #561). The sentinel remains grep-matchable for tooling (AC-4 backward compat) but is no longer the absolute last visible line. Renamed from "Layer 5" to "Layer 4b" by Issue #923 (4a/4b grouping reflects that both are orchestrator-side completion reinforcements from #552). | `commands/issue/create.md` ステップ 4.4 (Single Issue 完了レポート) / ステップ 5.6 (Decompose 完了レポート) |
| ~~**4. Mechanical enforcement**~~ (retired) | (Historical) PostToolUse hook `auto-fire-step0.sh` (matcher `Skill`) fired after sub-skill Skill tool completion to patch `*_post_*` flow-state phases and inject continuation context. The mechanical enforcement layer was removed along with the implicit-stop guard layer; recovery now relies on `/rite:resume` rather than a runtime continuation hook. | (historical: `hooks/auto-fire-step0.sh`) |
| ~~**6. stop-guard incident emit**~~ (retired) | (Historical) When `stop-guard.sh` blocked an implicit stop, it emitted a `manual_fallback_adopted` workflow-incident sentinel for post-hoc visibility. Both the Stop hook and the workflow-incident mechanism (PR 2b, #1088) have since been removed; an implicit stop now simply leaves the workflow mid-flight for the user to recover via `/rite:resume`. | (historical: `hooks/stop-guard.sh`) |

The remaining **primary active layers** are the prompt contract (Layer 1), the caller HTML hint (Layer 3), and the orchestrator-side reinforcements (Layer 4a pre-check list, Layer 4b completion message). Layers 2, 4, and 6 are retired and shown above only as historical context. Weakening any active layer (e.g., relaxing Layer 1 imperative phrasing without compensating at Layer 3) re-opens the original implicit-stop failure mode. The flat-workflow refactor traded the mechanical enforcement layer for a simpler "user runs `/rite:resume` to recover" philosophy, accepting that occasional implicit stops will surface to the user; the trade-off was deemed favorable because the mechanical enforcement layer was itself a frequent failure source (auto-fire-step0.sh state mutations were hard to recover from when wrong).

### Contract specification

For every Skill tool invocation within an orchestrator:

1. When the sub-skill returns control (outputs its result pattern), the orchestrator LLM **MUST NOT** end its response.
2. The orchestrator **MUST NOT** re-invoke the completed sub-skill.
3. The orchestrator **MUST** execute its 🚨 Mandatory After section for the current phase, beginning with the `.rite-flow-state` update, then proceeding to the next phase — all in the same response turn.

> **Historical note (item 4, retired)**: A former item 4 instructed the orchestrator to follow `ACTION:` instructions on `stop-guard.sh` exit 2. With the Stop hook removed, this branch is unreachable at runtime — Layer 1 (this prose) and Layer 3 (caller HTML hint) are the active enforcement.

The contract ends only when the orchestrator's terminal completion marker has been output:

| Orchestrator | Terminal marker |
|-------------|----------------|
| `/rite:pr:open` | Step 6 completion notice listing the draft PR number/URL and the next-command suggestions (`/rite:pr:iterate` / `/rite:pr:ready` / `/rite:pr:merge` / `/rite:pr:cleanup`) |
| `/rite:pr:iterate` | `[review:mergeable]` or `[fix:replied-only]` (whichever sub-skill returns first terminates the loop) / `[fix:cancelled-by-user]` (user-initiated cancel via fix.md AskUserQuestion) |
| `/rite:pr:ready` | `[ready:completed]` (E2E flow) / completion display message (standalone) |
| `/rite:pr:merge` | `[merge:completed]` |
| `/rite:issue:create` | `<!-- [create:completed:{N}] -->` (HTML-comment wrap form per #561) preceded by user-visible `✅ Issue #{N} を作成しました: {url}` and next-step guidance |

### Phase-aware continuation hints (#525)

> **Historical note**: Before the Stop hook was retired, these phase-specific continuation hints were emitted by the Stop hook (`stop-guard.sh`) when a stop attempt was blocked with an active per-session flow state. the hint table below is preserved as **prompt-level guidance** that the orchestrator surfaces directly when a sub-skill returns without producing the expected terminal marker. These hints are now part of the prompt contract (Layer 1) rather than a runtime enforcement mechanism.

| Active phase | Hint content |
|-------------|-------------|
| ~~`create_post_interview`~~ (retired) | (Historical) The flat-workflow consolidation merged this phase into `create.md`; the flow state no longer records it. |
| ~~`create_delegation`~~ (retired) | (Historical) Delegation phase は flat-workflow 統合で create.md 内部に取り込まれた |
| ~~`create_post_delegation`~~ (retired) | (Historical) Same as above |

These hints are **best-effort**: the primary enforcement is the prompt contract (Layer 1) — the orchestrator's 🚨 Mandatory After scaffolding ensures the workflow does not end mid-flight regardless of any runtime hook layer.

### Contract violation recovery (`auto_continuation_failed`, obsolete)

When the contract is violated in practice — i.e., the user types `continue` to recover — there is **no** automatic detection or registration. The orchestrator simply resumes from where it stopped.

> **History (PR 2b, #1088)**: A follow-up (#525 Decision Log D-02) once proposed an optional (`MAY`) `auto_continuation_failed` sentinel that would auto-register the violation as an Issue via start.md ステップ 8.5. That proposal depended on the workflow-incident mechanism, which has since been removed entirely. The `auto_continuation_failed` sentinel was never implemented and is now obsolete.

### Acceptance criteria

| AC | Description |
|----|-------------|
| AC-1 | bug fix preset で `/rite:issue:create` が end-to-end で `[create:completed:{N}]` まで自動完了する（利用者の `continue` 介入なし） |
| AC-2 | M complexity 以上で flat create.md が同 turn 内で Single Issue → ステップ 4 (Heuristics + 出力) を実行する |
| ~~AC-3~~ (retired) | (Historical) `create.md` の Sub-skill Return Protocol セクションに "anti-pattern" / "correct-pattern" / "same response turn" / "DO NOT stop" の 4 phrase が全て含まれる。The dedicated section was consolidated into the flat workflow; the contract is now enforced by `commands/pr/cleanup.md` + `commands/wiki/ingest.md` + the orchestrator's inline "Mandatory After" prose. |
| ~~AC-4~~ (obsolete) | (Historical) `auto_continuation_failed` sentinel 実装時、ステップ 8.5 で観測可能（MAY）。The workflow-incident mechanism was removed (PR 2b, #1088); this sentinel was never implemented. |
| AC-5 | Terminal Completion pattern (`[create:completed:{N}]` + `.rite-flow-state active: false`) が引き続き動作する (non-regression) |
| AC-6 | Terminal sub-skill の最終出力に `✅` で始まるユーザー向け完了メッセージが含まれる。Register 経路: `✅ Issue #{N} を作成しました: {url}`、Decompose 経路: `✅ Issue #{N} を分解して {count} 件の Sub-Issue を作成しました: {url}`。いずれの形式も `[create:completed:{N}]` は最終行として維持される |
| ~~AC-7~~ (retired) | (Historical) `stop-guard.sh` が `create_post_interview` / `create_delegation` / `create_post_delegation` phase で implicit stop を block した際、`manual_fallback_adopted` sentinel を emit する。Both the Stop hook layer and the workflow-incident mechanism (PR 2b, #1088) were removed; implicit stops are now simply recovered by the user via `/rite:resume`. |
| AC-8 | `create.md` に "Pre-check list" セクションが存在し、4 項目全て `YES` が turn 終了の必要条件として文書化されている |

## Error Handling

### Auto-Retry

| Error Type | Retry Count | Interval |
|------------|-------------|----------|
| GitHub API temporary error (5xx) | 3 | Exponential backoff |
| Network error | 3 | 5 seconds |
| Rate limit (429) | 1 after wait | API-specified time |

### Manual Recovery Guidance

For persistent errors, provide:

1. **Detailed error explanation**
2. **Possible causes** (list if multiple)
3. **Recovery steps** (step-by-step)
4. **Links to related documentation**

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `gh: command not found` | gh CLI not installed | Guide in `/rite:init` |
| `authentication required` | GitHub not authenticated | Guide `gh auth login` |
| `branch already exists` | Branch conflict | Suggest alternative name |
| `Context limit reached` | Long-running flow exceeded context window | `/clear` then `/rite:resume` |

### Context Limit Recovery

Long-running commands such as the end-to-end flow `/rite:pr:open` → `/rite:pr:iterate` (branch creation → implementation → PR creation → review-fix loop) may exceed Claude Code's context window and get interrupted with `Context limit reached`.

**Recovery steps:**

1. Run `/clear` to reset the context
2. Run `/rite:resume` to continue from where it left off

**Why this works:**

- Work memory (Issue comments) and the per-session flow state file persist workflow state across sessions
- All git artifacts (branches, commits, PRs) are preserved — nothing is lost
- `/rite:resume` reads the persisted state and resumes the appropriate phase

**What is preserved:**

| Artifact | Storage | Survives context limit |
|----------|---------|------------------------|
| Branch | Git | Yes |
| Commits | Git | Yes |
| Draft PR | GitHub | Yes |
| Work memory | Issue comment | Yes |
| Flow state | `.rite/sessions/{session_id}.flow-state` (see [Multi-Session State Management](#multi-session-state-management)) | Yes |

### API Error Handling

#### Retry Strategy

| Error Type | Response |
|-----------|----------|
| Network error | Max 3 retries (exponential backoff: 2s, 4s, 8s) |
| Rate limit (403/429) | Wait per `Retry-After` header, then retry |
| Auth error (401) | Display error, guide `gh auth login` |
| Not Found (404) | Display error, guide configuration check |
| Server error (5xx) | Max 2 retries (3s interval) |

#### Fallback Strategy

| Situation | Fallback Behavior |
|-----------|-------------------|
| Project API failure | Execute Issue creation only, skip Projects operations |
| Iteration API failure | Display warning, skip Iteration operations |
| Field update failure | Display warning, continue to next operation |
| Status update failure | Guide manual update method |

#### Error Message Format

```
Error: {error summary}

Cause: {possible cause}

Solution:
1. {step 1}
2. {step 2}

Details: {technical details for debugging}
```

---

## Migration

### Introducing to Existing Projects

**Hybrid Approach:**

- Existing Issues are read-only (viewable via `/rite:issue:list`)
- Edit/update only newly created Issues
- Auto-link if existing Projects found

### Version Upgrade

**Auto-Migration:**

1. Auto-convert configuration file format
2. Update Projects field structure
3. Create backup on breaking changes

---

## Internationalization

### Language Auto-Detection

1. Detect user input language (from recent input)
2. Reference system locale
3. Check `language` setting in config file

### Supported Languages

- Japanese (ja)
- English (en)

### Language File Structure

Language files use a split directory structure organized by language and domain:

```
plugins/rite/i18n/
├── en.yml # English (deprecated, kept for backward compatibility)
├── ja.yml # Japanese (deprecated, kept for backward compatibility)
├── en/
│ ├── common.yml # Common messages (shared across commands)
│ ├── issue.yml # Issue-related messages
│ ├── pr.yml # PR-related messages
│ └── other.yml # Other messages (init, resume, lint, etc.)
└── ja/
 ├── common.yml # 共通メッセージ
 ├── issue.yml # Issue 関連メッセージ
 ├── pr.yml # PR 関連メッセージ
 └── other.yml # その他メッセージ（init, resume, lint 等）
```

Each domain file contains keys grouped by command context (e.g., `# rite:init`, `# rite:resume`). Messages are referenced in commands using `{i18n:key_name}` placeholder syntax.

---

## Dependencies

### Required

| Tool | Purpose | Installation Check |
|------|---------|-------------------|
| gh CLI | GitHub API operations | `gh --version` |

### Optional

| Tool | Purpose |
|------|---------|
| Project-specific build tools | Build/Test/Lint |

---

## Distribution

Distributed via Claude Code plugin system:

```bash
# Add the marketplace
/plugin marketplace add B16B1RD/cc-rite-workflow

# Install the plugin
/plugin install rite@rite-marketplace
```

---

## Project Types

### Supported Types

| Type | Description | Characteristics |
|------|-------------|-----------------|
| `generic` | Universal | Basic field configuration |
| `webapp` | Web Application | Front/Back/DB separation |
| `library` | OSS Library | Breaking changes, CHANGELOG focus |
| `cli` | CLI Tool | Command changes, compatibility focus |
| `documentation` | Documentation | Build, link verification focus |

### Type-Specific PR Templates

#### generic

```markdown
## Summary
<!-- 1-2 sentence description -->

## Changes
- Change description

## Checklist
- [ ] Tested
- [ ] Documentation updated

Closes #XXX
```

#### webapp

```markdown
## Summary

## Changes
- [ ] Frontend
- [ ] Backend
- [ ] Database

## Screenshots
<!-- If applicable -->

## Test Plan
- [ ] Unit tests
- [ ] E2E tests
- [ ] Manual testing

## Performance Impact
<!-- If applicable -->

Closes #XXX
```

#### library

```markdown
## Summary

## Changes

## Breaking Changes
- [ ] None
- [ ] Yes (details: )

## Migration Guide
<!-- If breaking changes exist -->

## Tests
- [ ] Unit tests
- [ ] Integration tests

## Documentation
- [ ] API docs updated
- [ ] README updated
- [ ] CHANGELOG updated

Closes #XXX
```

#### cli

```markdown
## Summary

## Changes

## Command Changes
- [ ] New command added
- [ ] Existing command modified
- [ ] Options added/changed

## Compatibility
- [ ] Backward compatible
- [ ] Breaking changes

## Help/Manual
- [ ] --help updated
- [ ] man page updated

Closes #XXX
```

#### documentation

```markdown
## Summary

## Changes
- [ ] New documentation
- [ ] Existing documentation update
- [ ] Structure changes

## Checklist
- [ ] Build successful
- [ ] Links verified
- [ ] Spell checked
- [ ] Style guide compliant

## Preview
<!-- Preview URL, etc. -->

Closes #XXX
```

---

## Future Extensions

1. **Enhanced AI Code Review**
 - More detailed security analysis
 - Performance optimization suggestions

2. **CI/CD Integration**
 - GitHub Actions integration
 - Auto-deploy triggers

3. **Metrics & Dashboard**
 - Development velocity visualization
 - Issue resolution time analysis

---

## References

- [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [Claude Code Plugins Reference](https://code.claude.com/docs/en/plugins-reference)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
- [Conventional Commits](https://www.conventionalcommits.org/)
