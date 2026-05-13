---
title: "同一手順が複数 site に分散する場合は片方を canonical source と宣言する"
domain: "patterns"
created: "2026-05-13T06:43:41Z"
updated: "2026-05-13T06:43:41Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260513T063128Z-pr-946-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260513T060844Z-pr-946.md"
tags: ["canonical-source", "drift-prevention", "asymmetric-fix-transcription", "precedence-rule", "review-fix-convergence"]
confidence: high
---

# 同一手順が複数 site に分散する場合は片方を canonical source と宣言する

## 概要

同一の placeholder 値生成手順 / 規約 / 設計判断が文書内の複数 site に書かれる場合、放置すると Asymmetric Fix Transcription を誘発する。canonical fix は「**片方を canonical source と明示宣言** し、他方は summary / cross-reference 位置付けに整理する」こと。precedence rule (矛盾発生時は canonical を優先) を本文に書くことで、reviewer 評価で severity 差 (PARTIAL vs FIXED) が出ても silent drift にならず合意に収束する。

## 詳細

### 観測 (PR #946 / Issue #944)

`commands/wiki/ingest.md` で `{related_page_title}` / `{related_page_path}` placeholder の値生成手順が以下の 3 site に分散していた:

1. 新規 `### 4.3 関連ページの特定` セクション (canonical fix のメイン site)
2. Phase 5.3 placeholder 表の `{related_page_title}` / `{related_page_path}` 行
3. Phase 5.3 直下の「設計意図 (#941 fix)」blockquote

cycle 1 review で「fallback 文字列が 2 箇所に literal で存在し drift 源を形成」(MEDIUM)・「循環参照ループ」(LOW) が指摘された。fix 適用時に「4.3 を canonical source」と明示宣言し、Phase 5.3 の placeholder 表と blockquote を summary / cross-reference に位置付け直すことで cycle 2 で 0 blocking findings に収束 (1 cycle convergence)。

### 適用パターン

```markdown
> **Canonical source 宣言**: 本セクション (X.Y) は `{placeholder}` の値決定手順の **canonical source** です。
> Phase A.B の placeholder 表と #NNN fix 設計意図 blockquote は要約・補足記述であり、
> 矛盾が発生した場合は本 X.Y を優先します。
```

各 site の **役割**:

| Site | 役割 | 内容詳細度 |
|------|------|----------|
| Canonical source | 値生成手順の唯一の真実源 | 完全な手順 + 規約 + 該当なし時の fallback |
| Summary site | placeholder 表 / 概要表 | placeholder 名 + 一言要旨 + canonical へのリンク |
| Cross-reference site | 設計意図 blockquote / forward reference | 「詳細は X.Y 参照」の 1 行 |

### Reviewer 評価への効果

precedence rule (canonical 優先) が明文化されていると、cycle 2 reviewer 評価で severity 差 (PARTIAL vs FIXED) が出ても **severity gap が 1 以下に収束し agreement に到達する**。理由: 矛盾発生時の解決手順が文書内で明示されているため、reviewer は「どちらが正か」ではなく「canonical が更新されたか」を確認するだけで済む。silent drift の余地が消える。

### 検出シグナル

- 同一 placeholder / 規約が複数 site に literal で存在する (`grep` で複数 hit)
- 一方を更新すると他方が stale 化するパターンが review で指摘される
- reviewer の severity 評価が site 間で異なる (一方は FIXED、他方は PARTIAL)

### 防御策

- canonical 宣言を blockquote で目立たせ、他 site から `[[canonical-source-declaration-for-multi-site-procedure]]` リンクで参照
- summary site / cross-reference site には「canonical: §X.Y 参照」を明記し、独自詳細を書かない
- 変更時は canonical を先に更新し、他 site の summary をそれに従わせる契約を本文 / DRIFT-CHECK ANCHOR に書く

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #946 cycle 2 re-review (1 cycle convergence + canonical source 宣言の効力実証)](../../raw/reviews/20260513T063128Z-pr-946-cycle2.md)
- [PR #946 fix (Canonical source 宣言の明示 fix pattern)](../../raw/fixes/20260513T060844Z-pr-946.md)
