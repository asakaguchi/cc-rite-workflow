---
title: "累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable"
domain: "heuristics"
created: "2026-05-17T13:40:00Z"
updated: "2026-05-17T22:44:27Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260517T223309Z-pr-1032.md"
  - type: "retrospectives"
    ref: "raw/retrospectives/20260517T133937Z-pr-1011-retro.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T133901Z-pr-1011-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T133937Z-pr-1011-cycle-2.md"
tags: []
confidence: high
---

# 累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable

## 概要

PR #997 cycle 2 の LOW follow-up として起票された PR #1011 (Issue #999) は、3 cycle で 0 findings に収束した実例。cycle 1 で code-quality MEDIUM + security LOW の 2 reviewer 独立指摘が Phase 5.2 cross-validation で HIGH に boost、cycle 1 fix 自体が新たな minor inaccuracy を導入 (Wiki 経験則「fix-induced regression」の再現)、cycle 2 で 2 階層構造に書き直し、cycle 3 で 3 reviewer マージ可。

## 詳細

### Cycle 1: cross-validation severity boost が正しく機能

- **対象**: `pre-tool-bash-guard.sh:315` のコメント論拠 (PR #997 cycle 2 で追加した「(A)〜(G) deny case-glob は trailing space 必須」)
- **指摘**: code-quality MEDIUM + security LOW が同じ箇所のコメント論拠不整合を独立に指摘
- **boost**: Phase 5.2 cross-validation で 2 reviewer 合意 → MEDIUM の 1 段階上 HIGH に severity boost
- **意義**: 単独 reviewer なら LOW で informational に降格される finding が、複数 reviewer の独立検証で blocking 化される実例

### Cycle 2: fix-induced regression の典型

- **fix**: cycle 1 fix で (A)/(B)-(G) サブブロック別の説明に書き直した
- **新たな drift**: 「(B)-(G) は trailing space 省略」と一括説明したが、(G) branch は短形式 (`-D` 等は trailing space あり) と long-form (`--delete` は省略) の混在、(E) worktree は case-glob (省略) と token-loop precondition (必須) の混在 → 実装と乖離
- **検出**: code-quality reviewer が LOW finding として検出 (Likelihood-Evidence anchor で実装の line 569-575 + 576-582 直接照合、Python trace で false positive 検証)
- **Phase 5.3.0 Post-Reviewer Safety Net**: Likelihood-Evidence anchor 完備のため降格対象外、formal finding として残った

### Cycle 3: 2 階層構造で収束

- **fix**: 「主要因 (全サブブロック共通: path 由来トークンは ` git/<X>` 形となり前 boundary が崩れて連続 token `git <verb>` に到達しない) + 補強要因 (サブブロック別 trailing space)」の 2 階層構造に書き直し
- **検証**: 3 reviewer (prompt-engineer + code-quality + security) すべて 0 findings、マージ可判定
- **収束条件**: cycle 3 で初めて (A)/(B)/(C)/(D)/(E case-glob)/(E token-loop)/(G 短形式)/(G long-form) の 7 形式すべてを実装と意味的に整合させた

### Patterns Reinforced

1. **Cross-validation severity boost の威力**: 単独 LOW + 単独 MEDIUM が cross-validate で HIGH に昇格して blocking 化された (Phase 5.2 ルール)
2. **fix-induced regression の段階的詳細化**: cycle 1 → cycle 2 → cycle 3 で「一括説明 → サブブロック別 → 2 階層 (主要因/補強要因)」と段階的に正確化された (最初から 2 階層で書いていれば cycle 2 を skip できた可能性)
3. **Likelihood-Evidence anchor の重要性**: cycle 2 LOW finding は anchor 完備のため Phase 5.3.0 で降格されず blocking 維持された
4. **3 reviewer 並列レビューが accumulated PR で正しく機能**: prompt-engineer + code-quality + security の組み合わせが多角的に検証

### Anti-Patterns Avoided

- **silent skip**: Wiki ingest 経路の auto_ingest 判定で bash パース bug により silent skip が発生 (本セッションで後追い手動 ingest として記録)。本来は Phase 6.5.W / 4.6.W で自動 ingest されるべき経路

### PR #1032 (Issue #1025): bash semantics 版 3-cycle 連鎖収束の実証

PR #1032 (Issue #1025 — `plugins/rite/commands/pr/fix.md` L797-L802 の `mktemp_failure_find_err` 経路 SoT 同期 refactor) は、PR #1011 の 3-cycle 収束パターンの **bash semantics 版** 連続再現事例。各 cycle で異なる drift class が surface し cycle 4 で 0 findings に到達:

- **Cycle 1 (CRITICAL — bash 言語仕様罠)**: format 同期目的の SoT-aligned refactor で `if ! cmd; then rc=$?` 形式を新規導入し bash `!` 演算子の boolean 反転による rc 常時 0 化 silent regression。reviewer 2 名 cross-validation 一致検出
- **Cycle 2 (MEDIUM + LOW — fix-introduced regression)**: cycle 1 fix が hardcoded line-number reference (`L1147-L1150`) を comment に埋め込み SoT 実位置 (L1122-L1156) と乖離 + L799 mktemp の `2>/dev/null` 欠落で 24/25 サイト対称化漏れ
- **Cycle 3 (MEDIUM — numeric counter drift の先回り対応)**: cycle 2 fix の semantic anchor 化宣言と同時に新規導入された numeric counter (`fix.md 内 24/25 site と pattern 一致`) を本 fix で先回りで相対 semantic 表現に置換 (cycle 4 で MEDIUM として再検出される経路を予測対応)
- **Cycle 4 (mergeable — 0 findings)**: 両 reviewer (prompt-engineer / code-quality) 独立 0 findings 評価、3-cycle 収束完了

**PR #1011 との対比による新観点**:

1. **drift class が cycle ごとに異なる shrinking pattern**: PR #1011 は同一 class (cycle 1 / 2 とも「サブブロック別 trailing space 説明の精密化」) の段階的詳細化で収束したが、PR #1032 は **cycle ごとに異なる drift class** (cycle 1: bash 言語仕様 → cycle 2: documentation pointer → cycle 3: numeric counter) が連続発火。それでも **shrinking cycle count (3 findings → 2 findings → 1 finding → 0 findings)** で 4 cycle で収束する empirical 規則が成立。
2. **3-cycle 連鎖は drift class 横断でも 4 cycle 内で完結する**: cycle ごとに drift class を semantic anchor に置換していくことで、各 cycle で発火する drift class が異なっても shrinking cycle で収束。「recursive recurrence in fix layer」の発火上限は **3 cycle 連鎖 + cycle 4 で 0 findings 期待** が 2 連続 (PR #1011, PR #1032) で再現された empirical evidence。
3. **format 同期 refactor の小規模 PR でも 3-cycle 連鎖が発火する**: PR #1011 は 7 形式 (A/B/C/D/E case-glob/E token-loop/G 短形式/G long-form) の対称性を扱う中規模 PR だったが、PR #1032 は **6 行の bash block を新 SoT 形式に refactor する小規模 PR** でも同型の 3-cycle 連鎖が発火することを示した。これは「PR の規模ではなく **新 SoT との対称化責務の層数** (本 PR では format token / bash structure / runtime semantics の 3 層) が 3-cycle 連鎖の発火条件である」観点を支持する。
4. **「累積対策 PR の 3-cycle 収束記録」pattern の reproducibility は 2 PR 連続で確立**: PR #1011 (heuristics 経験則の起点) → PR #1032 (連続再現事例) として、本 heuristics 経験則は 2 PR 連続で再現された。bash semantics layer まで含む drift class 横断の 3-cycle 連鎖でも 4 cycle で収束する empirical pattern が、`fix-induced-drift-in-cumulative-defense.md` と本ページの両方で観測されている。

## 関連ページ

- （関連ページなし）

## ソース

- [PR #1011 3-cycle convergence retrospective](../../raw/retrospectives/20260517T133937Z-pr-1011-retro.md)
- [PR #1011 cycle 1 review (1 HIGH cross-validated)](../../raw/reviews/20260517T133901Z-pr-1011-cycle-1.md)
- [PR #1011 cycle 2 review (1 LOW + 1 informational)](../../raw/reviews/20260517T133937Z-pr-1011-cycle-2.md)
- [PR #1032 cycle 4 review (mergeable — bash semantics 版 3-cycle 連鎖収束、cycle 4 で両 reviewer 0 findings 合意、drift class 横断 (bash 言語仕様 → documentation pointer → numeric counter) でも 4 cycle で収束する 2 連続再現事例)](../../raw/reviews/20260517T223309Z-pr-1032.md)
