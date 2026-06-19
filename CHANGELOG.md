# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Phase number policy: Entries describe changes at the feature-name level, not
internal `Phase X.Y.Z` implementation identifiers. Phase numbers inside
`review.md` / `fix.md` / `pr/open.md` may be renumbered between releases, so
CHANGELOG entries must remain stable across such refactors. When a change
genuinely needs locational precision, prefer referencing the file name
(e.g. `review.md`) over internal phase numbers. See Keep a Changelog 1.1.0
"Guiding Principles" for the rationale and conventions.

History-dependent phrasing policy: Entries describe each change at the feature
level. A Fixed/Changed/Removed entry may state the prior behavior it corrects —
that is the change log's purpose — but it must name the specific key, feature,
or behavior involved (e.g. `multi_session.enabled`, `max_review_fix_loops`)
rather than a vague implicit reference ("the previous behavior", "the old way")
whose baseline a new reader cannot resolve. Each version section is itself the
comparison anchor, so avoid cross-version "used to / previously" framing that is
not tied to a named key or feature. Breaking-change notices and migration guides
that aid upgraders are kept verbatim.
-->

## [Unreleased]

## [0.6.4] - 2026-06-20

### Fixed

- **`/rite:pr:open` branch creation is now worktree-isolated as a hard invariant under `multi_session.enabled: true`** — branch creation re-resolves `multi_session` from `rite-config.yml` immediately before the branch is created (instead of relying on a `[CONTEXT]` marker that can be lost across resume / context compaction / mid-flow entry), so the `git switch -c` legacy path is reachable only when `multi_session.enabled: false`. After `EnterWorktree`, an invariant check verifies the repository top-level matches the worktree path and halts on mismatch instead of silently continuing on the main tree; `flow-state.sh set --require-worktree` emits a loud warning when a branch/PR phase would be recorded without a worktree. (#1596)

## [0.6.3] - 2026-06-19

### Docs

- Restructured the README into a bilingual layout: `README.md` (English, with the English intro video) and a new `README.ja.md` (Japanese, with the Japanese intro video), cross-linked by a language switcher at the top of each (#1585, #1587)

## [0.6.2] - 2026-06-19

### Docs

- Added a Demo section with an introductory video (Japanese subtitles) near the top of the README (#1580)

## [0.6.1] - 2026-06-18

### Fixed

- **`EnterWorktree` failure under harness git misdetection now points to a restart remedy** — when `multi_session.enabled: true` (default), `/rite:pr:open` Step 2.3-W and `/rite:resume` re-entry detect the harness git repository misdetection (`.git` present and `git` CLI healthy, but the startup check reports false) and recommend restarting Claude Code from the repository root so the already-created worktree is reused (`WT_CASE=reuse`), instead of offering only the prior "abort / `git switch -c`" fallback. Documented in `getting-started.md` and `git-worktree-patterns.md`. (#1574)

## [0.6.0] - 2026-06-18

### Added

- **Canon TDD cycle for the implementation phase** — when `tdd.enabled: true` (default on), `/rite:issue:implement` drives implementation through a Canon TDD loop: pick one behavior from the test list → confirm Red → minimal Green → Refactor → repeat until the list is empty. Falls back gracefully: `commands.test: null` runs in "Degraded TDD" mode (test-list discipline kept, auto-run skipped with a warning), and `tdd.enabled: false` restores the prior non-TDD flow. (#1567)
- **`tdd:` configuration section, default-on (opt-out)** — distributed `rite-config.yml` ships a `tdd:` section with `enabled: true`; `/rite:init --upgrade` back-adds it to existing projects via the same active-section mechanism as `wiki` / `multi_session`. (#1566)
- **Canon TDD documentation and test-list framing** — the Issue template Section 6 "Test Specification" is now framed as the Canon TDD test list (one T-xx row = one Red→Green→Refactor cycle), reflected across `skills/rite-workflow`, `docs/SPEC.md`, getting-started, and `pr/open.md`. (#1568)

## [0.5.5] - 2026-06-17

### Fixed

- **`bang-backtick-check.sh` no longer hard-blocks consumer repos** — a new `--skip-if-no-target` flag makes `--all` return a clean skip (rc=0) instead of an `rc=2` invocation error when there is no `plugins/rite/` markdown to scan (marketplace-only consumer repos), removing the forced manual gate bypass in `/rite:pr:ready` and `/rite:pr:create`. Self-host repos keep the original `rc=2` misconfiguration diagnostic. (#1551)
- **Active-but-idle session worktrees protected from lazy reap** — `pr-cycle-cleanup.sh` keeps a worktree whose issue claim holder is `active=true` even when the claim heartbeat has gone stale (idle past `CLAIM_STALE_SECONDS`), preventing the `/clear` "Path does not exist" error from recurring on resume. (#1553)
- **Read-only commands relay their real output again** — removed `context: fork` from `/rite:issue:list`, `/rite:investigate`, `/rite:workflow`, and `/rite:skill:suggest` so their output is shown inline instead of being replaced by the harness control wrapper. (#1556)
- **`orphan-reference-check.sh --all` works inside session worktrees** — the `--all` scan now walks paths relative to `REPO_ROOT`, so running from a `.rite/worktrees/issue-N` worktree no longer excludes every file and exits `2`; orphan detection is restored under the default `multi_session.enabled: true`. (#1557)

## [0.5.4] - 2026-06-16

### Added

- **OKF v0.1 minimal conformance for Wiki concept pages** — concept page frontmatter now carries `type` and `okf_version` fields, aligning Wiki pages with Open Knowledge Format v0.1.
- **OKF v0.1 sync and upstream visualizer integration guide** — documentation now covers OKF v0.1-conformant synchronization and connecting the upstream visualizer.

### Changed

- **`/rite:pr:run` defaults to draft-only** — the command runs `open → iterate` (stopping at draft) by default, and `ready → merge → cleanup` is opt-in via the `--merge` flag.
- **Wiki `index.md` reshaped to OKF bullet form with two-pass query** — `index.md` adopts an OKF bullet structure and `wiki:query` resolves in two passes.
- **Wiki `log.md` reshaped to OKF form** — `log.md` adopts an OKF structure and the `ingest:skip` state moves into raw frontmatter.

### Fixed

- **`wiki:close` heredoc write-failure guard** — `close.md` Phase 4.4.W guards against heredoc write failure, mirroring the review/fix path.
- **`/rite:pr` review/fix `$trigger_exit` defensive default** — Step 3 assigns a defensive default to `$trigger_exit`.
- **Live-process worktrees protected from `/clear` "Path does not exist"** — worktrees with a live process are protected so the `/clear` "Path does not exist" error does not recur.

## [0.5.3] - 2026-06-14

### Added

- **`/rite:pr:run`** — a batch PR lifecycle command that runs `open → iterate → ready → merge → cleanup` sequentially and autonomously across multiple Issues.
- **`/rite:lint` number-reference guard** — a `number-reference-check.sh` lint (non-blocking warning) that detects Issue/PR number references (`#NNN`, `Issue #NNN`, `PR #NNN`) re-introduced into the number-free surface (`CHANGELOG.md`, `CHANGELOG.ja.md`, `lint.md`), guarding the cleaned surface against recurrence.

### Fixed

- **Parallel sessions no longer contaminate each other's flow state** — `session_id` resolution is now env-first, so concurrent sessions resolve distinct identifiers instead of clobbering a shared `flow_state`.
- **`/rite:pr:cleanup` reclaims temporary branches and worktrees name-independently** — cleanup no longer relies on branch or worktree naming to find and remove the artifacts it created.
- **In-use session worktrees are protected from reap** — lazy reap skips worktrees owned by active sessions, and `/clear` self-repairs dangling session state.
- **`drift-check` over-detection removed** — eliminated false-positive drift findings and aligned the document-missing reason emitted by the check.
- **`decompose-issues.sh` no longer crashes on an empty `labels_csv`** — Sub-Issue creation handles an empty label set instead of failing.
- **`/rite:pr:merge` success path terminates with a fixed `exit 0`** — a trailing no-op prevents the merge success path from inheriting a non-zero exit status.

### Changed

- **`wiki:ingest` write-failure handling** — the write-failure path now emits a dedicated `content_write_failed` reason instead of a generic failure reason.
- **Documentation surface made number-free and present-tense** — removed implicit history-dependent phrasing (e.g. "the previous behavior", "the old way") and Issue/PR number references across user-facing config and docs, spec and design docs, command/skill/hook/script comments, and tests, stating the rationale directly in prose. The CHANGELOG history-dependent-phrasing policy is now documented in the file header.
- **Account migration** — updated `B16B1RD` references to `asakaguchi` following the repository account transfer.

### Removed

- **README v0.4.0 Breaking Changes section** — dropped the now-historical upgrade notice from the README.

## [0.5.2] - 2026-06-12

### Fixed

- **`/rite:init --upgrade` short-circuit path no longer drops drift back-adds** — when no pending drift was detected, the `--upgrade` short-circuit path skipped the back-add step that the full path performs, so projects taking the short-circuit could miss newly added config sections and sub-keys. The short-circuit now applies the same drift back-add logic, covered by an added drift-detection test.
- **Fixed broken references to the non-existent `_resolve-flow-state-path.sh`** — updated stale script references in the hooks documentation to the actual `flow-state.sh` path.

### Changed

- **Unified flow state on the per-session model** — removed the legacy `flow_state.schema_version=1` (single-file) path from the hooks (`session-start`, `session-end`, `post-compact`, `pre-compact`, `post-tool-wm-sync`), `init.md`, and the config template, consolidating on per-session flow state. Stale `schema_version` test fixtures/labels were neutralized, `commit.contextual` was added to the SPEC Deprecated key list, and `SPEC.md` / `getting-started.md` were updated to follow the `--upgrade` drift back-add behavior change.

## [0.5.1] - 2026-06-12

### Fixed

- **`/rite:init --upgrade` now converges to the latest config defaults** — the `--upgrade` path previously dropped newly added top-level sections, new sub-keys inside existing sections, and the `multi_session` block, producing a two-tier behavior where upgraded projects drifted from what a fresh `/rite:init` produces. `--upgrade` now back-adds `multi_session` with `enabled: true` (an explicit `false` is preserved; idempotent), fills only the missing sub-keys from the template default while preserving existing sibling values, and tracks newly added top-level sections via a drift anchor. Covered by a new sub-key-merge drift-detection test (T-12), which was unified onto the shared `_test-helpers.sh` harness. `commands/getting-started.md` documents the `--upgrade` `multi_session` back-add behavior.

## [0.5.0] - 2026-06-12

### Added

- **Session worktrees for work isolation** — `multi_session` configuration with session-scoped worktree creation via `EnterWorktree`, resume re-entry, and lazy reap on cleanup. Default ON (opt-in → default).
- **Issue claim mechanism** (`issue-claim.sh`) — fail-fast guard preventing two sessions from working the same Issue concurrently.
- **`/rite:learn`** — Socratic understanding-check command for completed Issue/PR sessions.
- **Assumption Surfacing step** in `/rite:issue:create` — surfaces implicit model assumptions and classifies them (derive / ask / defer).
- **Knowledge routing (4-channel)** added to coding principles, with comment why-over-what and rejected-alternative routing.
- **Review scope classification** — `scope` / `pre_existing` / `acknowledged` fields (review-result-schema 1.1.0), 3-way recommendation disposition, and a Phase 7 post-condition gate.
- **Wiki lint helper scripts** for the three machine-decidable categories, plus concurrent-ingest exclusion (session lock + push retry).
- **New `/rite:lint` guards** — hardcoded line-number drift, CLOSED+COMPLETED board-not-Done drift, and operational bash-block heaviness.
- Artifacts schema 1.1.0 migration script + version-drift hook.

### Changed

- `multi_session.enabled` now defaults to `true` for new projects.
- Numerous Source-of-Truth consolidations across commands, references, and templates (Type crosswalk, contract section mapping, etc.).
- Reviewer base / severity-levels gained Scope Assignment responsibility.

### Fixed

- Extensive stabilization across the review-fix loop, hooks (flow-state multi-state API, legacy `.rite-flow-state` migration, bang-backtick guard, drift-check), Issue/PR orchestration, and Wiki ingest/query (300+ fixes consolidated since v0.4.0).

> This is a large consolidation release (644 commits since v0.4.0). Entries are summarized at the feature level per the project's CHANGELOG policy.

## [0.4.0] - 2026-04-22

### BREAKING CHANGE

- **Cycle-count-based review-fix degradation fully abolished; replaced by 4 quality signals** — **BREAKING CHANGE**
  - **Removed configuration keys** (three keys from `rite-config.yml`; these keys were never present in `plugins/rite/templates/config/rite-config.yml`):
    - `review.loop.severity_gating_cycle_threshold`
    - `review.loop.scope_lock_cycle_threshold`
    - `safety.max_review_fix_loops`
  - **Removed logic**:
    - `plugins/rite/commands/pr/references/fix-relaxation-rules.md` convergence strategy override table (`severity_gating` / `scope_lock` / `batched` as strategies) and Loop Termination hard-limit row.
    - `plugins/rite/commands/pr/fix.md` Phase 0.4 Convergence Strategy Load (the full block loading `convergence_strategy` from `.rite-flow-state`).
    - `plugins/rite/commands/issue/start.md` Phase 5.4.6 Step 3.5 Review-Fix Loop Hard Limit Check (the `extend (+5) / retry / escalate` 3-choice dialog).
    - `plugins/rite/commands/issue/start.md` Phase 5.4.1.0 cycle-trajectory pattern analysis (Converging / Stalled / Diverging / Oscillating) and the `convergence_strategy` write to `.rite-flow-state`.
  - **New behavior**: the review-fix loop now has exactly two exit paths — (a) 0 findings → `[review:mergeable]`, or (b) any of the **four quality signals** fires → `AskUserQuestion` escalation (`本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション`).
  - **Four quality signals**:
    1. Same-finding cycling — detected in `start.md` Phase 5.4.1.0 via SHA-1 fingerprints of `file + category + normalized message`. One re-occurrence escalates.
    2. Root-cause-missing fix — detected in `fix.md` Phase 3.2.1 by an LLM-semantic check of the commit body for a `root-cause(scope):` action line (new Contextual Commits action type), a `decision(scope):` line that explicitly names the root cause, or a free-form `Root cause:` / `根本原因:` paragraph. Missing → `AskUserQuestion` 3-option prompt.
    3. Cross-validation disagreement — detected in `review.md` Phase 5.2 when two reviewers report the same `file:line` with severity gap ≥ 2 and debate fails to resolve.
    4. Finding quality gate failure — new `Finding Quality Guardrail` in `_reviewer-base.md` filters bikeshedding / defensive / hypothetical / style-only findings before output; if nothing remains, reviewer self-reports as "degraded" via a `### Reviewer self-assessment` section and escalates.
  - **Finding fingerprint specification**: `sha1(normalize(file_path) + ":" + category + ":" + normalize(message))` with identifier masking and Jaccard token similarity > 0.7 for near-match detection. See `start.md` Phase 5.4.1.0 for the full spec.
  - **Minor version bump**: 0.3.10 → 0.4.0 (6 version files synchronized).
  - **Removed-key handling**: The three removed keys are silently ignored at runtime. There is no `/rite:lint` deprecation scan or warning for them.
  - **No cycle-count safety limit (by design)**: There is intentionally no hidden iteration guard. The 4 quality signals are the sole termination mechanism. Reintroducing an iteration counter would contradict the core goal of this release (removing cycle-count-based degradation).

### Migration guide

Existing users with any of the following in `rite-config.yml` should remove those lines:

```yaml
# Remove all three:
review:
  loop:
    severity_gating_cycle_threshold: 5
    scope_lock_cycle_threshold: 7
safety:
  max_review_fix_loops: 7
```

The keys are silently ignored at runtime in v0.4.0. There is no functional replacement — non-convergence is now detected automatically by the four quality signals and no cycle-count threshold needs to be configured.

If you previously relied on `max_review_fix_loops` hitting a hard limit to escape runaway loops, the same safety is now provided by Quality Signal 1 (fingerprint cycling) which fires on the **second** occurrence of any finding — typically faster than any cycle-count threshold would have tripped.

### Changed

- **Review-Fix Cycle Overhaul (Fail-Fast Response + Separate Issue user confirmation + configuration layer)** — **BREAKING CHANGE** (finalizes the rollout, which began with the principles doc layer, the reviewer exit layer, and the Fact-Check layer). Wires the `fix` response layer and configuration layer to the previously-merged principle/exit/fact-check layers.
  - `plugins/rite/commands/pr/fix.md` Phase 2 now begins with a **Fail-Fast Response Principle** section enforcing a 4-item checklist (`throw/raise` propagation / existing error boundaries / not hiding via null-checks / fix the test instead) before deciding a fix approach. Adopting a fallback requires an explicit justification in the commit message; unthinking defensive code is re-flagged at Phase 5 re-review.
  - `plugins/rite/commands/pr/fix.md` Phase 4.3.3 **removes the E2E `AskUserQuestion` skip** — separate-issue creation is now gated by user confirmation **regardless** of caller (E2E `/rite:issue:start` loop or standalone). Options are unified to `retry in current PR / create separate issue / withdraw`, all of which converge to `findings == 0` so the review-fix loop still terminates.
  - `plugins/rite/commands/pr/fix.md` and `plugins/rite/commands/issue/start.md`: the `"severity_gating"` convergence strategy has been **removed**. All PR-originating findings must be addressed within the current PR regardless of severity (本 PR 完結原則). `rite-config.yml` `fix.severity_gating.enabled` is retained as a deprecated compatibility key pinned to `false`. Non-convergence is now handled via the unified `AskUserQuestion` route in fix.md Phase 4.3.3. Use `"batched"` or `"scope_lock"` strategy for non-convergence mitigation instead.
  - `plugins/rite/templates/config/rite-config.yml` adds **config scaffolding keys** (declaration only, runtime wiring tracked as a follow-up): `review.observed_likelihood_gate.*`, `review.fail_fast_first.*`, `review.separate_issue_creation.*`, `fix.fail_fast_response`. The `fix.severity_gating.enabled: false` key is retained as a deprecated compatibility shim and is actively honored (pinned to `false`). **Known limitation**: The non-deprecation scaffolding keys (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`, `fail_fast_response`) are **not yet referenced by conditional runtime logic** in `commands/` / `agents/` / `skills/` / `hooks/`. The new behavior (Fail-Fast Response Principle, always-confirm separate-issue creation) is hardcoded in `fix.md` Phase 2 / Phase 4.3.3 prose and cannot currently be disabled via config. These keys are provided so users can see the intended configuration surface; wiring them to conditional branches is tracked as a follow-up Issue.
  - `plugins/rite/i18n/{ja,en}/pr.yml` adds four i18n message keys (`review_fail_fast_first_warning`, `review_observed_likelihood_demotion_notice`, `review_separate_issue_user_confirmation_question`, `fix_fail_fast_response_checklist_prompt`) with ja/en parity. **Known limitation**: these keys are **not yet referenced** via the `{i18n:key_name}` lookup in `commands/` / `skills/` / `agents/`. The corresponding prompts in `fix.md` / `review.md` currently embed their text directly. Call-site wiring is tracked as a follow-up.
  - **Migration guide**: Existing users with `fix.severity_gating.enabled: true` in `rite-config.yml` will find the key silently pinned to `false`. Non-convergence is now resolved via the `retry in current PR / create separate issue / withdraw` `AskUserQuestion` at fix.md Phase 4.3.3. Users who relied on automatic severity-based deferral should adopt `"batched"` or `"scope_lock"` strategy. **Opt-out limitation**: the other new config keys (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`) are **not yet actionable as opt-outs** — the new behavior is currently enforced unconditionally in the prose. To disable any of these, the corresponding prompt sections in `fix.md` / `review.md` must be edited directly until the wiring PR lands.

- **Named subagent invocation for `/rite:pr:review` reviewers** — **BREAKING CHANGE**. `plugins/rite/commands/pr/review.md` now invokes reviewer agents via `subagent_type: "rite:{reviewer_type}-reviewer"` (scoped named subagent) instead of `subagent_type: general-purpose`. Under named subagent invocation, each reviewer's agent file body (`plugins/rite/agents/{reviewer_type}-reviewer.md`) becomes the sub-agent's **system prompt** automatically, and YAML frontmatter (`model`, `tools`) is honored by the runtime. This gives reviewer discipline stronger system-prompt-level enforcement (rather than user-prompt injection which can be diluted) and activates per-reviewer model pins (9 reviewers pinned to `model: opus`). A reviewer_type → subagent_type mapping table was added for the 13 reviewers. Empirical verification confirmed that the `rite:` prefix is mandatory in plugin distribution — bare `{reviewer_type}-reviewer` fails agent resolution with `Agent type not found` error. **User impact**: users previously running reviews on sonnet will see forced opus upgrade for 9 reviewers and a corresponding cost increase (opt-out by removing `model: opus` from individual agent frontmatters). See `docs/migration-guides/review-named-subagent.md` for the full migration guide, opus recommendation rationale, and 3 rollback scenarios (all-reviewer resolution failure / tech-writer Bash permission / verification mode output format broken)
- **`{agent_identity}` placeholder renamed to `{shared_reviewer_principles}` in `review.md`** — **BREAKING CHANGE** (for rite plugin developers editing `review.md` templates). `review.md` now extracts only the shared reviewer principles from `_reviewer-base.md` (Reviewer Mindset / Cross-File Impact Check / Confidence Scoring). Part B (agent-specific identity) extraction was removed entirely — it is no longer needed because the named subagent system prompt delivers agent-specific discipline directly. This is a **hybrid approach**: agent body → system prompt (via named subagent), shared principles → user prompt (via `{shared_reviewer_principles}`). The alternative (inlining shared principles into 13 agent files) was rejected to preserve `_reviewer-base.md` as the single source of truth. The review template sections `## あなたのアイデンティティと検出プロセス` were renamed to `## 共通レビュー原則` to reflect the narrower scope. Preserves the Part A bug fix that ensures Cross-File Impact Check reaches reviewers
- **Retry classification extended with `subagent resolution failure` in `review.md`** — Added a new retry classification entry for the case where the Task tool cannot resolve a scoped subagent name (e.g., `Agent type 'rite:code-quality-reviewer' not found. Available agents: ...`). Retry: **No**. Action: fail immediately with the scoped name used and the error message. Do NOT silently fall back to `general-purpose` — that would defeat the named subagent quality improvement. If all reviewers fail this way, the orchestrator prompts the user via `AskUserQuestion` (retry / rollback to `general-purpose` temporarily / abort review). Classification detection pattern: Task tool response contains `Agent type '{scoped_name}' not found`

- **docs: reflect v0.4.0+ implementation across SPEC / README / CLAUDE.md / CHANGELOG** — Multi-PR documentation alignment sweep after v0.4.0:
  - Commands table + Agent File Format Note — added `/rite:issue:recall` to README / README.ja / SPEC / SPEC.ja Commands tables, added `/rite:init --upgrade` to README.ja, replaced the `subagent_type: general-purpose` note with the named-subagent description
  - SPEC Plugin Structure tree refreshed to match v0.4.0+ file layout (commands/issue sub-skills, commands/pr/references, commands/wiki, agents/_reviewer-base, skills/{investigate,wiki}, hooks/{scripts,tests}, templates/{config,review,wiki}, scripts expansion, references expansion); Configuration section compressed to a pointer to `docs/CONFIGURATION.md`; Hook Specification extended with post-compact / phase-transition-whitelist / verify-terminal-output (removed) / session-ownership / issue-comment-wm-sync / wiki-ingest-trigger + wiki-query-inject / workflow-incident-emit / hook-preamble / helper-scripts sub-sections
  - CLAUDE.md architecture diagram refreshed; `docs/BEST_PRACTICES_ALIGNMENT.md` archived under `docs/archive/` as historical v0.1–v0.3 reference
  - CHANGELOG Unreleased populated with post-v0.4.0 develop activity
  - Repo-wide version rename 1.0.0 → 0.4.0 (next release planned as v0.4.0 not v1.0.0); version files, README badges, CHANGELOG [1.0.0] entry → [0.4.0], and internal `v1.0.0` references updated
- **Bidirectional backlink format unified to colon notation** across `commands/` — `refactor(commands)` aligning Wiki cross-reference style project-wide, and extending existing DRIFT-CHECK ANCHOR blocks in `wiki/ingest.md` / `wiki/lint.md` with bidirectional backlink entries.
- **Semantic anchor migration** — replaced residual hard-coded line-number literals in `commands/init.md:145` and `hooks/scripts/gitignore-health-check.sh:298` with semantic anchors resilient to future edits.
- **`/rite:wiki:lint` `--auto` early-return alignment** — Phase 1.1 / 1.3 early-return paths aligned with the Phase 9.2 three-piece convention so sentinel / status-line / continuation-hint emission is uniform.
- **Wiki skill polish** — `skills/wiki/SKILL.md` EN description aligned with its canonical form; `wiki/lint.md` completion-report UX output order aligned with the canonical frontmatter order.

### Added

- **Workflow incident auto-registration mechanism** — `/rite:issue:start` now auto-detects workflow blockers (Skill load failure, hook abnormal exit, manual fallback adoption) and registers them as Issues to prevent silent loss. New `plugins/rite/hooks/workflow-incident-emit.sh` emits sentinel patterns (`[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...; iteration_id=...`) from skill internal failure paths and orchestrator fallback prompts. New workflow incident detection logic in `start.md` detects sentinels via context grep, presents `AskUserQuestion` for confirmation, and calls the existing `create-issue-with-projects.sh` with `Status: Todo / Priority: High / Complexity: S / source: workflow_incident`. Same-type incidents are deduplicated within a session. Failure to register is non-blocking. Default-on via new `workflow_incident:` config section (set `enabled: false` to opt out). 11 unit tests added under `plugins/rite/hooks/tests/workflow-incident-emit.test.sh`. Implements all 10 ACs (Skill load failure / hook abnormal exit / manual fallback adoption detection, dedupe, default-on, opt-out, recommendation-flow non-interference, non-blocking error handling). Driven by the meta-incident demonstrated in an earlier PR cycle, where a Skill loader bug was silently bypassed via Edit-tool fallback
- **tech-writer Critical Checklist concretized** — Added 5 doc-implementation consistency items: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order-Emphasis Consistency`, and `Screenshot Presence`. Each item carries a verification method (Grep/Read/Glob), and 3 new sample rows have been added to the Prohibited vs Required Findings table sourced from an internal documentation-centric PR case study (private repository, organization name redacted)
- **internal-consistency.md reference** — New reference file that complements `fact-check.md` (external specs) with an internal-facts verification protocol. Defines 5 Verification Protocol categories, Confidence 80+ gate, severity mapping, and a Cross-Reference section linking it to `tech-writer.md`, `review.md`, and related agent files
- **Doc-Heavy PR Detection** — Automatic detection of documentation-centric PRs in `review.md` (formula: `(doc_lines / total_diff_lines >= 0.6)` OR `(doc_files_count / total_files_count >= 0.7 AND total_diff_lines < 2000)`). Excludes rite plugin's own `commands/`, `skills/`, `agents/` `.md` files **and `.md` / `.mdx` translation documentation under `plugins/rite/i18n/**`** (prompt-engineer territory / dogfooding artifacts; non-Markdown translation resources such as `.yml` / `.json` / `.po` under `plugins/rite/i18n/` are not part of the `doc_file_patterns` numerator in the first place, so the exclusion is a no-op for them). Added optional schema `review.doc_heavy.*` (keys: `enabled`, `lines_ratio_threshold`, `count_ratio_threshold`, `max_diff_lines_for_count`) to `rite-config.yml`
- **Doc-Heavy Reviewer Override** — When `{doc_heavy_pr == true}`, promote tech-writer from recommended to mandatory and add code-quality as co-reviewer through one of three independent paths so the final state always has ≥2 reviewers:
  - **Normal path**: Add code-quality when fenced code blocks (` ```bash ` / ` ```yaml ` / ` ```python ` etc.) are detected in the diff. Pure-prose PRs do **not** trigger this path.
  - **Fail-safe path**: When the diff scan itself fails (`git diff` IO error, grep IO error, etc.), code-quality is added regardless of whether fenced blocks were detected, to preserve verification strength when the detection signal is unavailable.
  - **Fallback path**: When no fenced blocks are detected and the Doc-Heavy override produced no addition, the sole-reviewer guard adds code-quality as a fallback in the next phase.

  Passes `{doc_heavy_pr=true}` flag to tech-writer to activate the 5-category verification protocol defined in `internal-consistency.md` (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence), makes the `Evidence:` line mandatory on each finding, and triggers the Doc-Heavy post-condition check in `review.md`
- **`/rite:pr:fix` accepts PR URL / comment URL directly** — `/rite:pr:fix` now accepts PR URL or comment URL arguments in addition to PR number, allowing findings from external review tools (e.g. `/verified-review`) to be parsed directly into the fix loop. Accepted URL formats include trailing paths (`/files`), query strings (`?tab=files`), and fragment identifiers (`#diff-...`) — all are normalized on argument ingest. Comments must contain a markdown table with at least 4 columns (with optional 5th `confidence` column). See `plugins/rite/commands/pr/fix.md` argument-parsing sections for the full argument spec, header detection keywords, and severity alias mapping
- **`[fix:pushed-wm-stale]` output pattern** — `/rite:pr:fix` now emits `[fix:pushed-wm-stale]` when the work memory update soft-failed. Firing conditions map 1:1 to the reason table in `commands/pr/fix.md` — each natural-language phrase below annotates its corresponding `reason` label. See the reason table for the complete list of `reason` values:
  - `current_body` empty → `current_body_empty`
  - `issue_number` not found → `issue_number_not_found`
  - PATCH 4xx/5xx → `patch_failed`
  - `pr_body` grep IO error → `pr_body_grep_io_error` (+ `mktemp_failed_pr_body_grep_err` for its stderr tempfile)
  - branch grep IO error → `branch_grep_io_error` (+ `mktemp_failed_branch_grep_err`)
  - `gh api comments` fetch failure → `gh_api_comments_fetch_failed` (+ `mktemp_failed_gh_api_err`)
  - Python script unexpected exit (generic) → `python_unexpected_exit_$py_exit`
  - `git diff` failure (Python sentinel detection) → `python_sentinel_detected` (reserved exclusively for `GIT_DIFF_FAILED_SENTINEL` match via `sys.exit(2)`)
  - work memory body corruption detected → `wm_body_empty_or_too_short` / `wm_header_missing` / `wm_body_too_small`
  - mktemp failure → `mktemp_failed_*` family (`mktemp_failed_pr_body_tmp`, `mktemp_failed_body_tmp`, `mktemp_failed_tmpfile`, `mktemp_failed_files_tmp`, `mktemp_failed_history_tmp`, `mktemp_failed_diff_stderr_tmp`, etc.)

  The `git diff` failure path also routes through `WM_UPDATE_FAILED=1; reason=python_sentinel_detected` (via Python `sys.exit(2)` and bash `exit 1`). The bash `exit 1` only kills the current bash invocation, but the retained `WM_UPDATE_FAILED=1` flag survives in the conversation context — the soft-failure evaluation still runs, detects the flag via row 2 of the evaluation-order table, and emits `[fix:pushed-wm-stale]` (NOT `[fix:error]`). The hard fail-fast design ensures the PATCH is silently rejected, but the `[fix:pushed-wm-stale]` output pattern is the correct caller-facing signal (see `commands/pr/fix.md` evaluation order and `reason` table for the authoritative flow). Callers (`/rite:issue:start` review-fix loop) **must not** silently treat `[fix:pushed-wm-stale]` as `[fix:pushed]`; instead, they must surface a warning via `AskUserQuestion` and let the user decide whether to continue with stale work memory or pause for manual recovery. See `commands/pr/fix.md` caller semantics for the full contract
- **Bidirectional backlink format verification in `/rite:lint`** — `/rite:lint` now mechanically verifies that Wiki pages maintain bidirectional backlink references in the canonical colon-delimited form. Runs as a non-blocking structural drift check in Phase 3.x and surfaces mismatches in the final report.

### Fixed

- **`wiki-query-inject.sh` origin/wiki fallback** — `/rite:wiki:query` now reads Wiki content via `origin/{wiki_branch}` when the local `wiki` branch does not exist (fresh clone / separate worktree). Previously `git show "${wiki_branch}:.rite/wiki/index.md"` used the bare branch name and failed with `fatal: invalid object name 'wiki'` when only `origin/wiki` was available locally, causing `/rite:wiki:query` to silently return empty context after `/rite:pr:cleanup` on another worktree. Uses the same ref-selection pattern as `cleanup.md` Phase 4.W.1 Step 2 and `wiki-growth-check.sh`. Negative case (neither local nor origin) continues to emit the existing `WARNING: wiki branch not found` and exit 0 (non-blocking). Also adds `wiki_ingest_push_failed` sentinel emission to `cleanup.md` Phase 4.W.3 when `wiki-worktree-commit.sh` reports `push=failed` (rc=4 path inside ingest), so `origin/wiki` divergence becomes observable in the incident layer while preserving loss-safe cleanup continuation. Additionally restores the `wiki_ingest_push_failed` incident type that `plugins/rite/hooks/workflow-incident-emit.sh` was missing from its `--type` whitelist — all existing callers in `pr/review.md`, `pr/fix.md`, and `issue/close.md` that emit this type were silently falling through to the `hook_abnormal_exit` fallback branch, so the dedicated `wiki_ingest_push_failed` sentinel defined in `issue/start.md` ステップ 8.5 (旧 Phase 5.4.4.1 を統合) had never actually been emitted in practice
- **Part A extraction bug in `review.md`** — Fixed Part A section extraction from `_reviewer-base.md` that was dropping `## Cross-File Impact Check` (everything between `## Reviewer Mindset` and `## Confidence Scoring`). Extraction now covers all sections from document start to `## Input` heading (exclusive), enabling the 5 mandatory cross-file consistency checks (deleted/renamed exports, changed config keys, changed interface contracts, i18n key consistency, keyword list consistency) to actually reach reviewer agents for the first time
- **tools/model frontmatter drift in reviewer agents** — Removed `tools:` frontmatter from all 13 reviewer agents (`api`, `code-quality`, `database`, `dependencies`, `devops`, `error-handling`, `frontend`, `performance`, `prompt-engineer`, `security`, `tech-writer`, `test`, `type-design`) and `model: sonnet` from 4 reviewers (`code-quality`, `error-handling`, `performance`, `type-design`). Previously these fields were ignored at runtime (reviewers are invoked via `subagent_type: general-purpose`), but would have silently broken when the named subagent migration completes (tech-writer would lose Bash and break Doc-Heavy PR Mode; 4 reviewers would regress to sonnet for opus users). The 9 remaining reviewers retain `model: opus` as an explicit high-quality review pin (intentionally kept; opus was already the runtime-effective model and removing the pin would have regressed them to session default which may be sonnet). Related `docs/SPEC.md` / `docs/SPEC.ja.md` Agent File Format section updated to mark `tools` as optional (inherit) and the Current Agents table updated to reflect the 4 reviewers as `inherit`
- **Verification-mode post-condition check added** — `review.md` now adds a post-condition check (child of the Verification Mode Findings Collection logic) that validates each reviewer in `verification` mode emits the `### 修正検証結果` table. On initial detection, a per-reviewer retry (via the reviewer invocation Task tool) is attempted with strict verification template instructions; on persistent absence, `verification_post_condition: error` is set, the overall assessment is promoted to `修正必要` (unified with the escalation chain labels — `要修正` is a reviewer-level label and is not used for overall assessment promotion), and all findings from the non-compliant reviewer are treated as blocking. Classification vocabulary is `passed` / `warning` / `error` (unified with `doc_heavy_post_condition`). Retained flags `verification_post_condition` and `verification_post_condition_retry_count` (per-reviewer dict) are registered in the retained flags list and displayed in the verification mode template. Prevents silent pass when a reviewer skips verification output
- **`commands/pr/fix.md` reason-table drift** — Expanded the `reason` table to cover all 28 `WM_UPDATE_FAILED` reasons actually emitted in the work memory update paths (previously only 12 were listed, 16 were missing). The eval-order table row 2 now defers to "reason 表のいずれか" instead of enumerating a subset, eliminating the double-drift problem. DoD verification (manually executed): `comm -3 <(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' plugins/rite/commands/pr/fix.md | sed 's/.*reason=//' | sort -u) <(awk '/^\*\*`reason` フィールド/{in_table=1;next} in_table && /^\*\*/{in_table=0} in_table && /^\| `[a-z_]/{match($0, /`[a-z_][a-z_0-9]*[^`]*`/); print substr($0, RSTART+1, RLENGTH-2)}' plugins/rite/commands/pr/fix.md | sed 's/\$.*//' | sort -u)` returns empty (28 WM_UPDATE_FAILED reasons in emits exactly match the 28 entries in the reason table). The awk pattern is scoped to the `**\`reason\` フィールド` section to avoid false positives from other tables in `fix.md` (absorbed from C2)
- **Sub-skill return implicit-stop multi-layer defense** — Accumulated fixes hardening the sub-skill return → orchestrator continuation path against Bash heuristic-induced implicit stops. Covers `create-interview`, `wiki/ingest.md` Phase 8 auto-lint, `pr/cleanup` wiki-ingest return, and `pr/cleanup` wiki-auto-ingest Phase 5 boundaries. Includes `INTERVIEW_DONE=1` plain-text marker and `stop-guard.sh` case-arm `WORKFLOW_HINT` expansion with Step 0 Immediate Bash Action.
- **`wiki/lint.md` Phase 9.2 `--auto` continuation sentinel** — `--auto` output now emits an explicit continuation sentinel so callers can distinguish completed-with-warnings from silent-skip.
- **`pr/cleanup` completion message trailing blank line** — Removed the spurious trailing blank line after the "次のステップ" heading for cleaner terminal rendering.
- **Preprocessor-safe syntax migration in `wiki/` and `pr/cleanup`** — Residual `!`+backtick expressions that the slash-command preprocessor evaluated via bash (causing `slash command not found` failures) were migrated to the `if ! cmd; then` form per the documented convention.

## [0.3.10] - 2026-04-04

### Changed

- Review-fix loop overhaul — bash error-handling detection, existing CRITICAL visibility, first-pass rule improvements
- Sole reviewer guard + Step 6 sub-checks extension to eliminate blind spots in single-reviewer scenarios
- Reviewer co-selection expanded — code-quality reviewer now co-selected for code blocks in .md files
- prompt-engineer-reviewer detection scope expanded — Content Accuracy, List Consistency, Design Logic Review
- Stale Cross-References detection step coverage added to Step 7
- Verification mode disabled by default + context-pressure phase condition branching
- i18n Sprint key sections merged + en/ja other.yml duplicate sections normalized
- Hook scripts unified to `echo | jq` syntax

### Fixed

- Hook script jq extraction robustness — CWD fallback, pre-tool-bash-guard fallback, context-pressure.sh silent abort prevention
- Review quality improvements — Confidence Calibration sort order, E2E auto-create flow, recommendation-flow Source C consistency, multiple comment precision fixes

## [0.3.9] - 2026-04-03

### Added

- Reviewer foundation — `{agent_identity}` extraction, `_reviewer-base.md` shared principles, 4 core agents (security, code-quality, prompt-engineer, tech-writer) + confidence_threshold config
- Reviewer expansion — 7 remaining agents rebuilt + 2 new reviewers (error-handling, type-design)
- `schema_version` introduction + automatic upgrade mechanism for `rite-config.yml`

### Fixed

- Removed deprecated `commit.style` code examples from all documentation and project-type templates
- Updated config examples in documentation to `schema_version: 2` format
- Enforced sub-agent invocation in verification mode re-review
- Auto-create Issues from recommendation items marked as "separate Issue"
- Reset `error_count` to 0 on `flow-state-update.sh` patch mode to prevent stale circuit breaker

## [0.3.8] - 2026-04-01

### Added

- Fact-Checking Phase for PR review — verifies external specification claims against official documentation via WebSearch/WebFetch
- context7 MCP tool integration as optional verification method for fact-checking (`review.fact_check.use_context7`, default: off)

### Fixed

- Added `.rite-initialized-version` and `.rite-settings-hooks-cleaned` to `.gitignore`

## [0.3.7] - 2026-04-01

### Changed

- Reviewer findings now include WHY + EXAMPLE structure for more actionable fix guidance

## [0.3.6] - 2026-03-27

### Added

- Sprint Contract — per-step verification criteria for implementation phases
- Evaluator calibration — few-shot examples and skeptical tone for reviewers
- Post-Step Quality Gate — self-check after each implementation step
- Context reset strategy enhancement — stronger context management across phases

## [0.3.5] - 2026-03-27

### Added

- `/rite:investigate` skill — structured code investigation with Grep→Read→Cross-check 3-phase process
- `investigation-protocol.md` reference for lightweight code investigation across all workflow phases
- `investigate.codex_review.enabled` option in `rite-config.yml` to make Codex cross-check optional

### Fixed

- Migrated legacy hooks from `settings.local.json` to native `hooks.json` management

## [0.3.4] - 2026-03-20

### Changed

- Unified plugin path resolution to a version-independent method — `session-start.sh` now writes resolved path to `.rite-plugin-root`, command files read it via `cat`

## [0.3.3] - 2026-03-19

### Fixed

- Fixed SessionStart hook error when executing `/clear` in marketplace-installed environments

## [0.3.2] - 2026-03-17

### Fixed

- `/rite:init` now detects existing hooks in `settings.json` to prevent conflicts

### Changed

- Removed unused settings and added missing settings in `rite-config.yml`

### Docs

- Added AskUserQuestion enforcement and branch deletion steps to release skill

## [0.3.1] - 2026-03-17

### Fixed

- Verification mode now triggers full review instead of partial review
- Removed `{session_id}` placeholder and unified to auto-read pattern
- Strengthened sub-skill return interruption prevention in `create.md`
- Fixed Issue comment work memory backup sync
- Fixed bash redirection error when `.rite-session-id` is absent
- Fixed `session-start.sh` not resetting other sessions' active state on startup/clear
- Removed graduated relaxation logic from review-fix loop — all findings now require fix
- Made reviewer confirmation and Ready confirmation unskippable in e2e flow
- Used patch method for flow-state deactivation
- Fixed blocking/non-blocking remnants in review template output examples
- Fixed path resolution inconsistency with `--if-exists` pattern
- Added Defense-in-Depth flow-state updates to early-phase sub-skills

### Changed

- Abolished `loop_count`/`max_iterations`/`loop-limit` parameters
- Completely removed `--loop` parameter from `flow-state-update.sh`
- Added `hooks/hooks.json` native method with double-execution guard
- Added 3 quality rules to the review template
- Abolished trap in `session-start.sh` and improved debug logging

### Docs

- Updated review-fix loop documentation

## [0.3.0] - 2026-03-16

### Added

- Session ownership system for multi-session conflict prevention
  - Session ownership helper functions and flow-state overwrite protection
  - Session ownership support in `session-start.sh`
  - Session ownership support in `session-end.sh` and `stop-guard.sh`
  - Session ownership support in `wm-sync`, `pre-compact`, `context-pressure` hooks
  - `--session {session_id}` parameter added to all command files + `resume.md` ownership transfer

### Fixed

- Checklist auto-check processing added to `start.md`
- Branch existence check now uses output string instead of exit code
- Issue create output order improved — next steps moved to end
- PostToolUse hook auto-syncs Issue comment work memory on phase change
- `review.md` READ-ONLY constraint added to normalize review-fix loop
- Review → fix loop branch instructions rewritten to imperative conditional
- `session-end.sh` diagnostic log added for other session exit path
- Debug output remnants removed from hooks

### Changed

- Issue comment work memory update logic refactored to script for deterministic execution

### Docs

- Added `git branch --list` DO NOT warning to `gh-cli-commands.md`

## [0.2.5] - 2026-03-16

### Added

- Contextual Commits integration: structured action lines in commit body for decision persistence
  - Configuration and reference documentation (`commit.contextual` setting)
  - Action line generation in `implement.md` commit flow
  - Action line generation in `pr/fix.md` review-fix commit flow
  - `/rite:issue:recall` command for searching contextual commit history
  - Action line generation in `team-execute.md` parallel commit flow

### Fixed

- Edge case handling in `recall.md`: base branch fallback, grep metacharacter escaping, max-count consistency
- Added GitHub Projects integration and status transitions to release skill

## [0.2.4] - 2026-03-14

### Fixed

- Work memory implementation plan step states now batch-updated on commit
- Applied Defense-in-Depth pattern to create-decompose.md
- Unified legacy state name `blocked` to `recovering` in tests
- Added develop branch recovery procedure for auto-deletion after merge

### Changed

- Clarified Defense-in-Depth pattern ordering and removed redundancy
- Introduced PostCompact hook for automated auto-compact recovery

### Improved

- Enhanced prompt quality for create sub-skill

## [0.2.3] - 2026-03-13

### Fixed

- Reinforced auto-continuation after sub-skill return in create workflow

## [0.2.2] - 2026-03-12

### Added

- Marketplace hook path auto-update on version upgrade

### Fixed

- Parent Issue Projects status auto-update not executing

## [0.2.1] - 2026-03-12

### Added

- E2E flow context window overflow prevention mechanism
- Agent delegation Skill tool format in prompts
- Agent delegation AGENT_RESULT fallback handling

### Fixed

- Reinforced prompt to prevent Claude from stopping during sub-skill transitions
- Clarified work memory progress summary and changed files update logic
- Sub-skill transition instructions strengthened in create workflow
- Hardcoded bash hook paths replaced with `{plugin_root}` for marketplace compatibility
- Clarified resume counter restoration execution timing and ownership
- `context-pressure.sh` python3 startup optimization and COUNTER_VAL validation
- Ensured GitHub Projects registration when creating Issues via PR command
- Separated work memory progress summary and changed files update from checklist update
- `flow-state-update.sh` `--active` flag support in patch mode
- `flow-state-update.sh` `--` separator before jq filter in patch mode
- `fix.md` work memory trap integration for `$pr_body_tmp`
- Fixed work memory progress summary and changed files not updating during review/fix loop

### Changed

- Progress summary regex hardened for robustness
- Updated `lint.md` references and added concrete examples to `start.md`
- `resume.md` counter restoration snippet structured as formal subsection
- `review.md` session info update defense-in-depth intent documented

## [0.2.0] - 2026-03-05

### Added

- Plugin version check on session startup

### Changed

- Replaced Zen/禅 references with rite in SPEC and command docs

## [0.1.3] - 2026-03-05

### Changed

- Offloaded deterministic processing to shell scripts (`flow-state-update.sh`, `issue-body-safe-update.sh`), replacing 24 inline jq + atomic write patterns across 8 files
- Extracted completion report section from `start.md` into `completion-report.md`
- Extracted assessment rules from `review.md` into `references/assessment-rules.md`
- Extracted archive procedures from `cleanup.md` into `references/archive-procedures.md`
- Optimized SKILL.md description to active style and compressed table to pointer + summary format
- Added Why-driven rationale to MUST/CRITICAL directives across 7 major commands
- Added Input/Output Contract sections to 7 major commands

## [0.1.2] - 2026-03-04

### Fixed

- Fixed `work-memory-init` validation script missing else branch for success case
- Fixed work memory comment being overwritten by API error response
- Fixed unnecessary hooks unregistered message during rite workflow execution
- Fixed `stop-guard.sh` trap missing EXIT signal
- Fixed `stop-guard.sh` compact_state stop block failure
- Fixed `session-start.sh` jq error handling issues
- Fixed `/rite:issue:start` completion report not executing
- Fixed parent Issue Projects status not updating from Todo to In Progress
- Fixed `/rite:issue:start` Bash command errors
- Fixed find cleanup pattern to be mktemp suffix-length independent
- Fixed `ready.md` output pattern and defense-in-depth for Mandatory After
- Applied work memory update safety patterns consistently across all commands
- Fixed stop-guard and post-compact-guard deadlock race condition
- Fixed `/clear → /rite:resume` duplicate guidance message

### Changed

- Refactored `stop-guard.sh` grep -A20 hard-coded value to awk section extraction
- Refactored `pre-compact.sh` echo|jq pipe to here-string
- Refactored `stop-guard.sh` subshell optimization
- Unified PID-based temp file naming to mktemp with fallback

### Removed

- Removed rebrand mentions from v0.1.0 changelog entries

## [0.1.1] - 2026-03-03

### Fixed

- Fixed Implementation Contract format not applied when creating single Issue for large-scope tasks
- Fixed `/rite:issue:create` interruption after sub-skill return
- Fixed `/rite:issue:start` interruption during end-to-end flow
- Fixed work memory corruption on update with safety patterns and destruction prevention

## [0.1.0] - 2026-03-01

### Added

- Initial release of Rite Workflow
- Issue-driven development workflow for Claude Code
- Multi-reviewer PR review system with debate phase
- Sprint planning and team execution
- GitHub Projects integration
- Hook-based session management (stop-guard, pre-compact, session lifecycle)
- i18n support (Japanese, English)
- TDD Light mode
- Parallel implementation with git worktree support

[0.6.4]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.5.5...v0.6.0
[0.5.5]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.10...v0.4.0
[0.3.10]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/asakaguchi/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/asakaguchi/cc-rite-workflow/releases/tag/v0.1.0
