---
title: "Validation chain の発火 reason は最初に入力を parse する段階で決まる（暗黙 validation が後続 check を unreachable 化）"
domain: "heuristics"
created: "2026-06-01T06:01:05+00:00"
updated: "2026-06-01T06:01:05+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260601T054111Z-pr-1226.md"
tags: []
confidence: medium
---

# Validation chain の発火 reason は最初に入力を parse する段階で決まる（暗黙 validation が後続 check を unreachable 化）

## 概要

validation chain の error reason を doc 化する際は「どの段階が最初に入力を parse するか」が実発火 reason を決める。jq による値注入 (`jq '.timestamp = $ts'`) は入力 JSON の parse を要するため暗黙の syntactic validation を兼ね、後続の明示的 `jq empty` check は syntactically invalid JSON の経路では到達不能 (effectively unreachable) な defense-in-depth backstop になる。reason 説明文を実挙動に整合させる doc 修正は、reason 文字列 / `[CONTEXT]` emit を不変に保てば非ブロッキングで安全。

## 詳細

PR #1226 で `review-result-save.sh` の validation chain (`cat` → `jq` timestamp 注入 → `jq empty`) を 3 reviewer (prompt-engineer / error-handling / code-quality) が独立にトレースし、`review.md` の reason 説明と実挙動の乖離を整理した (0 blocking finding)。

### 観察された制御フロー

1. `cat` で生成済み JSON を読む
2. `jq '.timestamp = $ts'` で timestamp を注入する — **この段階で入力 JSON を parse・再シリアライズする**
3. `jq empty` で syntactic validity を検査する (`json_invalid` reason の発火点)

syntactically invalid JSON（literal substitute 漏れを含む）は **step 2 の注入段階で parse に失敗し `write_failure` として fail する**。よって step 3 の `jq empty` (= `json_invalid`) には到達しない。従来の doc は `json_invalid` を「literal substitute 漏れ検出」と記述していたが、実際の発火 reason は `write_failure` であり、`json_invalid` は effectively unreachable な backstop だった。

### 一般化できる経験則

- **発火 reason は「最初に入力を consume/parse する段階」で決まる**。後段に明示的な検査 step があっても、前段の操作が同じ property を暗黙に検証していれば、その失敗クラスでは後段が unreachable になる。
- **値の注入・変換は暗黙の syntactic validation を兼ねる**。`jq`・`yq`・JSON/YAML parser を介した値の読み書きは、それ自体が構文検査として機能する。後続に置いた「念のための」明示 check は、同一失敗クラスに対しては defense-in-depth backstop であって実発火経路ではない。
- **error reason を doc 化する前に control flow をトレースする**。observability ドキュメント (reason 説明・`[CONTEXT]` emit の意味づけ) は「どの段階が最初に失敗を捕捉するか」を実装で裏取りしてから書く。これは [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md) の reason-documentation への適用形。
- **整合 doc 修正は reason 文字列 / sentinel emit を verbatim 保持すれば非ブロッキング**。実行順序・reason 文字列・`[CONTEXT]` emit を変えず、説明文とコメントのみを実挙動に合わせる修正は機能変更を伴わず安全。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #1226 review results](../../raw/reviews/20260601T054111Z-pr-1226.md)
