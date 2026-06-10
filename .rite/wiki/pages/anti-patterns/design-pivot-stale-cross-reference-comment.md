---
title: "同一 PR 内の設計 pivot 後に cross-reference コメントが旧設計の説明のまま残る"
domain: "anti-patterns"
created: "2026-06-10T00:38:14Z"
updated: "2026-06-10T00:38:14Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260610T001830Z-pr-1337.md"
  - type: "fixes"
    ref: "raw/fixes/20260610T002120Z-pr-1337.md"
tags: ["comment-rot", "design-pivot", "cross-reference", "self-inconsistency", "sweep-test"]
confidence: high
---

# 同一 PR 内の設計 pivot 後に cross-reference コメントが旧設計の説明のまま残る

## 概要

実装途中で設計を pivot (例: sweep 条件の変更) した際、pivot した実装本体とそのコメントは更新されるが、**同一 PR 内の別箇所にある cross-reference コメント (他の検査・関数を説明する参照文)** が旧設計の説明のまま残り、同一ファイル内で自己矛盾する記述が生まれる。将来のメンテナが誤記述側に合わせて実装を「修正」すると、pivot で獲得した防御 (fail-closed sweep 等) が silent に弱体化する。

## 詳細

### 失敗の構造 (PR #1337 で実測)

PR #1337 で sweep test TC-3 を実装する際、初版の「`>&2` 同一行条件 sweep」が mutation 検証で vacuous と判明し、「全行 sweep + 明示 allowlist の fail-closed 設計」へ pivot した。TC-3 自身のコメントは pivot 後の設計を正しく説明していたが、**TC-1 側の cross-reference コメント (「TC-3 が同一行 `>&2` 条件で別途 sweep する」) が pivot 前の説明のまま commit** された:

- TC-3 実装: `>&2` フィルタなしの全行 sweep + allowlist (pivot 後)
- TC-3 コメント: 「`>&2` 同一行条件では構造的に検出できない…そのため全行 sweep」(pivot 後、正しい)
- TC-1 コメント: 「TC-3 が同一行 `>&2` 条件で別途 sweep する」(pivot 前の記述が残留、**正反対**)

review cycle 1 で code-quality reviewer が MEDIUM (current-pr) として検出。リスクは「将来のメンテナ (本リポジトリでは LLM エージェント) が TC-1 側の誤記述に合わせて TC-3 に `>&2` フィルタを追加し、fail-closed sweep が silent 弱体化する」こと。

### root cause

設計 pivot は「実装 + 直近コメント」のペアで行われがちで、**pivot 対象を参照する離れた箇所のコメント**が同期更新の対象から漏れる。pivot 前に書いたコメントは pivot 時点で既に存在しているため、「新規追加分のレビュー」の心理的スコープから外れやすい。

### 防止策

1. **pivot 時の cross-reference grep**: 設計変更した識別子 (TC 名 / 関数名 / モード名) を同一 PR の diff 全体 + 対象ファイル全体で grep し、旧設計を説明する記述が残っていないか確認する
2. **propagation scan に「説明文」も含める**: fix の伝播スキャンはコードの同型 idiom だけでなく、変更対象を説明する prose / コメントも対象にする
3. **コメントは実装の設計判断を二重記述しない**: cross-reference コメントには「TC-3 が別途 sweep する」程度の存在参照に留め、検出方式の詳細 (同一行条件 / 全行 sweep) は TC-3 側コメントに一元化する — 詳細の重複が drift 面積を生む

### 関連する既知 anti-pattern との区別

- [fix-comment-self-drift](./fix-comment-self-drift.md): fix で書いたコメント自身が convention を破る話。本ページは**設計 pivot による同一 PR 内の記述自己矛盾**で、コメント自体は convention 準拠でも内容が実装と矛盾する
- Asymmetric Fix Transcription (対称位置への伝播漏れ): 対称な実装サイトへの fix 伝播漏れ。本ページはその**説明文 (prose) 版**にあたる

## 関連ページ

- [Fix 修正コメント自身が canonical convention を破る self-drift](./fix-comment-self-drift.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1337 review results (cycle 1) — TC-1 コメントと TC-3 実装の矛盾を code-quality reviewer が MEDIUM で検出](../../raw/reviews/20260610T001830Z-pr-1337.md)
- [PR #1337 fix results — コメント 4 行の書き換えで解消、root cause は設計 pivot 後の cross-reference コメント追随漏れ](../../raw/fixes/20260610T002120Z-pr-1337.md)
