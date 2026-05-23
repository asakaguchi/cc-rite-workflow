---
title: "mktemp 失敗は silent 握り潰さず WARNING を可視化する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-05-18T17:30:00Z"
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
tags: ["bash", "mktemp", "disk-full", "inode-exhaustion", "observability", "silent-fallback", "awk", "test-helper"]
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

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](./trap-register-before-mktemp.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #548 cycle 1 fix (mktemp 失敗の silent 握り潰し禁止)](../../raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 2 review (stderr suppression pattern の網羅検出)](../../raw/reviews/20260416T171008Z-pr-548.md)
- [PR #550 cycle 1 fix (silent fallback 一般化: rev-parse / push target 誤診回避)](../../raw/fixes/20260416T202213Z-pr-550.md)
- [PR #550 cycle 3 fix (asymmetric silent fallback の対称化)](../../raw/fixes/20260416T214823Z-pr-550.md)
- [PR #1049 cycle 1 fix (awk 経路への一般化、5 failure mode 区別の 3 点セット canonical pattern: `if !` awk wrap + stderr tempfile 退避 + 空 section guard。test helper layer で 3 reviewer 独立 MEDIUM 指摘から cycle 1 fix で 1-cycle 収束、text manipulation primitive 全般 (awk / sed / cut / sort) への適用範囲拡張を実測)](../../raw/fixes/20260518T164053Z-pr-1049.md)
