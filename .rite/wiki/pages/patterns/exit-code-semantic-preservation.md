---
title: "Exit code semantic preservation: caller は case で語彙を保持する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-07-03T18:30:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260415T094007Z-pr-529.md"
  - type: "reviews"
    ref: "raw/reviews/20260608T112156Z-pr-1306.md"
  - type: "fixes"
    ref: "raw/fixes/20260608T112705Z-pr-1306.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T164934Z-pr-1743.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T165654Z-pr-1743.md"
tags: ["bash", "exit-code", "api-contract", "sentinel"]
confidence: high
---

# Exit code semantic preservation: caller は case で語彙を保持する

## 概要

shell script の header で `Exit codes: 0=success, 2=legitimate skip, 3=real error` のように exit code の語彙を定義しても、caller が `if cmd` / `cmd || handle_error` のように non-zero を一律 failure 扱いすると、legitimate skip も false-positive incident として報告される。caller 側に case 文で exit code ごとの分岐を書くのが API 契約の完成。

## 詳細

### Anti-pattern: 一律 failure 扱い

```bash
# ❌ NG: exit 2 (legitimate skip) も failure として sentinel emit
if ! bash wiki-ingest-commit.sh; then
  echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=ingest_failed"
fi
```

script が `exit 2` で skip（例: `wiki.enabled=false`）した場合も incident として報告され、false-positive が観測ダッシュボードを汚染する。

### Canonical pattern: case 文で語彙を保持

```bash
set +e
bash wiki-ingest-commit.sh
rc=$?
set -e
case "$rc" in
  0)
    echo "[CONTEXT] WIKI_INGEST=ok"
    ;;
  2)
    # legitimate skip — incident 扱いしない
    echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=wiki-disabled"
    ;;
  3)
    echo "ERROR: wiki-ingest-commit.sh 内部で git 操作失敗 (rc=3)" >&2
    exit 1
    ;;
  4)
    # commit landed, push failed — 非 fatal
    echo "WARNING: commit は landed したが push に失敗 (rc=4)" >&2
    echo "  手動回復: git -C .rite/wiki-worktree push origin $wiki_branch" >&2
    ;;
  *)
    echo "ERROR: 予期しない exit code ($rc)" >&2
    exit 1
    ;;
esac
```

### 双方向契約

exit code 語彙は片方向の宣言では不十分。以下の両方を揃える:

1. **script 側**: header comment に `Exit codes:` セクションを書く
2. **caller 側**: `case "$rc" in` で全 rc 値を explicit に routing

`case` に `*)` デフォルトを置いて未知の rc を fail-fast させることで、script 側が exit code を追加したときの silent OK 判定も防げる。

### sentinel emit との組み合わせ

skip 経路では `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=...` のような sentinel を emit することで、caller の caller（workflow 監視側）が incident とそうでないものを区別できる。sentinel + case の 2 層で語彙を保持する。

### `$?` 経由の 3 値コマンドとの違い

本パターンは「独自定義 exit code を持つスクリプト」を対象とする。`git diff --quiet` のような標準コマンドの 3 値 exit code (0/1/>1) も case で扱うが、そちらは [`if ! cmd` anti-pattern](../anti-patterns/bash-if-bang-rc-capture.md) が別軸で混在するので区別して扱うこと。

### script 自身の失敗経路も宣言した exit-code 契約に従う (PR #1306 で追加)

caller 側の case routing だけでなく、**script 自身のすべての内部失敗経路** が header で宣言した exit-code 語彙に従う必要がある。peer script から arg-parse を copy-paste すると、peer と異なる exit-code 契約のもとで失敗経路が契約違反の code を emit する。

PR #1306 の `projects-board-drift-check.sh` は `watchdog-status-mismatch.sh` から作法を踏襲したが、exit-code 契約を再設計した (watchdog: `exit 1=fatal` / 本 script: **`exit 1=drift warning` / `exit 2=invocation error`**)。arg-parse の `--limit) LIMIT="${2:-}"; shift 2` を verbatim copy-paste した結果、`--limit` に値が無いと `set -e` 下で `shift 2` が exit 1 abort → **usage error が exit 1 (=「drift 検出」warning) として誤分類** され、lint 上で実在しない drift を報告する経路が生まれた (code-quality + error-handling の cross-validated MEDIUM)。

- **`${2:-}` は防御にならない**: `${2:-}` は `set -u` の unset 参照だけを防ぐ。`shift 2` が引数不足で失敗する経路は防げない。
- **canonical fix**: `[ "$#" -lt 2 ]` で値の存在を gate し、欠落時は契約どおり exit 2 (invocation error) へ統一する。
- **教訓**: 独自 exit-code 契約を持つ script では「全失敗経路 (arg-parse 含む) が契約の code を emit するか」を runtime で検証する。peer からの copy-paste 同形性は exit-code 契約一致を保証しない (Asymmetric Fix Transcription の peer script flag 契約 runtime 検証 sub-pattern (PR #631) の再演)。新規 lint step 追加 PR では exit-code 契約が反復 trigger になる (PR #1306 は cycle 1 の dominant finding として検出、4 cycle で mergeable)。
- **successful preventive application (PR #1743)**: 新規 drift-check スクリプトが `--repo-root) [ $# -ge 2 ] || { echo "ERROR: ..." >&2; usage >&2; exit 2; }` の consume-before-validate ガードを「set -u の unbound $2 が exit 1 = drift 誤分類になるのを防ぐ」rationale コメント付きで最初から適用し、回帰 TC（`--repo-root` 値欠落 → rc=2）で pin した。sibling スクリプト（doc-heavy-patterns-drift-check.sh）に同パターンが pre-existing で残る点は scope 外として別 Issue 追跡 — 本 pattern の事前適用 + TC pin が cycle 収束を阻害しない実例。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)
- [set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する](../anti-patterns/bare-statement-under-set-e-dead-code-rc-branch.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #529 fix cycle 1 (exit 2 semantic preservation)](../../raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 review (6-reviewer による exit code mismatch 検出)](../../raw/reviews/20260415T094007Z-pr-529.md)
- [PR #1306 review cycle 1 (peer copy-paste の exit-code 契約非対称 + shift 2/set -e abort)](../../raw/reviews/20260608T112156Z-pr-1306.md)
- [PR #1306 fix cycle 1 (`[ "$#" -lt 2 ]` gate で欠落時 exit 2 へ統一)](../../raw/fixes/20260608T112705Z-pr-1306.md)
