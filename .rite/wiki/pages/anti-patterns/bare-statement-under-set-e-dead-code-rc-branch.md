---
title: "set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する"
domain: "anti-patterns"
created: "2026-06-02T04:59:29Z"
updated: "2026-06-02T04:59:29Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260602T045929Z-pr-1242.md"
tags: ["bash", "rc-capture", "set-e", "silent-failure", "dead-code"]
confidence: high
---

# set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する

## 概要

`set -euo pipefail` 下で外部コマンド (`python3` / `jq` / `grep` 等) を **単独文 (bare statement)** として実行すると、コマンドが非ゼロ終了した瞬間に `set -e` が script 全体を abort する。その結果、直後の `rc=$?` capture と、それを参照する rc 分岐 (rc=1 no-op 処理 / rc=2 corruption 報告 等) が **dead code 化** し、「失敗時に diagnostics を surface する」という設計意図が実際には一度も実行されない。`if cmd; then rc=0; else rc=$?; fi` のような **set -e 免除文脈** へコマンドを移すのが canonical。

## 詳細

### 実証

```bash
# ❌ NG: bare statement は set -e で abort し rc=$? に到達しない
set -euo pipefail
python3 some-script.py < input > output 2>err   # rc != 0 でここで abort
_py_rc=$?                                        # 未到達 (dead code)
if [ "$_py_rc" -eq 0 ]; then ...                 # rc=0 のみ到達
else
  # rc=1 no-op / rc=2 corruption の報告分岐 — set -e abort により永久に未実行
fi
```

`if [ -n "$tmp" ]; then ... fi` のような **外側の if は python3 の exit status を消費しない** (到達ガードにすぎない) ため、bare statement は set -e の免除を受けられない。`&&` / `||` / `if cmd; then` のいずれの set -e 免除文脈にも置かれていないことが発火条件。

### 影響

Issue #1241 (PR #1242) では `session-start.sh` の settings.local.json 修復経路でこの構造が発生していた。rc=2 (不正 JSON) / rc=1 (no-op) で abort すると、下流の marker 書き込み・flow-state migrate・STATE_FILE 解決・recovery 注入が **すべて skip** される。PR が主張する「不正 JSON 時に corruption を surface する」報告分岐は、dead code のため実際には一度も実行されていなかった。

### Canonical Fix

```bash
# ✅ OK: if 条件 (set -e 免除文脈) で rc を捕捉する
set -euo pipefail
if python3 some-script.py < input > output 2>err; then
  _py_rc=0
else
  _py_rc=$?       # 非ゼロ exit がここで正しく捕捉される
fi
case "$_py_rc" in  # rc=0 / rc=1 / rc=2 / other すべて到達可能
  ...
esac
```

`set +e; cmd; rc=$?; set -e; case` 形式も等価な代替 (一時的に errexit を無効化する)。どちらを採るかは周辺コードの慣用と一致させる。

### `if ! cmd; then rc=$?` 版との区別

本 anti-pattern は姉妹 anti-pattern [`if ! cmd; then rc=$?` は常に 0 を捕捉する] と **root cause が異なる**:

| failure mode | 原因 | 症状 |
|--------------|------|------|
| bare statement (本ページ) | `set -e` が非ゼロ exit で abort | `rc=$?` 以降が **dead code** (未到達) |
| `if ! cmd` (姉妹ページ) | `!` 演算子が exit status を boolean 反転 | `rc=$?` が **常に 0** (到達するが値が誤り) |

両者とも「`set -euo pipefail` 下で外部コマンドの実 rc を安全に捕捉する」ファミリに属するが、前者は到達不能、後者は誤値という別の壊れ方をする。canonical fix の `if cmd; then rc=0; else rc=$?; fi` は **`!` を付けない** 点が重要 (`!` を付けると姉妹 anti-pattern を踏む)。

### Asymmetric Fix Transcription との関係

Issue #1241 の本バグは PR #1240 の **inline → delegate refactor** (RITE_HOOK_RE を python script へ委譲) の際に、`&&` 条件形式から外部コマンド呼び出しを単独文へ移動したことで guard が解体された pre-existing latent bug だった (revert test 不成立で別 Issue 化)。これは [Asymmetric Fix Transcription (対称位置への伝播漏れ)] の「inline → delegate refactor 時の wrapper guard 解体」sub-pattern (PR #659) の実例であり、本 PR #1242 はその **逆方向 (修復) の適用例**。

### Detection Heuristic

`set -euo pipefail` を持つ script で「外部コマンド単独文の直後に `rc=$?` (または `_rc=$?`) があり、その rc を参照する分岐が続く」箇所を横断 grep する:

```bash
grep -nE '^\s*(python3|jq|grep|awk|sed|[a-zA-Z0-9_./-]+)\s+.*$' --include='*.sh' -r . | ...
# より実用的には: 各 hook で `rc=$?` の直前行が if 条件 / && / || で囲まれているかを目視確認
```

Issue #1241 subtask4 では他 hook (post-compact.sh / pre-tool-bash-guard.sh 等) を横断調査し、`session-start.sh:188` が唯一の該当箇所 (他は if/else・set +e 等で安全) と確認した。inline → delegate 委譲リファクタを行う PR では、委譲先コマンドが set -e 免除文脈に置かれているかを必ず verify すること。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #1242 review results](../../raw/reviews/20260602T045929Z-pr-1242.md)
