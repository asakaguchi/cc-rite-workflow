---
title: "Cleanup refactor は reasoning prose を保持し review-history journal のみ削除する"
domain: "heuristics"
created: "2026-05-07T04:15:00+00:00"
updated: "2026-05-08T03:43:04+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260506T190517Z-pr-877.md"
  - type: "reviews"
    ref: "raw/reviews/20260506T195728Z-pr-878.md"
  - type: "reviews"
    ref: "raw/reviews/20260506T204827Z-pr-879.md"
  - type: "reviews"
    ref: "raw/reviews/20260507T014914Z-pr-880.md"
  - type: "reviews"
    ref: "raw/reviews/20260507T032241Z-pr-881.md"
  - type: "reviews"
    ref: "raw/reviews/20260507T040320Z-pr-882.md"
  - type: "reviews"
    ref: "raw/reviews/20260507T044332Z-pr-883.md"
  - type: "reviews"
    ref: "raw/reviews/20260507T163353Z-pr-889.md"
  - type: "reviews"
    ref: "raw/reviews/20260508T032656Z-pr-890.md"
  - type: "reviews"
    ref: "raw/reviews/20260508T034304Z-pr-890.md"
  - type: "fixes"
    ref: "raw/fixes/20260508T033003Z-pr-890.md"
  - type: "fixes"
    ref: "raw/fixes/20260508T033628Z-pr-890.md"
tags: [refactor, cleanup, charter, simplification, pre-commit-gate]
confidence: high
---

# Cleanup refactor は reasoning prose を保持し review-history journal のみ削除する

## 概要

charter cleanup / simplification refactor で過去の review cycle 経緯記述や finding ID 引用を機械的に削除する際、reasoning prose (なぜそう実装したかの根拠) を残し、review-history journal (`cycle 10 C-1 対応`、`旧実装は X だった、本 cycle で Y を追加` 等) のみを除去するのが正しい削除単位。reasoning ごと消すと LLM runtime の判断材料が失われる。

## 詳細

### 削除単位の 3 分類 (PR #877 で実測)

charter で禁止されている `cycle [0-9]+|verified-review cycle` パターンの引用は、以下 3 種に分類して削除する:

1. **inline parenthetical** (約 60% — table cell 末尾の `(cycle 8 H-5 対応)` 等)
   - phrase 単位で削除する
   - 削除後の文末が `されていない)` `**WARNING only**)` 等で自然に閉じることを確認する
   - 空括弧 `()` や末尾 `、)` のような artifact が残らないか grep で検証

2. **bash literal 内 historical comment 行** (約 40% — `# verified-review cycle 15 F-8 対応:` 等)
   - 行単位で削除可能 (bash 構文に影響なし)
   - 同一 `# A\n# B\ncode` から `# A\ncode` への変更は構造的閉じトークン (`}` / `fi` / `esac`) に影響しない

3. **prose blockquote 内 cycle 番号付き経緯記述** (残り)
   - 文節単位で書き換える
   - 例: `verified-review (cycle 8) M-9 対応: 旧実装は X だった。本 cycle で Y を追加` → `silent data loss 防止のため hard fail させる`
   - **WHY を残し、HOW IT GOT THERE を削除する**

### 「reasoning は残す」が中核原則

`旧実装は Y だった、本 cycle で Z を追加` のような構造の削除では、`本 cycle で Z を追加` 部分だけ消して `Y のため Z にする` 形に書き換える。これにより:

- LLM が runtime に reading するときの「なぜそう実装したか」の根拠が維持される
- review-history journal (charter 禁止対象) は除去される
- charter 5 自問の `[3] 説明か手順か` で「説明 (経緯) は削除、手順 (根拠) は維持」の境界が明確化する

### 削除パターンの非対称性は意図的

3 分類で削除単位が異なる (phrase / line / 文節) のは表面的な構文単位の違いではなく、各構造で「reasoning vs journal」の境界が異なる場所に出るため:

- table cell では reasoning は cell 本文、journal は parenthetical → phrase 削除
- bash literal comment では reasoning は次行の動作仕様、journal は単独行 → 行削除
- prose blockquote では reasoning と journal が文中に混在 → 文節書き換え

「全て同じ単位で削除」とすると、reasoning ごと消す経路 (case 1 で table 全行削除) や bash 動作説明ごと消す経路 (case 2 で `# explanation\n# cycle X` の前者まで巻き込む) が出るため、構造別の削除単位を意識する必要がある。

### Cross-validation で削除の安全性を担保

charter cleanup は機械的削除のため文意破壊や構造破壊のリスクがある。PR #877 では以下で安全性を担保:

- pre-commit baseline grep で develop HEAD の lint findings 数を記録 → 本 PR でリグレッションがゼロであることを実証 (drift 32 件 / comment-journal 22 件→7 件で 15 件削減確認)
- Reviewer 並列起動 (Prompt Engineer + Code Quality) で AC-1/2/3 + cross-file impact + 表構造整合性を独立検証
- AC-2 (`bash plugins/rite/hooks/tests/4-site-symmetry.test.sh`) で機能契約 non-regression を機械確認

これにより 0 件 finding で 1 cycle で承認に到達した。

### 連続 5 PR (sibling 検証) で 0 finding 1 cycle 着地が再現

PR #877 (`pr/review.md` から 41 件削除)、PR #878 (`pr/fix.md` から 31 件削除)、PR #879 (`pr/cleanup.md` から 16 件削除)、PR #880 (`pr/references/bash-trap-patterns.md` から 11 件削除)、PR #881 (`pr/references/fact-check.md` から 2 件削除) は、親 Issue #843 Phase 0a の sibling PR として同型の cleanup pattern を独立適用した。5 PR とも:

- 同じ 3 分類 (inline parenthetical / bash literal comment / prose blockquote) で削除単位を決定
- pre-commit baseline grep + Reviewer 並列起動 + 機能契約 test PASS の 3 layer
- prompt-engineer / code-quality の 2 reviewer 共に 0 blocking findings で 1 cycle 着地

連続 5 PR の独立適用で同等の効率 (0 finding 1 cycle) が再現したことで、本経験則は「単一 PR の偶然的 success」ではなく「再現可能な canonical 手順」として実証された。5 PR の合計削除件数は 101 件で、ファイルあたりの引用密度に応じてスケール (`pr/review.md` 41 / `pr/fix.md` 31 / `pr/cleanup.md` 16 / `pr/references/bash-trap-patterns.md` 11 / `pr/references/fact-check.md` 2) する。**極小規模 PR (+2/-2) でも同パターンが成立する**ことが PR #881 で実証され、規模スケール下限が 2 件まで拡張された。

PR #880 では prompt-engineer が file 内非対称 (PR description 削除分類と AC-1 strict regex の判定基準乖離による残存引用 2 件) を Important × 2 で検出したが、Phase 5.3.0 Observed Likelihood Gate で Likelihood-Evidence anchor 未提示のため推奨事項へ機械的降格 → Issue #872「Scope 外指摘ハンドリングポリシー」により対応見送り。本系列の cleanup PR は **strict regex マッチ件数で削除対象を確定** (PR description の説明的件数とは独立) する運用が高信頼であることを副次的に再確認した。

PR #881 は `Issue #[0-9]+` 本文引用パターン (`Layer 4 (親 Issue #N の #M)` 形式) を「別 PR で対応」に一般化する極小 inline parenthetical 削除のみで構成され、reasoning prose (caller 同期が意図的 PR 分離である説明) は完全に保持された。これにより、本経験則の「reasoning は残す」中核原則は規模に関係なく成立することが追加実証された。

PR #882 (`pr/references/archive-procedures.md` から 4 件削除、+4/-4 行) は連続 6 件目の sibling として本経験則の reproducibility をさらに補強した。削除対象は `Issue #496 / PR #531` / `Issue #658 — observed on #593 stuck at "In Review" and #652 stuck at "In Progress"` / `(Issue #693)` × 2 / `— see Issue #658 for rationale` の 4 箇所で、いずれも parenthetical な過去 PR/Issue 番号引用に該当 (3 分類のうち inline parenthetical と bash literal 内 historical comment の混在)。reasoning prose (LLM attention loss / partial-failure paths による silent skip 説明、`current_body` 等のシェル変数喪失に関する Note for Claude、`same delegate pattern as Phase 3.2` の cross-reference) は完全に保持された。両 reviewer (prompt-engineer / code-quality) ともに 0 blocking findings で 1 cycle 着地。**references/ 配下の reference ファイルにも本パターンが適用可能であることが本 PR で実証**され、対象範囲が `pr/{review,fix,cleanup}.md` の主要 command ファイルから references/*.md にも拡張された。

PR #883 (`pr/references/internal-consistency.md` から 5 件削除、+5/-5 行) は連続 7 件目の sibling として references/ 配下への適用 2 例目を実証した。削除対象は `本 Issue #350 検証付きレビュー L-12 / L-16 / L-1 / M-12 / L-2 / C-3` の 5 行に渡る review round ID 引用で、いずれも `Issue #N で.*対応` charter pattern に該当する inline parenthetical (`(本 Issue #N 検証付きレビュー L-X で〜)`) および prose blockquote 内 cycle 番号付き経緯記述の混在。reasoning prose (`drift 監視 invariant の詳細は Drift Detection Invariants セクションに分離している` / `drift リスク` の現状記述 / `重複構造そのものは残っており、将来の更新時に再 drift する手動依存リスクは健在` の警告) は完全に保持され、line 382 の「取り戻している」→「維持している」のような state aspect の書き換えのみで意味の load-bearing claim は保持された。両 reviewer (prompt-engineer / code-quality) ともに 0 blocking findings で 1 cycle 着地、累計 105 件削除 / 7 PR 連続成功で本経験則の信頼性が high として一層強化された。**事前 Wiki query injection** (Phase 3.0.W) で本経験則ページが LLM に注入されたことが、実装計画段階での「reasoning prose 保持」原則の早期反映に寄与した実例として記録される。

PR #889 (`pr/references/fact-check.md` から 5 件削除、+5/-5 行で行数 438 不変) は連続 8 件目の sibling として references/ 配下への適用 3 例目を実証した。削除対象は (a) セクション見出し `Internal Likelihood Claims（検証必要・新規）` から `・新規` を削除、(b) 段落 `External Claim と直交する新カテゴリ` から `新` を削除、(c) blockquote 内の `歴史的経緯により` / `caller 側 (review.md / assessment-rules.md) の同期が必要なため別 PR で対応予定` 削除、(d) `新セクションは` を `### 外部仕様の検証結果 および ### 矛盾により除外された指摘 セクションは` に具体化、(e) blockquote 末尾の `caller 側の更新は別 PR で対応し、本ファイルと意図的に PR を分離している` を削除、の 5 種で、`歴史的経緯` / `別 PR で対応` / `意図的に PR を分離` / `新カテゴリ` / `新セクション` / `検証必要・新規` の 6 種 charter 違反パターンが含まれる混合ケース。**in-place edit 中心 (5 insertions + 5 deletions、行数 438 不変)** でも reviewer が「specificity 向上」(`新セクションは` → 具体的セクション名への置換) を改善方向の変更として認識した観察が追加され、本経験則の適用範囲は「-N 行の削除規模」だけでなく「行数不変の inline 置換」にも及ぶことが実証された。両 reviewer (prompt-engineer / code-quality、sole reviewer guard により co-reviewer 追加) ともに 0 blocking findings で 1 cycle 着地、累計 110 件削除 / 8 PR 連続成功で本経験則の信頼性は最高水準で再確認された。事前 Wiki query injection の効用は PR #883 に続き本 PR でも観察された。

### PR #890 で発見された限界: slim refactor で識別子削除 / 構造ラベル変更を伴う場合は 3 cycle 構成になりうる (Phase C1 cleanup.md slim、Issue #845)

PR #890 (`pr/cleanup.md` の Sub-skill Return Protocol セクションを 96 行 → 26 行に slim、-70 行) は連続 9 件目の sibling だが、**初めて 1 cycle 着地から外れた 3 cycle 構成** で収束した (cycle 1 で 4 件 broken refs 検出、cycle 2 で 1 件 Step 番号引用検出、cycle 3 で 0 blocking)。これは「reasoning prose 保持 / journal 削除」原則は維持されたが、**section heading や Item 番号体系を削除する slim refactor では同ファイル内の暗黙参照 (orphan dangling reference) が発生する** という限界を明らかにした。具体的な failure mode は 2 種:

1. **broken intra-file reference (cycle 1, CRITICAL × 4)**: 削除した識別子 (例: `Pre-check Item N` / `場面 (a)/(b)` / `Item 0 Routing dispatcher`) を、同ファイル内 4 箇所の散文・WARNING メッセージが name-by-name で参照したまま残置 → 削除済み識別子への dangling reference。両 reviewer (prompt-engineer / code-quality) が独立検出した cross-validation 高信頼度。
2. **literal 構造ラベル変更時の verbatim 引用 grep 不一致 (cycle 2, LOW × 1)**: `Step 1` ラベル → `inline (1)` 番号への構造的書き換えで、別の場所の verbatim 引用と grep 不一致。cycle 1 の broken reference (識別子削除) とは別 class (構造ラベル変更) の漏れ。

**canonical 対策の拡張**: 既存経験則の `pre-commit baseline grep` 段階で、削除予定の識別子だけでなく **「変更する構造ラベル」も grep の対象に含める** ことが必要。具体的には:

- 削除する識別子 (例: `Pre-check Item`、`場面 (a)/(b)`、`Routing dispatcher`) の同ファイル内全箇所を `grep -nE` で事前列挙
- 変更する構造ラベル (例: `Step [0-9]+`、`Phase [0-9]+\.[0-9]+`、heading hierarchy 変更) の同ファイル内全箇所を `grep -nE` で事前列挙
- 両 grep 結果を slim 後に再 grep し、**全 hit 件数が 0 になる** ことを pre-commit gate で確認

この 2 拡張を pre-commit gate に追加することで、broken intra-file reference / 構造ラベル grep 不一致の両 sub-pattern を構造的に予防できる。PR #890 の 3 cycle 収束は事後的に修正コスト (+7/-7 + cycle 2 の最小差分) が低く済んだが、pre-commit gate に上記 2 拡張を入れていれば 0 cycle で landed していた可能性が高い。

**規模スケールへの拡張**: PR #890 は -70 行という大規模 slim でありながら charter 違反引用は cycle 番号引用ではなく **section 構造の identity 表現** (heading / Item 番号) が中心だった点で、既存 8 PR (charter 違反引用の機械的削除中心) とは failure mode が異なる。本経験則の `削除単位の 3 分類` (inline parenthetical / bash literal comment / prose blockquote) は **削除対象が引用 phrase / 行 / 文節の場合** に適用される canonical で、**削除対象が section heading / Item 番号体系の場合** は本ページの新 sub-pattern (broken intra-file reference + 構造ラベル変更時の verbatim 引用 grep 不一致) を併用する必要がある。累計 117 件 / 9 PR で 8 PR (1 cycle) + 1 PR (3 cycle) の sibling 比率が確立し、本経験則の信頼性は high 水準を維持したまま「適用範囲の境界」を実測した。

## 関連ページ

- [既存ページなし — 本ページが本テーマの初出](#)

## ソース

- [PR #877 review results](raw/reviews/20260506T190517Z-pr-877.md)
- [PR #878 review results](raw/reviews/20260506T195728Z-pr-878.md)
- [PR #879 review results](raw/reviews/20260506T204827Z-pr-879.md)
- [PR #880 review results](raw/reviews/20260507T014914Z-pr-880.md)
- [PR #881 review results](raw/reviews/20260507T032241Z-pr-881.md)
- [PR #882 review results](raw/reviews/20260507T040320Z-pr-882.md)
- [PR #883 review results](raw/reviews/20260507T044332Z-pr-883.md)
- [PR #889 review results](raw/reviews/20260507T163353Z-pr-889.md)
- [PR #890 review cycle 1](raw/reviews/20260508T032656Z-pr-890.md)
- [PR #890 review cycle 3 (mergeable)](raw/reviews/20260508T034304Z-pr-890.md)
- [PR #890 fix cycle 1](raw/fixes/20260508T033003Z-pr-890.md)
- [PR #890 fix cycle 2](raw/fixes/20260508T033628Z-pr-890.md)
