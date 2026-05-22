# Bulk Sub-Issue Creation Pattern — 単一 Bash invocation 要件と Anti-pattern

> **SoT scope**: `/rite:issue:create` の XL 分解パスにおける **bulk Sub-Issue creation の単一 Bash invocation 要件** と **post-loop sanity check 設計** の規約集。bash literal の SoT は `commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 統合ブロック一本に集約する。本 reference は規約・理由付け・anti-pattern を documents し、code literal を持たない (二重 SoT が drift を生む経験則に基づく)。

## 位置づけ

`commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 は単一 Bash tool invocation の連結ブロックとして実行される。本 reference はこのブロックの設計判断 (なぜ単一 invocation か、なぜ post-loop sanity check が必須か、なぜ Pre-amble + Per-Sub-Issue body 分割が anti-pattern か) を集約する。実 bash literal および placeholder の正確な配置は create.md を参照する。

## なぜ単一 Bash invocation が要件か (AC-1 enforcement boundary)

ステップ 5.4 は 2 つの部分から構成される:

1. **Pre-amble** (1 回のみ実行): counter (`created_count` / `failed_count` / `link_failures`)、accumulator (`created_numbers`)、loop index (`i`)、jq 派生の `sub_labels_json` を初期化する
2. **Per-Sub-Issue body** (ステップ 5.1 分解 list の項目数 N 回繰り返し実行): Sub-Issue を作成し、成功時に link-sub-issue.sh を inline で呼び出し、counter / accumulator を更新する

両者は同一の Bash tool invocation で実行されることが MUST 要件。Bash 変数 (配列を含む) は別々の Bash tool 呼び出し境界で消失する — Claude Code の Bash tool は各呼び出しで新規 shell process が起動するため、前の呼び出しで宣言した変数は次の呼び出しでは参照不可。

分割すると counter が常に初期値のままになり、以下の silent failure が連鎖する:

- ステップ 5.4 末尾の zero-iteration guard が false-positive で発火する (`created_count==0`)
- loop-abort sanity check (`created_count + failed_count != expected_sub_count`) が意味を成さなくなる
- accumulator (`created_numbers`) が空のままで CONTEXT marker `SUB_ISSUE_NUMBERS=${created_numbers[*]}` が空文字列になり、ステップ 5.5 の Tasklist 編集が空 list を書き込んだまま完了レポートに到達する (silent AC-1 violation)

これが本コマンドにおける silent-skip リスク最大の箇所であり、Pre-amble + Per-Sub-Issue body + post-loop sanity check の分割は **いかなる事情でも許容されない**。

## Placeholder 展開 protocol

create.md のブロックは LLM が placeholder を展開して bash literal を生成する形式を採る。LLM が処理する記号と、runtime bash 変数として scope に存在する記号を混同しないため、両者を明確に分ける:

| 種類 | 例 | 展開タイミング |
|------|----|---------------|
| LLM placeholder (1 回置換) | `{sub_count}` / `{labels_csv}` / `{owner}` / `{repo}` / `{priority}` / `{project_number}` / `{plugin_root}` | Pre-amble 部分で各 placeholder を rite-config.yml / 親 Issue 等の値で 1 回置換 |
| LLM placeholder (反復置換) | `{sub_N_title}` / `{sub_N_body}` / `{sub_N_complexity}` | Per-Sub-Issue body を複製するたびに該当反復の実値で置換 |
| LLM marker (複製範囲) | `{REPEAT_FOR_EACH_SUB_ISSUE}` ... `{END_REPEAT}` | LLM が間の Per-Sub-Issue body を ステップ 5.1 分解 list の項目数 N 回複製する範囲指定 |
| Runtime bash 変数 | `$parent_issue_number` / `$i` / `$tmpdir` / `$sub_labels_json` | ステップ 5.3 や Pre-amble で代入される shell 変数。`{}` 形式の placeholder ではないため `$` 形式で参照する |

create.md の bash literal を LLM が読む際は、`{}` placeholder と `$` runtime 変数を取り違えないこと。`{parent_issue_number}` のような書き方は placeholder と誤認させるため出現しない (実際 create.md は `$parent_issue_number` の形で参照する)。

## Post-loop sanity check の必須性

ステップ 5.4 末尾には counter ベースの 2 種類の sanity check が配置される:

| Check | 発火条件 | 役割 |
|------|---------|------|
| zero-iteration guard | `created_count == 0 && expected_sub_count > 0` | placeholder 展開失敗 or shell loop 失敗を `sub_issue_zero_iteration_loop` incident として sentinel emit |
| loop-abort sanity check | `created_count + failed_count != expected_sub_count` | mid-loop の set -e / jq crash / signal を `sub_issue_loop_abort` incident として sentinel emit |

これらが機能するためには Pre-amble での counter 初期化と Per-Sub-Issue body 内での counter 更新が漏れなく実行される必要があり、これも「単一 Bash invocation」要件の load-bearing 理由の一つ。

## Anti-pattern: Pre-amble + Per-Sub-Issue body 分割

❌ **以下の anti-pattern を絶対に行わないこと**: Pre-amble を 1 つの Bash tool 呼び出しで実行し、各 Sub-Issue 作成 + linkage を別々の Bash tool 呼び出しに分割する。

Bash variable scope は tool invocation 境界で消失するため、上記分割では Pre-amble で初期化した counter (`created_count` 等) と accumulator (`created_numbers`) が次の Bash 呼び出しでは見えない。各 Sub-Issue 作成呼び出しが独立した shell process で実行され、counter は常に未定義 (or 初期値 0) のまま、accumulator は常に空のまま完了レポートに到達する。post-loop sanity check はそれぞれ別の shell process でも実行されないか、実行されても counter が常に 0 のため zero-iteration guard が常に発火する。

✅ **正しい pattern**: Pre-amble + N 個の Per-Sub-Issue body + 末尾の sanity check + fetch を **すべて 1 回の Bash tool invocation 内で順次実行** する。具体的な bash literal は `commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 統合 bash block を参照。

create.md ステップ 5.3-5.4 本体の AC-1 critical 警告で何度繰り返されているように、この single-Bash-invocation 要件は本コマンドにおける silent-skip リスク最大の箇所である。

## Error handling for partial failures

- Sub-Issue creation がループ途中で失敗した場合、エラーを log して `failed_count` を進め、残りの Sub-Issue 作成を継続する (per-call non-blocking)。
- linkage 失敗は `link_failures` で計上し、Sub-Issue creation 自体は成功扱い (body meta fallback が残るため AC-1 の最終防衛は親 Issue body の `## 親 Issue` メタが担う)。
- ループ完了後、ステップ 5.6 完了レポートで成功 / 失敗 / linkage 失敗の件数を報告する。
- 失敗した Sub-Issue は user が手動で `/rite:issue:create` で retry 可能。
