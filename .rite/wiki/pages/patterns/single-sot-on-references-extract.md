---
title: "References 抽出 refactor では canonical contract の SoT を 1 reference に固定し他は anchor 参照のみとする"
domain: "patterns"
created: "2026-05-12T15:29:45Z"
updated: "2026-05-19T12:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260512T134356Z-pr-936.md"
  - type: "fixes"
    ref: "raw/fixes/20260512T134908Z-pr-936.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T114404Z-pr-1062.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T122133Z-pr-1062.md"
tags: ["sot", "refactor", "references-extraction", "drift", "canonical-contract"]
confidence: high
---

# References 抽出 refactor では canonical contract の SoT を 1 reference に固定し他は anchor 参照のみとする

## 概要

本体 command を slim 化するために散文 rationale + bash literal を複数 references に分割する refactor では、共通契約 (Sentinel Visibility Rule のような cross-cutting な canonical contract) を両方の reference に重複保持してはならない。両方が「SoT を主張する」状態は drift を必ず起こすため、refactor 計画段階で「どの reference が SoT か」を 1:1 で決定し、他方は anchor 参照のみとする。`assert_not_grep` ベースの drift guard を test に追加することで、将来の再混入を構造的に block できる。

## 詳細

### 失敗モード

PR #936 (Issue #900 PR D、`start.md` から 3 references への抽出) で実測。Sentinel Visibility Rule のような cross-cutting な契約を `workflow-incident-detection.md` と `workflow-incident-emit-pattern.md` の両 reference に同一 bash literal で保持すると、両者が SoT を主張する状態になる。後続 PR で片方を改修したときに他方への伝播が漏れる経路は `asymmetric-fix-transcription` と同型だが、起点は **refactor 計画段階の設計不備** にある (fix 適用時の伝播漏れではなく、そもそも 2 箇所に SoT を置いたこと自体が原因)。

### 検出手段

- review 段階で「同一 canonical literal が複数 reference に重複保持されている」ことを `diff -u {ref_A} {ref_B}` ベースの section-level 一致 grep で機械検証
- test 側に `assert_not_grep` (= 「該当 literal は 1 reference にしか存在してはならない」) を pin することで将来の再混入を構造的に block (PR #936 cycle 1 fix で `sentinel-visibility-rule.test.sh` に 57 assertion 追加して実証)
- refactor 計画文書 (例: `docs/designs/redesign-issue-start-hybrid.md`) で各 reference の責務スコープを 1:1 で宣言する段階で「同一契約が複数の責務範囲に出現」する重複を pre-extraction 検出

### Canonical 対策

1. **Refactor 計画段階の SoT 1:1 決定**: 抽出対象の canonical contract をリストアップし、各々を 1 reference に固定する。複数 reference で参照されるものは「SoT は X、Y/Z は anchor 参照のみ」と明示する
2. **Anchor 参照の規約化**: SoT でない reference は `> Reference: [<concept>](path/to/sot.md#anchor)` 形式の anchor link のみを記述し、literal の重複保持を禁止する
3. **Drift guard test の同時追加**: refactor PR と同じ commit で `assert_not_grep` ベースの drift guard test を pin することで、抽出後の再混入を構造的に block する
4. **ファイル移動時の bash コメント内 path の hygiene**: refactor のサブ作業として、bash コメント内に書かれた相対 path (例: `../../skills/...` など) は機械的に解決されないため、移動先で path が壊れる経路がある (PR #936 F-02 MEDIUM)。reviewer checklist に「bash comment 内 path 一致確認」を入れる

### Sub-pattern: SoT の prose 要約参照 vs literal algorithm copy-paste (PR #1062 cycle 1-3)

SoT を参照する新規 site が「SoT と同方式」と prose で宣言するだけでは insufficient であり、SoT の具体的アルゴリズム (bash literal / pseudo-code) を copy-paste で取り込むか、SoT helper を invoke する形に統一する必要がある。PR #1062 で `references/fingerprint-cycling.md` (SoT) の `normalize` 4 ステップ仕様を新規 site `fix.md` Phase 2.1.A bash block が **prose 要約から推測して 2 ステップに勝手に simplify** した結果、fix.md persist fingerprint と review.md compare fingerprint が同一 finding に対して異なる SHA-1 hash になり AC-3 suppression contract が初日から silent failure。2 reviewer 独立検出の CRITICAL × 2 として cycle 1 で surface し、cycle 3 まで再発を引きずった。

**失敗モード** (PR #1062 cycle 1-3 で実測):

- **Step 1**: 新規 site 実装時に SoT を「prose 要約から再実装」: `references/fingerprint-cycling.md` の「`category`, `description`, `file:line` を combine して normalize 後 SHA-1 する」散文記述を新規 bash block で 2 step に再構築 (4 step normalize を 2 step に simplify)
- **Step 2**: review 段階で「SoT と同方式」claim を prose レベルで verify: bash literal の bit-exact 一致は verify されず、cycle 1 reviewer は SoT 参照の存在のみ確認
- **Step 3**: 後続 cycle で suppression contract failure が actual hash 差として観測されて初めて CRITICAL re-detect

**Canonical 対策**:

1. **SoT の bash literal を copy-paste で取り込む**: prose 要約に依存せず、SoT 側の具体的 bash 実装 (normalize 4 ステップ等) をそのまま新規 site に copy。SoT 改修時は両 site の bash literal が drift しないか pre-commit gate で grep verify
2. **SoT helper の invoke 経路に統一**: `compute_fingerprint()` のような shell function / script として SoT を実装し、新規 site は helper を invoke するだけにする。実装は SoT 1 箇所に集約、新規 site は契約 invocation のみ
3. **2 段階契約による verify**: 「(a) document レベルの formula 一致 (両 file の prose に同じ formula 文字列が書かれているか grep)」と「(b) implementation レベルの bash bit-exact 一致 (両 file の bash block を `diff` で照合)」を **両方** 実行する pre-merge gate を導入

**「prose 要約に依存した『SoT と同方式』claim」を禁止形式として codebase 規範化** することで、本 sub-pattern の structural prevention が可能。Wiki 経験則 [SoT-reviewer 表現 drift](../anti-patterns/sot-reviewer-expression-drift.md) (pos/neg 表現の drift) と並ぶ **SoT 参照型 DRY 設計の 2 大典型落とし穴** として位置付ける。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する](../anti-patterns/sot-reviewer-expression-drift.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](drift-check-anchor-prose-code-sync.md)

## ソース

- [PR #936 review results](../../raw/reviews/20260512T134356Z-pr-936.md)
- [PR #936 fix cycle 1 results](../../raw/fixes/20260512T134908Z-pr-936.md)
- [PR #1062 cycle 1 review (SoT prose 要約に依存した「同方式」claim が bash literal bit-exact 一致を満たさず CRITICAL × 2 として 2 reviewer 独立検出。`fingerprint-cycling.md` の normalize 4 ステップ仕様を新規 site で 2 ステップに simplify した silent failure)](../../raw/reviews/20260519T114404Z-pr-1062.md)
- [PR #1062 cycle 4 mergeable (cycle 3 で bash literal を SoT から copy-paste することで document/code 両層 symmetric に到達、2 段階契約 (document formula 一致 + bash bit-exact 一致) doctrine を確立)](../../raw/reviews/20260519T122133Z-pr-1062.md)
