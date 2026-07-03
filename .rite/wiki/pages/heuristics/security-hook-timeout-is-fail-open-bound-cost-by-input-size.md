---
type: "heuristics"
title: "セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する"
domain: "heuristics"
description: "PreToolUse 等の hook timeout は fail-open (timeout→tool 許可) なので、hook の評価コストが入力サイズで発散すると timeout→fail-open bypass が成立する。反復回数上限では不十分で、全パターン検査の前に入力バイト長の O(1) ガードを置き O(n²) 経路を短絡する。"
created: "2026-07-03T08:30:23+00:00"
updated: "2026-07-03T08:30:23+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260703T070536Z-pr-1736.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T071412Z-pr-1736.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T073719Z-pr-1736.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T075749Z-pr-1736.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T082154Z-pr-1736.md"
tags: ["security", "hook", "timeout", "fail-open", "fail-closed", "dos", "input-size-bound", "pretooluse", "super-linear", "bypass"]
confidence: high
---

# セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する

## 概要

PreToolUse 等の hook の timeout は **fail-open**（timeout に達すると Claude Code が hook を kill して tool 実行を許可する）である。したがってセキュリティ境界の hook（reviewer subagent の状態変更 git をブロックする guard 等）で、hook の評価コストが入力サイズに対して発散すると、攻撃者が入力を巨大化して評価を timeout させ、deny が emit されないまま危険な操作が実行される **timeout→fail-open bypass** が成立する。反復「回数」の上限だけでは各反復が O(入力長) の場合に防げない。全パターン検査の **前段** に入力バイト長の O(1) ガードを置き、超過時は正規化・検査を一切走らせず fail-closed deny することでコストを入力サイズで bound する。

## 詳細

PR #1736（`pre-tool-bash-guard.sh` の Pattern 4 = reviewer 状態変更 git guard を fail-closed 化）で、timeout bypass を 4 cycle かけて塞いだ実測から得た経験則。

### なぜ timeout が bypass になるか

- **PreToolUse hook の timeout は fail-open**（公式 docs で fact-check 済み。timeout / cancel → tool は通常の permission flow に進む = 許可される。command hook のデフォルト timeout は 600s）。
- guard の評価が入力サイズに対し super-linear だと、reviewer subagent が状態変更 git を巨大パディングして評価を timeout 域に押し上げられる。timeout すると deny が emit されず、パディングされた git がそのまま実行される。
- **ERR trap では捕捉できない**: timeout はプロセスが外部から kill されるため、`set -e` / ERR trap は発火しない。crash 系の fail-closed 化とは別の防御が要る。

### なぜ反復回数上限では不十分か

- 「global flag の正規化ループを N 回で打ち切る」ような反復**回数**の上限は、各反復が O(入力長) のコストを持つ場合に無力。128 回の上限でも、各反復が 10KB の flag 値を処理すれば 128×O(10KB) で数十秒に達する（実測 128×10KB=1.28MB → hook 全体で timeout）。
- さらに、正規化ループの **手前** にある whole-string 処理（bash の `${var%%pattern}` パラメータ展開等）自体が huge input で O(n²) になりうる。実測: `${COMMAND%%<<*}`（heredoc 除去）が ~1.3MB の入力で **~45s**。`[[ =~ ]]` 正規表現も数 MB の meta 文字列で **>2min**。これらは反復上限の外にあり、上限を追加しても timeout する。

### 正しい塞ぎ方: 全検査の前に O(1) 入力サイズガード

- 正常なコマンドは高々数 KB。全パターン検査の **前** に `${#COMMAND}`（O(1) で高速。2MB でも ~2.5ms）で総バイト長を測り、閾値（例 64KB）超過なら **正規化も検査も一切走らせず** fail-closed deny する。`BLOCKED_PATTERN` を先に立てることで後続の O(n²) 経路（heredoc 除去・各パターン検査）を一括短絡できる。
- これは反復回数ではなく **入力サイズ** でコストを bound する。巨大 flag 値 / 多数 flag / 巨大 meta 文字列 / 巨大 heredoc body の全経路を 1 つのガードで塞ぐ。反復回数上限は ≤閾値の入力で fork 数を bound する **secondary** な防御として併置する。
- ガードは対象セッション（reviewer subagent 等）に **scope** する。main セッションを size で誤 deny しない（誤 deny 禁止）。main セッションが huge input で遅くなるのは fail-open な convenience パターン側の pre-existing な性質でありセキュリティ bypass ではない（別スコープ）。
- **allow→deny flip が防御価値の証拠**: 本来 allow される read-only なコマンド（例 `git status`）を巨大化したものが deny に変わることを確認すると、ガードが「本来通るものを止めている」ことが実証できる（脅威モデルの本質）。

### 併走する 2 つの副次教訓

- **テスト用 fault-injection は fail-closed 側限定**: セキュリティ hook をテストするための env var 等の fault-injection を本番コードに置く場合、set 時に **allow へ反転する経路（fail-open injection）を作らない**。deny のみを誘発する self-restrictive な fail-closed 側に限定する。fail-open 側の injection は settings.json の env 等で有効化できる allow-all バックドアになる。fail-open 不変性は injection ではなく trap 配線の static 検証で pin する。
- **外部ツールの挙動主張は fact-check してから finding を確定**: 「hook の timeout は fail-open」のような外部ツール（Claude Code）の挙動主張は、推測でなく公式 docs で fact-check してから採否を決める。reviewer 間で「trigger 経路なし」の判断が割れるのは、解析スコープの差（無限ループの有無だけ見たか、super-linear コストまで見たか）に起因することが多い。

## 関連ページ

- [consume 操作 (read+delete+return) は delete-then-return 順で fail-closed にする](../patterns/consume-operation-delete-then-return-fail-closed.md)
- [security guard の deny メッセージ改善は判定ロジック不変の subkind タグ分岐で行う](../patterns/security-guard-message-only-subkind-branching.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1736 review results (cycle 1) — timeout→fail-open bypass の HIGH 指摘 (super-linear 正規化 + fail-open timeout) と fault-injection の allow-all バックドア指摘](../../raw/reviews/20260703T070536Z-pr-1736.md)
- [PR #1736 fix results (cycle 1) — 反復上限で塞ごうとした初回対応 (後に不十分と判明)](../../raw/fixes/20260703T071412Z-pr-1736.md)
- [PR #1736 review results (cycle 2) — 反復上限では各反復 O(入力長) を縛れず bypass 未解消、O(1) 総バイト長ガードを正規化前に置くべきとの再指摘 (HIGH)](../../raw/reviews/20260703T073719Z-pr-1736.md)
- [PR #1736 fix results (cycle 2) — 全検査の前に ${#COMMAND} の O(1) ガードを追加し O(n²) heredoc 除去 (${COMMAND%%<<*}=45s) と Pattern 2 regex (>2min) を一括短絡](../../raw/fixes/20260703T075749Z-pr-1736.md)
- [PR #1736 review results (cycle 4) — 全 4 reviewer 指摘ゼロで収束。O(1) 総バイト長ガードで全経路封鎖を実機検証](../../raw/reviews/20260703T082154Z-pr-1736.md)
