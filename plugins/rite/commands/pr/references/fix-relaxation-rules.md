# Fix Targeting Rules

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

Defines how fix targets are determined in the `/rite:pr:iterate` review-fix loop.

## Overview

All findings whose `scope ∈ {current-pr, follow-up}` are always blocking regardless of severity. The review-fix loop continues until all such findings are resolved (**0 blocking findings remaining is the only normal exit**). Findings with `scope == "nit-noted"` are **not blocking** — they are handled via the reply-only path (Issue #1018 / M2) and never participate in `/rite:pr:fix` Phase 2.1 selection nor in mergeable countdown. **別 Issue 化の経路は廃止済み** (Issue #1136) — current-pr / follow-up 指摘は本 PR で対応するか accept (認知のみ) で受け流すかの 2 択になる。

## Fix Target Classification

Findings are classified by **severity × scope**. Scope was added in schema 1.1.0 (Issue #1016); the M2 receive-flow path (Issue #1018) routes `nit-noted` findings out of the blocking set entirely.

| Severity | Scope | Classification | Action |
|----------|-------|----------------|--------|
| CRITICAL | current-pr / follow-up | Blocking | Must fix |
| CRITICAL | nit-noted | **禁止** (schema invariant #4 FAIL) | Reviewer reject + reroll — never reaches fix loop |
| HIGH | current-pr / follow-up | Blocking | Must fix |
| HIGH | nit-noted | **禁止** (schema invariant #4 FAIL) | Reviewer reject + reroll — never reaches fix loop |
| MEDIUM | current-pr / follow-up | Blocking — but auto-demoted to nit-noted when finding has no functional impact (see §Practical Impact Demotion) | Demote then reply-only; functional impact 確認後に blocking 判定 |
| MEDIUM | nit-noted | **blocking 対象外** (requires `nit_reason`) | Reply-only via Phase 2.4 `nit-noted-reply`, no fix commit |
| LOW-MEDIUM | current-pr / follow-up | Blocking — but auto-demoted to nit-noted when `review.scope_assignment.auto_demote_low: true` (default) | Demote then reply-only |
| LOW-MEDIUM | nit-noted | **blocking 対象外** | Reply-only via Phase 2.4 `nit-noted-reply` |
| LOW | current-pr | Blocking — but auto-demoted to nit-noted when `review.scope_assignment.auto_demote_low: true` (default) | Demote then reply-only; opt-out with `auto_demote_low: false` keeps blocking |
| LOW | follow-up | **禁止セル** (SoT: [`severity-levels.md` §Severity × Scope Matrix](../../../references/severity-levels.md#severity--scope-matrix)) | LOW × follow-up は意味論的禁止 (LOW は本 PR で修正するか nit として受け流すかの二択)。reviewer 側で reject される — fix loop には到達しない |
| LOW | nit-noted | **blocking 対象外** | Reply-only via Phase 2.4 `nit-noted-reply` |

> **scope=nit-noted は blocking 対象外**: 上表で「blocking 対象外」の行は (a) `/rite:pr:fix` Phase 1.3 で「nit (認知のみ)」セクションに分類、(b) Phase 1.4 で auto-select 対象から除外、(c) Phase 2.1 を skip して Phase 2.4 へ直行、(d) fix commit 対象からも完全除外、(e) Phase 4.6 サマリで `acknowledged_nit_count` として独立カウントされる。`/rite:pr:review` Phase 5.3 評価では `overall_assessment` に影響せず、mergeable 判定 countdown 対象からも除外される (詳細は [`assessment-rules.md`](./assessment-rules.md) §5.3.1 / §5.3.3 参照)。

## Practical Impact Demotion (Issue #1136)

`auto_demote_low` の対象を **「LOW + 実害なし MEDIUM」** に拡張する。reviewer の指摘が以下のカテゴリに該当する場合、`severity=MEDIUM` でも `scope=nit-noted` に自動降格して reply-only 経路に流す:

| カテゴリ | 例 | 降格判定 |
|---------|---|---------|
| style preference | indentation 揃え方、命名 case の好み、import 順序 | **降格** (nit-noted へ) |
| typo (user-facing でない) | comment 内 / variable 名 / 内部ログ文字列の typo | **降格** |
| dead code がコメント済み | `// TODO: remove` 等の宣言だけある dead code | **降格** |
| TODO comment | `// TODO:` で実装方針を note しただけ | **降格** |
| 命名 nit (bikeshedding) | `getUserData` vs `fetchUser` のような同義語論争 | **降格** |

**降格対象外** (必ず blocking):

| カテゴリ | 例 | 理由 |
|---------|---|------|
| security | auth bypass、injection、secret leak | functional impact 大 |
| correctness bug | race / off-by-one / null deref / 不正な状態遷移 | runtime behavior 破壊 |
| data loss / corruption | DB migration の不可逆操作、書き込み順序問題 | recover 不能 |
| regression | 既存 behavior の silent 変更 | 既存ユーザー影響 |
| user-facing typo | UI / error message / docs / API response 内の typo | 利用者の混乱 / 信頼性低下 |

判定境界が曖昧な場合 (例: typo が internal log か user-facing か判別困難) は **降格しない** (blocking 維持)。「迷ったら blocking」が原則で、reviewer の意図と乖離するリスクを避ける。

設定:

```yaml
review:
  scope_assignment:
    auto_demote_low: true   # default true; LOW + 実害なし MEDIUM を nit-noted に降格
```

`auto_demote_low: false` の場合、LOW × current-pr / 実害なし MEDIUM × current-pr は通常通り blocking 扱いになる。

## Loop Termination (Issue #1136)

The review-fix loop exits via:

| Exit Type | Condition | Result |
|-----------|-----------|--------|
| **Normal** | 0 blocking findings remaining | `[review:mergeable]` → `/rite:pr:iterate` がループ終了 |
| **Manual abort** | ユーザーが Ctrl+C で中断 | `flow-state` に現 phase が残るので `/rite:resume` で復帰 |

`/rite:pr:iterate` には cycle counter / N 回上限 / quality-signal escalation / ping-pong サーキットブレーカー は**存在しない** (Issue #1136 で全廃)。「指摘ゼロまでループする」の契約に忠実で、停止する場合はユーザー判断のみ。

`fix.md` Phase 3 の Root Cause Gate (#557) は引き続き **fix commit 側の品質ゲート**として機能する (root-cause-missing fix を reject)。loop 制御とは別経路。

## Caller Detection

**Scope**: このセクションは **fix target 選択**（Phase 2.1、どの findings を修正対象とするか）の caller-based 自動化のみを扱います。

Automatic fix target selection (Phase 2.1) is applied only when `/rite:pr:fix` is called from within the `/rite:pr:iterate` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains execution context from `/rite:pr:iterate` review-fix loop | Within loop → Apply automatic selection (all findings) |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` (recent message) | Within loop → Apply automatic selection (all findings) |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options. Issue #1136 以降は separate-issue creation の AskUserQuestion 経路は廃止されているため、Phase 2.1 の選択肢は「コードを修正する / accept (認知のみ) / 説明・返信のみ」の 3 択になる (skip → 別 Issue 化の選択肢は提示しない)。
