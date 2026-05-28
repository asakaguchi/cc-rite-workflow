---
title: "prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する"
domain: "anti-patterns"
created: "2026-05-28T23:42:28Z"
updated: "2026-05-28T23:42:28Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260528T232433Z-pr-1177.md"
  - type: "fixes"
    ref: "raw/fixes/20260528T232834Z-pr-1177.md"
tags: ["bash", "case-statement", "extensibility", "hook"]
confidence: high
---

# prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する

## 概要

`case "$VAR" in FINALIZE:*) ...;; *) ...;; esac` のように prefix で分岐する case 文で、`*)` catch-all に「意味のある既定動作」(例: 継続コマンド再注入) を置くと、将来 prefix 名前空間を拡張した際に**未知の新 prefix が silent に default 動作へ吸収される**。新 prefix が「継続」として扱われるため、追加した分岐が抜けていてもエラーにならず、誤動作が表面化しない設計脆さになる。

## 詳細

PR #1177 (`/rite:pr:iterate` 終了点の FINALIZE handoff backstop) で、Stop hook `stop-loop-continuation.sh` が handoff 値の prefix で reason を分岐する `case "$HANDOFF" in FINALIZE:*) ;; *) ;; esac` を実装した。`*)` arm は継続 handoff (`/rite:...`) を「次コマンド再注入」として扱う既定動作を持つ。

このとき **code-quality reviewer と error-handling reviewer が独立に同じ脆さを指摘** (high-confidence consensus): handoff prefix が将来 3 種類目に拡張されたとき、新 prefix は `FINALIZE:*` に一致せず `*)` へ落ちるため、意図せず「継続」として処理される。catch-all が error/fallback ではなく**正規の動作**を担っているため、分岐漏れが検出されない。

### canonical 対策

- prefix 名前空間が拡張前提なら、`*)` を「既知の継続 prefix の明示列挙」+「真に未知の値は WARNING/fail-loud」に分離する。catch-all に正規動作を載せない。
- 既知 prefix を allowed values として明示し、想定外値は sentinel/WARNING で可視化する ([bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](../patterns/bash-initial-value-aligns-with-allowed-values.md) と同じ defensive 方針)。
- case dispatch は語彙を潰さず保持する ([Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md) と同根 — exit code でも prefix でも、default arm への意味集約は semantic loss を生む)。

### 併発した comment 責務分離の乖離

同 hook の説明コメントが「prefix で **block を分岐**」と書かれていたが、実装上 prefix が分岐するのは **reason** のみで、block 可否は「handoff が非空かどうか」という別軸で決まる。曖昧表現が直交する 2 軸 (block 可否 / reason 選択) を混同させ、後続編集者の誤読を招く。fix では「prefix で reason を分岐 (block 可否は別軸)」と機構の責務を明示する形に補正した。catch-all 脆さと同じく「prefix dispatch の意味を正確に書く」doctrine の一部。

## 関連ページ

- [bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](../patterns/bash-initial-value-aligns-with-allowed-values.md)

## ソース

- [PR #1177 review results](../../raw/reviews/20260528T232433Z-pr-1177.md)
- [PR #1177 fix results](../../raw/fixes/20260528T232834Z-pr-1177.md)
