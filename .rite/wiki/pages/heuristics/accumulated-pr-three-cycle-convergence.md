---
title: "累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable"
domain: "heuristics"
created: "2026-05-17T13:40:00Z"
updated: "2026-05-18T17:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260518T165729Z-pr-1049-cycle2.md"
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

### PR #1049 (Issue #1047): 1-cycle convergence の下限事例

PR #1049 (`_test-helpers.sh` への新規 `assert_grep_in_section` helper 追加 + T-2/T-3/T-4 caller test 3 ファイルの API 移行) は、本ページが記録してきた 3-cycle 収束 pattern の **対比となる下限事例** として位置付けられる。cycle 1 で 3 reviewer 独立合意 HIGH を含む 3 finding 検出 → cycle 1 fix で structural resolution → cycle 2 で 0 finding mergeable に到達する **1-cycle convergence (cycle 0 を含めて 2 cycle で完結)** を実測:

- **Cycle 1 (HIGH × 1 cross-validated, MEDIUM × 1, LOW × 1)**: test / code-quality / error-handling の 3 reviewer 並列レビューで HIGH (helper file 内 test coverage 対称性欠落) を独立 grep evidence 付きで cross-validated detection。MEDIUM (awk silent swallow による 5 failure mode 混同) と LOW (docstring-実装 drift) も並行発火。
- **Cycle 1 fix (3 finding 全件 structural fix)**: TC-12 self-test 追加で sibling helper 群との対称性回復、`if !` awk wrap + stderr tempfile + `[ ! -s ]` 空 section guard の 3 点セットで 5 failure mode 区別、docstring を実装と byte 同期。
- **Cycle 2 re-review (0 finding mergeable)**: 同じ 3 reviewer 並列 re-review で全件 FIXED 判定、推奨事項 3 件 (boundary 2 + actionable 1) はすべて scope 外として user 取り下げ、cross-validated CRITICAL/HIGH/MEDIUM 0 件で 1 cycle 収束。

**PR #1011 / #1032 との対比による新観点**:

1. **shrinking cycle count の下限は 1 cycle convergence (cycle 0 含め 2 cycle)** — 累積対策 PR の 3-cycle 連鎖が「上限」だとすると、本 PR #1049 は対極の「下限」事例として 1-cycle 収束を実測。**収束 cycle 数は (a) 問題の structural clarity、(b) cycle 1 fix の semantic 完全性、(c) reviewer cross-validation の depth の 3 因子で決まる** 観点を支持。PR #1049 は (a) helper test coverage 対称性が grep evidence で 1 trigger で structurally clear に成立、(b) cycle 1 fix が 3 reviewer 全指摘を semantic anchor 化で一括解消、(c) 3 reviewer 並列レビューで cross-validation depth 最大 — の 3 因子がすべて揃った。
2. **「fix-induced regression が発火しない条件」の輪郭** — PR #1011 / #1032 では cycle 1 fix が新規 drift を導入したが、PR #1049 では cycle 1 fix が新規 drift を introduce せずに直接 mergeable に到達。違いは「fix が structural anchor (TC-12 self-test、3 点セット) を新規確立する形態」であることで、fix-induced regression は **「format 同期 / 列挙対称化 / hardcoded reference 書き換え」など precedent-following 形態** の fix で発火率が高く、**「新規 contract 確立」形態** の fix では発火率が低い、という pattern 仮説を提示。
3. **3 reviewer 並列レビュー × 1 cycle 収束の reproducibility 候補** — 累積 30 回目 (PR #984、4 reviewer 全員 0 finding 1 cycle merge) と本 PR #1049 (3 reviewer 並列で HIGH cross-validated → 1 cycle 構造的解消) が **「複数 reviewer 並列レビューが initial detection の完全性を上げ、fix の structural anchor 確立を促進する」** 共通 mechanism を示唆。3-cycle 連鎖の前提となる「cycle 1 fix の不完全性」が、reviewer cross-validation depth で抑制される経路を支持する empirical evidence。
4. **Reviewer 自身による FIXED verification の standard pattern** — error-handling reviewer が cycle 1 で MEDIUM (awk silent swallow) を指摘し、cycle 2 で同 reviewer 自身が「5 failure mode を診断レベルで区別可能化された」と FIXED verification するパターンは、`fix-verification-requires-natural-workflow-firing.md` の reviewer ownership pattern と整合。「指摘した reviewer が次サイクルで verify する」契約は、PR #1049 のような 1-cycle 収束 PR でも standard pattern として再現されることを実測。

## 関連ページ

- （関連ページなし）

## ソース

- [PR #1011 3-cycle convergence retrospective](../../raw/retrospectives/20260517T133937Z-pr-1011-retro.md)
- [PR #1011 cycle 1 review (1 HIGH cross-validated)](../../raw/reviews/20260517T133901Z-pr-1011-cycle-1.md)
- [PR #1011 cycle 2 review (1 LOW + 1 informational)](../../raw/reviews/20260517T133937Z-pr-1011-cycle-2.md)
- [PR #1032 cycle 4 review (mergeable — bash semantics 版 3-cycle 連鎖収束、cycle 4 で両 reviewer 0 findings 合意、drift class 横断 (bash 言語仕様 → documentation pointer → numeric counter) でも 4 cycle で収束する 2 連続再現事例)](../../raw/reviews/20260517T223309Z-pr-1032.md)
- [PR #1049 cycle 2 re-review (mergeable — 1-cycle convergence の下限事例、3 reviewer 並列レビューで HIGH cross-validated → cycle 1 fix で structural resolution → cycle 2 で 0 finding mergeable。3-cycle 連鎖の対極として 1-cycle 収束が成立する 3 条件 (structural clarity / cycle 1 fix semantic 完全性 / reviewer cross-validation depth) を実測)](../../raw/reviews/20260518T165729Z-pr-1049-cycle2.md)
