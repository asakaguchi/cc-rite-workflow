---
title: "「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる"
domain: "heuristics"
created: "2026-06-10T12:50:00+09:00"
updated: "2026-06-10T13:50:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260609T233431Z-pr-1334.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T230419Z-pr-1332.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T230945Z-pr-1332-c2.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T231510Z-pr-1332-c3.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T232051Z-pr-1332-c4.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T232442Z-pr-1332-c5.md"
tags: []
confidence: high
---

# 「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる

## 概要

ドキュメントやテストの保守ガイダンスで「contract の全 consumer」のような網羅性を主張する列挙を書くとき、reviewer の指摘任せに 1 件ずつ追加していくと cycle ごとに新たな漏れが見つかり review-fix loop が発散する。grep による機械的全数棚卸し → 包含基準での分類 → 全数列挙 + scope note (含む/除く基準と棚卸し方法) の明記、で 1 cycle で収束させる。

## 詳細

PR #1332 (Issue #1207、doc cross-ref drift 解消) で、link-sub-issue.sh の「contract 変更時に更新すべき consumer」列挙が 5 cycle にわたり発散した実測:

- cycle 1: 復旧手順 literal (create.md) の pointer 欠落 → 追加
- cycle 2: runtime consumer (backfill-sub-issues.sh) の漏れ → 追加 + usage 例 (graphql-helpers.md) も追加
- cycle 3: sibling test (create-md-invocation-symmetry.test.sh TC-5b) の漏れ → 追加 + scope note 導入
- cycle 4: scope note の自己定義基準に合致する integration test stub (decompose-issues.test.sh) の漏れ → **grep 全数棚卸しで残余ゼロを確認してから**追加し、棚卸し方法 (`grep link-sub-issue で棚卸し済`) を scope note に明記
- cycle 5: 3 reviewer が独立に全数列挙を再検証し過不足ゼロで 0 findings 収束

教訓:

1. **「網羅完了」の主張は機械的棚卸しの裏付けが必須**: reviewer の知識ベースの指摘で 1 件ずつ追加する方式は、毎 cycle 新しい盲点 (runtime consumer / sibling test / mock stub / usage 例) が surface して収束しない。`grep -rln <token>` の全 hit を包含基準 (literal 保持の有無) で分類し、残余ゼロを確認してから「全数」と書く。
2. **scope note には基準と棚卸し方法の両方を書く**: 「literal を持つ consumer のみ (設計ドキュメント除く)」という基準だけだと、基準に合致する未列挙ファイルの存在が次 cycle の指摘になる。「grep X で棚卸し済」と方法まで書けば、将来の更新者も同じ手順で再検証できる。
3. **二次 drift に注意**: cross-ref drift の修正 PR 自体が、参照先の置換で「旧参照先が担っていた別役割 (復旧手順等) への pointer」を消す二次 drift を起こしやすい。置換前に旧参照先の全役割を棚卸しする。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [形状検証 gate の allowlist 化は複数行 bypass・上流 degraded 値・コメント同期をセットで棚卸しする](./allowlist-gate-hardening-checklist.md)

## ソース

- [PR #1332 fix cycle 1 (復旧手順 pointer 追加)](../../raw/fixes/20260609T230419Z-pr-1332.md)
- [PR #1332 fix cycle 2 (runtime consumer 追加)](../../raw/fixes/20260609T230945Z-pr-1332-c2.md)
- [PR #1332 fix cycle 3 (sibling test 追加 + scope note 導入)](../../raw/fixes/20260609T231510Z-pr-1332-c3.md)
- [PR #1332 fix cycle 4 (grep 全数棚卸しで収束)](../../raw/fixes/20260609T232051Z-pr-1332-c4.md)
- [PR #1332 review cycle 5 mergeable (3 reviewer 独立検証で過不足ゼロ)](../../raw/reviews/20260609T232442Z-pr-1332-c5.md)
- [PR #1334 review mergeable (派生事例: doc 追記の Issue 番号帰属を git log で裏取りし、番号を付ける対象を裏付けの取れた側のみに限定して誤帰属を回避 — reviewer の独立検証と一致して 1 cycle 0 findings 収束)](../../raw/reviews/20260609T233431Z-pr-1334.md)
