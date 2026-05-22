# Workflow Incident Emit Pattern — Orchestrator + Sub-skill 共通契約 SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` ワークフローにおける **Workflow Incident Sentinel の emit pattern** の SoT である。
>
> - **Sentinel Visibility Rule**: sub-skill が emit した sentinel を orchestrator が context grep で発見できる経路を保証するための契約。
> - **Orchestrator-direct emit pattern**: start.md ステップ 5 / 6 / 7.2 / 8.2 で orchestrator 自身が sentinel を emit する 4 invocation point の標準形。
> - **5 caller × type マッピング**: どの caller がどの sentinel type を emit するかの参照表。
>
> `workflow-incident-detection.md` (ステップ 8.5 SoT) と pair で使用する。

## なぜ emit pattern を統一する必要があるか

ステップ 8.5 (`workflow-incident-detection.md` SoT) の **Step 1 — Sentinel detection (context grep)** は、`[CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; iteration_id=<pr>-<epoch>` の完全形 sentinel 行が orchestrator の conversation context に存在することを前提とする。

emit point が以下 2 系統に分かれているため、**両系統が同じ sentinel 文字列を必ず context へ流入させる**ことが detection の前提条件となる:

1. **Sub-skill 内部** (`lint.md` / `pr/create.md` / `pr/fix.md` / `pr/review.md`): bash tool stdout は orchestrator context に流入するが、`AskUserQuestion` 直後など sub-skill が中断する経路で sentinel が response text に含まれない場合、Step 1 grep が miss する経路がある。
2. **Orchestrator-direct** (`start.md` ステップ 5 / 6 / 7.2 / 8.2): bash command を orchestrator 自身が走らせるため stdout は確実に context へ流入するが、response text 化を skip すると後続 cycle の self-detection 経路で見えなくなる。

本 reference は両系統の **emit + response text inclusion** を canonical 化する。

## Sub-skill 内部 emit pattern (Sentinel Visibility Rule)

Sub-skills は orchestrator の conversation context 内で **inline 実行** される (forked execution で `AskUserQuestion` が e2e フローで失敗した過去経路を修正済み)。Bash tool call の stdout は orchestrator context に直接可視。

**防御的実践 (defense-in-depth)**: sub-skill は emitted sentinel を final response text にも含める。execution context が将来変わっても sentinel detection の堅牢性を保つため。

### Canonical bash literal

```bash
# Step 1: emit sentinel via hook script (silent capture)
sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type {sentinel_type} \
  --details "{specific failure description}" \
  --pr-number {pr_number} 2>/dev/null) || true

# Step 2: also echo to stderr for human-visible debugging
[ -n "$sentinel_line" ] && echo "$sentinel_line" >&2
```

### LLM responsibility

sub-skill LLM は捕捉した `sentinel_line` の値 (非空時) を **final response message text に verbatim 含める**:

```
[lint:error] — 3 errors detected
[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=rite:lint tool not found: ruff; iteration_id=0-1775650793
```

inline 実行下では sentinel は bash stdout 経由で orchestrator context に既に流入しているが、response text への明示的 inclusion は defense-in-depth として必須。

## Orchestrator-direct emit pattern

`start.md` 内で orchestrator が 直接 sentinel を emit する 4 invocation point:

| ステップ | Trigger | sentinel `type` | Canonical literal |
|---------|---------|------------------|-------------------|
| 5 | `[lint:aborted]` (rite:lint 中断) | `manual_fallback_adopted` | 下記 §A |
| 6 | `[pr:create-failed]` (rite:pr:create 失敗) | `skill_load_failure` (+ user 選択時に `manual_fallback_adopted`) | 下記 §B |
| 7.2 | `[fix:error]` (rite:pr:fix エラー fallback 選択時) | `manual_fallback_adopted` | 下記 §C |
| 8.2 | `[ready:error]` (rite:pr:ready 失敗 fallback 選択時) | `skill_load_failure` (+ user 選択時に `manual_fallback_adopted`) | 下記 §D |

orchestrator は bash command を自分で走らせるため stdout は確実に context へ流入する。それでも sentinel line を **response text に含めなければならない** — 後続 cycle の self-detection (ステップ 8.5 step 1 grep) が conversation context の grep で動作するため。

### §A — ステップ 5 `[lint:aborted]`

```bash
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type manual_fallback_adopted \
  --details "rite:lint aborted by user" \
  --pr-number 0 || true
```

`|| true` は non-blocking guarantee (emit failure が workflow を halt させない) のため必須。

### §B — ステップ 6 `[pr:create-failed]`

```bash
# Step 1: skill_load_failure を emit
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type skill_load_failure \
  --details "rite:pr:create returned create-failed" \
  --pr-number 0 || true
```

次に user に `AskUserQuestion` で「再試行」/「Edit ツールで PR 作成して continue (incident 記録)」/「以降をスキップしてステップ 8.6 完了レポートへ」を確認する。「Edit ツールで PR 作成して continue」 選択時に追加で:

```bash
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type manual_fallback_adopted \
  --details "rite:pr:create manual fallback" \
  --pr-number 0 || true
```

### §C — ステップ 7.2 `[fix:error]`

`rite:pr:fix` から `[fix:error]` が返った場合、user に `AskUserQuestion` で「再試行」/「Edit ツールで手動 fallback (incident 記録)」/「ステップ 8.6 完了レポートへスキップ」/「terminate」を確認する。「Edit ツールで手動 fallback」 選択時に:

```bash
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type manual_fallback_adopted \
  --details "rite:pr:fix error fallback" \
  --pr-number {pr_number} || true
```

sentinel は ステップ 8.5 で次 cycle に検出される。

### §D — ステップ 8.2 `[ready:error]`

```bash
# Step 1: skill_load_failure を emit
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type skill_load_failure \
  --details "rite:pr:ready returned error" \
  --pr-number {pr_number} || true
```

次に user に `AskUserQuestion` で「再試行」/「Edit ツールで手動 Ready 化 (incident 記録)」/「ステップ 8.6 完了レポートへスキップ」/「terminate」を確認する。「Edit ツールで手動 Ready 化」 選択時に追加で:

```bash
bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type manual_fallback_adopted \
  --details "rite:pr:ready manual fallback" \
  --pr-number {pr_number} || true
```

## 5 caller × invocation point マッピング

ステップ 8.5 検出経路は 5 callsite 後の **Mandatory After** で実行される (`workflow-incident-detection.md` Step 1 grep の context window で確実に sentinel を捕捉するため):

| Caller | Invocation point | Trigger (always run after) |
|--------|------------------|----------------------------|
| ステップ 5 (lint) | Mandatory After ステップ 5 — Step 2 | After `[lint:*]` pattern |
| ステップ 6 (pr:create) | Mandatory After ステップ 6 — between "Verify" and "Proceed to ステップ 7 now" | After `[pr:created:{N}]` or `[pr:create-failed]` |
| ステップ 7.1 (pr:review) | After Review — Step 3 | After `[review:*]` pattern |
| ステップ 7.2 (pr:fix) | After Fix — Step 3 | After `[fix:*]` pattern |
| ステップ 8.2 (pr:ready) | Mandatory After ステップ 8.2 — Step 3 | After `[ready:*]` pattern |

各 Mandatory After section は **「Run ステップ 8.5 detection」step** を含み、orchestrator に直近 conversation context の grep を指示する。`AskUserQuestion` fallback option で manual fallback を選んだ際の emit (orchestrator-direct §A-§D) もここで検出される。

## 不変条件

1. **`|| true` は必須**: emit failure は非 fatal であり workflow を halt させてはならない。
2. **response text に sentinel を含める**: bash stdout で既に context に流入していても、response text への inclusion は defense-in-depth として必須。
3. **`pr-number 0` は PR 未作成時**: ステップ 5 / 6 emit 時の `--pr-number 0` は「該当 PR なし」を意味し、`iteration_id` の prefix が `0-` となる。
4. **emit 後の `AskUserQuestion` は user 経路ごと独立**: orchestrator が emit→user 確認→Issue 登録/skip の経路を持つのは ステップ 8.5 の Step 4-7 で、本 reference の emit point は **sentinel を文字列として context に流入させること** だけが責務。
