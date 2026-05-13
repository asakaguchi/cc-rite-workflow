---
title: "同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む"
domain: "anti-patterns"
created: "2026-05-13T00:00:00+00:00"
updated: "2026-05-13T00:00:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260512T235812Z-pr-939.md"
tags: []
confidence: medium
---

# 同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む

## 概要

同一 placeholder トークン (例: `{source_ref}`) を「frontmatter フィールドの識別子 (bare path、resolution 対象外)」と「Markdown link URL の path 値 (resolution 対象)」の 2 用途で再利用すると、後者の resolution 文脈で必要な prefix (例: `../../`) が抜けたまま実装されて silent broken_refs を量産する failure mode。Issue #938 / PR #939 で wiki page-template.md の `{source_ref}` が同症状を示し broken_refs 218 件の根本原因となった実測。

## 詳細

### 観測された症状 (Issue #938 / PR #939)

`plugins/rite/templates/wiki/page-template.md` の `{source_ref}` placeholder が以下の 2 箇所で参照されていた:

| 箇所 | 用途 | 文脈 |
|------|------|------|
| line 8 (`sources[].ref:`) | frontmatter フィールド値 (識別子) | YAML / lint scope 外、解決対象ではない |
| line 29 (`[desc]({source_ref})`) | Markdown link URL | wiki page (`.rite/wiki/pages/{domain}/`) を起点に resolution される |

ingest.md の substitution logic は `{source_ref}` に bare path (例: `raw/reviews/20260413T...md`) を渡していたため、line 8 は意図通り動作するが line 29 は wiki root への 2 階層上昇を表す `../../` prefix が欠落し、`.rite/wiki/pages/{domain}/raw/reviews/20260413T...md` (存在しない) を指して `/rite:wiki:lint` が broken_refs として検出していた (40 pages × 平均 5.45 件 = 218 件)。

### 修正パターン

placeholder 値そのものを変更すると line 8 (識別子) の semantics が破壊されるため、**template リテラル側に prefix を hardcode** することで両用途の分離を保ったまま resolution を正しく行う:

```markdown
# Before (broken)
sources:
  - ref: "{source_ref}"          # ← line 8: 識別子、bare path で OK
- [{source_description}]({source_ref})  # ← line 29: URL、bare path だと broken

# After (fixed in PR #939)
sources:
  - ref: "{source_ref}"          # ← 不変、識別子のまま
- [{source_description}](../../{source_ref})  # ← prefix を template literal 側に追加
```

`{source_ref}` placeholder 自体は wiki-root 相対 bare path のまま維持され、URL prefix は template 側の責務として明示分離される。

### Root Cause Analysis

`{source_ref}` という 1 つの placeholder トークンに 2 つの異なる semantics (識別子 vs resolution-target) を持たせると、片方の semantics 変更が他方に影響しないかを毎回確認する責務が implicit に発生する。レビュアー / 開発者は「placeholder 名が同じ」という visual cue から「同じ semantics」と誤推論しやすく、resolution 文脈の prefix 要件を見落とす。

### 検出シグナル

以下のパターンが diff に現れたら本 anti-pattern の警戒対象:

- 同一 placeholder トークン (`{X}` / `${X}` / `%X%` 等) が同一 template 内で **異なる文脈** で参照されている
  - frontmatter / YAML / config フィールドの値 (構造化データ、識別子)
  - Markdown link URL / HTML href / script src (resolution 対象、相対 path 計算が必要)
  - bash 変数展開 / コマンド引数 (シェル escaping が必要)
- placeholder 値そのものに resolution prefix を含めるか、template literal 側に prefix を hardcode するか、設計判断が明示されていない

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../../pages/anti-patterns/asymmetric-fix-transcription.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../../pages/anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #939 review results](../../raw/reviews/20260512T235812Z-pr-939.md)
