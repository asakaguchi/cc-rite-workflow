# Pre-check List — Sub-skill Return Routing & Turn Termination Gate

> **Source of Truth**: 本ファイルは `/rite:issue:create` ワークフロー orchestrator (`create.md`) の **Pre-check list (Issue #552)** の SoT である。Item 0 (routing dispatcher) と Item 1-3 (state checks) を集約し、2 種類の `grep -F` 呼び出し + ERE 注意書き・4 sentinel literal (2 form 族) ・場面 (a) / (b) の評価意味分岐を 1 ファイルに閉じ込めることで `create.md` 本体の認知負荷を下げる。`create.md` Sub-skill Return Protocol セクションは本ファイルへ参照する。
>
> **抽出経緯**: Pre-check list の Item 0/1/2/3 は grep パターン × sentinel 形式 × 場面 (a)/(b) 評価意味反転の組合せが多く、`create.md` 本体に inline 展開すると LLM の一読理解を阻害していたため本 reference に抽出 (Issue #773 / #768 P1-3 / P3-9)。現状: **2 回の `grep -F` 呼び出し + 4 sentinel literal (`[interview:skipped]` / `[interview:completed]` / `[interview:error]` の bare bracket 族 + `[create:completed:{N}]` の HTML-comment 族 の 2 form 族) + 場面 (a)/(b)**。`[CONTEXT] INTERVIEW_DONE=1` plain-text marker と HTML-comment form `<!-- [interview:*] -->` は parent-routing pattern 移行 (ADR `docs/designs/parent-routing-unification.md`) で廃止され、`[interview:*]` は bare bracket form に統一済。`[interview:error]` は catastrophic Pre-flight failure を表す halt sentinel として parent-routing pattern と同時に追加された (詳細は ADR 参照)。
>
> **Enforcement coupling**: protocol violation 時は `manual_fallback_adopted` workflow_incident sentinel が **stdout** に emit され (`workflow-incident-emit.sh:110,113` の `printf '[CONTEXT] WORKFLOW_INCIDENT=1; ...'`)、Claude Code Bash tool 経由で conversation context にマージされて Phase 5.4.4.1 で grep 検出される (AC-7)。historical: 旧 `stop-guard.sh` (撤去済み、commit `e2dfae0`) が場面 (b) で機械検証していたが、stop hook 撤去後は post-hoc workflow_incident 検出に責務が集約された。

## Evaluation context (2 場面で同じチェックリストを使う)

| 場面 (a): sub-skill return 直後 | 場面 (b): turn 終了直前 |
|---|---|
| まだワークフロー中途。`NO` は「次の継続ステップを実行すべき」を意味する | 終端到達確認。`NO` は **protocol violation** (工程を飛ばして停止しようとしている) |

場面 (a) では Item 1-3 が `NO` でも正常 (まだ Issue 未作成段階)。場面 (b) では 4 項目すべて `YES` が turn 終了の必要条件。

## Procedure

Item 0 は **routing dispatcher** (YES/NO ではなく tag に応じて経路を選ぶ前段処理)。Item 0 を最優先で evaluate し、該当する経路に進んだ後、場面 (b) では **Item 1-3 が YES/NO で評価される状態チェック**。turn 終了の可否は Item 1-3 のみを集計する。

| # | Check (種別) | If YES/NO / routing, do |
|---|-------------|------------------------|
| 0 | **Routing dispatcher** (状態質問ではない): 直前の sub-skill return tag は何か? | Grep the recent output for `[interview:skipped]` / `[interview:completed]` / `[interview:error]` / `[create:completed:{N}]`。`[interview:*]` は **bare bracket form** (parent-routing pattern、ADR `docs/designs/parent-routing-unification.md` 参照)、`[create:completed:*]` は HTML-comment form `<!-- [create:completed:N] -->`。推奨形式は 2 回の `grep -F` 呼び出し: `grep -F '[create:completed:'`、`grep -F '[interview:'`。ERE を使う場合は `grep -E '\[(interview\|create):[a-z:0-9]+\]'` **ではなく** `grep -E '\[(interview|create):[a-z:0-9]+\]'` (unescaped pipe — ERE では `\|` がリテラル `|` として解釈されるため alternation として機能しない、#582 で検出)。`[interview:skipped]` / `[interview:completed]` のいずれかが matched 時点で **continuation trigger** として扱う — Phase 2 (Task Decomposition Decision) へ進む (sub-skill が flow state を `create_post_interview` に書込済のため caller-side mandatory after section は不要、parent-routing pattern)。`[interview:error]` matched: catastrophic Pre-flight failure (詳細は `create-interview.md` "`[interview:error]` halt 判定ルール" 表参照) — Phase 2 進入禁止、manual intervention を要求して halt する。If `[create:completed:{N}]` matched: run 🚨 Mandatory After Delegation self-check (Step 1/2 no-ops when marker is present, Step 3 is idempotent output)。If tag が上記いずれでもない / 無い: 通常の Phase 進行中なので Item 1-3 を評価 (場面 (a) は NO でも legitimate)。未知 tag (unexpected return format): manual 停止して diag log を確認。**本 Item は YES/NO 集計から除外** — ルーティング前段として機能する。 |
| 1 | **State check**: `[create:completed:{N}]` が HTML コメントまたはベアブラケット形式で最終行 (あるいは末尾近傍) に出力済みか? | 推奨形式: `grep -F '[create:completed:'` (fixed string で HTML コメント内の string も matchable)。ERE 使用時は `grep -E '\[create:completed:[0-9]+\]'` (`-E` flag 必須 — BRE では `[0-9]+` が「1 個の数字 + リテラル `+`」と解釈され sentinel にマッチしない、#582 で検出)。**注意**: bracket-unescaped 形式 `[create:completed:[0-9]+]` は character class として誤解釈されるため使用禁止。場面 (a) では `NO` でも legitimate — 次の Pre-write + sub-skill invocation に進む。場面 (b) では `NO` は terminal sub-skill が未完了 — Mandatory After Delegation Step 3 (defense-in-depth として完了メッセージ + 次のステップ + HTML コメント sentinel を出力) を実行。 |
| 2 | **State check**: ユーザー向け完了メッセージが表示済みか? (3 形式のいずれか 1 つを含めば YES) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal sub-skill の完了メッセージが欠落 — Mandatory After Delegation Step 3 を実行 (idempotent)。**識別 substring**: 3 形式は以下の排他的な substring で識別可能 — register: `を作成しました:` (コロン付き URL), decompose: `を分解して` (中間句), orchestrator fallback: `を作成しました` かつ `:` を含まない。いずれか 1 形式の識別 substring を含めば YES 判定。 |
| 3 | **State check**: flow state が deactivate 済みか? (`active: false`, `phase: create_completed`) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal state 未到達 — terminal sub-skill を呼ぶか Mandatory After Delegation Step 2 を実行。 |

> **Note — Positional 制約 (collision-safe matching for Item 0 dispatcher)**: bare bracket form は LLM narrative 内に anti-pattern example (`[WRONG] <LLM output: "[interview:skipped]">` 等) や migration note (backtick-quoted literal) として出現しうるため、dispatcher の grep は **直近の sub-skill 出力範囲** に限定すること。具体的には (a) **fenced code block 内** (` ``` `〜` ``` ` の間) のマッチは無視する、(b) **直近 assistant turn の末尾** (sub-skill return 直後) のマッチを優先採用する。HTML-comment form (`[create:completed:*]`) は rendered narrative では出現しにくいため本制約の影響は小さいが、bare bracket form (`[interview:*]`) は narrative quote と区別がつきにくい点に注意。

## Rule

**Item 1-3 すべて `YES`** が turn 終了の必要条件 **ただし場面 (b) においてのみ**。Item 0 は routing dispatcher で YES/NO 集計には含まれない (経路選択が完了すれば Item 1-3 の evaluation に進む)。場面 (a) では Item 1-3 の `NO` は「次のステップに進め」を意味する正常シグナル。Item 1-3 全 `YES` は terminal state (Issue 作成完了 + sentinel 出力 + flow-state deactivate) を保証する。

## Responsibility split

本 Pre-check list は turn 終了直前の手続的検証、`create.md` の Anti-pattern / Correct-pattern sections は sub-skill return 直後の推奨/禁止パターン (重複ではなく補完関係)。Pre-check list の各項目が `NO` の場合は Anti-pattern のルール (「turn を閉じない」) に従い即時継続すること。

## Self-check alias (後方互換)

`Has [create:completed:{N}] been output?` = Pre-check Item 1。下流の Mandatory After sections から本 Pre-check list を参照する際は Item 1-3 の終端条件をまとめて評価する。
