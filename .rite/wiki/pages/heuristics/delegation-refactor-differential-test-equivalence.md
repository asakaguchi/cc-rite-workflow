---
title: "委譲リファクタの動作保持は原実装との差分テストで機械的に立証する"
domain: "heuristics"
created: "2026-05-30T09:32:00Z"
updated: "2026-05-31T17:12:40Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260530T064117Z-pr-1204.md"
  - type: "reviews"
    ref: "raw/reviews/20260531T004233Z-pr-1208.md"
  - type: "reviews"
    ref: "raw/reviews/20260531T163857Z-pr-1218.md"
  - type: "fixes"
    ref: "raw/fixes/20260531T164546Z-pr-1218.md"
  - type: "reviews"
    ref: "raw/reviews/20260531T165600Z-pr-1218.md"
tags: ["refactor", "verification", "testing", "delegation"]
confidence: high
---

# 委譲リファクタの動作保持は原実装との差分テストで機械的に立証する

## 概要

inline ロジック (inline Python / bash 等) を helper や transform へ委譲しつつ「動作を verbatim 保持する」ことが hard constraint のリファクタでは、**原アルゴリズムを参照実装として再現し、新実装と同一入力で出力を byte 比較して全件一致を示す** differential equivalence test を verification の中核に据える。これにより「同じはずだ」という主張を、レビュー可能な機械的証明へ変換できる。

## 詳細

PR #1204 (#1195 #8) は `archive-procedures.md` §3.5.2 の inline Python (~75 行、進捗 checklist の section merge) を `merge-checklist` transform へ委譲した。hard constraint は原アルゴリズムの verbatim 保持 (全文・完全行 dedup / section 末尾挿入 / section 不在 no-op / 末尾改行保持)。

- **立証法**: 原 §3.5.2 アルゴリズムを参照実装として bash/Python で再現し、新 transform と同一の 7 エッジケース (EOF section ±末尾改行 / 中間 section / 末尾空行 / section 不在 / 部分 dedup / 全項目既出 / 末尾改行なし) で出力を byte 比較 → 全件一致を確認。
- **通常の unit test との違い**: 期待値を人手でハードコードする unit test は、原実装の**非自明な暗黙挙動** (section 不在時の silent drop、末尾改行の正規化、複数 section 時の挿入先 等) を取りこぼしやすい。期待値を「原実装の出力そのもの」に取ることで、これらの暗黙エッジまで含めて等価性を保証できる。
- **強い signal**: PR #1204 では 5 レビュアー (prompt-engineer / code-quality / test / error-handling / security) のうち複数が、指示されずとも独立に「原 inline block と新実装の差分比較を byte 一致で確認する」手法を採用した。委譲リファクタの正当性検証として differential equivalence test が自然に選ばれることは、本 heuristic の有効性を裏付ける。結果は指摘 0 件 / 1 cycle 収束。
- **適用条件**: behavior-preserving な refactor 限定 (inline → helper 委譲 / 関数抽出 / 言語間移植 等)。動作を意図的に変える refactor には不適 (差分が出るのが正しいため)。

### 出力契約の verbatim 保持も差分検証の対象に含める (PR #1208)

PR #1208 (#1195 #10) は `wiki/lint.md` §6.2 の `all_source_refs` 集合構築 (~240 行 inline bash) を `wiki-lint-source-refs.sh` へ委譲した。本 PR の特徴は、差分検証の対象がアルゴリズム等価性だけでなく **出力契約そのもの** に及ぶ点: marker block (`---all_source_refs_begin/end---`) と 3 値 enum (`unknown` / `true` / `io_error`) を verbatim 保持することが下流 step の分岐を壊さない hard constraint であり、reviewer は (a) develop inline 実装との byte-level diff、(b) 新規 test 34/34 pass、(c) 実機 injection 検証の 3 点で確認し、5 reviewer 全員 0 blocking / 1 cycle 収束。

- **最も効率的な検証経路**: 「inline 削除版 vs helper 新規版の機械 diff」+「既存テスト実行」+「出力契約 (marker block / enum) の verbatim 一致確認」の 3 点セット。#1204 (#8) に続く同 umbrella 内 2 例目の独立再現で、faithful-port 委譲の検証手法として differential equivalence + 出力契約 verbatim の組み合わせが定着していることを示す。
- **trust boundary を確定してから injection を評価する**: faithful-port の bash injection 評価では入力の trust boundary を明示するのが有効。本 PR の page/branch 入力は LLM 制御下の wiki ページパスで外部ユーザー入力ではなく、防御は double-quote + allowlist gate (placeholder residue / partial pollution) の二層。injection リスクは「入力が誰の制御下にあるか」を確定してから severity を評価する。

### doc 適用範囲の対称記述 (sub-insight)

同 PR で prompt-engineer が surface した非ブロッキング推奨: §3.5.1 (完了情報 / append-eof 委譲) は「`### 完了情報` は WM 初期テンプレに存在しない新規セクション」と section-novelty を明記していたが、対称位置の §3.5.2 (進捗 merge) は「対象 `### 進捗` が v1 legacy 限定で、default v2 WM (`### 進捗サマリー` table) では merge が常に no-op になる」という適用範囲を記述していなかった。委譲リファクタでは **(a) 動作の等価性 (差分テスト) と (b) doc の適用範囲記述の対称性** の両方を verify する。(b) は [[asymmetric-fix-transcription]] の doc レイヤー版。

### 抽出境界に取り残されるデッドコードも検出対象 (PR #1218)

PR #1218 (#1195 #2) は `pr/fix.md` ステップ1.2.0 Hybrid Review Source Resolution の Selection logic (~550 行) を新規 `review-source-resolve.sh` へ verbatim 抽出した。同 umbrella #1195 内 **3 例目** の faithful-port 委譲で、検証は (a) `git show develop:...fix.md` の inline block との byte-level diff、(b) 同梱 test 37 assertions pass、(c) `distributed-fix-drift-check.sh` の新規 drift 0 (stash before/after 比較で delta=0) の **3 点セットを #1204 / #1208 と同型に再現**し、cycle 2 で 0 findings 収束。

本 PR が新たに surface した failure mode は、差分検証では「意味論的差分ゼロ」と判定される一方で **抽出境界に取り残されるデッドコード** が混入する点。cycle 1 で 3 reviewer が独立検出した 3 件はすべて「抽出時に上流境界からコピーされたが、対になる依存が抽出範囲外に残ったため宙に浮いた」コード:

- **cleanup 変数の no-op 化**: `norm_tmp` / `handed_off_norm_tmp` の宣言 + trap 参照だけが helper にコピーされたが、対になる非空代入 (`norm_tmp=$(mktemp ...)`) は schema normalization block (fix.md 側の **別 bash fence = 別プロセス**) に残ったため、helper 内では cleanup が常に `rm -f "" ""` の no-op になる。Claude Code の Bash tool は呼び出しごとに別プロセスで shell 変数も trap も継承されないため、「block 終了時 trap で削除」というコメントの主張が cross-process で成立しない。
- **未使用変数の習慣的混入**: standalone 化の際に習慣で追加した `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` は、helper が sibling script を source/invoke しないため未使用。develop の inline block には存在しなかった。
- **誤った namespace の enumeration への reason 追加**: caller reason を、本来属する 1.2.0 `FIX_FALLBACK_FAILED` 系列ではなく、別 step (2.4.N `NIT_NOTED_REPLY_*`) の独立 namespace enumeration に重複追加していた (drift Pattern-5 の file-level union では hook error にならないが、表と enumeration の同期契約に違反)。

canonical 対策: faithful-port 委譲の review checklist に「コピーした **cleanup 変数の非空代入 site が helper 内に存在するか** (別 fence に残っていないか)」「standalone 化で追加した変数が実際に使われるか」「reason を **正しい step の namespace** に追加したか」を加える。これらは runtime 挙動を変えないため差分テスト・test pass では検出されず、reviewer の cross-file grep でのみ surface する。

加えて、cycle 2 で reviewer が検出した **pre-existing 事項** (severity_map fence の `norm_tmp` orphan / `json_commit_sha_err` の signal-window leak) は、いずれも develop 時点から存在し本 PR diff が原因でない (revert test FAIL) ため指摘事項から除外し、investigation 推奨 / follow-up Issue (#1219 / #1220) に再分類した。faithful-port 委譲のレビューでは **verbatim 保持スコープを尊重し pre-existing バグを current-pr 指摘に混ぜない** scope 規律が重要 ([[scope-creep-rejection-empirical-gate]] / PR #1205 #1195 #9 の verbatim 保持スコープ尊重と同型)。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1204 review results](../../raw/reviews/20260530T064117Z-pr-1204.md)
- [PR #1208 review results](../../raw/reviews/20260531T004233Z-pr-1208.md)
- [PR #1218 review results (cycle 1)](../../raw/reviews/20260531T163857Z-pr-1218.md)
- [PR #1218 fix results](../../raw/fixes/20260531T164546Z-pr-1218.md)
- [PR #1218 review results (cycle 2)](../../raw/reviews/20260531T165600Z-pr-1218.md)
