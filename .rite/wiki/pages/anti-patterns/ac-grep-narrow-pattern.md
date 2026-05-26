---
title: "AC 検証 grep を狭い正規表現で定義すると bare prose / 表ヘッダ / 副詞句が捕捉できない"
domain: "anti-patterns"
created: "2026-05-27T01:30:00Z"
updated: "2026-05-27T01:30:00Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260526T152327Z-pr-1151.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T151003Z-pr-1151.md"
tags: ["acceptance-criteria", "verification-grep", "word-boundary", "rename-pr", "definition-of-done"]
confidence: high
---

# AC 検証 grep を狭い正規表現で定義すると bare prose / 表ヘッダ / 副詞句が捕捉できない

## 概要

大規模な terminology rename PR で Acceptance Criteria を `grep "Phase [0-9]+(\.[0-9]+)?"` のような **「キーワード + 数字」必須** の正規表現で定義すると、bare キーワード単独 prose (`本 Phase` / `各 Phase` / `後続 Phase` / `5 Phase`)、表ヘッダのキーワード列名、命名規約 prose 内のキーワード参照、副詞句 (`現 Phase は set -e なし`) を **すべて捕捉できない盲点** が生じる。AC が「0 件」と報告されても実際の prose 残留は数十件オーダーで残るため、rename PR の Definition of Done としては不十分。

## 詳細

### 発生条件

AC を以下のような狭い正規表現で定義した場合:

```
grep -rnE "Phase [0-9]+(\.[0-9]+)?" plugins/rite/commands/wiki/
```

このパターンは以下を **すべて見逃す**:

1. **bare キーワード単独 prose**: `本 Phase` / `各 Phase` / `後続 Phase` / `5 Phase` (数字が前にある / 後ろにない / 別文脈)
2. **表ヘッダのキーワード列名**: マークダウン表の `| Phase | 内容 |` ヘッダ
3. **命名規約 prose**: `function 名 token は規約確立 history を保持するため phase を維持` のような meta 説明
4. **副詞句**: `現 Phase は set -e なし` (Phase の後に番号がない名詞句)

### PR #1151 での実測

AC-3 strict (`grep "Phase [0-9]+(\.[0-9]+)?"` = 0 件) を満たしたにも関わらず、wiki/ingest.md (L197, 823, 941) / wiki/init.md (L68, 106) / wiki/lint.md (L459, 896, 973, 1052-1053, 1383, 1786) に **13+ 件の bare `Phase` 残留** が判明 (review cycle 0 の HIGH/MEDIUM finding として検出)。AC grep が `Phase + 数字` のみを対象とするため、文中 bare `Phase` を捕捉できないことが構造的盲点として表面化。

### 対策

大規模 rename PR では AC の grep pattern を **word boundary** で再定義する:

```bash
# 旧 (盲点あり)
grep -rnE "Phase [0-9]+(\.[0-9]+)?" {target_dirs}/

# 新 (word boundary)
grep -rnE "Phase\b" {target_dirs}/
# 残留全件を出して、historical preservation / 表ヘッダ / 命名規約等の意図的残留を一件ずつ triage する
```

`Phase\b` で検出された全件を以下のカテゴリで分類する:

| カテゴリ | 対応 |
|---------|------|
| 普通の Phase N 参照 | rename 対象 |
| bare prose (`本 Phase`, `各 Phase`) | rename or 表現変更 (例: 「本ステップ」) |
| 表ヘッダの列名 | rename (列名も統一) |
| 命名規約の `phase` token | コメントで「規約確立 history のため `phase` を保持」と明示 |
| Archive doc の historical reference | front-matter で preservation policy を declare し、AC から除外 |

### 派生する命名規約の semantic mismatch

PR #1151 の fix cycle 1 で関連する別 anti-pattern も発見された: bash function 命名規約 (`_rite_<scope>_<phase>_cleanup` の `<phase>` token) が「ステップ番号の小数点除外連結形式 → `phase22`」という semantic mismatch を含む。`<phase>` token を「Step N.M の concat」として残すか「規約由来の固定 token」として扱うかを規約 prose で明示しないと、LLM が「ステップ 2.2 → step22」と誤読する経路を生む。

## 関連ページ

- [Rename PR の callee → caller 片方向 over-translation で Out-of-Scope の broken cross-ref を生成する](./rename-pr-callee-caller-over-translation.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #1151 fix cycle 1 (18 fixes)](../../raw/fixes/20260526T152327Z-pr-1151.md)
- [PR #1151 review cycle 0](../../raw/reviews/20260526T151003Z-pr-1151.md)
