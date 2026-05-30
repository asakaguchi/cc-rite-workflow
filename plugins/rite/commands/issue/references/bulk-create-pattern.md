# Bulk Sub-Issue Creation Pattern — spec 駆動 helper 委譲と post-loop sanity check

> **SoT scope**: `/rite:issue:create` の XL 分解パスにおける **bulk Sub-Issue creation の設計判断** と **post-loop sanity check 設計** の規約集。bash literal の SoT は `scripts/decompose-issues.sh` (native while-loop) に集約する。placeholder spec (親+Sub の入力 JSON) は `commands/issue/create.md` ステップ 5.3-5.5 (B) が Write tool で生成する spec.json が SoT。本 reference は規約・理由付け・anti-pattern を documents し、code literal を持たない (二重 SoT が drift を生む経験則に基づく)。

## 位置づけ

`commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 は `scripts/decompose-issues.sh` への委譲として実装される。LLM は (A) `mktemp` で workdir 確保 → (B) **Write tool** で各 raw body ファイルと spec.json を生成 → (C) `decompose-issues.sh --spec <spec.json>` を単一呼び出し、の 3 段で実行する。本 reference はこの委譲先 helper の設計判断 (なぜ親+Sub 作成を一つの native loop に集約するか、なぜ post-loop sanity check が必須か、なぜ Pre-amble + Per-Sub-Issue body 分割が anti-pattern か) を集約する。実 bash literal は `scripts/decompose-issues.sh` を、spec.json スキーマと placeholder 配置は create.md を参照する。

## なぜ親+Sub 作成を単一 helper に集約するか (AC-1 enforcement boundary)

`scripts/decompose-issues.sh` は 3 つの部分から構成される:

1. **Pre-amble** (1 回のみ実行): counter (`created_count` / `failed_count` / `link_failures`)、accumulator (`created_numbers`)、`expected_sub_count` (post-loop sanity check の比較基準、spec の `.sub_issues | length` から代入)、jq 派生の `sub_labels_json` を初期化する
2. **Per-Sub-Issue loop** (spec の `sub_issues[]` 要素数 N 回繰り返し実行): 各要素から Sub-Issue を作成し、成功時に link-sub-issue.sh を呼び出し、counter / accumulator を更新する
3. **Post-loop sanity check** (1 回のみ実行): counter と `expected_sub_count` を比較して zero-iteration / loop-abort の silent failure を検出する (詳細は後述 "Post-loop sanity check の必須性")

3 部分は helper 内の単一 shell process で連続実行されるため、Pre-amble で宣言した Bash 変数 (配列を含む) が loop と post-loop に渡る scope 連続性は **native loop が構造的に充足する**。委譲前のインライン block では「同一の Bash tool invocation で連続実行されること」が orchestrator 側の MUST 要件だったが、helper 化により counter/accumulator は helper の shell process 内で完結し、orchestrator から見れば `decompose-issues.sh` 呼び出しは 1 回の Bash tool invocation である。

仮にこの scope 連続性が崩れる (Pre-amble・loop・post-loop が別 shell process に分割される) と counter が常に初期値のままになり、以下の silent failure が連鎖する:

- zero-iteration guard が false-positive で発火する (`created_count==0`)
- loop-abort sanity check (`created_count + failed_count != expected_sub_count`) が意味を成さなくなる
- accumulator (`created_numbers`) が空のままで CONTEXT marker `SUB_ISSUE_NUMBERS=${created_numbers[*]}` が空文字列になり、ステップ 5.5 の Tasklist 編集が空 list を書き込んだまま完了レポートに到達する (silent AC-1 violation)

これが本コマンドにおける silent-skip リスク最大の箇所であり、helper を Pre-amble + Per-Sub-Issue loop + post-loop sanity check の 3 つに分割して別呼び出しにすることは **いかなる事情でも許容されない**。委譲後はこの 3 部分が `scripts/decompose-issues.sh` 一本の native shell として実体配置されるため、本制約は構造的に満たされる。

## spec.json と runtime bash 変数の分離

create.md のブロックは LLM が spec.json を生成して helper に渡す形式を採る。LLM が処理する値と、helper の runtime bash 変数として scope に存在する記号を混同しないため、両者を明確に分ける:

| 種類 | 例 | 展開タイミング |
|------|----|---------------|
| spec.json 共有フィールド (1 回設定) | `labels_csv` / `projects.owner` / `repo` / `projects.priority` / `projects.project_number` | create.md (B) で各値を rite-config.yml / 親 Issue 等から 1 回設定 |
| spec.json `sub_issues[]` 要素 (N 件展開) | 各要素の `title` / `body_file` / `complexity` | create.md (B) で Sub-Issue 件数 `{sub_count}` だけ配列要素として LLM が展開 (各反復で実値置換) |
| LLM placeholder (create.md 側) | `{DECOMPOSE_WORKDIR}` / `{plugin_root}` / `{sub_N_title}` 等 | create.md (A)/(B)/(C) で workdir パスや反復実値に置換 |
| Runtime bash 変数 (helper 側) | `$parent_issue_number` / `$sub_number` / `$sub_labels_json` / `$created_numbers` | `decompose-issues.sh` 内で代入される shell 変数。spec のフィールドでも `{}` placeholder でもなく `$` 形式で参照する |

helper 内の bash literal を読む際は spec フィールド・`$` runtime 変数を取り違えないこと。完了レポート markdown 部分 (create.md ステップ 5.6) は別途 LLM placeholder として `{parent_issue_number}` を使う (HTML sentinel `<!-- [create:returned-to-caller:{parent_issue_number}] -->`、報告本文の `Issue #{parent_issue_number}` 等) — helper が emit する CONTEXT marker `PARENT_ISSUE_NUMBER` を LLM が literal 置換した値であり、helper 内 scope とは異なる。

## Post-loop sanity check の必須性

`scripts/decompose-issues.sh` の loop 末尾には counter ベースの 2 種類の sanity check が配置される:

| Check | 発火条件 | 役割 |
|------|---------|------|
| zero-iteration guard | `created_count == 0 && expected_sub_count > 0` | spec の `sub_issues[]` 空展開 or shell loop 失敗を WARNING として stderr emit |
| loop-abort sanity check | `created_count + failed_count != expected_sub_count` | mid-loop の jq crash / signal による iteration drop を WARNING として stderr emit |

これらが機能するためには Pre-amble での counter 初期化と loop 内での counter 更新が漏れなく実行される必要があり、これも「3 部分を単一 helper の native loop に集約する」設計の load-bearing 理由の一つ。

## Anti-pattern: Pre-amble + Per-Sub-Issue body 分割

❌ **以下の anti-pattern を絶対に行わないこと**: 委譲先 helper を解体し、Pre-amble を 1 つの Bash 呼び出しで実行して各 Sub-Issue 作成 + linkage を別々の Bash 呼び出しに分割する。

Bash variable scope は shell process 境界で消失するため、上記分割では Pre-amble で初期化した counter (`created_count` 等) と accumulator (`created_numbers`) が次の呼び出しでは見えない。各 Sub-Issue 作成呼び出しが独立した shell process で実行され、counter は常に未定義 (or 初期値 0) のまま、accumulator は常に空のまま完了レポートに到達する。post-loop sanity check はそれぞれ別の shell process でも実行されないか、実行されても counter が常に 0 のため zero-iteration guard が常に発火する。

✅ **正しい pattern**: Pre-amble + N 回の Per-Sub-Issue loop + 末尾の sanity check + fetch を **`scripts/decompose-issues.sh` 一本の native shell として実行** する。create.md は (A) workdir 確保 → (B) Write tool で spec.json 生成 → (C) `decompose-issues.sh --spec` 単一呼び出し、の 3 段でこの helper を呼び出すだけに留める。具体的な bash literal は `scripts/decompose-issues.sh` を参照する。

この scope 連続性は本コマンドにおける silent-skip リスク最大の箇所であり、helper 内 native loop として一本化することで満たされる。

## Error handling for partial failures

- Sub-Issue creation がループ途中で失敗した場合、エラーを log して `failed_count` を進め、残りの Sub-Issue 作成を継続する (per-call non-blocking)。
- linkage 失敗は `link_failures` で計上し、Sub-Issue creation 自体は成功扱い (body meta fallback が残るため AC-1 の最終防衛は親 Issue body の `## 親 Issue` メタが担う)。
- ループ完了後、ステップ 5.6 完了レポートで成功 / 失敗 / linkage 失敗の件数を報告する。
- 失敗した Sub-Issue は user が手動で `/rite:issue:create` で retry 可能。
