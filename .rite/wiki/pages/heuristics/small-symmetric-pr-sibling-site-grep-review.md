---
title: "極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる"
domain: "heuristics"
created: "2026-04-19T06:45:00Z"
updated: "2026-05-14T22:40:21Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T062330Z-pr-592.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T182616Z-pr-963.md"
  - type: "fixes"
    ref: "raw/fixes/20260514T223534Z-pr-967.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T224021Z-pr-967.md"
tags: []
confidence: high
---

# 極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる

## 概要

5 行程度の極小 refactor PR (特定 Phase の sibling site 対称化) では、複数の同型箇所 (例: 4 sibling site) を Grep + Read で網羅的に照合し、変数名とラベル以外の構造的差分を洗い出すことで、「指摘事項 0 件 + merge 可」の判定を短時間で Confidence 80+ として出せる。

## 詳細

**適用対象**: selective surface / stderr suppression / mktemp + trap / `LC_ALL=C` 適用等、プロジェクト内で意図的に繰り返される idiom の一部を対象とした対称化 PR。

**レビュー手順の骨子**:

1. **sibling site の全量列挙**: 対象 idiom の canonical 文字列 (例: `WARNING(cat hint):`, `head -3 "$index_err"`) を Grep で repo 全体から探す。hit した箇所が「本 PR で対称化すべき全 sibling site」の母集団になる。
2. **構造的差分の逐行照合**: Read で各 sibling を並べ、変数名・エラーラベル・ファイル path 以外の差分を抽出する。差分が「想定内の局所変数名のみ」なら構造的対称性は成立。
3. **Counter 宣言の検証** (該当する場合): 「N 箇所対称化」と PR / commit message に書かれている場合、Grep hit 数と照合する。drift があれば LOW 以上の finding として報告。

**なぜこれが有効か**:

- 極小 PR は変更行が少ないため、Grep で期待 pattern を repo 全体から拾い出す方が、diff を単体で読むより網羅的。
- 対称化タスクの本質 hazard は「対称位置への伝播漏れ」(既存 wiki: Asymmetric Fix Transcription) であり、これは diff 単体には現れず sibling site の grep でのみ検出できる。
- sibling 数が 4 以下の場合、Read で並べて照合する cost が Grep 以外のレビュー方式より低い。

**合わせて適用すべきサブ技法**:

- **ハードコード番号の実在性検証**: PR 本文やコメント内の `PR #NNN` / `Issue #NNN` 参照は `gh pr view` / `gh issue view` で実在と state を確認する。これは wiki の「Hallucinated canonical reference」anti-pattern をレビュー側で pre-block する対称技法。
- **Scope 外推奨事項の別 Issue 候補化**: 本 PR で同時対応すべきでない対称化余地 (例: `LC_ALL=C` の追加適用) は、レビューで明示的に「scope 外 / 別 Issue 候補」として推奨事項に残す。複数 reviewer が独立に同じ推奨を挙げた場合は候補の妥当性が triple cross-validation される。

**適用時の注意**:

- sibling 数が 5 以上になる場合は Grep 照合の読み込み量が増え、単純 diff レビューとの境界が曖昧になる。併用を検討する。
- idiom が意図的な非対称性 (例: `separate_branch` と `same_branch` で実装契約が異なる) を含む場合、構造的差分を「対称化すべきか意図的か」の二段階で分類する必要がある。

**PR #963 累積 evidence (4-site `from=` discriminator pattern)**: 小規模 refactor PR (+22/-5, 4 files) で 0 blocking finding 1 cycle 着地。`LOCKDIR_CLEANUP_FAILED=1` emit の片肺問題を `from={start_md_termination,start_finalize_termination,session_start_cleanup,cleanup_work_memory}` という 4 値 discriminator で対称化した PR。3 reviewer (prompt-engineer / code-quality / error-handling) 全員が承認、推奨事項 LOW 3 + scope 外候補 MEDIUM 2 のみ。本ページの手順 (sibling site grep + 構造的差分照合 + counter 宣言検証) が hint:specific-assertion-pin で適用された case study であり、4 hit grep + 1 hit Note 内列挙の expected 数も PR 本文で事前宣言された。さらに「pre-existing drift (4-site-symmetry.test.sh の scope mismatch)」と「隣接 site (cleanup-work-memory.sh の per-file lockdir) の非対称」を **scope 外推奨事項 / 別 Issue 候補** として残す sub 技法 (本ページ既存記述) が複数 reviewer から独立に挙がり triple cross-validation された。

**PR #967 累積 evidence (2-site work memory lockdir 別系統対称化、PR #963 follow-up の sibling separation case)**: PR #963 cycle 1 で reviewer が「scope 外推奨事項 / 別 Issue 候補」として挙げた「cleanup-work-memory.sh の per-file lockdir 非対称」を Issue #964 として切り出した follow-up PR (+13/-3, 2 files)。global state lockdir (4 site、`from=cleanup_work_memory`) と per-issue work memory lockdir (2 site、`from=cleanup_work_memory_wm_dir` / `cleanup_work_memory_issue`) を **別系列として明示分離** したマッピング表を start-finalize.md に追加。cycle 1 で prompt-engineer reviewer が 1 MEDIUM (note 引用の consumer scope 不正確 — `pre-compact.sh:82` global state vs `work-memory-update.sh:153` per-issue の取り違え) を独立検出し、cycle 2 で 1-line wording fix により 3 reviewer 全員 0-finding mergeable 着地。本 case は (a) 別 Issue 化された scope 外推奨が次 PR で自然に消化される運用パターン、(b) 「対称化」と並行して「別系列の明示分離」が必要な場合の note 文言精度 (consumer 引用の scope 一致) が独立 finding として浮上する sub 技法を実証。`{n}-site mapping note を追加する PR では同名類似 idiom (例: lockdir cleanup) の consumer も grep で照合して引用 scope を verify する` という追加 hint を canonical 化。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](canonical-list-count-claim-drift-anchor.md)

## ソース

- [PR #592 review results](../../raw/reviews/20260419T062330Z-pr-592.md)
- [PR #963 review results](../../raw/reviews/20260514T182616Z-pr-963.md)
- [PR #967 fix results](../../raw/fixes/20260514T223534Z-pr-967.md)
- [PR #967 review results (cycle 2 mergeable)](../../raw/reviews/20260514T224021Z-pr-967.md)
