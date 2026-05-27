---
title: "Flatten refactor の削除スコープは 3 軸 (歴史注釈 / 同期保守情報 / 機能 statement) で classification する"
domain: "heuristics"
created: "2026-05-27T00:30:00Z"
updated: "2026-05-27T00:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260526T175307Z-pr-1155.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T180309Z-pr-1155.md"
tags: ["refactor", "flatten", "deletion-scope", "silent-regression", "declarative-defense"]
confidence: high
---

# Flatten refactor の削除スコープは 3 軸 (歴史注釈 / 同期保守情報 / 機能 statement) で classification する

## 概要

「declarative defense layer の物理排除」を目標とする flatten refactor PR では、削除対象を **(a) 歴史注釈 / (b) 現役の同期保守情報 / (c) 機能を持つ statement** の 3 軸で classification してから削除する。混同すると次 cycle で reviewer が新規 finding を出して fix loop が永久化する。`Reference:` link や 分散実装一覧 (SoT)、Pattern 規範に基づく WARNING emit は **Keep カテゴリ** で、削除すると silent regression を生む。

## 詳細

### 発生条件

cleanup.md スタイルへの「フラット化」のような flatten refactor PR では、blockquote / コメント / 注釈の物理削除がスコープになるが、削除対象には混在した複数性質のテキストが含まれる:

1. **歴史注釈** (削除可): `# F-05/F-06 fix: ...` / `# Issue #547: ...` / `# cycle 6 fix: ...` のような git blame で追える過去 fix の自己弁護コメント
2. **現役の同期保守情報** (Keep): SoT への分散実装一覧、`Reference: bash-trap-patterns.md#signal-specific-trap-template` のような Pattern 規範への link
3. **機能を持つ statement** (Keep): Pattern 3 規範に基づく `if ! mktemp ...; then echo "WARNING: ..."; var=""; fi` のような mktemp 失敗時 WARNING emit (silent fallback への格下げは [[mktemp-failure-surface-warning]] 違反)

判別基準は **「git blame で追える過去の自己弁護か / 現在の reader が判断に必要か」** の 2 軸で評価する。

### PR #1155 で実測した failure mode

PR #1155 cycle 1 fix (Issue #1154 — `wiki:* commands` の cleanup.md スタイル本格フラット化) で本 anti-pattern が 3 reviewer 独立検出された:

#### Failure 1: 機能 statement の silent fallback への格下げ

`ingest.md` L248 (cat_err) / L535 (_reset_err) で Pattern 3 規範の 3 行 WARNING (mktemp 失敗 / 対処 / 影響) が `var=$(mktemp 2>/dev/null) || var=""` の silent fallback に格下げされた。同一 PR 内の他 site (find_err / lint.md add_err / commit_err / sort_err) は WARNING emit を維持しており **非対称な regression**。

#### Failure 2: 同期保守情報の喪失

`query.md` から `wiki.enabled` YAML パース実装の分散ファイル一覧 (10 site) が完全削除された。歴史注釈ではなく現役の同期保守情報であり、将来パース仕様変更時の drift リスク mitigation 機能。

#### Failure 3: blockquote 削除と statement 削除の混同

「blockquote 排除」スコープで削除した中に、Pattern 規範に基づく機能 WARNING や Reference link が混入。「コメント削除のみ許容」と PR 説明文に書きながら、実際には functional statement に手が入っていた。

### 削除前検証ルール

flatten refactor PR では、削除前に以下の 3 ステップで分類する:

1. **git blame check**: 該当行を `git blame` で追って、過去 fix の self-defense comment か (= 削除可) を判定
2. **grep evidence check**: 削除対象が現役の SoT / 分散実装一覧 / Pattern 規範への link を含むか (`grep -rn "Reference:" / "SoT" / 分散実装` で逆検索)
3. **functional statement check**: 削除対象が `if ! ...; then echo "WARNING" >&2; fi` のような機能 emit を含むか (= Keep)

### 一般化

- **Keep カテゴリの canonical な扱い方**: 削除でなく SoT への移管 (= [[single-sot-on-references-extract]]) によって drift-free に集約する。inline での性質再宣言は削除し、SoT への forward-pointer に置き換えるのが drift-free 経路
- **同 PR 内の対称性 grep 検査**: 削除作業中、同 PR の他 site で同型 pattern (`mktemp ... || var=""`) を grep で網羅検査して非対称な regression を防止 ([[asymmetric-fix-transcription]] の予防策)

## 関連ページ

- [[mktemp-failure-surface-warning]] ([mktemp-failure-surface-warning.md](../patterns/mktemp-failure-surface-warning.md))
- [[asymmetric-fix-transcription]] ([asymmetric-fix-transcription.md](../anti-patterns/asymmetric-fix-transcription.md))
- [[single-sot-on-references-extract]] ([single-sot-on-references-extract.md](../patterns/single-sot-on-references-extract.md))

## ソース

- [PR #1155 review cycle 1 (3 reviewer 独立検出の HIGH x 3 — 削除対象 3 軸 classification 違反の同時混入)](../../raw/reviews/20260526T175307Z-pr-1155.md)
- [PR #1155 fix cycle 1 (フラット化 PR スコープの誤適用回収、削除前検証ルール確立)](../../raw/fixes/20260526T180309Z-pr-1155.md)
