# Step 0 Results — Implicit-stop Boundary 検証

> **Status**: ⏳ 実機実行待ち (template)
>
> このドキュメントは実機実行後に結果を埋める雛形。Plan §21.2 Step 0 の
> falsification ベース検証結果と、Step 1 以降の採用 architecture の確定を記録する。

## 1. 実験設計サマリ (Plan §20.2 から)

| Variant | Boundary | Marker | 仮説 |
|---|---|---|---|
| A | Skill (sub-skill) | `[trial:completed:N]` | H1: baseline (Skill + completion-like marker) |
| B | Task (subagent) | `[trial:completed:N]` | H2: Task で implicit stop が遮断されるか |
| C | Bash worker | `[trial:completed:N]` | H3: Bash で構造的に回避できるか |
| D | inline (no boundary) | `[trial:completed:N]` | marker-only baseline |
| E | Task (subagent) | `[next: step_3]` | H5: marker form の効果 |

各 variant **20 trials**。Failure 判定は `parent_continuation_success` (step3 flag の有無)。

## 2. 実行環境 (実機実行時に埋める)

| 項目 | 値 |
|---|---|
| 実施日 | _YYYY-MM-DD_ |
| Claude CLI version | _e.g., 2.1.145 (Claude Code)_ |
| Model | _claude-opus-4-7[1m]_ |
| Plugin root | `/home/akiyoshi/Projects/personal/cc-rite-workflow` |
| Git commit | _<hash>_ |
| Branch | _develop_ |
| Git dirty | _false_ |
| `rite@rite-marketplace` | _false (必須)_ |
| Bash version | _e.g., 5.2.x_ |
| OS | _Linux WSL2 / macOS_ |

`preflight.sh` 出力をここにコピー。

## 3. 結果サマリ (実機実行時に埋める)

`tests/step0-experiment/scripts/aggregate.sh` の出力をここに転記。

```
Variant                        Total    OK  Fail  Excl FailRate
a-skill-completion                ??    ??    ??    ??     ??
b-task-completion                 ??    ??    ??    ??     ??
c-bash-completion                 ??    ??    ??    ??     ??
d-inline-completion               ??    ??    ??    ??     ??
e-task-non-completion             ??    ??    ??    ??     ??
```

## 4. Falsification 判定

| Hypothesis | Verdict | 根拠 |
|---|---|---|
| H2: Task isolation 十分 | _supported / falsified / undetermined_ | Variant B の failure 数 (20 trial 中) |
| H3: Bash worker 十分 | _supported / falsified / undetermined_ | Variant C の failure 数 |
| H4: marker dominant | _marker_dominant / boundary_dominant / undetermined_ | A vs D の failure rate 差 |
| H5: marker phrasing 効果 | _non_completion_marker_helps / marker_form_minor / undetermined_ | B vs E の failure rate 差 |

`aggregate.json` の `verdicts` フィールドをここに転記。

## 5. 観察された失敗パターン (実機実行時に埋める)

各 failure trial について、以下を分類:

- **session_jsonl path**:
- **直前の tool call**:
- **stop reason**:
- **parent の最終出力**:
- **failure type**: `implicit_stop_after_boundary` / `wrong_reinvoke` / `narrative_only` / その他

## 6. 採用 architecture の確定

Step 0 結果に基づき、Plan §21.3 の意思決定 table を埋める:

| Step 0 結果 | 採用 path |
|---|---|
| Task isolation OK + Bash worker OK | Hybrid 案 (Plan §17.4 / §21.1) |
| Task isolation 不可 + Bash worker OK | Bash worker 主軸 (subagent 不使用) |
| Bash worker でも failure 残存 | Alt C (marker phrasing 修正) を併用 |
| 全 variant で failure 残存 | 元の案 A (Read 経由) フォールバック |

**確定した採用 architecture**: _実機実行後に記入_

## 7. Step 1 以降の go/no-go 判定

- [ ] Step 0 検証完了 (5 variant × 20 trial = 100 trial 以上)
- [ ] Falsification verdict 全て確定 (H2/H3/H4/H5)
- [ ] 採用 architecture 確定
- [ ] Step 1 (`branch-setup` Bash worker 化) 着手可能

## 8. 関連ファイル

- 上位 Plan: `/home/akiyoshi/.claude/plans/rite-issue-create-rite-issue-start-rite-lovely-snowglobe.md`
- 実験 fixture: `tests/step0-experiment/`
- 実行手順: `tests/step0-experiment/HOW-TO-RUN.md`
- Variant 別結果: `tests/step0-experiment/results/<variant>/trial-*.json`
- 集計: `tests/step0-experiment/results/aggregate.json`

## 9. 補足観察 / 次に検討すべきこと

- (実機実行時に追記)
