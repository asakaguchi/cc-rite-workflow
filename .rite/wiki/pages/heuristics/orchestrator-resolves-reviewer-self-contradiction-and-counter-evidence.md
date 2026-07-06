---
type: "heuristics"
title: "Orchestrator は reviewer 間の反証と reviewer 自身の自己矛盾（指摘記載 vs 結論）を解決してから blocking 判定する"
domain: "heuristics"
description: "複数 reviewer の所見が食い違う場合は他 reviewer の反証（既存実装の grep 確認）で解決し、単一 reviewer の指摘事項テーブル記載でも reviewer 自身が「対応不要」と結論した場合は Finding Quality Guardrail (bikeshedding filter) で blocking から除外する。"
created: "2026-07-06T04:10:00+00:00"
updated: "2026-07-06T05:02:35+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260706T033041Z-pr-1756.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T040234Z-pr-1756-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T043448Z-pr-1757.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T050235Z-pr-1758.md"
tags: []
confidence: medium
---

# Orchestrator は reviewer 間の反証と reviewer 自身の自己矛盾（指摘記載 vs 結論）を解決してから blocking 判定する

## 概要

PR #1756 の 2 cycle レビューで、orchestrator（consolidation 担当）が単純な「指摘事項テーブルの件数 = blocking 件数」という機械的合算をせず、(1) 複数 reviewer 間の反証関係、(2) reviewer 自身の総合評価と個別指摘の矛盾、の 2 つを見て blocking findings を確定させた 2 つの実例。

## 詳細

### 実例 1: cross-validation による反証（cycle 1）

tech-writer が「Issue body 取得のフォールバック欠如」を懸念として指摘したが、同時に走った prompt-engineer が「Phase 1.5 で既に Issue body を無条件取得済みのため懸念は根拠がない」と独立に反証した。orchestrator は `grep` で `pr-create/SKILL.md` の Phase 1.5 実装を直接確認し、`gh issue view {issue_number} --json number,title,body,state,labels` が無条件実行されることを検証した上で、tech-writer の指摘を false positive と判断して fix 対象から除外した。

**教訓**: 単一 reviewer の懸念を鵜呑みにせず、(a) 他 reviewer が独立に反証していないか、(b) 反証内容が実装の事実と一致するか、を orchestrator 自身が実ファイルで検証する。2 reviewer が食い違う所見を出すのは対立ではなく、互いの盲点を埋め合う機会として扱う。

### 実例 2: Finding Quality Guardrail (bikeshedding filter) の適用（cycle 2）

fix 後の cycle 2 レビューで、prompt-engineer / tech-writer の両者が「overall assessment: Approve/mergeable」と明記した上で、指摘事項テーブルには計 5 件（見出しの語順選好、文の冗長さ、参照アンカーの非対称、列挙順序の不一致、用語の近接による誤読可能性）を掲載していた。個別の指摘文はいずれも「任意」「対応不要（記録のみ）」と reviewer 自身が明記しており、プロジェクト規約の明示的違反を伴わない好み・スタイルレベルの指摘だった。orchestrator は `_reviewer-base.md` の Finding Quality Guardrail（bikeshedding: プロジェクト規約の明示的違反を伴わない好み・スタイル指摘は filter 対象）をこの 5 件に適用し、blocking findings を 0 件と判定して `[review:mergeable]` を確定した。

**教訓**: 「指摘事項テーブルに載っている = 自動的に blocking」という機械的解釈をしない。reviewer 自身の overall assessment（Approve/mergeable）と個別指摘の文言（「任意」「対応不要」）が一致している場合、その指摘は Finding Quality Guardrail の対象として orchestrator が自身の判断で blocking から除外してよい。逆に、reviewer が overall assessment で懸念を示しているのに個別指摘が軽微に見える場合は、機械的に除外せず再確認する（非対称的な適用— bikeshedding filter は「reviewer 自身が要求していない追加対応をしない」ためのものであり、reviewer の総合判断を覆すためのものではない）。

### 実例 3: 全く別の PR・reviewer 組み合わせでの再現（PR #1757）

1 行のドキュメント修正 PR（Doc-Heavy PR、tech-writer + code-quality の2reviewer構成）でも同一パターンが再現した。両 reviewer が独立に計 5 件（Low 2件 + nit 3件）を指摘したが、いずれも各 reviewer 自身が「任意の改善」「マージをブロックしません」「対応不要」と明記し、overall assessment はいずれも「承認（mergeable）」だった。orchestrator は同じ Finding Quality Guardrail を適用し blocking findings 0 件で mergeable 確定した。

**教訓**: この解決パターンは特定の PR やレビュアー組み合わせに依存しない汎用的な orchestrator 責務である。「reviewer 自身の overall assessment ＋ 個別指摘文言の両方が非ブロッキングを明示している」という条件が揃えば、PR の性質（コード変更 / ドキュメント変更）や reviewer の専門領域に関わらず適用してよい。

### 実例 4: docs整合修正PRでの再現（PR #1758）

2ファイル（+8/-1）のドキュメント参照不整合修正PRで、prompt-engineer（必須）+ code-quality（sole-reviewer guard co-reviewer）の2reviewer構成でも同一パターンが再現した。両reviewerが独立に計3件（すべてLow）を指摘したが、いずれも各reviewer自身が「対応不要」「任意」「現状維持が妥当」と明記し、overall assessmentはいずれも「承認（mergeable）」だった。orchestratorは同じFinding Quality Guardrailを適用しblocking findings 0件でmergeable確定した。

**教訓**: sole-reviewer guardによる2人目co-reviewer追加時にも同じ判定パターンが安定して機能する。co-reviewerが独自の観点（本例ではテンプレート内表記形式の混在）を追加指摘しても、reviewer自身が非blockingと明記していれば同一のguardrailで扱える。

## 関連ページ

- [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](./scope-creep-rejection-empirical-gate.md)

## ソース

- [PR #1756 review results](../../raw/reviews/20260706T033041Z-pr-1756.md)
- [PR #1757 review results](../../raw/reviews/20260706T043448Z-pr-1757.md)
- [PR #1758 review results](../../raw/reviews/20260706T050235Z-pr-1758.md)
