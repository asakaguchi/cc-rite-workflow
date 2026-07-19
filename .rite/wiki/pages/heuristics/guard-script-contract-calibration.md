---
type: "heuristics"
title: "再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する"
domain: "heuristics"
description: "guard 系スクリプトは「宣言した検出範囲」と「実際の regex」の対応がレビューで実測検証される。regex は現存パターンの再現でなく宣言意図（quote/flag バリアント含む）に合わせ、非検出形は Known boundary 節に隠さず列挙する。opt-in flag は実装と call site 配線を同一コミットで行う。PR #1909 cycle 3-5 の実測。"
created: "2026-07-19T15:00:00+09:00"
updated: "2026-07-19T15:00:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T030534Z-pr-1909-c3.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T030743Z-pr-1909-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T031816Z-pr-1909-c4.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T031957Z-pr-1909-c4.md"
tags: []
confidence: high
---

# 再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する

## 概要

lint / recurrence-guard 系スクリプトのレビューでは「docstring が宣言する検出範囲」と「実際の regex が検出する範囲」の対応が合成テストで実測検証され、乖離は指摘になる。regex は「現存パターンの正確な再現」だけで校正せず宣言意図（quote/flag バリアント含む）に合わせ、意図的な非検出形は Known boundary 節に完全列挙する。PR #1909 の cycle 3-5 で実測された連鎖。

## 詳細

PR #1909（sandbox 非互換パターンの全域スイープ + tmp-hardcode-check.sh 新設）で観測された 3 つの失敗形:

1. **regex が宣言より狭い**: docstring は「mktemp with a /tmp-prefixed template」「fixed /tmp path hardcode (assignment / redirect / -file option)」と宣言したが、regex は quoted template（`mktemp "/tmp/rite-XXXXXX"`）・flag 介在（`mktemp -d /tmp/...`）・quoted redirect・unquoted 代入の 4 形式を素通しした。皮肉なことに、sweep 自身が教える安全形が quoted スタイル（`mktemp "${TMPDIR:-/tmp}/..."`）のため、「quoted のまま /tmp へ regress する」形式が最も蓋然性の高い将来の回帰形だった。レビュアーは widened regex で 4/4 検出かつ false positive 0 を実測して指摘した。
2. **Known boundary の記載漏れ**: 検出契約の SoT である Known boundary 節に、実測済みの非検出形（refspec 後置 flag `git push origin -u branch`）を書き漏らした。「regex を広げる」より「境界を明記する」が正しいケース — prose への false positive を生む拡張は避け、docstring 追記で契約を誠実にする。
3. **dead option 化**: consumer-repo 用の `--skip-if-no-target` flag を実装したのに、唯一の call site（lint check table）に渡し忘れた。flag の help text が明記するユースケースそのもので配線されておらず、2 reviewer が独立に検出して severity boost（MEDIUM→HIGH）。**opt-in flag の実装と call site への配線は同一コミットで行う**。

**付随ヒューリスティック — 再出現推奨の先回り**: 複数 cycle にわたって再出現する actionable 推奨事項は、次 cycle で指摘に昇格する傾向がある（helper docstring drift が cycle 2 推奨 → cycle 3 指摘に昇格した実例）。収束を早めるには、再出現した推奨を指摘昇格前に先回りで潰す。

## 関連ページ

- [機械的一括置換は同一リテラルの役割差を無視すると load-bearing fixture を壊す](../anti-patterns/bulk-substitution-ignores-literal-role.md)
- [テンプレート流用の新規スクリプトは最新兄弟の防御を継承する](./new-script-inherits-latest-sibling-defenses.md)

## ソース

- [PR #1909 review results (cycle 3)](../../raw/reviews/20260719T030534Z-pr-1909-c3.md)
- [PR #1909 fix results (cycle 3)](../../raw/fixes/20260719T030743Z-pr-1909-c3.md)
- [PR #1909 review results (cycle 4)](../../raw/reviews/20260719T031816Z-pr-1909-c4.md)
- [PR #1909 fix results (cycle 4)](../../raw/fixes/20260719T031957Z-pr-1909-c4.md)
