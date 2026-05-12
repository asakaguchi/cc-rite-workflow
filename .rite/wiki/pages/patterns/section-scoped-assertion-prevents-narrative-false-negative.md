---
title: "Test assertion は section-scoped で行頭 prefix を必須にし narrative mention の false negative を防ぐ"
domain: "patterns"
created: "2026-05-12T15:29:45Z"
updated: "2026-05-12T15:29:45Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260512T134356Z-pr-936.md"
  - type: "fixes"
    ref: "raw/fixes/20260512T134908Z-pr-936.md"
tags: ["test-design", "grep", "false-negative", "section-scoped", "assertion-strictness"]
confidence: high
---

# Test assertion は section-scoped で行頭 prefix を必須にし narrative mention の false negative を防ぐ

## 概要

構造保護 test (例: 「契約 row が table に存在する」「特定 bash literal が 1 reference に存在する」) を substring grep ベースで書くと、narrative の言及 (= prose で言葉として書かれているだけ) や heading-only mention、single-instance match で pass する false negative を生む。`awk '/^## §3/,/^## §4/'` 等の section-scoped 範囲抽出 + 行頭 prefix 必須 (`^\| ...`) で contract row のみを検証する設計が必要。

## 詳細

### 失敗モード

PR #936 で 3 件 MEDIUM (F-03/F-04/F-05) として実測。具体的には:

- **F-03**: 「Detection scope 7-type table の 7 行を機械検証」のつもりが substring grep で書かれていたため、narrative で `7-type` と言及するだけで pass する false negative
- **F-04**: heading だけ存在すれば pass する経路 (本文が空でも検出不能)
- **F-05**: 同じ pattern が 1 箇所でも存在すれば pass する経路 (本来 N 箇所すべてを検証すべき場面で 1 箇所だけ存在しても pass)

これらの false negative は test が「PASS」と報告しても構造保護が成立しない状態を量産する。`test-pin-protection-theater` の sub-class として、「assertion の string match 強度が claim の対象と乖離する」failure mode に分類できる。

### 検出手段

- mutation test (= 該当 contract row を 1 行削除した状態で test が FAIL するか確認) で empirical に false negative を発見する
- assertion の grep pattern が substring か行頭 anchored か (`^\|` `^## ` 等の anchor の有無) を mechanical に lint する
- section-scoped で抽出してから match していない grep を疑う (`awk '/^## §N/,/^## §M/'` のような section range の不在を pattern として detect)

### Canonical 対策

1. **Section-scoped 範囲抽出**: `awk '/^## §3/,/^## §4/' file | grep ...` のように section heading で範囲を絞ってから grep する。section heading そのものを範囲開始 / 終了 marker として使う
2. **行頭 prefix 必須化**: table row の検証なら `^\|` (Markdown table の column separator)、code block 内 literal の検証なら `^[[:space:]]*<literal>` のように行頭 anchor を必須にする
3. **件数 assert**: 「N 行存在する」を claim するなら `[ "$(awk ... | grep -cE '...')" = "N" ]` で件数も pin する (substring の有無だけでなく)
4. **Mutation test の併設**: assertion 強度の empirical 検証として、契約 row を意図的に 1 行削除した mutation で test が FAIL することを CI で確認する (test fidelity の正味)

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [Mutation testing で test の fidelity を empirical に測る](mutation-testing-test-fidelity.md)
- [ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない](test-counting-occurrence-vs-line-unit.md)
- [`grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort](../anti-patterns/grep-oe-wc-pipefail-silent-abort.md)

## ソース

- [PR #936 review results](../../raw/reviews/20260512T134356Z-pr-936.md)
- [PR #936 fix cycle 1 results](../../raw/fixes/20260512T134908Z-pr-936.md)
