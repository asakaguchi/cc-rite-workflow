---
title: "Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする"
domain: "heuristics"
created: "2026-05-26T00:00:00Z"
updated: "2026-05-26T00:00:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260525T070727Z-pr-1139.md"
  - type: "reviews"
    ref: "raw/reviews/20260525T081823Z-pr-1139.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T104719Z-pr-1139.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T124932Z-pr-1139.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T141022Z-pr-1139.md"
tags: ["docs-drift", "verification-protocol", "implementation-grep", "release-prep", "deprecated-sync", "fact-check"]
confidence: high
---

# Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする

## 概要

Documentation の prose が言及する実装側 (commands/, scripts/, templates/, .ja./.md ペア) の現状 (file 存在・key live 状態・sentinel emit 経路・heading slug) を grep / `ls` / `git show` で機械的に verify する step が review protocol に欠落すると、CHANGELOG / SPEC / CONFIGURATION / migration-guide の記述が実装の現状と乖離したまま merge される。PR #1139 (Issue #1138、v0.5.0 リリース前 docs 見直し、cycle 14 / 51 findings) で 14 サイクル通じて発火し、cycle 5 で「documentation 内 prose が言及する実装側を grep で確認する」が明文化され、cycle 8 で「fix 履歴の遡及確認」、cycle 12 で「SPEC 全文 1 度通読」、cycle 13 で「prose 内 step 番号書き換えの implementation SoT grep verify」と運用層拡張された。

## 詳細

### 観測された具体パターン

PR #1139 cycle 1-14 で 51 件の findings が出た root cause は、ほぼ全件が「documentation の prose が implementation の現状を verify せずに整合性のみ追っていた」点に集約される。本 PR の場合 documentation 側だけで内的整合は cycle 1+2 でほぼ取れていたが、実装側との照合が cycle 5 まで実施されなかったため latent な dead reference / factually-wrong claim が cycle 後半まで蓄積した。

具体的な失敗形態:

1. **CHANGELOG `removed in #N` claim の `ls` 未 verify** (cycle 2 F-01 CRITICAL): CHANGELOG が `plugins/rite/i18n/ja/` を「remain on disk but are no longer referenced at runtime」と書いたが、ディレクトリ自体は #1117 で完全削除されており `ls` は ENOENT を返す。`removed in #N` 系の claim は対応する path に対して `ls` / `git show {sha}:{path}` で actual state を verify せず prose を書いた結果、CHANGELOG 自身が factually false。
2. **CHANGELOG の `# wave` で削除された複数 keys の DEPRECATED 化漏れ** (cycle 1 F-04/F-05, cycle 2 F-02 HIGH): `#1118` で 3 keys が同時削除されたが PR は `separate_issue_creation.*` のみ DEPRECATED 化し、`observed_likelihood_gate.*` / `fail_fast_first.*` / `fix.severity_gating` / `project.type` の他 4 keys を docs 側に live として残置。`# wave` を unit of consistency と認識せず個別 key として処理した結果。canonical 対策: CHANGELOG に `removed in #N` を追記する PR は、その # で削除された全 keys を CHANGELOG 自体から再抽出し、各 key について `grep -rn '<key>' docs/` で残存する live citation を機械検出し、同じ DEPRECATED 化パターンで一括更新する。
3. **Sentinel / Terminal marker の implementation 未 verify** (cycle 1 F-02/F-03 HIGH): docs/SPEC.md Terminal marker 表に新コマンド (`iterate.md` / `ready.md`) の sentinel を書く際、`grep -n '\[iterate:completed\]' plugins/rite/commands/pr/iterate.md` で実装側に存在するかを verify せず、旧 orchestrator の用語 (`Workflow Termination block`) を流用。`iterate.md` の実 sentinel は `[review:mergeable]` / `[fix:replied-only]` / `[fix:cancelled-by-user]` で、phantom sentinel が docs に landed していた。
4. **Documentation が言及する live phase の implementation grep 欠落** (cycle 5 F-01 CRITICAL 4 箇所): documentation が「review 出力からの自動 Issue 作成は発生しない」と factually false な主張をしていたが、`review.md` Phase 7 を grep すると `source: pr_review` 経路で live。#1136 で削除されたのは `fix.md` Phase 4.3 のみ。documentation の「fully removed」claim が cycle 5 まで implementation grep されなかった結果、5 cycle 通じて生き残った。cycle 5 で tech-writer が新規 hunt で実装側 grep を実施した結果として初めて発見。
5. **Self-Defeating Fix の連続再発** (cycle 4/5/8/11/12): fix 自体が新たな dead reference / fact error を導入する pattern が 5 cycle 連続で発火。cycle 4 で「self-defeating fix」が learned に記録されたが、cycle 5/8/11/12 でも同根 (新規導入する説明文の事実確認 step が verification protocol に組み込まれていない) で再発。learned 単発記録では足りず verification protocol レベルでの強制が必要。
6. **TOC anchor の symmetric fix sweep 漏れ** (cycle 12 F-01 / cycle 13 CQ-F-01 HIGH): SPEC TOC anchor mismatch を 1 箇所 fix した際、同じ rename pattern を持つ他の heading を全て sweep する step が欠落。cycle 12 で `Internationalization` H2 rename を fix したが `Project Types` H2 rename を sweep し忘れ、cycle 13 で再検出。
7. **Tree comment / Plugin Structure tree の implementation mirror drift** (cycle 11 F-02 HIGH): SPEC plugin structure tree が templates/ / commands/ の実状を mirror する場合、関連する config 変更 (#1118 で `project-types/` 削除) の影響を tree 側に grep 反映する step が欠落。

### 確立された verification protocol

PR #1139 から導かれた「documentation review verification protocol」の必須 step:

1. **CHANGELOG fact-check**: `removed in #N` / `migrated in #N` 等の claim には対応 path に対して `ls path/` / `git show {sha}:{path}` で actual state を verify する。
2. **`# wave` grep sweep**: CHANGELOG に `# N` 言及がある場合、その PR で削除された全 keys / features を `git show {sha}` で enumerate し、各 key について `grep -rn '<key>' docs/` で残存 live citation を一括検出する。`# wave` は unit of consistency。
3. **Sentinel / Terminal marker の implementation 存在 verify**: docs に sentinel literal (`[xxx:completed]` 等) を書く前に必ず `grep -n '\[<sentinel>\]' plugins/rite/commands/` で実装側に存在するか確認する。旧 orchestrator 由来の用語 (`Workflow Termination block` 等) は特に高 risk。
4. **`fully removed` 系 claim の path 分解**: 「fully removed」claim は (a) fix-side (b) review-side 等の経路ごとに分解し、各経路の現状を `grep -rn` で個別 verify する。1 経路 only の removal は `2 経路 + 各経路の #N status` table 形式で明示。
5. **Heading slug 再計算 verify**: 手書きで anchor (`#xxx`) を書く PR では GitHub slug 算法 (`lowercase + 非英数除去 + space→hyphen`) で再計算し本文の anchor と一致するか verify する。typo は silent failure。
6. **JA/EN pair grep**: 片方 fix の際は対応する日英ペアを `grep -rn` で再走査し parity drift を防ぐ。fix の日英ペア同時適用 verification が verification protocol に必要。
7. **同 file 内の関連 prose grep**: fix 適用時に同 file 内の関連 prose を `grep` 検索し self-contradiction を防ぐ (cycle 7→8 で CONFIGURATION.md L548 を post-#1136 に書き直したが他 5 箇所が live モデル残置した self-contradiction を一括補修した教訓)。
8. **Docs vs Template SoT grep** (cycle 10 F-01): docs を更新する際、対応する template (`templates/config/rite-config.yml` 等、配布物の SoT) も grep で確認する。docs と template の SoT drift は配布物としての挙動に影響する。
9. **SPEC 全文 1 度通読**: SPEC は section ごとに独立した記述が散らばっており、削除済機能の言及が複数 section (tree / Phase / Project Types / sub-skill table) に分散する場合、全文 1 度通読が必要 (cycle 12 F-02/F-03 で section ごとに散在する Project Types / /rite:init Phase 2 Detection を一括 retired 化した教訓)。

### Root cause summary

documentation review の verification protocol が **「内的整合 (CHANGELOG ↔ CONFIGURATION の言及対応など)」のみに focus し「documentation ↔ implementation の cross-reference 検証」を欠いていた** ことが PR #1139 の 51 findings / 14 cycle convergence の本質。release-prep docs PR は特に「latest implementation の grep が SoT」と認識し、prose 内のあらゆる factual claim (file 存在・key live・sentinel emit・phase 経路) を implementation grep で裏取りする protocol を必須にすべき。

### 適用範囲

- リリース直前の大規模 docs 整備 PR (本 PR #1139 のような pre-release docs review)
- 大型 retire/decompose 系 PR (`#1117` i18n 廃止、`#1118` scaffolding 削除、`#1136` /rite:issue:start 4 分解 など) の事後 docs 整備
- migration-guide 更新 PR (旧 → 新 phase mapping を含むため特に implementation grep が critical)
- CONFIGURATION.md / SPEC.md / CHANGELOG.md / README.md の cross-doc 整合 PR

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1139 review cycle 1 (anchor link typo / phantom sentinel / Asymmetric Fix Transcription on #1118 wave)](../../raw/reviews/20260525T070727Z-pr-1139.md)
- [PR #1139 review cycle 2 (CHANGELOG `remain on disk` factual error / project.type CHANGELOG vs CONFIGURATION drift)](../../raw/reviews/20260525T081823Z-pr-1139.md)
- [PR #1139 fix cycle 5 (Verification Cross-Reference Gap 確立: review.md Phase 7 live を 5 cycle 経て初検出)](../../raw/fixes/20260525T104719Z-pr-1139.md)
- [PR #1139 fix cycle 8 (Implementation-Grep Verification Gap: fix 履歴の遡及 grep 必須化)](../../raw/fixes/20260525T124932Z-pr-1139.md)
- [PR #1139 fix cycle 12 (SPEC Multi-Section Same-Topic Drift: SPEC 全文 1 度通読の必要性)](../../raw/fixes/20260525T141022Z-pr-1139.md)
