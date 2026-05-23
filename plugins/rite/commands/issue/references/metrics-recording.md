# Metrics Recording — orphan reference

> **Status: Orphan (no active caller).** The metrics recording step (Step 1–5
> + Mandatory After) was originally an inline section of `start.md`, then
> extracted here for cognitive-load reasons. The flat workflow consolidation
> later moved away from a dedicated metrics phase; no current command file
> sources this reference.
>
> **Retained because**: the Step 1–5 rubric, threshold-evaluation criteria,
> repeated-failure classification, and PATCH heredoc together represent the
> most complete record of how end-to-end metrics were intended to be
> captured. A future reintroduction (post-PR metrics dashboard, retro logs,
> etc.) should pick up from this file rather than re-deriving the criteria.
>
> **The `phase5_*`-form identifiers in this file are intentional — not legacy
> drift.** The markers used below (`phase5_post_metrics`,
> `phase5_post_status_in_review`, `phase5_5_2_metrics`) are **metrics-gate
> internal markers, NOT work-memory phase vocabulary**. They are distinct from
> the work-memory `phase5_*` examples that Issue #1104 / #1109 unified to the v3
> enum (`implement` / `lint` / …): those were work-memory phase labels, whereas
> these name points in the (now-orphan) metrics recording flow. The `phase5_*`
> form here is **historically fixed and deliberately NOT renamed**, to preserve
> traceability with the original design discussion. Because this file has no live
> writer/reader (see the orphan banner above), these markers never appear in a
> real flow-state `.phase` value — a `phase5_*` drift-cleanup grep that lands here
> can treat them as documentation-only and skip them.

## Skip Steps note (Phase 5.6 pre-condition)

`metrics.enabled: false` in rite-config.yml の場合、Step 1-5 を skip する。**ただし Mandatory After 5.5.2 は無条件実行する。** `phase5_post_metrics` marker は Phase 5.6 pre-condition で要求されるため、Mandatory After を skip すると `.phase = phase5_post_status_in_review` のままで Phase 5.6 ERROR gate が hard abort する。

Otherwise:

## Step 1: Collect metrics

Collect metrics from the current workflow execution:

| Metric | Source | How to Obtain |
|--------|--------|---------------|
| `plan_deviation_rate` | Issue body checklist items (Phase 3.6) vs completed items | `planned_steps` = total checklist items added in Phase 3.6. `actual_steps` = checked items at completion. Formula: `abs(actual - planned) / planned * 100`. If `planned = 0`, set judgment to `skip` |
| `test_pass_rate` | From Phase 5.2 lint results | 100% if tests passed or no tests configured |
| `review_critical_high` | Phase 5.4 review results | Count of CRITICAL+HIGH findings from the last `📜 rite レビュー結果` PR comment |
| `review_fix_loops` | PR comments | Count `📜 rite レビュー結果` comments on the PR: `gh api repos/{owner}/{repo}/issues/{pr_number}/comments --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | length'` |
| `plan_deviation_count` | flow-state | Read `implementation_round` field (set by Phase 5.1.3) via `flow-state.sh`. **Use the same fail-fast pattern documented at the Phase 3 pre-condition** (canonical `if cmd; then :; else rc=$?; fi` form). flow-state.sh launch failure 時は metrics output を skip し、silent に `"0"` 扱い (= "no deviation" の誤分類) しないこと。per-session state を参照 (legacy state file snapshot ではない)。Phase 5.1 への re-entry 数 (checklist failure 由来) を計測。詳細な bash literal は本ファイルの「`plan_deviation_count` 取得 bash block」セクション参照 |

> **Note**: bash literal は table cell 内に埋め込まず、独立 code block として下に分離している。これは LLM が table を読んで値を提示する際に、cell 内 literal を正規の Bash tool 呼び出しと誤認するリスクを避けるため。table cell 内の prose は Phase 3 pre-condition への semantic reference にとどめる。

### `plan_deviation_count` 取得 bash block

canonical capture pattern を維持し `caller-markdown-block.test.sh` G-03 metatest が pass することを保証:

```bash
# canonical fail-fast pattern (Phase 3 pre-condition と同型): flow-state.sh 起動失敗時は
# silent default 0 (= "no deviation") に降格せず、metrics output を skip する。
# 注意: inline 1 行 form を維持 (caller-markdown-block.test.sh TC-6 が
# `if val=...; then :; else rc=$?` の 1 行 canonical capture pattern を grep で pin する)。
if val=$(bash {plugin_root}/hooks/flow-state.sh get --field implementation_round --default 0); then :; else rc=$?; echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_5_2_metrics; rc=$rc" >&2; echo "WARNING: flow-state.sh failed (rc=$rc) — metrics for plan_deviation_count skipped" >&2; echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:resume で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2; val=""; fi
# numeric type validation (writer/reader/resume 3 layer 対称化 doctrine): 他 caller (Phase 5.7
# parent_issue_number / implement.md parent_issue_number / pr/review.md loop_count /
# resume.md parent_issue_number_raw) と同様に non-numeric 値を 0 に降格して partial corruption
# (`| 計画逸脱回数 | abc回 |` 等) を防ぐ。空文字列 (flow-state.sh 失敗) は下記 if-z で別途
# METRICS_SKIPPED 経路へ流すため、ここでは非空かつ非数値のみ 0 に降格する。
case "$val" in
  '') ;;
  *[!0-9]*)
    echo "WARNING: implementation_round is not numeric ('$val'), defaulting to 0 (partial corruption 防止)" >&2
    val=0
    ;;
esac
plan_deviation_count="$val"
# flow-state.sh 失敗時 (`val=""`) は METRICS_SKIPPED sentinel を emit し、後続 Step 2/3/4
# (threshold evaluation + failure classification + PATCH heredoc generation) を skip させる。
# silent に空文字列 `{plan_deviation_count}` substitute が下流 heredoc (Phase 5.5.2 完了レポート)
# に流入し `| 計画逸脱回数 | 回 | ...` の partial corruption が発生する経路
# を遮断する。Claude は本 sentinel を会話履歴で grep し、検出時は **Phase 5.5.2 metrics body 生成を skip** すること
# (= metrics PATCH を実行せず、ただし Mandatory After 5.5.2 の `phase5_post_metrics` marker は必ず書き込み、Phase 5.6 へ進む)。
#
# 成功経路では PLAN_DEVIATION_COUNT sentinel を emit し、Claude が会話履歴を grep して
# Step 4 heredoc の `{plan_deviation_count}` placeholder に literal substitute する。シェル変数
# `$plan_deviation_count` は Bash tool 境界で消失するため、stdout/stderr に明示的に emit しない限り
# Claude は値を読み取れない。同型の cross-boundary state transfer は resume.md Phase 1.3 routing
# table emit / start.md ステップ 8.4 (parent close) で確立済みの canonical pattern。
#
# Emit channel policy: cross-boundary state transfer の sentinel は **stdout / stderr のいずれでも会話コンテキストに記録される**。
# Claude Code の Bash tool は stdout/stderr 両方を会話コンテキストに取り込む仕様のため、emit channel の
# 統一は機能要件ではない。本箇所は METRICS_SKIPPED と PLAN_DEVIATION_COUNT を一貫して stderr に emit する
# (両者を観測値ストリームとして揃える設計選択)。PARENT_ISSUE / PARENT_ISSUE_DISPLAY は stdout 側で emit する
# 既存の canonical pattern を維持しつつ、本箇所の stderr 採用は **observability ログ専用ストリームを stderr に集約する** 一貫性のための設計選択。
if [ -z "$val" ]; then
  echo "[CONTEXT] METRICS_SKIPPED=1; reason=state_read_failed" >&2
else
  echo "[CONTEXT] PLAN_DEVIATION_COUNT=$plan_deviation_count" >&2
fi
```

### Claude への指示 (METRICS_SKIPPED 検出時の挙動)

上記 bash block 実行後、stderr に `[CONTEXT] METRICS_SKIPPED=1; reason=state_read_failed` が emit された場合、Claude は **Step 2 (threshold evaluation)、Step 3 (failure classification)、Step 4 (PATCH heredoc generation) の 3 step すべてを skip** し、`Phase 5.5.2: flow-state.sh 失敗のため metrics 更新を skip しました (manual intervention で次回計測してください)` を stderr に出力する。その後、**Mandatory After 5.5.2 (`flow-state.sh set --phase phase5_post_metrics` の marker 書き込み) を unconditional に実行してから Phase 5.6 へ進む** (AC-5 により body skip 時も marker 書き込みは必須。これを skip すると Phase 5.6 pre-condition `expected: phase5_post_metrics` で hard abort する)。Phase 5.5.2 の実 heading 構造は Step 1=collect / Step 2=threshold / Step 3=failure classification / **Step 4=Append metrics section to work memory (= heredoc PATCH 本体)** / Step 5=repeated failure であり、Step 4 が PATCH heredoc 本体のため、Step 4 を skip 対象に含めないと空 placeholder の partial corruption が再発する self-defeating defense になる。

## Step 2: Evaluate thresholds

Read `metrics.baseline_issues` from rite-config.yml (default: 3).

### Step 2a: Count completed Issues with metrics

Search the 10 most recently closed Issues for work memory comments containing `📊 メトリクス`:

```bash
# 直近の closed Issue 番号を取得（最大10件）
recent_issues=$(gh api "repos/{owner}/{repo}/issues?state=closed&per_page=10&sort=updated&direction=desc" --jq '.[].number')

# 各 Issue のメトリクスセクションを検索
for issue_num in $recent_issues; do
  metrics=$(gh api "repos/{owner}/{repo}/issues/${issue_num}/comments" \
    --jq '[.[] | select(.body | contains("📊 メトリクス"))] | last | .body' 2>/dev/null)
  if [ -n "$metrics" ] && [ "$metrics" != "null" ]; then
    echo "FOUND:${issue_num}"
  fi
done
```

### Step 2b: Determine baseline status

- **Baseline period** (completed Issues with metrics < `baseline_issues`): Set all judgments to `skip`. Display: `📊 Baseline 収集中 ({n}/{baseline_issues}) — 閾値判定はスキップします`
- **Post-baseline**: Proceed to Step 2c

### Step 2c: Evaluate thresholds (post-baseline only)

1. **Per-Issue thresholds** (from Step 1 values): `plan_deviation_rate <= 30`, `test_pass_rate == 100`, `review_fix_loops <= 3`. Set `pass` or `warn`.
2. **MA thresholds**: Parse `📊 メトリクス` sections from the 5 most recent completed Issues (found in Step 2a). Extract each metric value, calculate the moving average, and compare against `baseline_ma5 * improvement_factor`. Set `pass`, `warn`, or `skip` (if fewer than `baseline_issues` completed).

## Step 3: Determine failure classification

If any threshold is `warn`: classify each violation per the [Metric-to-Failure-Class Mapping](../../../references/execution-metrics.md#metric-to-failure-class-mapping) table. Select primary failure class (most frequent; tie-break: last occurring).

## Step 4: Append metrics section to work memory

Update the Issue work memory comment by appending the metrics table per [Execution Metrics recording format](../../../references/execution-metrics.md#recording-format).

> **Reference**: Apply [Work Memory Update Safety Patterns](../../../references/gh-cli-patterns.md#work-memory-update-safety-patterns).

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# comment_data の取得・追記内容の heredoc 定義・PATCH を分割すると変数が失われる
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [ -z "$comment_id" ]; then
  # comment not found: skip metrics recording entirely (non-fatal; metrics are optional)
  echo "ERROR: Work memory comment not found. Skipping metrics recording." >&2
  exit 0
fi

# 1. Backup before update
backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
printf '%s' "$current_body" > "$backup_file"

if [[ -z "$current_body" ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH." >&2
  echo "Backup saved at: $backup_file" >&2
  exit 1
fi

# 2. Append metrics section
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
printf '%s\n\n' "$current_body" > "$tmpfile"
# ⚠️ 以下の heredoc 内の {…} プレースホルダーを Step 1-3 の実測値で置換してから実行すること
cat >> "$tmpfile" << 'METRICS_EOF'
### 📊 メトリクス

| メトリクス | 値 | 閾値 | 判定 |
|-----------|-----|------|------|
| 計画乖離率 | {plan_deviation_rate}% | ≤30% | {judgment} |
| テスト通過率 | {test_pass_rate}% | 100% | {judgment} |
| レビュー指摘(CRITICAL+HIGH) | {review_critical_high}件 | MA5≤{threshold} | {judgment} |
| review-fixループ | {review_fix_loops}回 | ≤3 | {judgment} |
| 計画逸脱回数 | {plan_deviation_count}回 | MA5≤{threshold} | {judgment} |

**Baseline**: {baseline_status}
**失敗分類**: {primary_failure_class} ({corrective_action_pointer})
METRICS_EOF

# 3. Empty body guard
if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH." >&2
  echo "Backup saved at: $backup_file" >&2
  exit 1
fi

# 4. Header validation
if grep -q -- '📜 rite 作業メモリ' "$tmpfile"; then
  : # Header present, proceed
else
  echo "ERROR: Updated body missing work memory header. Restoring from backup." >&2
  cp "$backup_file" "$tmpfile"
  exit 1
fi

# 5. PATCH
jq -n --rawfile body "$tmpfile" '{"body": $body}' \
  | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
    -X PATCH --input -
patch_status=$?
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed (exit code: $patch_status). Backup saved at: $backup_file" >&2
  exit 1
fi
```

### Placeholder descriptions

`{plan_deviation_rate}`, `{test_pass_rate}`, `{review_critical_high}`, `{review_fix_loops}`, `{plan_deviation_count}` are the values collected in Step 1. **`{plan_deviation_count}` の source**: Step 1 bash block の stderr に emit される `[CONTEXT] PLAN_DEVIATION_COUNT=<N>` 行を Claude が会話履歴で first-match で grep し、`<N>` 部分を literal substitute する (flow-state.sh 失敗時は `[CONTEXT] METRICS_SKIPPED=1` が代わりに emit され、本 heredoc 全体が skip される — 上記「Claude への指示 (METRICS_SKIPPED 検出時の挙動)」段落を参照)。`{judgment}` is `pass`/`warn`/`skip` from Step 2. `{threshold}` is the MA5 threshold. `{baseline_status}`, `{primary_failure_class}`, `{corrective_action_pointer}` are from Steps 2-3. Before executing this bash block, replace all `{...}` placeholders in the heredoc body with actual values computed in Steps 1-3. The heredoc uses a single-quoted delimiter (`'METRICS_EOF'`) so shell variables are NOT expanded; Claude must substitute the placeholder text directly in the template before passing it to the Bash tool.

## Step 5: Check repeated failure

If `safety.auto_stop_on_repeated_failure: true` and the same primary failure class has occurred `safety.repeated_failure_threshold` times consecutively (across recent Issues), trigger fail-closed:

```
⚠️ 安全装置が発動しました（繰り返し失敗検出）
分類: {failure_class} が {count} 回連続
是正アクション: {corrective_action_pointer}
```

Present options via `AskUserQuestion`:
- 続行（制限を引き上げ）→ Proceed to 5.6
- 中止（作業メモリに状態保存）→ Phase 5.6
- 手動介入（ユーザーが直接対応）→ terminate

## 関連

- [`../../../references/execution-metrics.md`](../../../references/execution-metrics.md) — メトリクス定義 / 閾値 / failure classification
- [`../../../references/gh-cli-patterns.md`](../../../references/gh-cli-patterns.md#work-memory-update-safety-patterns) — Work Memory Update Safety Patterns
- [`./pre-condition-gate.md`](./pre-condition-gate.md) — Phase 5.6 pre-condition の `flow-state.sh` fail-fast pattern
- `plugins/rite/hooks/tests/caller-markdown-block.test.sh` TC-6 — `implementation_round` inline form pin (本 reference の bash block を grep 対象とする)
