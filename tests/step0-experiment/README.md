# Step 0: Implicit-stop Boundary 検証実験

このディレクトリは、Plan `/home/akiyoshi/.claude/plans/rite-issue-create-rite-issue-start-rite-lovely-snowglobe.md` §21.2 Step 0 の **「Sub-skill return 後の implicit stop は本当に Skill ツール仕様外用法が原因か」** という leading hypothesis を falsification ベースで検証する実験 fixture と観測ツール群。

## 実験の目的

5 つの異なる「parent ↔ child boundary tool」を比較し、以下を確定させる:

- **H1**: Skill boundary が implicit stop を発火させやすいか
- **H2**: Task subagent boundary は parent context を遮断し implicit stop を起こさないか
- **H3**: Bash worker boundary は implicit stop を構造的に回避するか
- **H4**: Completion-like marker (`[X:completed]`) 自体が独立した stop trigger になっているか
- **H5**: Non-completion marker (`[next: phase_X]`) に変えると Task boundary でも parent が継続するか

Step 0 が **Plan 全体の go/no-go ゲート**。ここで採用アーキテクチャが確定し、Step 1 以降の作業方針が決まる。

## Variants 一覧

各 variant は同一の「3 step orchestrator」を持ち、Step 2 の boundary tool だけを差し替える。

| Variant | Boundary Tool | Marker | 検証する仮説 |
|---|---|---|---|
| A (baseline) | `Skill: test:step0-variant-a-subskill` | `[trial:completed:N]` (completion-like) | H1: Skill 経由は止まりやすいか |
| B | `Task` (subagent) | `[trial:completed:N]` | H2: Task で隔離されるか |
| C | `Bash` (worker) | `[trial:completed:N]` | H3: Bash で構造的に回避できるか |
| D | (no boundary, inline) | `[trial:completed:N]` | Inline + marker のベースライン |
| E | `Task` (subagent) | `[next: step_3]` (next-instruction) | H5: marker 形式の効果 |

D vs A の差で「Skill boundary 自体の効果」、E vs B の差で「marker 形式の効果」、C vs A の差で「Bash の効果」を分離できる。

## Primary metric: `parent_continuation_success`

各 trial の orchestrator は以下の 3 step を実行する:

1. **Step 1**: `tests/step0-experiment/results/{variant}/trial-{N}-step1.flag` ファイルを `touch` で作る (parent が orchestrator を起動した証拠)
2. **Step 2**: boundary tool を呼び出し、completion marker (variant E は next-instruction marker) を含むテキストを return させる
3. **Step 3**: boundary 結果を受けて、`trial-{N}-step3.flag` を `touch` で作る (parent が boundary 後に next action を取った証拠)

**判定**:
- step1 と step3 の両方の flag が存在 → `parent_continuation_success = true`
- step1 のみ (step3 なし) + session が `stop_reason: end_turn` で終了 → `parent_continuation_success = false` (= implicit stop)
- step1 すらない → 異常 trial (除外)

## Falsification thresholds

| Hypothesis | Falsification condition |
|---|---|
| H2 (Task isolation) | Variant B で 20 trial 中 **2 回以上**失敗 → Task isolation 不十分 |
| H3 (Bash worker) | Variant C で 20 trial 中 **2 回以上**失敗 → Bash worker でも防げない |
| H4 (Marker dominance) | A vs D の failure rate 差が **小さい** (< 5 percentage points) → boundary tool より marker phrasing が dominant |
| H5 (Non-completion marker) | E vs B の failure rate 差が **大きい** (> 30 percentage points) → marker phrasing の効果が大きい |

## Controls (全 variant 共通)

各 trial で以下を fixed control として固定する。`scripts/preflight.sh` で検証:

- 同 Claude Code version (CLI version を `claude --version` で取得)
- 同 model (Opus 4.7、`~/.claude/settings.json` 確認)
- 同 plugin root (`/home/akiyoshi/Projects/personal/cc-rite-workflow`、marketplace cache 無効化)
- 同 git commit hash
- 同 `rite-config.yml`
- `rite@rite-marketplace: false` 設定済み

## ディレクトリ構造

実 Skill ツール / Task agent の発火に slash command/agent 登録が必要なため、fixture は plugin 配下に置く。本ディレクトリは補助スクリプトと結果置き場のみ。

```
plugins/rite/
├── commands/test/step0/
│   ├── a-orchestrator.md    # /rite:test:step0:a-orchestrator
│   ├── a-subskill.md        # /rite:test:step0:a-subskill (Variant A の child skill)
│   ├── b-orchestrator.md    # /rite:test:step0:b-orchestrator
│   ├── c-orchestrator.md
│   ├── d-orchestrator.md
│   └── e-orchestrator.md
├── agents/
│   ├── test-step0-b.md      # Variant B/E の subagent (Task tool spawn)
│   └── test-step0-e.md      # Variant E の subagent (non-completion marker emit)
└── scripts/test/
    └── step0-worker.sh      # Variant C の bash worker

tests/step0-experiment/
├── README.md (本ファイル)
├── HOW-TO-RUN.md            # 坂口さん向け実機実行手順書
├── variants/
│   ├── a-skill-completion/README.md      # variant 詳細説明
│   ├── b-task-completion/README.md
│   ├── c-bash-completion/README.md
│   ├── d-inline-completion/README.md
│   └── e-task-non-completion/README.md
├── scripts/
│   ├── preflight.sh         # marketplace cache 検出 + 環境ロック
│   ├── observe.sh           # JSONL parser, parent_continuation_success 判定
│   ├── record-trial.sh      # 1 trial 完了時に呼ぶ記録ヘルパー
│   └── aggregate.sh         # 全 variant の集計と falsification 判定
└── results/                 # gitignore (.gitkeep のみ commit)
    └── {variant}/trial-{N}.json
```

## 関連 doc

- 上位 plan: `/home/akiyoshi/.claude/plans/rite-issue-create-rite-issue-start-rite-lovely-snowglobe.md`
- 結果レポート (実機実行後に埋める): `docs/investigations/step0-results.md`
- 操作手順書: `tests/step0-experiment/HOW-TO-RUN.md`

## 注意事項

- 本ディレクトリの fixture は **実験専用**。プロダクションコード (`plugins/rite/`) には影響しない設計
- variants の `.md` ファイルは Claude Code セッション内で `Read` で読み込んで実行する想定。Slash command 化は不要
- 各 trial は独立した Claude Code セッションで実行する (前 trial の context が漏れないように `/clear` 必須)
