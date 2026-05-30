---
title: "委譲リファクタの動作保持は原実装との差分テストで機械的に立証する"
domain: "heuristics"
created: "2026-05-30T09:32:00Z"
updated: "2026-05-30T09:32:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260530T064117Z-pr-1204.md"
tags: ["refactor", "verification", "testing", "delegation"]
confidence: medium
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

### doc 適用範囲の対称記述 (sub-insight)

同 PR で prompt-engineer が surface した非ブロッキング推奨: §3.5.1 (完了情報 / append-eof 委譲) は「`### 完了情報` は WM 初期テンプレに存在しない新規セクション」と section-novelty を明記していたが、対称位置の §3.5.2 (進捗 merge) は「対象 `### 進捗` が v1 legacy 限定で、default v2 WM (`### 進捗サマリー` table) では merge が常に no-op になる」という適用範囲を記述していなかった。委譲リファクタでは **(a) 動作の等価性 (差分テスト) と (b) doc の適用範囲記述の対称性** の両方を verify する。(b) は [[asymmetric-fix-transcription]] の doc レイヤー版。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1204 review results](../../raw/reviews/20260530T064117Z-pr-1204.md)
