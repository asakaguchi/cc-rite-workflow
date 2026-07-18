---
type: "heuristics"
title: "セッション worktree + sandbox 環境の 2 つの罠: cwd 相対 write-allowlist によるブロックと `.rite-plugin-root` のブランチ相違"
domain: "heuristics"
description: "(1) worktree cwd から main checkout 配下（`.rite/review-results/` 等）への書き込みは sandbox の write-allowlist（cwd 相対の `.`）でブロックされる。(2) `.rite-plugin-root` をセッション worktree へコピーする際、コピー元（main checkout）のブランチが worktree のブランチと異なると古い `plugins/rite` を指す自己参照の罠がある。"
created: "2026-07-18T23:38:52Z"
updated: "2026-07-18T23:38:52Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260718T194343Z-pr-1902.md"
tags: ["multi-session", "worktree", "sandbox", "plugin-root", "write-allowlist"]
confidence: medium
---

# セッション worktree + sandbox 環境の 2 つの罠: cwd 相対 write-allowlist によるブロックと `.rite-plugin-root` のブランチ相違

## 概要

`multi_session` によるセッション worktree 運用と sandbox 環境を組み合わせたとき、cwd の位置とファイルの実体が乖離する 2 種類の罠が観測された（PR #1902 の作業中に実際に踏んだ）。

1. worktree cwd から main checkout 配下（例: `.rite/review-results/`）への書き込みは、sandbox の write-allowlist が cwd 相対の `.` として解決されるためブロックされる。
2. `.rite-plugin-root` をセッション worktree へコピーする際、コピー元（main checkout）のブランチが worktree のブランチと異なる状態でコピーすると、コピーされた値が古い（未修正の）`plugins/rite` を指してしまう。

## 詳細

### 罠 1: cwd 相対 write-allowlist によるブロック

sandbox の書き込み許可リストは cwd（`.`）を基準に解決される。セッション worktree（`.rite/worktrees/issue-{N}` 配下）から main checkout 配下のパス（例: main checkout の `.rite/review-results/{pr}.json`）へ絶対パス・相対パスいずれで書き込もうとしても、cwd が worktree 側にある限り「cwd 相対の `.`」には含まれず拒否される。既知の Issue #1896 と同種の事象。

**対処**: state 書き込み先は `state-path-resolve.sh` 等の共有 root 解決 helper で解決し、cwd 依存を明示的に解消してから書き込む。単純に相対パスを組み立てるだけでは worktree/main checkout どちらの cwd から呼ばれても正しく解決されない。

### 罠 2: `.rite-plugin-root` のブランチ相違による自己参照

`.rite-plugin-root` はセッション worktree セットアップ時に main checkout からコピーされる。このコピー操作の時点で main checkout 側のブランチが（同セッションの他の作業などで）worktree のブランチと異なる状態になっていると、コピーされる `.rite-plugin-root` の中身（解決済み `plugins/rite` の絶対パス）が、修正前の古いコードを指す plugin_root になり得る。結果として、worktree 内で実行するスキル・hook が意図せず未修正の旧 `plugins/rite` を参照してしまう。

**対処**: `.rite-plugin-root` を参照する前に、その値が指す `plugins/rite` が現在作業中のブランチの内容と一致しているかを疑う。特に、コピー元 main checkout のブランチを切り替える操作を挟んだ直後は要注意。

## 関連ページ

- [worktree 運用の git 状態検出は .git 直書きせず git rev-parse --git-path で解決する](../patterns/worktree-aware-git-state-detection.md)

## ソース

- [PR #1902 review results](../../raw/reviews/20260718T194343Z-pr-1902.md)
