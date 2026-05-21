# Step 0 実機実行手順書 — 坂口さん向け

このドキュメントは Plan §21.2 Step 0 (5 variant × 20 trial = 100+ 実機実行) を効率的に回すための手順書。

## 0. ⚠️ 事前に必須の修正

`preflight.sh` の検出結果 (2026-05-21 時点):

```
FAIL: rite@rite-marketplace=true in settings.json.
Per CLAUDE.md this shadows local changes. Set to false.
```

CLAUDE.md の警告:

> **`rite@rite-marketplace: false` を維持すること**: `~/.claude/settings.json` の `enabledPlugins` で `rite@rite-marketplace` が `true` になっていると、キャッシュされた古いマーケットプレイス版が優先ロードされ、ローカルの修正が一切反映されない

**Step 0 着手前に必ず修正**:

```bash
# 確認
jq '.enabledPlugins["rite@rite-marketplace"]' ~/.claude/settings.json
# → true なら NG

# 修正 (バックアップ取得後)
cp ~/.claude/settings.json ~/.claude/settings.json.bak
jq '.enabledPlugins["rite@rite-marketplace"] = false' ~/.claude/settings.json.bak > ~/.claude/settings.json
```

修正後 `bash tests/step0-experiment/scripts/preflight.sh` で再確認し、`preflight_ok=true` が出力されることを確認すること。

## 1. 事前準備 (1 回だけ実行)

```bash
cd /home/akiyoshi/Projects/personal/cc-rite-workflow

# 1. preflight 全項目を pass にする
bash tests/step0-experiment/scripts/preflight.sh
# → 最後の行が `preflight_ok=true` ならOK

# 2. 全 fixture が plugin に展開されていることを確認
ls plugins/rite/commands/test/step0/
# a-orchestrator.md a-subskill.md b-orchestrator.md c-orchestrator.md d-orchestrator.md e-orchestrator.md

ls plugins/rite/agents/ | grep test-step0
# test-step0-b.md
# test-step0-e.md

ls plugins/rite/scripts/test/
# step0-worker.sh

# 3. Claude Code を再起動 (新しい command / agent を認識させる)
# → ターミナルで `/exit` してから `claude` 再起動

# 4. 結果ディレクトリ準備
mkdir -p tests/step0-experiment/results/{a-skill-completion,b-task-completion,c-bash-completion,d-inline-completion,e-task-non-completion}
```

## 2. 1 trial の手順

各 trial は **新しい Claude Code セッション**で実行する (前 trial の context が漏れないように)。

### Step A — 環境変数を export してセッション開始

ターミナル A (記録用) で：

```bash
# variant と trial ID を決定
export RITE_STEP0_VARIANT=a-skill-completion    # a/b/c/d/e に応じて変える
export RITE_STEP0_TRIAL_ID=01                   # 01, 02, ..., 20
export RITE_STEP0_RESULTS_DIR=/home/akiyoshi/Projects/personal/cc-rite-workflow/tests/step0-experiment/results/$RITE_STEP0_VARIANT

# 同じシェルで Claude Code セッションを開始 (env が継承される)
claude code
```

### Step B — orchestrator を呼ぶ

Claude セッション内で variant に応じた slash command を実行:

| Variant | Slash command |
|---|---|
| a-skill-completion | `/rite:test:step0:a-orchestrator` |
| b-task-completion | `/rite:test:step0:b-orchestrator` |
| c-bash-completion | `/rite:test:step0:c-orchestrator` |
| d-inline-completion | `/rite:test:step0:d-orchestrator` |
| e-task-non-completion | `/rite:test:step0:e-orchestrator` |

orchestrator が 3 step を実行する (Step 1: flag → Step 2: boundary → Step 3: flag)。`Trial $RITE_STEP0_TRIAL_ID variant=X complete.` の 1 行で終わるのが成功。途中で stop してユーザー入力を求められたら **continue を入力せずそのまま 1 トライアル失敗**として記録。

### Step C — Claude セッションを終了して結果を記録

ターミナル A に戻り:

```bash
# /exit でセッション終了 (または Ctrl-D)

# 結果を記録
bash tests/step0-experiment/scripts/record-trial.sh \
  $RITE_STEP0_VARIANT $RITE_STEP0_TRIAL_ID

# 出力: results/<variant>/trial-<N>.json
```

### Step D — 次の trial へ

`RITE_STEP0_TRIAL_ID` をインクリメント (01 → 02 → ... → 20) して Step A-C を繰り返す。
20 trial が終わったら次の variant へ (a → b → c → d → e)。

## 3. 効率化のヒント

### 3.1 バッチ的に回すパターン

各 trial 間に手動操作 (セッション再起動 + slash command 入力) があるため完全自動化は難しい。最低限の効率化:

```bash
# シェル関数で 1 trial 分の env 設定を一発化
step0_trial() {
  local variant=$1 trial=$2
  export RITE_STEP0_VARIANT=$variant
  export RITE_STEP0_TRIAL_ID=$(printf '%02d' $trial)
  export RITE_STEP0_RESULTS_DIR=/home/akiyoshi/Projects/personal/cc-rite-workflow/tests/step0-experiment/results/$variant
  echo "READY: variant=$variant trial=$RITE_STEP0_TRIAL_ID"
  echo "slash command: /rite:test:step0:${variant%%-*}-orchestrator"
}
# 使い方: step0_trial a-skill-completion 1
#         claude code
#         (slash command 実行)
#         /exit
#         bash tests/step0-experiment/scripts/record-trial.sh $RITE_STEP0_VARIANT $RITE_STEP0_TRIAL_ID
```

### 3.2 1 セッションで複数 trial を回す変則実装

**非推奨** (context 汚染が起きる) だが、急ぐ場合:

- 1 セッション内で `RITE_STEP0_TRIAL_ID` を変えながら同 orchestrator を何度も呼ぶ
- ただし前 trial の出力が次の trial の判断に影響する可能性があり、結果の信頼度が下がる
- やむを得ず使う場合、各 trial 間で `/clear` を入れる

### 3.3 タイムアウト

各 trial は通常 30 秒〜2 分で終わる。5 分以上待っても完了しない場合は異常 trial として `excluded` 扱いにする。

## 4. 異常 trial の判断基準

`outcome` フィールドの種類:

| outcome | 意味 | 集計 |
|---|---|---|
| `success` | step1 と step3 の両 flag 存在 | failure rate の分母+分子 (success として) |
| `failure_implicit_stop` | step1 のみ存在、step3 なし | failure rate の分母+分子 (failure として) |
| `excluded_no_start` | step1 すら無い (orchestrator が起動失敗) | 除外 (re-trial) |

`excluded_no_start` は環境設定ミス (env var 未 export 等) なので、原因を解消して同じ trial ID で再実行。

それ以外の異常 (例: Claude が Step 1 で異常終了した、Bash error が出た等) は手動で結果ファイルに `"outcome": "excluded_anomaly"` と書き換えて備考を記入。

## 5. 全 trial 完了後

```bash
bash tests/step0-experiment/scripts/aggregate.sh
```

出力例:

```
========================================
Step 0 Aggregate Results
========================================
Variant                        Total    OK  Fail  Excl FailRate
a-skill-completion                20    18     2     0   .1000
b-task-completion                 20    20     0     0   .0000
c-bash-completion                 20    20     0     0   .0000
d-inline-completion               20    20     0     0   .0000
e-task-non-completion             20    20     0     0   .0000

Falsification verdicts:
  H2 (Task isolation):     supported
  H3 (Bash worker):        supported
  ...
```

この結果を `docs/investigations/step0-results.md` の各セクションに転記。

## 6. 採用 architecture 決定

`step0-results.md` §6 の table に沿って Step 1 以降の方針を確定。Plan §21.3 を参照:

| Step 0 結果 | 採用 path |
|---|---|
| Task isolation OK + Bash worker OK | **Hybrid 案** (推奨、Plan §17.4 / §21.1) |
| Task isolation 不可 + Bash worker OK | Bash worker 主軸 (subagent 不使用) |
| Bash worker でも failure 残存 | Alt C (marker phrasing 修正) を併用 |
| 全 variant で failure 残存 | 元の案 A (Read 経由) フォールバック |

## 7. トラブルシューティング

### 7.1 slash command が見つからない

```
/rite:test:step0:a-orchestrator → "command not found"
```

→ Claude Code を再起動して plugin 再ロード。再起動後も見つからなければ `~/.claude/settings.json` の `enabledPlugins` に "rite" が `true` で入っているか確認。

### 7.2 Task agent が見つからない

```
Agent tool error: subagent_type "test-step0-b" not registered
```

→ Claude Code 再起動。`plugins/rite/agents/test-step0-b.md` の YAML frontmatter `name: test-step0-b` を確認。

### 7.3 step1 flag が作られない

→ env var が未 export。`echo $RITE_STEP0_TRIAL_ID $RITE_STEP0_RESULTS_DIR` で確認してから Claude セッションを開始。

### 7.4 marketplace cache が残っている

`preflight.sh` を再実行して `marketplace=ok (rite@rite-marketplace=false)` を確認。trial 結果 JSON の `marketplace_rite` フィールドが `"false"` であることも `record-trial.sh` 実行後に確認する。

## 8. 関連 doc

- 上位 Plan: `/home/akiyoshi/.claude/plans/rite-issue-create-rite-issue-start-rite-lovely-snowglobe.md` §21 (最終確定 Plan)
- 実験設計: `tests/step0-experiment/README.md`
- 結果レポート: `docs/investigations/step0-results.md`
