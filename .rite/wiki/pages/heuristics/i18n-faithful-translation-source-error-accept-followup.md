---
title: "i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する"
domain: "heuristics"
created: "2026-06-03T23:10:10Z"
updated: "2026-06-03T23:10:10Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260603T174323Z-pr-1263.md"
  - type: "fixes"
    ref: "raw/fixes/20260603T175332Z-pr-1263.md"
tags: ["i18n-parity", "faithful-translation", "accept-path", "fingerprint-suppression", "follow-up-issue", "fact-check"]
confidence: high
---

# i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する

## 概要

i18n 同期 PR (EN → JA 全面追従など) では、忠実翻訳が原本 (EN) に既存する事実誤りをそのまま翻訳側へ転写する。翻訳 PR でも原本への盲目的信頼をせず実装突合 (grep verify) を行うことで原本由来の誤りが初めて表面化する。検出した誤りの正しい決着は「翻訳側での部分修正」ではなく「原本+翻訳の両側同時修正を別 Issue 化 + 本 PR は accept (認知のみ) + fingerprint 永続化」である — 翻訳側単独修正は i18n parity を破壊するため。

## 詳細

### 観測された具体パターン (PR #1263 / Issue #1262)

`docs/SPEC.ja.md` を英語版 `docs/SPEC.md` の per-session flow-state モデルへ全面同期する i18n parity 回復 PR で、以下が実測された:

1. **忠実翻訳による誤り転写**: EN SPEC.md に既存する 2 件の事実誤り (存在しないファイル `state-read.sh` への参照 / `_resolve-flow-state-path.sh`+`STATE_FILE_PATH` への参照) を JA 版が忠実に翻訳し、JA 側に新規導入した (revert test pass = 本 PR diff 由来の finding として成立)。
2. **検出経路は実装突合**: Doc-Heavy mode の 5 カテゴリ検証で大半の主張 (hooks.json 7 events / PHASE_ENUM_V3 13 値 / session-ownership.sh 4 関数・4 source caller / loop_count writer 0 hits 等) を実装側 grep verify した結果として、原本由来の誤り 2 件が表面化した。翻訳元 (EN) の誤りは fact 検証で初めて見える — 原本への盲目的信頼では検出できない。
3. **決着の構造判断**: JA 単独修正は i18n parity (EN ↔ JA の対応関係) を破壊するため、scope=follow-up (EN+JA 両側同時修正の別 Issue) が適切と tech-writer / code-quality の両レビュアーが独立に同一結論へ収束した。

### accept (認知のみ) 経路の初適用

HIGH × follow-up の 2 findings に対し、Issue #1019 M5 の accept (認知のみ) 経路を初適用した:

- **コード変更ゼロ** で acknowledged 化し、fingerprint 永続化 (`.rite/state/accepted-fingerprints-{pr}.txt`、2 件) により次 cycle での同一 finding 再提示を suppression。
- accept reason の明文化: 「EN SPEC.md 側に同一誤りが存在し JA 単独修正は parity を破壊するため、EN+JA 両側同時修正の follow-up Issue で対応」。
- 統計: Total findings 2 / Fixed 0 / Accepted 2 — fix も reply も行わない第 3 の決着が正規経路として機能した。

### 判断基準

| 状況 | 決着 |
|------|------|
| 翻訳側が独自に導入した誤り | 本 PR 内で fix |
| 原本に既存する誤りの転写 (revert test pass) | accept + EN/JA 両側同時修正の follow-up Issue 化 |
| 原本の誤りを翻訳側単独で修正 | ❌ 禁止 — i18n parity を破壊し、次の同期 PR で再転写される |

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1263 review results](../../raw/reviews/20260603T174323Z-pr-1263.md)
- [PR #1263 fix results](../../raw/fixes/20260603T175332Z-pr-1263.md)
