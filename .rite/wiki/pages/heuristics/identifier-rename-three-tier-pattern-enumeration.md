---
type: "heuristics"
title: "識別子リネームは3階層（コマンド文字列・ファイル名shorthand・裸トークン）で置換対象を洗い出す"
domain: "heuristics"
description: "識別子リネーム PR では rite:{old} の完全コマンド文字列だけでなく {old}.md のファイル名 shorthand、および拡張子なしの裸トークンの3階層を洗い出さないと、review-fix ループが段階的に狭いスコープへ収束しながら複数サイクルを消費する。"
created: "2026-07-08T13:13:15+09:00"
updated: "2026-07-08T13:13:15+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260708T013530Z-pr-1795.md"
  - type: "reviews"
    ref: "raw/reviews/20260708T021200Z-pr-1795-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260708T024653Z-pr-1795-cycle5.md"
  - type: "reviews"
    ref: "raw/reviews/20260708T034554Z-pr-1795.md"
  - type: "fixes"
    ref: "raw/fixes/20260708T013823Z-pr-1795.md"
  - type: "fixes"
    ref: "raw/fixes/20260708T021456Z-pr-1795-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260708T022258Z-pr-1795-cycle3.md"
tags: []
confidence: high
---

# 識別子リネームは3階層（コマンド文字列・ファイル名shorthand・裸トークン）で置換対象を洗い出す

## 概要

識別子リネーム PR では `rite:{old}` の完全コマンド文字列だけでなく `{old}.md` のファイル名 shorthand、および拡張子なしの裸トークン（一覧・例示内での言及）の3階層を意識的に洗い出さないと、review-fix ループが段階的に狭いスコープへ収束しながら複数サイクルを消費する。

## 詳細

PR #1795（Issue #1785、`/rite:init` → `/rite:setup` リネーム）の review-fix ループで、指摘パターンが段階的に狭いスコープへ収束していく現象が観測された（サーキットブレーカー `safety.max_review_cycles=5` に対し実際に5サイクル目まで到達）。

- **cycle 1**: 識別子文字数の変化（`init`=4文字 → `setup`=5文字）に伴い、固定spaces幅の ASCII メニュー列整形が1箇所ずれる LOW 指摘。trailing spaces 調整で即修正。
- **cycle 2**: 完全コマンド文字列 `rite:init` の置換自体は徹底されていたが、ファイル名の口語的 shorthand 参照 `init.md`（旧スキルファイル名の略記）が4箇所の参照ドキュメントに取り残されていた（LOW×4）。うち1件（wiki-patterns.md）は同一ファイル内で既にファイルパス形式 `skills/init/SKILL.md`→`skills/setup/SKILL.md` は更新済みなのに、隣接する shorthand 参照だけ未更新という内部不整合も伴っていた。
- **cycle 3**: `rite:init` でも `init.md` でもない、拡張子なしの裸トークン形式（スキル行数原則の例示リスト内の `init`、setup/SKILL.md 自身の自己参照）が残っていた（LOW×3）。過去2サイクルの一括置換パターンが「`rite:init`」と「`init.md`」の2形式しかカバーしておらず、第3の形式を見落としていたことが判明。
- **cycle 4/5**: 0 findings で収束。cycle 5 では security reviewer が「直前の fix で同一ファイル (`settings-local-rite-hook-cleanup.sh`) の5行目だけ直して13行目の同種参照を見落とす」ケースを検出し、fix で解消。

**教訓**: 識別子リネーム PR では、置換対象パターンを設計する際に少なくとも3階層を意識的に洗い出すべき:

1. `rite:{old}` の完全コマンド文字列
2. `{old}.md` のファイル名 shorthand
3. 拡張子なしの裸トークン（一覧・例示内での言及）

(3) は「`init` という一般語との衝突」の判定が難しく、文脈判断（bash 実行ブロックを持つ実行手順書スキルの列挙、という文脈が明確な場合のみ対象）が必要になる。また、reviewer の指摘に対する修正時は「同一ファイル内の他の類似箇所」への伝播スキャンを徹底すること（cycle 5 の同一ファイル内2箇所見落としが好例）。

このリポジトリでは rite:xxx 基底名衝突回避のリネームシリーズ（#1784 resume→recover、#1785 init→setup、#1786 review→pr-review、#1787 run→batch-run）が並行して進行しており、本パターンは他の兄弟 Issue でも再発しうる汎用的な知見である。

なお、置換スコープの厳密な線引き（`rite:init` という完全文字列のみを対象とし、裸の "init" という一般語や `init.md` のような pre-existing shorthand 参照はスコープ外、という revert-test 判断）自体は正しい設計判断であり、本ヒューリスティックは「スコープを広げよ」ではなく「意図したスコープ内の3階層を最初から漏れなく洗い出せ」という趣旨である。

## 関連ページ

- [識別子リネーム後の裸参照置換で除外すべき参照の分類](../patterns/rename-bare-reference-exclusion-classification.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1795 review results (cycle 2)](../../raw/reviews/20260708T021200Z-pr-1795-cycle2.md)
- [PR #1795 fix results (cycle 3)](../../raw/fixes/20260708T022258Z-pr-1795-cycle3.md)
- [PR #1795 review results (cycle 5, final)](../../raw/reviews/20260708T024653Z-pr-1795-cycle5.md)
