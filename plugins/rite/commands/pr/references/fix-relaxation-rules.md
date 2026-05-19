# Fix Targeting Rules

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

Defines how fix targets are determined in the `/rite:issue:start` review-fix loop.

## Overview

All findings whose `scope ∈ {current-pr, follow-up}` are always blocking regardless of severity. The review-fix loop continues until all such findings are resolved (**0 blocking findings remaining is the only normal exit**). Findings with `scope == "nit-noted"` are **not blocking** — they are handled via the reply-only path (Issue #1018 / M2) and never participate in `/rite:pr:fix` Phase 2.1 selection nor in mergeable countdown.

## Fix Target Classification

Findings are classified by **severity × scope**. Scope was added in schema 1.1.0 (Issue #1016); the M2 receive-flow path (Issue #1018) routes `nit-noted` findings out of the blocking set entirely.

| Severity | Scope | Classification | Action |
|----------|-------|----------------|--------|
| CRITICAL | current-pr / follow-up | Blocking | Must fix |
| CRITICAL | nit-noted | **禁止** (schema invariant #4 FAIL) | Reviewer reject + reroll — never reaches fix loop |
| HIGH | current-pr / follow-up | Blocking | Must fix |
| HIGH | nit-noted | **禁止** (schema invariant #4 FAIL) | Reviewer reject + reroll — never reaches fix loop |
| MEDIUM | current-pr / follow-up | Blocking | Must fix |
| MEDIUM | nit-noted | **blocking 対象外** (requires `nit_reason`) | Reply-only via Phase 2.4 `nit-noted-reply`, no fix commit |
| LOW-MEDIUM | current-pr / follow-up | Blocking | Must fix |
| LOW-MEDIUM | nit-noted | **blocking 対象外** | Reply-only via Phase 2.4 `nit-noted-reply` |
| LOW | current-pr | Blocking — but auto-demoted to nit-noted when `review.scope_assignment.auto_demote_low: true` (default) | Demote then reply-only; opt-out with `auto_demote_low: false` keeps blocking |
| LOW | follow-up | **禁止セル** (SoT: [`severity-levels.md` §Severity × Scope Matrix](../../../references/severity-levels.md#severity--scope-matrix)) | LOW × follow-up は意味論的禁止 (LOW は本 PR で修正するか nit として受け流すかの二択、別 Issue 化は冗長)。reviewer 側で reject される — fix loop には到達しない |
| LOW | nit-noted | **blocking 対象外** | Reply-only via Phase 2.4 `nit-noted-reply` |

> **scope=nit-noted は blocking 対象外**: 上表で「blocking 対象外」の行は (a) `/rite:pr:fix` Phase 1.3 で「nit (認知のみ)」セクションに分類、(b) Phase 1.4 で auto-select 対象から除外、(c) Phase 2.1 を skip して Phase 2.4 へ直行、(d) Phase 4.3.1 別 Issue 化候補からも完全除外、(e) Phase 4.6 サマリで `acknowledged_nit_count` として独立カウントされる。`/rite:pr:review` Phase 5.3 評価では `overall_assessment` に影響せず、mergeable 判定 countdown 対象からも除外される (詳細は [`assessment-rules.md`](./assessment-rules.md) §5.3.1 / §5.3.3 参照)。

## Loop Termination (v0.4.0 #557)

The review-fix loop exits via exactly two paths:

| Exit Type | Condition | Result |
|-----------|-----------|--------|
| **Normal** | 0 findings remaining | `[review:mergeable]` |
| **Escalate** | Any of the 4 quality signals fires | Present `AskUserQuestion` → user decides (continue / create separate Issue / withdraw / manual review) |

Cycle-count-based degradation (convergence strategy override / hard limit / severity gating) was fully removed in v0.4.0. See `commands/issue/start.md` Phase 5.4 for the escalate logic.

## Four Quality Signals for Escalation

Instead of cycle counting, the loop monitors quality signals that **each independently** indicate non-convergence. If any fires, the orchestrator escalates to the user.

| # | Signal | Detection | Where it runs |
|---|--------|-----------|---------------|
| 1 | **Same-finding cycling** | A finding fingerprint (file + category + normalised message) appears in two or more cycles | `start.md` Phase 5.4.1.0 |
| 2 | **Root-cause-missing fix** | A fix commit body lacks `Root cause:` / `根本原因:` section | `fix.md` Phase 3 (root-cause gate) |
| 3 | **Cross-validation disagreement** | Two or more reviewers report the same finding with severity gap ≥ 2 and debate fails to resolve | `review.md` Phase 5.2 + debate |
| 4 | **Finding quality gate failure** | Reviewer degrades itself (self-reports inability to provide confident findings) | `_reviewer-base.md` Finding Quality Guardrail |

Bikeshedding and defensive-code suggestions are filtered out by the Finding Quality Guardrail **before** output, so they never reach the loop counter. Only confident, evidence-backed findings participate in the fingerprint cycling signal.

## Caller Detection

**Scope**: このセクションは **fix target 選択**（Phase 2.1、どの findings を修正対象とするか）の caller-based 自動化のみを扱います。**separate issue creation**（Phase 4.3.3、skip findings の別 Issue 化可否の確認）は #506 以降、caller に関係なく **常に `AskUserQuestion` で確認** されるため、本 Caller Detection の対象外です。

Automatic fix target selection (Phase 2.1) is applied only when `/rite:pr:fix` is called from within the `/rite:issue:start` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains execution context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop → Apply automatic selection (all findings) |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` (recent message) | Within loop → Apply automatic selection (all findings) |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options. **Note**: Regardless of caller, separate-issue creation for skipped findings (Phase 4.3.3) always presents `AskUserQuestion` with options `retry in current PR / create separate issue / withdraw` as of #506.
