---
title: "stderr ノイズ削減: truncate ではなく selective surface で解く"
domain: "heuristics"
created: "2026-04-16T19:37:16Z"
updated: "2026-05-30T00:33:20Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md"
  - type: "reviews"
    ref: "raw/reviews/20260415T121203Z-pr-529-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T202213Z-pr-550.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T151325Z-pr-1201.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T151834Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T233836Z-pr-1202.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T234453Z-pr-1202.md"
tags: ["bash", "stderr", "observability", "noise-reduction", "per-step-diagnostic", "delegation-shim", "status-and-stderr-dual-capture"]
confidence: high
---

# stderr ノイズ削減: truncate ではなく selective surface で解く

## 概要

success path で git などのコマンドが出す stderr の「ノイズ」を抑えたい場面で、`2>/dev/null` や無条件 truncate を使うと legitimate な warning（`unable to rmdir` / remote hook advice など）まで silent drop してしまう。正しい設計は「情報量を減らす」ではなく「ノイズと警告を分離する」— git 側の `-q` / `--quiet` で informational を抑え、helper で warning/hint/error 行のみ selective surface する。

## 詳細

### Anti-pattern: 全 truncate

```bash
# ❌ NG: cycle 2 fix で導入された silent regression
dump_git_err() {
  # success path でも無条件 truncate
  : > "$git_err"
}
```

この解決は cycle 1 で出た「`Switched to branch 'wiki'` ノイズ」を消す動機で書かれたが、反面 legitimate warning (`hint: ...` / `unable to ...`) まで silent drop し、cycle 3 で silent regression として再検出された。

### Canonical pattern: selective surface

```bash
# ✅ OK: warning/hint/error 行のみ filter surface
surface_git_warnings() {
  local err_file="$1"
  [ -s "$err_file" ] || return 0
  head -n 10 "$err_file" | grep -iE '^(warning|hint|error):' >&2 || true
}

# 呼び出し側
git cmd 2>"$git_err"
rc=$?
if [ "$rc" -eq 0 ]; then
  surface_git_warnings "$git_err"  # success でも warning は残す
else
  head -3 "$git_err" | sed 's/^/  git: /' >&2
fi
```

### 責務分離の原則

stderr に出力される情報を以下の 2 責務に分ける:

| 責務 | 分類 | 対処 |
|------|------|------|
| informational (消してよい) | `Switched to branch` / `Already up to date` | `git <cmd> -q` / `--quiet` で上流抑制 |
| warning (消してはいけない) | `warning:` / `hint:` / `error:` | helper で selective surface |

「情報過多の解決」と「warning の silent loss」を同じツール（truncate）で扱わない。後者の fail mode を増やすだけ。

### `surface_git_warnings` の実装要点

- `head -n 10`: 大量 stderr で context を埋めない
- `grep -iE '^(warning|hint|error):`: 先頭タグで filter（git 出力のフォーマット安定性に依拠）
- `|| true`: grep no-match (rc=1) で script 全体を abort させない
- `>&2`: stdout への混入防止（parser 依存パイプラインを保護）

### Per-step tempfile 分離 (PR #550 での拡張)

multi-step 処理 (`git add` → `git diff --cached` → `git commit` → `git push` の 4 段) で 1 つの stderr tempfile を流用すると、**後段 step 失敗時に前段の warning が混在表示**されて root cause 診断が困難になる。step ごとに dedicated tempfile を確保し、trap cleanup で全 tempfile を纏めて削除するのが canonical:

```bash
# ✅ OK: per-step 分離
local add_err="" diff_err="" commit_err="" push_err=""
trap 'rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"' EXIT INT TERM HUP

add_err=$(mktemp /tmp/rite-add-err-XXXXXX) || add_err=""
diff_err=$(mktemp /tmp/rite-diff-err-XXXXXX) || diff_err=""
# ... (commit_err, push_err も同様)

git add -- "$@" 2>"${add_err:-/dev/null}" || { dump_err "$add_err" "add"; return 3; }
git diff --cached --quiet 2>"${diff_err:-/dev/null}"
# diff_err failure 時に add_err の warning が混ざらない
```

PR #550 (Issue #549) の `worktree_commit_push()` で実装。step-specific な診断情報を保つことで、`git push` が corrupt worktree で失敗したとき `rev-parse --abbrev-ref HEAD` の step に由来する warning と混ざらずに push 自体の失敗原因が特定できる。

### 委譲 shim は status (制御用) と stderr (診断用) の両方を capture する (PR #1201 での拡張)

helper script の機械可読 `status=...; reason=...` 出力を **制御フローに consume する** thin shim (PR #1201 — fix.md 4.5.2 が `issue-comment-wm-sync.sh` の status を読んで `WM_UPDATE_FAILED` routing に使う) では、status だけ capture して helper の stderr を `2>/dev/null` で破棄すると、**failure を routing できても root-cause が operator に届かない** diagnostic-degradation が起きる (error-handling reviewer が cycle 2 で MEDIUM 検出)。

教訓: **helper status を読んで失敗 routing する shim は、status (制御フロー用) と stderr (operator 診断・root-cause 用) の両方を capture する**。これは本 page の「stderr を silent drop しない」原則を delegation-shim 文脈へ拡張したもの — status は「何が起きたか」(routing 用) を、stderr は「なぜ起きたか」(診断用) を担い、責務が異なるため両方必要。

```bash
# ✅ OK: status を制御に使いつつ stderr も capture + selective surface
wm_sync_err=$(mktemp ...) || wm_sync_err=""
wm_out=$(bash helper.sh update --transform ... 2>"${wm_sync_err:-/dev/null}")
state=$(wm_state_of "$wm_out"); reason=$(wm_reason_of "$wm_out")
if [ "$state" != "success" ] && [ "$reason" != "no_comment" ]; then
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_..._failed" >&2   # 制御 routing
  [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && \
    { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | sed 's/^/    /' >&2; }  # 診断 surface
fi
```

実装時は **対称 counterpart (review.md 6.2 = fix.md 4.5) が既に確立した stderr-capture + head -5 surface パターン**を Read してそれに揃える (独自実装の逸脱を避ける)。PR #1201 cycle 2 fix は WM_UPDATE_FAILED routing と reason 語彙を一切変えず、trap に stderr tempfile を追加する形で「追加のみ」で適用した。

### 同一 helper の別 caller で同 anti-pattern が再発する (PR #1202 での evidence)

PR #1201 で確立した本拡張は、**直後の sibling PR #1202 (#1195 #7) で同一 helper (`issue-comment-wm-sync.sh`) の別 caller (`archive-procedures.md` §3.5.1 の WM 完了情報追記委譲) が同じ `2>/dev/null` 破棄を再演**した。委譲 shim が helper status を制御フローに consume しつつ helper stderr を握り潰す構造で、prompt-engineer + error-handling の 2 reviewer が cycle 1 で独立検出 (MEDIUM)。cycle 1 fix で canonical caller `fix.md 4.5.2` / `review.md 6.2` の **tempfile capture + `*)` arm で `head -5` surface** パターンに揃え、status 行による非ブロッキング判定 (`append-eof` への委譲) は不変のまま「追加のみ」で修正した。

教訓: **canonical caller が既に修正済みでも、同一 helper の新規 caller を追加するたびに stderr-discard が再導入される** ([[asymmetric-fix-transcription]] の「canonical pattern の対称伝播漏れ」と同根)。helper への新規委譲を書くときは、先に同 helper の既存 caller を grep して stderr-capture 規約の有無を確認し、それに揃えてから commit する。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)

## ソース

- [PR #529 fix cycle 1 (git stderr tempfile 退避の副作用)](../../raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 cycle 3 fix (success path で selective surface 導入)](../../raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #529 cycle 3 review (全 truncate の silent regression 検出)](../../raw/reviews/20260415T121203Z-pr-529-cycle-3.md)
- [PR #550 cycle 1 fix (per-step tempfile 分離の一般化)](../../raw/fixes/20260416T202213Z-pr-550.md)
- [PR #1201 review cycle 2 (委譲 shim の stderr 破棄 diagnostic-degradation 検出)](../../raw/reviews/20260529T151325Z-pr-1201.md)
- [PR #1201 fix cycle 2 (status + stderr 両 capture へ修正)](../../raw/fixes/20260529T151834Z-pr-1201.md)
- [PR #1202 review cycle 1 (同一 helper の別 caller §3.5.1 が 2>/dev/null 破棄を再演、2 reviewer 独立検出 MEDIUM)](../../raw/reviews/20260529T233836Z-pr-1202.md)
- [PR #1202 fix cycle 1 (canonical stderr-capture 規約へ整合、status 非ブロッキング判定は不変)](../../raw/fixes/20260529T234453Z-pr-1202.md)
