---
title: "Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む)"
domain: "anti-patterns"
created: "2026-05-15T10:05:00+09:00"
updated: "2026-05-15T10:05:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260515T005613Z-pr-969.md"
  - type: "fixes"
    ref: "raw/fixes/20260515T005734Z-pr-969.md"
  - type: "reviews"
    ref: "raw/reviews/20260515T010126Z-pr-969.md"
tags: []
confidence: high
---

# Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む)

## 概要

虚偽の test 担保宣言・scope 範囲・契約宣言を「scope を限定する正確な表現」に置換する fix で、reviewer が指摘した overclaim (例: `... で test 担保`) を解消する際、置換後の言い換えに別種の overclaim 語彙 (`固有 (unique to)`、`専用 (specific to)`、`全て (all)`、`必ず (always)` 等) を持ち込むリスク。fix-introduced finding として cycle 1 で検出されやすい。所有格 (`の`) や限定形容 (`での`、`に関する`) のみを使い、絶対化を含意する語彙は意図的に回避する。

## 詳細

### 失敗 mode

scope drift 解消の fix で典型的に発生する流れ:

1. 初回コード/コメントに `A は B で test 担保` のような **virtual claim** がある (実は B の test scope には A が含まれない false claim)
2. reviewer が virtual claim を指摘
3. fix で「A は本 sub-skill 固有の C」「A は専用の D」のように **新たな overclaim 語彙** を持ち込む置換を行う (固有 = "他に存在しない"、専用 = "他では使われない" を含意)
4. 次の cycle で別 reviewer が新 overclaim 指摘 (実際は他 sub-skill でも C/D pattern が共有されている → 2 件目の虚偽記述)

### 検出指標 (cycle 1 で具体検出された evidence)

| シグナル | 検出方法 |
|---------|---------|
| 置換後に `固有 (unique to)` / `専用 (specific to)` / `全て (all of)` / `必ず (always)` 等の絶対化語彙が新規登場 | reviewer が `grep -lE -- "--<flag-name>"` 等で 「実際は何箇所で使われているか」を確認し、置換後の主張と矛盾しているか judge |
| Cross-file consistency check で「A 以外の場所にも同 pattern が存在」を grep で示せる | reviewer の cross-file impact check (`_reviewer-base.md` Cross-File Impact Check section) で発火 |

### 回避規範

scope を限定する fix を書く際の語彙選択:

| 用途 | 推奨 | 回避 |
|------|------|------|
| 所属表現 | `本 sub-skill **の** X`、`本 sub-skill **での** X` | `本 sub-skill **固有の** X`、`本 sub-skill **専用の** X` |
| 否定形による scope 限定 | `... は本 sub-skill **は対象外**` | `... は本 sub-skill **でのみ** 該当` |
| 並列性の明示 | `(同 pattern は他 sub-skill / X workflow でも使用される共有 pattern)` | (補足なし) — 後段の reviewer が overclaim を疑う材料を与えない |

### PR #969 (Issue #965) での具体事例

- **cycle 0 (Issue #965 起票時)**: `start-finalize.md:36` に「4 引数 symmetry は `4-site-symmetry.test.sh` で test 担保」(virtual claim — test SITES には start-finalize.md は含まれていない)
- **cycle 1 fix**: 「`本 sub-skill 固有の` Pre-flight pattern。`4-site-symmetry.test.sh` は create-interview workflow 専用で本 sub-skill は対象外」に置換 (virtual claim は解消されたが「固有」が新 overclaim)
- **cycle 1 review (code-quality, Confidence 80)**: 「4 引数 pattern は実際は他 sub-skill でも使用される共有 pattern なので「固有」は事実誤認」と指摘
- **cycle 2 fix**: 「本 sub-skill **での** Pre-flight pattern (同 pattern は他 sub-skill / create-interview workflow でも使用される共有 pattern)」に再置換 (所有格のみ、並列性も明示)
- **cycle 2 review**: 両 reviewer ともに 0 findings 収束

### 設計判断としての価値

本 anti-pattern を識別することで、初回 fix で「固有」「専用」等を使いそうになった瞬間に self-check 可能になる。reviewer cross-file impact check が cycle 1 で発火する確率は高いが、cycle を 1 つ節約できる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #969 cycle 1 review](../../raw/reviews/20260515T005613Z-pr-969.md)
- [PR #969 fix results](../../raw/fixes/20260515T005734Z-pr-969.md)
- [PR #969 cycle 2 review (mergeable convergence)](../../raw/reviews/20260515T010126Z-pr-969.md)
