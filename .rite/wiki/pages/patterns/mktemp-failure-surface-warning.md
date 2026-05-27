---
title: "mktemp 失敗は silent 握り潰さず WARNING を可視化する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-05-27T00:30:00Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260518T164053Z-pr-1049.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T165559Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T171008Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T202213Z-pr-550.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T214823Z-pr-550.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T175307Z-pr-1155.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T182658Z-pr-1155-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T180309Z-pr-1155.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T183041Z-pr-1155-cycle2-fix.md"
tags: ["bash", "mktemp", "disk-full", "inode-exhaustion", "observability", "silent-fallback", "awk", "test-helper", "flatten-refactor-regression"]
confidence: high
---

# mktemp 失敗は silent 握り潰さず WARNING を可視化する

## 概要

`mktemp ... || echo ""` パターンは disk full / inode 枯渇 / permission denied を silent に握り潰し、後続の stderr capture 機能が無効化されたことを操作者に気付かせない。`if ! var=$(mktemp ...); then WARNING; var=""; fi` 形式で WARNING を stderr に surface する。

## 詳細

### Anti-pattern

```bash
# ❌ NG: mktemp 失敗を silent に握り潰す
git_err=$(mktemp /tmp/rite-git-err-XXXXXX 2>/dev/null) || git_err=""

# この時点で git_err=="" だと
git cmd 2>"${git_err:-/dev/null}"  # stderr は捨てられる（silent）
```

- disk full や inode 枯渇は low-frequency だが high-severity な障害
- silent 握り潰しにより、後続の `head -3 "$git_err"` による詳細 surface が機能しないまま運用が続く
- 根本原因（ディスク満杯）への気付きが遅れる

### Canonical pattern

```bash
# ✅ OK: 失敗を WARNING で可視化
if ! git_err=$(mktemp /tmp/rite-git-err-XXXXXX); then
  echo "WARNING: git stderr 退避用 tempfile の mktemp に失敗しました。stderr 詳細は失われます" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否を確認してください" >&2
  echo "[CONTEXT] FALLBACK=1; reason=mktemp_failure" >&2
  git_err=""
fi
```

- 操作者に root cause を伝える（inode / FS / permission の 3 候補）
- `[CONTEXT]` sentinel で機械可読な failure flag を emit する
- `git_err=""` で後続の fallback 経路は維持（best-effort continuation）

### `exec 9>...` の hard fail との区別

`set -euo pipefail` 配下では `exec 9>file` の I/O 失敗も script 全体を hard fail させる。advisory lock のような best-effort リソースでは subshell guard で test してから本命 `exec` に進む:

```bash
# ✅ 2 段階パターン
if ( exec 9>"$lockfile" ) 2>/dev/null; then
  exec 9>"$lockfile"
  flock -n 9 || { echo "WARNING: lock taken, skipping" >&2; exit 0; }
fi
```

### Detection Heuristic

```bash
# 全 *.sh で anti-pattern をスキャン
grep -nE 'mktemp[^|]*\|\|[[:space:]]*[a-z_]+=""' --include='*.sh' -r .
```

### 一般化: silent fallback 全般に適用される原則 (PR #550 で拡張)

本 pattern は `mktemp` に限らず、**「成功経路と見分けがつかなくなる silent fallback」全般**に適用される:

- `git rev-parse --abbrev-ref HEAD || echo HEAD` — detached HEAD / corrupt worktree を "HEAD" literal に塗り替え、push target 誤診の温床になる
- `git rev-parse HEAD || echo unknown` — corrupt 状態を `head=unknown; push=ok` として success 同等に見せる
- `rm -f` の非対称握り潰し — 同一ファイル内で rc=0 path では rm 失敗を surface するが rc=5 path で silent にすると、asymmetric silent fallback で障害箇所が部分的にしか見えない

いずれも **「低頻度だが起きたとき成功経路と区別不能」** という共通構造を持ち、`if ! ...; then WARNING; [CONTEXT]; var=""; fi` 形式で可視化する。PR #550 では `worktree_commit_push()` の head SHA capture と `wiki-ingest-commit.sh` の rm failure surfacing で同じ pattern を適用した (asymmetric 発火経路も同一方針で揃えるのが要点 — [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) 参照)。

### awk text manipulation 経路への一般化と 3 点セット canonical pattern (PR #1049 cycle 1 fix での evidence)

PR #1049 (Issue #1047 — `plugins/rite/hooks/tests/_test-helpers.sh` への `assert_grep_in_section` helper 追加) では、本 pattern が awk 経路にも適用可能であることが test / code-quality / error-handling の 3 reviewer 独立 MEDIUM 指摘 + cycle 1 fix で実測された。helper 内部の section 抽出経路:

```bash
# ❌ NG: awk 失敗を silent に握り潰す (PR #1049 cycle 1 検出)
awk '/start/, /end/' "$source_file" > "$section_file"
# awk syntax error / IO error / pattern not found / empty range が
# すべて空 section file に縮退し、後続 assert_grep が「pattern not found」を返す。
# operator 視点では 5 failure mode が単一エラーに収束し診断不能。
```

awk の exit code を捕捉しない経路は、上記 mktemp / git rev-parse と同 class の **「成功経路と区別不能な silent fallback」** に該当する。failure mode は以下の 5 種に展開可能で、それぞれが異なる対処を必要とする:

| Failure mode | 原因 | 必要な対処 |
|--------------|------|----------|
| file-missing | `$source_file` 不在 | 上位 caller の path 解決を確認 |
| mktemp-fail | `$section_file` の mktemp 失敗 | /tmp 容量 / inode / permission 確認 |
| awk-fail | awk syntax error / IO error / GNU/BSD awk 互換性 | awk script の portability 確認 |
| empty-section | start_pattern 〜 end_pattern が source に存在せず空抽出 | source layout の事前 grep 確認 |
| pattern-not-found | section 内に grep target が不在 (本来の検出意図) | 通常の test failure |

これら 5 mode を診断レベルで区別可能化する canonical fix は、PR #1049 cycle 1 fix で確立した **3 点セット**:

```bash
# ✅ OK: awk 経路の 5 failure mode 区別 (PR #1049 cycle 1 fix で確立)
section_file=$(mktemp /tmp/section-XXXXXX) || {
  echo "WARNING: mktemp failed for section_file" >&2
  echo "[CONTEXT] FALLBACK=1; reason=mktemp_failure_section" >&2
  return 1
}

# 1. if ! で awk を wrap し exit code を捕捉
# 2. stderr を tempfile に退避して詳細を surface
awk_err=$(mktemp /tmp/awk-err-XXXXXX 2>/dev/null) || awk_err=""
if ! awk '/start/, /end/' "$source_file" > "$section_file" 2>"${awk_err:-/dev/null}"; then
  echo "WARNING: awk section extraction failed" >&2
  [ -n "$awk_err" ] && [ -s "$awk_err" ] && head -3 "$awk_err" | sed 's/^/  /' >&2
  echo "[CONTEXT] FALLBACK=1; reason=awk_failure" >&2
  rm -f "$section_file" "$awk_err"
  return 1
fi
[ -n "$awk_err" ] && rm -f "$awk_err"

# 3. [ ! -s ] で空 section guard (empty-section と pattern-not-found を区別)
if [ ! -s "$section_file" ]; then
  echo "WARNING: section between /start/ and /end/ is empty" >&2
  echo "  source file: $source_file" >&2
  echo "[CONTEXT] FALLBACK=1; reason=empty_section" >&2
  rm -f "$section_file"
  return 1
fi
```

**3 点セットの意義**: (1) `if !` awk wrap で awk-fail を pattern-not-found から分離、(2) stderr tempfile 退避で awk 内部エラーの根本原因を surface、(3) 空 section guard で empty-section と pattern-not-found を分離 — の組み合わせで 5 mode 区別が成立。**「text manipulation 失敗を silent 握り潰さない」原則は awk / sed / cut / sort 等の helper layer 全般に適用可能** で、特に test helper のような **caller から 5 mode の使い分けができない layer** で重要 (caller test ファイルは「pattern matches or not」しか受け取れず、根本原因の WARNING が出ないと debug が不可能)。

PR #1049 の cycle 1 で test / code-quality / error-handling の 3 reviewer が独立に「awk silent swallow → 5 failure mode 混同」を MEDIUM 指摘し、cycle 1 fix の 3 点セットで cycle 2 では同 reviewer 自身が「5 mode が診断レベルで区別可能化された」と FIXED verification、1-cycle 収束に至った。本 evidence は「成功経路と区別不能な silent fallback」class が awk 経路を含む helper layer 全般で発火しうることを示し、本 pattern の適用範囲を mktemp / git semantics から **text manipulation primitive 全般 (awk / sed / cut / sort 等)** へ一般化する。

### Flatten refactor 経由の格下げ regression (PR #1155 で実測)

PR #1155 (Issue #1154 — `wiki:* commands` の cleanup.md スタイル本格フラット化) で、**「コメント削除のみ許容」を謳う flatten refactor PR が Pattern 3 規範 WARNING を silent fallback に格下げする regression** を実測した。本 pattern の維持が refactor PR の lurking failure mode として継続することを示す evidence。

#### 検出された格下げ

```bash
# Before (develop): Pattern 3 規範通り
if ! cat_err=$(mktemp /tmp/rite-wiki-ingest-cat-err-XXXXXX); then
  echo "WARNING: stderr 退避 tempfile (cat_err) の mktemp に失敗しました..." >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: file body 読取失敗の根本原因 (permission / IO error) が不可視になります" >&2
  cat_err=""
fi

# After (PR #1155 cycle 1 merge candidate): silent fallback に格下げ
cat_err=$(mktemp /tmp/rite-wiki-ingest-cat-err-XXXXXX 2>/dev/null) || cat_err=""
```

cycle 1 で `ingest.md` L248 (cat_err) / L535 (_reset_err) の 2 site が格下げ、cycle 2 で `lint.md` sort_err / add_err / commit_err の追加 3 site も同型 regression と判明 (合計 6 site の対称セットのうち cycle 1 で 2 site のみ fix、cycle 2 で残り surface)。

#### 一般化された経験則

- **「フラット化 PR」での非対称な statement 削除リスク**: blockquote 削除と同時に「コメント外観に見える」mktemp WARNING block が削除されやすい。Pattern 3 規範の WARNING block は **機能を持つ statement** であり、blockquote 削除スコープに含めてはならない ([[flatten-refactor-deletion-scope-classification]] の Keep カテゴリ判定基準を参照)
- **同 PR 内対称性 grep 検査による detection**: refactor 中 `grep -rn 'mktemp.*|| .*=""'` で同型 anti-pattern を網羅検査することが silent regression 検出の決定打。1 site だけ修正して「対称性が達成された」と評価しない ([[asymmetric-fix-transcription]] PR #1155 補強事例参照)
- **PR description の自己宣言と機能 statement 削除の乖離**: 「behavior-preserving refactor」「コメント削除のみ許容」を謳う PR でも、Pattern 3 規範 WARNING の格下げが silent 混入し得る。description だけで判断せず、機能 statement の existence-check を grep で実測する

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](./trap-register-before-mktemp.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)
- [[flatten-refactor-deletion-scope-classification]] ([flatten-refactor-deletion-scope-classification.md](../heuristics/flatten-refactor-deletion-scope-classification.md))

## ソース

- [PR #548 cycle 1 fix (mktemp 失敗の silent 握り潰し禁止)](../../raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 2 review (stderr suppression pattern の網羅検出)](../../raw/reviews/20260416T171008Z-pr-548.md)
- [PR #550 cycle 1 fix (silent fallback 一般化: rev-parse / push target 誤診回避)](../../raw/fixes/20260416T202213Z-pr-550.md)
- [PR #550 cycle 3 fix (asymmetric silent fallback の対称化)](../../raw/fixes/20260416T214823Z-pr-550.md)
- [PR #1049 cycle 1 fix (awk 経路への一般化、5 failure mode 区別の 3 点セット canonical pattern: `if !` awk wrap + stderr tempfile 退避 + 空 section guard。test helper layer で 3 reviewer 独立 MEDIUM 指摘から cycle 1 fix で 1-cycle 収束、text manipulation primitive 全般 (awk / sed / cut / sort) への適用範囲拡張を実測)](../../raw/fixes/20260518T164053Z-pr-1049.md)
- [PR #1155 cycle 1 review (flatten refactor PR で Pattern 3 規範 WARNING が silent fallback に格下げ regression、ingest.md L248 / L535 の 2 site で 3 reviewer 独立 HIGH 検出)](../../raw/reviews/20260526T175307Z-pr-1155.md)
- [PR #1155 cycle 2 review (cycle 1 fix が 2/6 site のみで partial fix、lint.md sort_err / add_err / commit_err の追加 3 site が surface)](../../raw/reviews/20260526T182658Z-pr-1155-cycle2.md)
- [PR #1155 cycle 1 fix (9 件の mktemp 呼び出しのうち 2 件のみ silent fallback だった非対称 regression の検出と復元)](../../raw/fixes/20260526T180309Z-pr-1155.md)
- [PR #1155 cycle 2 fix (6 site 対称セットの partial fix トラップ回収、grep 網羅検査の経験則化)](../../raw/fixes/20260526T183041Z-pr-1155-cycle2-fix.md)
