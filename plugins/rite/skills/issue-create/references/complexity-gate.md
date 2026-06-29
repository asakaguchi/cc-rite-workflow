# Complexity Gate — Tentative Complexity Estimation + Heuristics Scoring

> **SoT scope**: `/rite:issue-create` における **複雑度判定 (XS/S/M/L/XL)** の rubric を集約する。`templates/issue/default.md` の Complexity Heuristics セクションが本 reference を SoT として参照する。`skills/issue-create/SKILL.md` 側の consumer は ステップ 3.1 (規模ヒューリスティック) と ステップ 4.1 (Issue 情報の最終確認) の 2 箇所。

## Tentative Complexity Estimation

入力情報から暫定的に推定する quick reference 表。Issue 規模が `L` 以上に達するかを `skills/issue-create/SKILL.md` ステップ 3.1 で判別するための input として使う。

| Tentative Complexity | Criteria | Example |
|---------------------|----------|---------|
| **XS** | Change location is clear, 1 to a few lines of modification | typo fix, constant value change |
| **S** | Content update in a single file, implementation method is uniquely determined | function fix, style adjustment |
| **M** | Multiple files (approx. 2-5 files) or involves one design decision | small feature addition |
| **L** | Multiple files (approx. 6-10 files), requires multiple design decisions | medium-scale feature, design change |
| **XL** | Large-scale change (10+ files) or spans multiple domains, architecture-level design decisions | new system construction, architecture change |

- `skills/issue-create/SKILL.md` ステップ 3.1 規模ヒューリスティック条件「Complexity ≥ L (推定)」はこの Tentative 値を使う
- `skills/issue-create/SKILL.md` ステップ 3.2 分解確認では **XL のみ** を decomposition trigger とする (L は対象外)
- 最終的な complexity は `skills/issue-create/SKILL.md` ステップ 4.1 の AskUserQuestion 確認値が確定値となる ([Final Complexity Decision Rules](#final-complexity-decision-rules) 参照)

---

## Complexity Heuristics Scoring

Tentative と並行して評価する精緻 rubric。両者が不一致の場合は Heuristics Score を優先する。

Score を +1 する条件:

| Condition | Score |
|-----------|-------|
| Changed files > 3 | +1 |
| Spans multiple modules/services | +1 |
| Public API/interface changes | +1 |
| Migration/backward compatibility needed | +1 |
| Strict non-functional requirements | +1 |
| 2+ unresolved design decisions | +1 |

Score → complexity mapping:

| Score | Complexity |
|-------|------------|
| 0-1 | XS |
| 2 | S |
| 3-4 | M |
| 5 | L |
| 6+ | XL |

`skills/issue-create/SKILL.md` ステップ 1.3 (What/Why/Where 抽出) と ステップ 3.1 (規模ヒューリスティック) で得られた情報から各条件を評価する。

---

## Final Complexity Decision Rules

Tentative Complexity Estimation と Heuristics Scoring が不一致の場合、Heuristics Score が優先される。

| 状況 | Behavior |
|------|----------|
| Tentative と Heuristics が一致 | その値を最終 complexity として採用 |
| Tentative と Heuristics が不一致 | **Heuristics Score 優先** (Tentative は quick reference のみ) |
| `skills/issue-create/SKILL.md` ステップ 3.1 で大型タスク候補 (XL trigger) と判定された場合 | Tentative baseline として **XL** を採用。Heuristics scoring 条件が低 complexity を示せば downward 調整される |
