# Fingerprint Cycling Detection — Quality Signal SoT

> **Source of Truth**: 本ファイルは Review/Fix ループにおける **Fingerprint Cycling Detection** (review サイクル中の同一 finding 持続検出) と **Quality Signal 3 & 4 Detection** の SoT である。実際の caller は `pr/review.md` (Signal 3) と `pr/fix.md` (Signal 2) であり、`/rite:pr:open` のレビュー/修正ループ (ステップ 7) 内で間接的に実行される。本ファイルは fingerprint spec / similarity / Quality Signal markers / split bash / 4-option AskUserQuestion の標準形を定義する。

## 概要 — Quality Signal 1-4 の位置付け

`/rite:pr:open` の review-fix loop には cycle-count-based safety limit が **存在しない** 設計 (旧 cycle-count monitor は #557 で完全に削除済み)。代わりに以下 **4 つの quality signal** で escalation を行う:

| Signal | 検出 phase | 内容 |
|--------|-----------|------|
| **Signal 1** — 同一 finding cycling | Phase 5.4.1.0 (本 reference) | review サイクル間で同 fingerprint の finding が残存 |
| **Signal 2** — root-cause-missing fix | `fix.md` ステップ 3.2.1 | 根本原因を捉えない fix がコミットされる経路の検出 |
| **Signal 3** — cross-validation disagreement | `review.md` ステップ 5.2 + debate fails | レビュアー間の disagreement が debate でも解消されない |
| **Signal 4** — finding quality gate failure | `_reviewer-base.md` Finding Quality Guardrail | reviewer 自身が self-degraded 状態を宣言 |

Signal 1 は Phase 5.4.1.0 (本 reference §1)、Signal 3 と Signal 4 は Phase 5.4.3 Step 3.1 (本 reference §2) で検出する。4 signal すべてに対して **同じ 4-option AskUserQuestion** (本 reference §3) で escalation する。

設計判断 (#557 D-02): 4 quality signal を escalation の唯一機構とし、追加で iteration counter による safety limit を導入しない。counter を再導入すると #557 が明示的に削除した cycle-count-based degradation が再発する。

## §1 — Phase 5.4.1.0 Fingerprint Cycling Detection

`review.loop.convergence_monitoring` が enabled (default: `true`) で、PR に先行する `📜 rite レビュー結果` コメントがある時に発火する。Signal 1 of 4。

### Design note

旧 cycle-count-based convergence monitor を **置き換え** た新 monitor。cycle は数えない。**finding を semantic fingerprint で識別** し、cycle 間で同一 fingerprint が 1 度でも再出現すれば escalate する。

### Step 1 — Fetch 2 most recent review comments

直近の 2 件の `📜 rite レビュー結果` PR コメント (this cycle + previous cycle) を取得。2 件未満なら skip (比較対象なし):

```bash
# ⚠️ gh api --paginate + --jq は各ページ独立適用のため併用できない
# (gh の仕様: --paginate は複数ページを stdout に stream 出力し、--jq は各ページに独立適用される)。
# 代わりに --paginate --slurp で全ページを単一 JSON array に統合し、外側の jq で filter する。
# pipefail を有効化して pipeline 途中の失敗も捕捉する。
set -o pipefail
pr_number="{pr_number}"
gh_err=$(mktemp /tmp/rite-fp-gh-err-XXXXXX 2>/dev/null) || gh_err=""
if ! comments=$(gh api --paginate --slurp repos/{owner}/{repo}/issues/${pr_number}/comments 2>"${gh_err:-/dev/null}" \
    | jq 'add | [.[] | select(.body | contains("📜 rite レビュー結果"))] | .[-2:]'); then
  echo "WARNING: gh api による PR コメント取得または jq filter に失敗。fingerprint check を skip します (fail-open)" >&2
  [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | sed 's/^/  /' >&2
  [ -n "$gh_err" ] && rm -f "$gh_err"
  set +o pipefail
  echo "[CONTEXT] FINGERPRINT_CHECK skip (gh api or jq failure)"
  exit 0
fi
[ -n "$gh_err" ] && rm -f "$gh_err"
set +o pipefail

count=$(printf '%s' "$comments" | jq 'length' 2>/dev/null || echo 0)
if [ "${count:-0}" -lt 2 ]; then
  echo "[CONTEXT] FINGERPRINT_CHECK skip (only ${count:-0} review comment(s) on PR)"
  exit 0
fi
```

### Step 2 — Extract findings & compute fingerprints

Fingerprint spec:

```
fingerprint = sha1( normalize(file_path) + ":" + category + ":" + normalize(message) )
```

- `normalize(file_path)`: absolute path なら repository-root prefix を strip、`./` を collapse。
- `category`: reviewer identity + severity (例: `security-reviewer:HIGH`)。
- `normalize(message)`: 行番号を除去 (`:NNN:` → `:`)、識別子を `<ident>` placeholder で mask、lowercase、whitespace を collapse。

Similarity matching (fingerprint が完全一致しない場合):

- **same file path** AND **same category** AND **Jaccard token-similarity > 0.7** → 同一 fingerprint として扱う。

semantic 作業のため、LLM が各 `📜 rite レビュー結果` コメントの Markdown body (table / per-reviewer sections) から finding を抽出し、in-context で fingerprint を計算する。SHA-1 helper (macOS BSD / Linux coreutils portable):

```bash
# sha1sum は Linux coreutils、shasum は macOS/BSD (Perl script 付属)。どちらも利用不可な場合は python3 fallback。
sha1_portable() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1 | awk '{print $1}'
  else
    printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())'
  fi
}
sha1_portable "{file_path}:{category}:{normalized_message}"
```

### Step 3 — Compare fingerprint sets

| Condition | Signal |
|-----------|--------|
| Intersection size == 0 | **Healthy progress** — finding が残存していない、review を normal continue |
| Intersection size ≥ 1 | **Signal 1 fired (same-finding cycling)** — escalate |

context marker を emit:

```
[CONTEXT] FINGERPRINT_CYCLING hits={n} total_current={m} total_previous={p}
```

### Step 4 — Escalate via AskUserQuestion (hits >= 1 のみ)

```
品質シグナル発火: 同一 finding が 2 サイクル以上残存しています（{n} 件）。

継続サイクル数ではなく、指摘そのものの循環を検出しています。
```

4-option AskUserQuestion を提示する (§3 共通 4-option の節を参照)。

### Step 5 — Proceed to review invocation

Step 4 routing が「本 PR 内で再試行」または「別 Issue として切り出す (split bash 実行後)」の場合のみ実行:

```
Invoke `skill: "rite:pr:review"`.
```

review が return したら `pr/iterate.md` review-fix loop の fix side へ進む。

## §2 — Quality Signal 3 & 4 Detection (After Review)

review が return した後、最新の `📜 rite レビュー結果` PR コメント **AND** conversation context を以下 marker で grep:

| Marker | Source | Signal |
|--------|--------|--------|
| `[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement` | `review.md` ステップ 5.2 (cross-validation disagreement + debate fails) | Signal 3 — cross-validation disagreement |
| `### Reviewer self-assessment` section + `Status: degraded (quality-gate failure)` (review body 内) | 任意の reviewer 出力 (`_reviewer-base.md` Finding Quality Guardrail 経由) | Signal 4 — reviewer self-degraded |

### Detection bash (Signal 4)

```bash
latest_review=$(gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body' 2>/dev/null) || latest_review=""
signal4_hit=0
if printf '%s' "$latest_review" | grep -qE '^### Reviewer self-assessment'; then
  if printf '%s' "$latest_review" | grep -qE '^Status: degraded'; then
    signal4_hit=1
  fi
fi
echo "[CONTEXT] SIGNAL_4_HIT=$signal4_hit"
```

Signal 3 は `review.md` が stderr に emit 済みのため、conversation context を grep するだけで検出可能 (本 phase で再取得は不要)。

### Routing

Signal 3 または Signal 4 が発火した場合、**§3 の 4-option AskUserQuestion** を提示し、§3 の branching table を適用する。いずれも発火しなかった場合は Phase 5.4.3 Step 4 (review result pattern routing) に直接進む。

## §3 — 共通 4-option AskUserQuestion (Signal 1 / 3 / 4 共用)

| Option | Action |
|--------|--------|
| 本 PR 内で再試行（推奨） | review invocation (Phase 5.4.1.0 §1 Step 5 / Phase 5.4.3 Step 4) へ進む。再発火しても本 phase が再 escalate する (次サイクル経路) |
| 別 Issue として切り出す | §4 の split bash で persistent finding を tracking Issue 化、work memory に split メモを残し、review invocation へ進む |
| PR を取り下げる | `gh pr close {pr_number}` を実行、review invocation を skip、Phase 5.6 (completion report) へ jump (workflow 終端) |
| 手動レビューへエスカレーション | review invocation を skip、review-fix loop を抜けて Phase 5.5 (Ready for Review) へ jump (人手レビューに引継ぎ) |

### Branching after user selection

| Selection | Next |
|-----------|------|
| 本 PR 内で再試行 | review invocation 実行 |
| 別 Issue として切り出す | §4 の split bash 実行 → review invocation 実行 |
| PR を取り下げる | `gh pr close {pr_number}` → Phase 5.6 (review invocation skip) |
| 手動レビューへエスカレーション | Phase 5.5 へ jump (review invocation skip) |

## §4 — Split bash for "別 Issue として切り出す"

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 概要

レビューサイクル中に持続した finding を別 Issue として切り出しました (Quality Signal 1 発火)。

## 元の finding
{persistent_finding_body}

## 関連

- 元の PR: #{pr_number}
BODY_EOF

# jq -n の出力を stdin で create-issue-with-projects.sh に渡す (pr/review.md §3992 / Issue #1193 #5 と同じ pipe 形式、入れ子 $() を回避)
result=$(jq -n \
  --arg title "review-split: {short_summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "S" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: "none" }
    },
    options: { source: "fingerprint_split", non_blocking_projects: true }
  }' | bash {plugin_root}/scripts/create-issue-with-projects.sh)
new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
echo "✅ Fingerprint 循環 finding を #$(printf '%s' "$result" | jq -r '.issue_number') として切り出しました: $new_issue_url"
```

Signal 3 / Signal 4 由来の split では title prefix を `review-split:` のまま (Signal 1 と統一)、body の冒頭 "Quality Signal 1 発火" を実発火 signal 名に置換する。`options.source` も `fingerprint_split` → `quality_signal_3_split` / `quality_signal_4_split` に変更する。
