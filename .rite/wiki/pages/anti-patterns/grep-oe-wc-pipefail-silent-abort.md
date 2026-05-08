---
title: "`grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort"
domain: "anti-patterns"
created: "2026-05-08T17:43:55+00:00"
updated: "2026-05-08T17:43:55+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260508T174355Z-pr-906.md"
  - type: "reviews"
    ref: "raw/reviews/20260508T175233Z-pr-906.md"
tags: ["bash", "pipefail", "set-euo-pipefail", "grep", "ratchet-test", "silent-abort"]
confidence: high
---

# `grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort

## 概要

`set -euo pipefail` 配下で `count=$(grep -oE 'pattern' file | wc -l | tr -d ' ')` を ratchet test の occurrence count 取得に使うと、grep が 0 マッチ (exit 1) を返した瞬間 pipefail が pipeline 全体を abort させ、test 全体が pass/fail のいずれも emit せず silent terminate する。**最も危険なのは ratchet ideal 値 (= 違反 0 件) に到達した瞬間であり、目標達成のタイミングこそ test が動作不能になる致命的経路**。canonical fix は `count=$({ grep -oE 'pattern' file || true; } | wc -l | tr -d ' ')` のように grep を group + `|| true` で囲み exit 1 を吸収すること。

## 詳細

### 問題の構造 (PR #906 cycle 3 で CRITICAL として実機顕在化)

ratchet test (charter 違反パターンの上限カウント test) で違反 occurrence を数えるために以下のように書かれていた:

```bash
set -euo pipefail
bell_count=$(grep -oE '🚨' "$start_md" | wc -l | tr -d ' ')
issue_count=$(grep -oE 'Issue #[0-9]+' "$start_md" | wc -l | tr -d ' ')
cycle_count=$(grep -oE 'cycle [0-9]+' "$start_md" | wc -l | tr -d ' ')
```

現状は違反多数 (35 件 / 13 件 / 26 件) のため grep が match を返し pipeline は exit 0 で終わる。しかし:

- **後続 PR (B-H) で違反を 0 件まで削減すると**、grep が 0 マッチ (exit 1) を返す
- `set -o pipefail` により pipeline 全体の exit code が grep の 1 になる
- `set -e` により bash script 全体が abort
- test runner は pass/fail の summary line を出力する前に終了 → silent abort

**ratchet ideal 値 (= 0 件) に到達した瞬間 test が壊れる** ため、本来「達成 ✅」を emit すべきタイミングで CI が静かに失敗する。

### canonical fix

5 件すべての pipeline を group + `|| true` で吸収する形式に変更:

```bash
set -euo pipefail
bell_count=$({ grep -oE '🚨' "$start_md" || true; } | wc -l | tr -d ' ')
issue_count=$({ grep -oE 'Issue #[0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
cycle_count=$({ grep -oE 'cycle [0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
```

- **`{ cmd || true; }` group**: grep の exit 1 を group 内で 0 に変換し pipefail に伝播させない
- **`wc -l` 側で空 stdin を 0 に集計**: grep が空を返しても wc が `0\n` を出力するので `tr -d ' '` 後の count は `0` になり整数比較が機能する
- **再現確認**: 空 file に対し `grep -oE` で exit 1 を返す経路を実機検証 (cycle 3 reviewer の cross-check)

### Cycle Degeneration として実測された経緯

PR #906 で同一 fingerprint が 3 cycle に渡って degenerate した:

- **cycle 1**: 下限 assert を `grep -c` (line 単位) → `grep -oE | wc -l` (occurrence 単位) に変更、ただし `|| true` 防御を失った
- **cycle 2**: 上限 🚨 を同パターンに変更、同じく `|| true` を持たない (修正スコープ漏れの完了でしたが pipefail 防御は未遂)
- **cycle 3**: pipefail bug が CRITICAL として顕在化、5 件すべて `{ grep || true; } | wc -l` に修正

これは [Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) と Quality Signal 1 (fingerprint cycling) の典型例 — 「unit を変更したが defense (`|| true`) を移植し忘れる」cycle が 3 段で degenerate。

### 検出と運用

- **静的検出**: `grep -rEn '\$\(grep [^|]+\|[^|]+wc' <scope>` で pipeline + wc -l の組み合わせを抽出し、`|| true` の有無を確認
- **動的検出**: 0-match を意図的に発生させる mutation test (空 file で grep を呼ぶ) を test fidelity 検証に組み込む ([Mutation Testing Test Fidelity](../patterns/mutation-testing-test-fidelity.md))
- **iteration 用途では別 canonical**: 0/1/N 件の iteration が必要な場合は [`mapfile -t < <(...)`](../patterns/mapfile-process-substitution-pipefail-safe.md) を採用 (process substitution は pipefail を伝播させない)

### 関連 anti-pattern との違い

| Anti-pattern | 範囲 | canonical fix |
|--------------|------|--------------|
| 本ページ (`grep -oE | wc -l` ratchet count) | scalar count 取得 + 0-match 吸収 | `count=$({ grep -oE ... || true; } | wc -l | tr -d ' ')` |
| [grep -c || echo 0 double-print](./grep-c-or-echo-0-double-print.md) | `grep -c` の POSIX 仕様で 0 出力 + exit 1 | `count=$(grep -c ... || true); count=${count:-0}` |
| [bash-local-vs-toplevel-pipefail-asymmetry](./bash-local-vs-toplevel-pipefail-asymmetry.md) | function 内外の pipefail 伝播非対称 | `v=$(... || true) || v=""` |

## 関連ページ

- [`mapfile -t < <(...)` で pipefail safe な iteration を書く](../patterns/mapfile-process-substitution-pipefail-safe.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Mutation Testing Test Fidelity](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #906 fix results (cycle 3)](../../raw/fixes/20260508T174355Z-pr-906.md)
- [PR #906 review results (cycle 4 final)](../../raw/reviews/20260508T175233Z-pr-906.md)
