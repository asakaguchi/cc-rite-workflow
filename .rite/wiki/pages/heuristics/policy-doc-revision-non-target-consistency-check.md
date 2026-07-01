---
type: "heuristics"
title: "ポリシー分類ドキュメント改訂では、意図的に対象外とした既存要素が新記述と矛盾しないか確認する"
domain: "heuristics"
description: "frontmatter ポリシー表のような分類ルールを新設・改訂する際、変更対象のスキルだけでなく、意図的に変更しなかった既存要素（Non-Target）が新しい分類ルールの記述内容と実際に矛盾しないかを確認するチェックが有効。"
created: "2026-07-01T15:35:00+09:00"
updated: "2026-07-01T15:35:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260701T051115Z-pr-1694.md"
  - type: "reviews"
    ref: "raw/reviews/20260701T052256Z-pr-1694-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260701T060811Z-pr-1694.md"
  - type: "fixes"
    ref: "raw/fixes/20260701T051428Z-pr-1694.md"
  - type: "fixes"
    ref: "raw/fixes/20260701T060350Z-pr-1694.md"
tags: []
confidence: medium
---

# ポリシー分類ドキュメント改訂では、意図的に対象外とした既存要素が新記述と矛盾しないか確認する

## 概要

frontmatter ポリシー表のような分類ルールを新設・改訂する PR では、変更対象のファイルだけでなく、意図的に変更しなかった既存要素（Non-Target）が新しい分類ルールの記述内容と矛盾しないかを確認するチェックが有効。

## 詳細

PR #1694（Issue #1693、`disable-model-invocation` frontmatter を 14 スキルから削除する PR）で、`docs/SPEC.md` の frontmatter ポリシー表を「user-invocable」「純 sub-skill」の 2 区分から、Read 経由のみ到達する `reviewers` を説明する第 3 区分を加えた 3 区分に拡張した。

- cycle 1: tech-writer と prompt-engineer の 2 名が独立に「新しい 2 区分表が `reviewers/SKILL.md`（Read 経由でのみ到達する non-user-invocable knowledge スキル）という既存のエッジケースをカバーできていない」ことを指摘し、cross-validation で High Confidence となった（HIGH 1件）。
- cycle 1 fix: 第 3 区分をポリシー表に追記することで解消。Non-Target File（`reviewers/SKILL.md`）自体には手を触れず、ドキュメント側でギャップを埋めるアプローチを採用。
- cycle 2: 新設した第 3 区分の記述自体に対する再検証で、レビュアーが「upstream issue の状態」「Required 列のセマンティクス」等の周辺懸念を最初は指摘しかけたが、深掘り検証の結果、実装上の欠陥ではなく `design_confirmation`（対応不要）に分類し直した。
- cycle 3: 表面的には「指摘 0 件・mergeable」と判定されたが、実際には prompt-engineer から MEDIUM 指摘（`docs/SPEC.md:326` の第 3 区分が主張する「`reviewers` は `/rite:<name>` を持たない」という前提が、`reviewers/SKILL.md` に実際には `user-invocable: false` が設定されていないため frontmatter 上の裏付けを欠く、という論理矛盾）が出ていたが、エージェント応答の受け渡し不具合により見落とされたまま PR がマージされた（follow-up: Issue #1695）。

**教訓**: 新しい分類ルールを文書化するとき、ルールが「対象外」とする既存要素についても、その要素の実際の設定値（本件では frontmatter フィールド）を Grep/Read で確認し、ルールの前提となる主張（「〜は `/rite:<name>` を持たない」等）が実態と一致しているか検証する必要がある。ドキュメント修正 PR では、この種の「ルールの記述と対象外要素の実態との整合性」チェックが、通常の「変更箇所の正確性」チェックとは独立した観点として抜けやすい。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1694 review results](../../raw/reviews/20260701T051115Z-pr-1694.md)
- [PR #1694 fix results](../../raw/fixes/20260701T060350Z-pr-1694.md)
