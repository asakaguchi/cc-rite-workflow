---
description: 複数 Issue に対して open→iterate→ready→merge→cleanup を順次自律実行
---

# /rite:pr:run

1 個以上の Issue に対して `/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:ready` → `/rite:pr:merge` → `/rite:pr:cleanup` を **順次・完全自律（無確認）で実行** する。やることは以下のシーケンシャルなタスク列:

0. 引数の Issue 群でキューを初期化 / 既存キューから再開（`.rite/state/run-queue.json`）
1. キュー先頭（cursor）の Issue を取り出す（既に CLOSED なら coarse スキップ）。残りが無ければ完了通知（ステップ 7）
2. `/rite:pr:open` を invoke → PR 番号とブランチ名を取得
3. `/rite:pr:iterate` を invoke → `[review:mergeable]` まで
4. `/rite:pr:ready` を invoke
5. `/rite:pr:merge` を invoke
6. `/rite:pr:cleanup` を invoke → cursor を +1 → ステップ 1 へループ
7. 全 Issue 完了通知
8. （いずれかの段で失敗した場合）即停止して残り Issue を報告

**設計の核**: 成功する限り無確認で最後まで走り、失敗（iterate 非収束 / merge 不可 等）したら即停止する。本コマンドは flow-state の `handoff` を **一切 set しない**（iterate / cleanup が内部で使う handoff / FINALIZE と衝突させない）。継続は flat な順次ステップ構造で担保する（`/rite:pr:open` の Step 1→6 と同じ設計）。

途中で止まったら: 処理中 Issue は各 sub-skill が flow-state に phase を残すので `/rite:resume {issue}` で個別復帰する。残りキューは `.rite/state/run-queue.json` に残るので、引数省略 `/rite:pr:run` で cursor から再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。run-queue.json のパスは `state-path-resolve.sh` で解決した state root 基準とし、linked worktree を跨いでも同一ファイルを指す（各 Issue の open/cleanup が worktree を出入りしても一貫させるため）。

## Contract

**Input**: Issue number(s) — 1 個以上、空白区切り（省略時は run-queue.json から再開）
**Output**: 全 Issue 完走の完了通知（ステップ 7）、または最初の失敗での停止報告（残り Issue 含む、ステップ 8）
**自律度**: 完全自律（無確認）。merge を含め確認を挟まない。失敗時のみ停止。

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>...` | 処理対象の Issue 番号（1 個以上、空白区切り）。省略時は `.rite/state/run-queue.json` の未処理分（cursor 以降）から再開 |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_numbers}` | 引数（空白区切りの Issue 番号群。省略可） |
| `{current_issue}` | ステップ 1 の `RUN_NEXT=process; issue=` が指す Issue |
| `{pr_number}` | ステップ 2 の open 完了通知（`[pr:created:N]`）から抽出 |
| `{branch_name}` | ステップ 2 の open 完了通知「ブランチ: ...」行から抽出（ステップ 6 の cleanup に渡す） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 0: キュー初期化 / 再開判定

`.rite/state/run-queue.json`（`{issues, cursor}` の最小形）を Single Source of Truth として、引数の Issue 群と既存キューを突き合わせる。

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
queue_file="$state_root/.rite/state/run-queue.json"
mkdir -p "$(dirname "$queue_file")"

# 引数パース（"#1527, 1528" のような記号混在も許容して数値のみ抽出）
arg_str="{issue_numbers}"
arg_issues_json=$(printf '%s' "$arg_str" | grep -oE '[0-9]+' | jq -R 'tonumber' | jq -s '.' 2>/dev/null || echo '[]')
arg_count=$(echo "$arg_issues_json" | jq 'length')

if [ "$arg_count" -gt 0 ]; then
  if [ -f "$queue_file" ] && \
     [ "$(jq -cS '.issues' "$queue_file" 2>/dev/null)" = "$(echo "$arg_issues_json" | jq -cS '.')" ]; then
    cursor=$(jq -r '.cursor // 0' "$queue_file")
    echo "[CONTEXT] RUN_QUEUE=resume_match; cursor=$cursor; total=$arg_count"
  else
    # 新規 / 既存と不一致 → 上書き（古いキューは破棄）
    jq -n --argjson issues "$arg_issues_json" '{issues:$issues, cursor:0}' > "$queue_file"
    echo "[CONTEXT] RUN_QUEUE=initialized; cursor=0; total=$arg_count"
  fi
else
  if [ -f "$queue_file" ]; then
    cursor=$(jq -r '.cursor // 0' "$queue_file"); total=$(jq -r '.issues | length' "$queue_file")
    echo "[CONTEXT] RUN_QUEUE=resume_no_args; cursor=$cursor; total=$total"
  else
    echo "[CONTEXT] RUN_QUEUE=empty"
  fi
fi
```

| `RUN_QUEUE` marker | アクション |
|---|---|
| `initialized` / `resume_match` / `resume_no_args` | ステップ 1 へ進む |
| `empty` | 引数もキューも無い。使い方 `/rite:pr:run <issue_number>...` を案内して終了 |

---

## ステップ 1: 次の Issue を取り出す（coarse スキップ判定込み）

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
queue_file="$state_root/.rite/state/run-queue.json"
cursor=$(jq -r '.cursor // 0' "$queue_file")
total=$(jq -r '.issues | length' "$queue_file")

if [ "$cursor" -ge "$total" ]; then
  echo "[CONTEXT] RUN_NEXT=all-done"
else
  current=$(jq -r ".issues[$cursor]" "$queue_file")
  # coarse スキップ: 既に CLOSED の Issue（= 処理済み）は open し直さず cursor を進める
  state=$(gh issue view "$current" --json state --jq '.state' 2>/dev/null || echo "OPEN")
  if [ "$state" = "CLOSED" ]; then
    jq '.cursor += 1' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"
    echo "[CONTEXT] RUN_NEXT=skip-closed; issue=$current; new_cursor=$((cursor+1)); total=$total"
  else
    echo "[CONTEXT] RUN_NEXT=process; issue=$current; cursor=$cursor; total=$total"
  fi
fi
```

| `RUN_NEXT` marker | アクション |
|---|---|
| `process` | `issue=` を `{current_issue}` として retain → ステップ 2（open）へ |
| `skip-closed` | この Issue は既に処理済み。ステップ 1 を再実行（次の Issue へ） |
| `all-done` | 残り Issue 無し → ステップ 7（全完了通知）へ |

---

## ステップ 2: /rite:pr:open を invoke

> この skill return 後、停止せずに sentinel を判定してステップ 3 へ進む。本コマンドは handoff を使わないため、継続はこの flat 構造に依存する。

```text
skill: rite:pr:open
args: "{current_issue}"
```

| Sentinel | アクション |
|---------|-----------|
| open 完了通知（`[pr:created:N]` と「ブランチ: ...」行） | PR 番号 `N` を `{pr_number}`、ブランチ名を `{branch_name}` として retain → ステップ 3 へ |
| `[pr:create-failed]` / 完了通知に PR 番号が無い / sentinel 不在 | **失敗** → ステップ 8（段階=open） |

<!-- run orchestration: after open returns, do NOT stop — retain {pr_number}/{branch_name} and proceed to ステップ 3 -->

---

## ステップ 3: /rite:pr:iterate を invoke

> 本コマンドは iterate invoke の **前後で `flow-state.sh set` を呼ばない**（iterate 内部の handoff / FINALIZE 機構を壊さないため）。iterate は内部で review⇄fix を mergeable まで回し、完了通知を出して制御を戻す。戻った時点で handoff フィールドは空。

```text
skill: rite:pr:iterate
args: "{pr_number}"
```

| Sentinel | アクション |
|---------|-----------|
| `[review:mergeable]` | iterate 収束 → ステップ 4 へ |
| `[fix:replied-only]` | **非収束として失敗扱い** → ステップ 8（段階=iterate）。reply のみで mergeable 未到達のまま merge すると未解決指摘を握り潰すため。停止報告に続行コマンド `/rite:pr:ready {pr_number} && /rite:pr:merge {pr_number}` を案内 |
| `[fix:cancelled-by-user]` | ユーザー中断 → ステップ 8（段階=iterate） |
| `[fix:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=iterate） |

<!-- run orchestration: after iterate returns [review:mergeable], do NOT stop — proceed to ステップ 4 -->

---

## ステップ 4: /rite:pr:ready を invoke

> iterate 完走後は flow-state phase が `review`/`fix` のままのため、ready は E2E flow と判定し standalone 確認をスキップする（= 無確認自律）。run 側の追加操作は不要。

```text
skill: rite:pr:ready
args: "{pr_number}"
```

| Sentinel | アクション |
|---------|-----------|
| `[ready:returned-to-caller]` | ステップ 5 へ |
| `[ready:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=ready） |

<!-- run orchestration: after ready returns, do NOT stop — proceed to ステップ 5 -->

---

## ステップ 5: /rite:pr:merge を invoke

```text
skill: rite:pr:merge
args: "{pr_number}"
```

| Sentinel | アクション |
|---------|-----------|
| `[merge:returned-to-caller]` | ステップ 6 へ |
| `[merge:not-ready]` / `[merge:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=merge） |

<!-- run orchestration: after merge returns, do NOT stop — proceed to ステップ 6 -->

---

## ステップ 6: /rite:pr:cleanup を invoke → cursor を進める

```text
skill: rite:pr:cleanup
args: "{branch_name}"
```

> cleanup は branch / worktree 削除・Projects Status → Done・Issue close・未完タスクの follow-up Issue 化 + Projects 登録・Wiki ingest を担う。**follow-up Issue + Projects 登録は cleanup 内部に完全委譲**し、run は関与しない。

| Sentinel | アクション |
|---------|-----------|
| `[cleanup:returned-to-caller]` | この Issue 完了。下記 bash で cursor を +1 してステップ 1 へループ |
| sentinel 不在（cleanup 途中で停止） | merge は既に完了済み（成功扱い）。下記 bash で cursor を +1 してステップ 1 へ進む（cleanup の未完分は `/rite:resume {current_issue}` で個別補完できる旨を表示） |

cleanup から制御が戻ったら cursor を進める:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
queue_file="$state_root/.rite/state/run-queue.json"
jq '.cursor += 1' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"
new_cursor=$(jq -r '.cursor' "$queue_file"); total=$(jq -r '.issues | length' "$queue_file")
echo "[CONTEXT] RUN_ADVANCE; cursor=$new_cursor; total=$total"
```

`new_cursor < total` ならステップ 1 へ戻る（次の Issue を処理）。`new_cursor >= total` ならステップ 7 へ。

<!-- run orchestration: after cleanup returns, do NOT stop — advance cursor and loop back to ステップ 1 (next issue) or go to ステップ 7 -->

---

## ステップ 7: 全 Issue 完了通知

全 Issue を処理し終えたら run-queue.json を削除して完了を報告する:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
queue_file="$state_root/.rite/state/run-queue.json"
processed=$(jq -rc '.issues' "$queue_file" 2>/dev/null || echo "[]")
rm -f "$queue_file"
echo "[CONTEXT] RUN_DONE; processed=$processed"
```

`processed=` の Issue 一覧を `{processed_issues}` として完了通知に展開する:

```
## /rite:pr:run 完了

処理した Issue: {processed_issues}
全 Issue が open→iterate→ready→merge→cleanup を完走しました。

<!-- [run:all-completed] -->
```

---

## ステップ 8: 失敗時の停止報告（即停止）

いずれかのステップで失敗 sentinel を受領したら、run-queue.json を **残したまま**（cursor は失敗 Issue を指したまま）即停止して報告する。

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
queue_file="$state_root/.rite/state/run-queue.json"
cursor=$(jq -r '.cursor // 0' "$queue_file" 2>/dev/null || echo 0)
done_issues=$(jq -rc ".issues[:$cursor]" "$queue_file" 2>/dev/null || echo "[]")
remaining=$(jq -rc ".issues[$cursor:]" "$queue_file" 2>/dev/null || echo "[]")
echo "[CONTEXT] RUN_STOP; cursor=$cursor; done=$done_issues; remaining=$remaining"
```

`done=` / `remaining=` を読んで停止報告を出す:

```
## /rite:pr:run 停止

失敗した Issue: #{current_issue}（段階: {open|iterate|ready|merge|cleanup}）
失敗理由: {受領した失敗 sentinel または「sentinel 不在」}
失敗時の状態: PR #{pr_number}（{draft | open | 未作成}）

処理済み Issue: {done_issues}
未処理 Issue: {remaining_issues}

復旧:
- この Issue を続きから: /rite:resume {current_issue}
- 残りをまとめて再開: /rite:pr:run（引数省略で run-queue.json の cursor から再開）
```

> `[fix:replied-only]` で停止した場合は、停止報告に続行コマンドも併記する: `/rite:pr:ready {pr_number} && /rite:pr:merge {pr_number}`

---

## エラー時の方針

- **失敗は即停止**（成功する限り無確認で走る方針の対）。失敗 Issue の状態は各 sub-skill が flow-state に保持するため、`/rite:resume {issue}` で個別復帰できる
- run-queue.json は停止時に残す。引数省略 `/rite:pr:run` で cursor から再開する
- run は flow-state の `handoff` を使わないため、sub-skill 間（例: open 完了直後・iterate invoke 前）で turn が途切れた場合の構造ガードは持たない。これは `/rite:pr:open` のステップ間遷移と同じ前提で、各 skill invoke 直前の continuation hint（HTML コメント）と flat step 構造で継続を促す
- **前提**: 対象 Issue は事前に `/rite:pr:open` 可能な状態（open かつ品質十分）であること。closed / 親 Issue / 品質 C-D の場合は open 内部の AskUserQuestion で自律フローが止まる（open 無変更の代償。完全な無人化は保証しない）

---

## 設計判断

- **固定パイプライン特化**: 自由記述ゴールの自律解釈（汎用ゴールソルバー）はしない。rite の決定的 sentinel/handoff 設計と相性が悪いため、Issue 番号 → 固定 5 段パイプラインに限定する
- **handoff 不使用**: flow-state の `handoff` は単一フィールド + default-clear で、iterate / cleanup が内部で排他使用する。run が割り込むと sub-skill の継続保証（Stop hook 差し戻し）が壊れるため、run は handoff を一切 set しない。継続は flat step 構造に委ねる（`/rite:pr:open` と同じ）
- **phase enum を拡張しない / resume.md を変更しない**: 各 sub-skill が自分の phase を書くため、中断時の個別 Issue 復帰は既存 `/rite:resume` がそのままカバーする。run 専用 phase は持たない
- **キュー永続化**: 複数 Issue の残りキューは `state_root/.rite/state/run-queue.json`（`{issues, cursor}` の最小形）に持つ。会話コンテキストでなくディスクに置くことで compact / 中断を跨いでも残り Issue が失われない。linked worktree を跨ぐため `state-path-resolve.sh` で解決した main checkout root 基準で配置する
- **`[fix:replied-only]` は停止扱い**: iterate にとっては正常終了だが、run では mergeable 未到達とみなし merge 前に停止する（未解決指摘の握り潰し防止）
- **専用ヘルパー/hook を作らない**: run-queue.json は run.md 内 bash の `jq` 直接操作で完結する（既存の `.rite/state/` PR-state ファイルと同じく helper なし。単一セッションが順次書くため atomic は `jq → 一時ファイル → mv` で十分）
