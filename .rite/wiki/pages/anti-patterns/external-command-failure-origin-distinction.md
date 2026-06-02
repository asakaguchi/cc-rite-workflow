---
title: "外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure"
domain: "anti-patterns"
created: "2026-06-02T03:50:58Z"
updated: "2026-06-02T03:50:58Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260602T033014Z-pr-1244.md"
  - type: "fixes"
    ref: "raw/fixes/20260602T033213Z-pr-1244.md"
tags: ["gh-cli", "error-handling", "silent-failure"]
confidence: high
---

# 外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure

## 概要

`gh pr view N` のような外部コマンドが失敗したとき、失敗種別 (origin) を区別せず無条件に「別の番号空間・別経路とみなす」分岐は silent failure である。404 (semantic な not-found = `Could not resolve to a PullRequest`) と一時障害 (network / auth / rate-limit) は意味が全く異なる。前者だけが再分類 (例: 「N を Issue とみなす」) を正当化し、後者は誤分類せず中断すべき。さらに silent な scope 縮退 (PR 解決失敗 → Issue のみで続行) はユーザー通知を必須にする。rite codebase はこの house rule を `pr/fix.md` の canonical 警告として持つ。

## 詳細

PR #1244 (`/rite:learn` spec) の cycle 5 で error-handling reviewer が MEDIUM 検出した。`learn.md:54` が `gh pr view N` 失敗時に PR 404 と一時障害を区別せず無条件に「N を Issue とみなす」へ分岐していた。これは「gh 失敗 → 別番号空間へ再分類」を silent failure 禁止 anti-pattern として明示する repo の house rule (`pr/fix.md:236`) に反する。

### canonical 対策

- **失敗種別を exit code / stderr で区別する**: not-found (`Could not resolve to a PullRequest` 等の 404 シグナル) のみ別経路 (Issue 扱い) へ進む。一時障害 (network / auth / rate-limit) は誤分類せず中断する。
- **silent な scope 縮退にユーザー通知を添える**: 「PR 解決失敗 → Issue のみで続行」のように対象範囲を黙って狭める分岐は、必ずユーザーに通知する。
- 新規コマンドの prose 指示書 (LLM 実行手順) でも同 anti-pattern を踏襲しないよう、「失敗時に X とみなす」分岐を書くときは必ず失敗種別 (not-found vs transient) を区別する prose を添える。

### 観測された reviewer 非決定性

同 reviewer が cycle 4 ではこの論点を design_confirmation (任意) と判定し、cycle 5 で MEDIUM blocking に格上げした。reviewer の severity 判定は「read-only / 副作用なし」という緩和要因の重み付けで cycle 間に振動しうる。iterate ループは指摘ゼロまで継続する設計のため、振動する指摘も一度 blocking に出れば修正する (修正は codebase 規約との整合を高めるため正味プラス)。cycle 6 では「対応済み・severity 一貫性のため再指摘せず」と確認され収束した — reviewer prompt に「前 cycle で任意と判断した論点を理由なく blocking に格上げしない」severity 一貫性ガードを入れると収束が早まる。

## 関連ページ

- [gh api graphql は HTTP 200 + .errors[] で partial failure を返す (exit code では検知できない)](./gh-api-graphql-http200-partial-errors.md)
- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](../patterns/silent-fallback-observability-via-debug-log.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)

## ソース

- [PR #1244 review results (cycle 5)](../../raw/reviews/20260602T033014Z-pr-1244.md)
- [PR #1244 fix results (cycle 5)](../../raw/fixes/20260602T033213Z-pr-1244.md)
