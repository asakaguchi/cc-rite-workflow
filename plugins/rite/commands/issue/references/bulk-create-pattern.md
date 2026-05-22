# Bulk Sub-Issue Creation Pattern — 単一 Bash invocation での Pre-amble + Per-Sub-Issue body 連結

> **SoT scope**: `/rite:issue:create` の XL 分解パスにおける **bulk Sub-Issue creation の連結 bash literal** の正規定義。caller は `commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 統合ブロック (単一 Bash tool invocation で連続実行される)。
>
> **本体保持原則**: AC-1 enforcement boundary に関する critical 警告 (`single-Bash-invocation requirement` / `silent-skip risk` の 2 文) は `create.md` ステップ 5.3-5.4 本体に残す。AC-1 enforcement boundary の同 turn 警告は zero-iteration guard / loop-abort sanity check との因果関係を保つため、本体読込時に LLM が認識できる位置にある必要がある。本 reference は手順詳細とコードリテラルを集約する。

## 位置づけ

`commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 は単一 Bash tool invocation の連結ブロックとして実行される。その内訳:

| Step | 役割 | SoT |
|------|------|-----|
| ステップ 5.3 | Parent Issue 作成 (`{spec_document}` を parent body として直接使用) | `commands/issue/create.md` 本体 |
| **ステップ 5.4 (Pre-amble + Per-Sub-Issue body)** | **Bulk Creation of Sub-Issues (linkage inline)** | **本 reference** |
| ステップ 5.4 末尾 (zero-iteration guard / loop-abort sanity check) | placeholder 展開・loop 中断の sentinel 化 | `commands/issue/create.md` 本体 |
| ステップ 5.5 Step 1 | fetch 親 Issue body | `commands/issue/create.md` 本体 |
| ステップ 5.5 Step 2-3 | Tasklist 編集 + apply | `commands/issue/create.md` 本体 |
| ステップ 5.6 | Completion Report | `commands/issue/create.md` 本体 |

## なぜ単一 Bash invocation が要件か (AC-1 enforcement boundary)

ステップ 5.4 は 2 つの部分から構成され、両者は同一の Bash tool invocation で実行されることが MUST 要件:

1. **Pre-amble** (1 回のみ実行): counter (`created_count` / `failed_count` / `link_failures`) と accumulator (`created_numbers`) を初期化する
2. **Per-Sub-Issue body** (ステップ 5.1 分解 list の項目数 N 回繰り返し実行): Sub-Issue を作成し、成功時に link-sub-issue.sh を inline で呼び出し、counter / accumulator を更新する

**Bash 変数 (配列を含む) は別々の Bash tool 呼び出し境界で消失する**。これは Claude Code の Bash tool 仕様 — 各呼び出しで新規 shell process が起動するため、前の呼び出しで宣言した変数は次の呼び出しでは参照不可。

このため:

- Pre-amble + N 個の Per-Sub-Issue body + 末尾の sanity check のすべてを **1 回の Bash tool invocation 内で順次実行** する必要がある。
- 分割すると counter が常に 0 のままで、ステップ 5.4 末尾の zero-iteration guard が false-positive で発火する。逆に loop-abort sanity check は `created+failed != expected` を検出できなくなる。

> **これは本コマンドにおける silent-skip リスク最大の箇所**。Bookkeeping (counter 更新 / accumulator append) の省略 / script 分割は **いかなる事情でも許容されない**。

## Pre-amble (1 回のみ)

結合スクリプトの先頭に **1 回だけ** 配置する:

```bash
# === Loop pre-amble (このブロックは結合スクリプトの先頭で1回だけ実行) ===
# counter と accumulator は Per-Sub-Issue body の全反復で更新され、
# ステップ 5.4 末尾の zero-iteration guard / loop-abort sanity check から参照される。
created_count=0
failed_count=0
link_failures=0
created_numbers=()
expected_sub_count={sub_count}
```

## Per-Sub-Issue body (N 回複製)

ステップ 5.1 分解 list の各 Sub-Issue について、以下のブロックを **複製して同一スクリプトに連結** する。各複製ごとに `{sub_N_title}` / `{sub_N_body}` / `{sub_N_complexity}` placeholder を **その反復の実値で置換** すること。Sub-Issue 作成成功直後に同一スクリプト内で link-sub-issue.sh を inline 呼び出しする (post-loop linkage ではない):

```bash
# === Per-Sub-Issue body (N 回複製して連結。各複製ごとに placeholder を実値で置換) ===
# {sub_N_body} content is generated free-form by the LLM from the spec
# document (ステップ 5.1 で生成された設計仕様書) for the current Sub-Issue.
sub_tmpfile="$tmpdir/sub_${i}_body.md"
cat > "$sub_tmpfile" <<'SUB_BODY_EOF'
{sub_N_body}
SUB_BODY_EOF

if [ ! -s "$sub_tmpfile" ]; then
  echo "WARNING: Sub-Issue '{sub_N_title}' body が空、skip" >&2
  failed_count=$((failed_count + 1))
else
  sub_result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
      --arg title "{sub_N_title}" \
      --arg body_file "$sub_tmpfile" \
      --argjson labels "$sub_labels_json" \
      --argjson enabled true \
      --argjson project_number {project_number} \
      --arg owner "{owner}" \
      --arg status "Todo" \
      --arg priority "{priority}" \
      --arg complexity "{sub_N_complexity}" \
      --arg iter_mode "none" \
      --arg source "xl_decomposition" \
      '{
        issue: { title: $title, body_file: $body_file, labels: $labels },
        projects: {
          enabled: $enabled,
          project_number: $project_number,
          owner: $owner,
          status: $status,
          priority: $priority,
          complexity: $complexity,
          iteration: { mode: $iter_mode }
        },
        options: { source: $source, non_blocking_projects: true }
      }')" 2>&1)
  create_rc=$?
  if [ $create_rc -ne 0 ]; then
    echo "WARNING: Sub-Issue '{sub_N_title}' の作成に失敗: $sub_result" >&2
    failed_count=$((failed_count + 1))
  else
    sub_number=$(printf '%s' "$sub_result" | jq -r '.issue_number // empty')
    if [ -z "$sub_number" ] || [ "$sub_number" = "null" ]; then
      echo "WARNING: Sub-Issue '{sub_N_title}' の result に issue_number 無し" >&2
      failed_count=$((failed_count + 1))
    else
      # link-sub-issue.sh は non-blocking failure 時に exit 0 + status="failed" を返す契約のため、
      # bash exit code ではなく JSON stdout の `.status` を inspect すること。canonical SoT は
      # `references/sub-issue-link-handler.md` Variant B (counting)。
      link_result=$(bash {plugin_root}/scripts/link-sub-issue.sh \
          "{owner}" "{repo}" "$parent_issue_number" "$sub_number" 2>&1) || link_result=$(jq -n \
            --arg err "$link_result" \
            '{status:"failed",message:"link-sub-issue.sh fatal exit",warnings:[$err]}')
      link_status=$(printf '%s' "$link_result" | jq -r '.status // "failed"' 2>/dev/null || echo "failed")
      link_msg=$(printf '%s' "$link_result" | jq -r '.message // ""' 2>/dev/null || echo "")
      case "$link_status" in
        ok|already-linked)
          echo "✅ $link_msg"
          ;;
        failed)
          printf '%s' "$link_result" | jq -r '.warnings[]?' 2>/dev/null \
            | while read -r w; do echo "⚠️ $w" >&2; done
          echo "⚠️ Sub-issues API linkage failed for #$sub_number; body meta fallback in place" >&2
          link_failures=$((link_failures + 1))
          ;;
        *)
          # 未知 status を silent 通過させない (linkage の正否が報告から抜けると AC-1 が silent 違反)
          echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
          link_failures=$((link_failures + 1))
          ;;
      esac

      created_numbers+=("$sub_number")
      created_count=$((created_count + 1))
    fi
  fi
fi
# === Per-Sub-Issue body 終了。次の Sub-Issue があれば、ここに次の複製を連結する ===
```

## Post-loop sanity checks

ステップ 5.4 末尾には counter ベースの 2 種類の sanity check を配置する。本 reference の範囲外だが、Pre-amble で初期化した counter / accumulator の設計はこの 2 種が機能することを前提とする:

| Check | 発火条件 | 役割 |
|------|---------|------|
| zero-iteration guard | `created_count == 0 && expected_sub_count > 0` | placeholder 展開失敗 or shell loop 失敗を `sub_issue_zero_iteration_loop` incident として sentinel emit |
| loop-abort sanity check | `created_count + failed_count != expected_sub_count` | mid-loop の set -e / jq crash / signal を `sub_issue_loop_abort` incident として sentinel emit |

このため Pre-amble での `expected_sub_count={sub_count}` 設定 と Per-Sub-Issue body 内で `created_count` / `failed_count` を漏れなく更新することが load-bearing となる。

## Placeholder descriptions

Per-Sub-Issue body の placeholder は以下の通り:

| Placeholder | 値の source |
|-------------|-------------|
| `{sub_N_title}` | ステップ 5.1 分解 list の各エントリの title |
| `{sub_N_body}` | LLM が ステップ 5.1 設計仕様書 (該当 Sub-Issue 部分) から該当反復の値で free-form 生成 |
| `{sub_N_complexity}` | ステップ 5.1 で見積もった complexity (XS / S / M / L / XL の per-Sub-Issue 値) |
| `{priority}` | 親 Issue から継承 |
| `{owner}` | `github.projects.owner` (`rite-config.yml`) または `gh repo view --json owner --jq '.owner.login'` |
| `{repo}` | `gh repo view --json name --jq '.name'`。link-sub-issue.sh 呼び出しで必須。欠落すると GraphQL `repository(owner:..., name:"{repo}")` lookup が "Could not resolve to a Repository" で失敗し、AC-1 が silent 違反される (per-call 失敗が non-blocking なため)。 |
| `{parent_issue_number}` | ステップ 5.3 で作成した親 Issue 番号 |
| `{project_number}` | `github.projects.project_number` (`rite-config.yml`) |
| `{plugin_root}` | [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) で解決 |

## Error handling for partial failures

- Sub-Issue creation がループ途中で失敗した場合、エラーを log して `failed_count` を進め、残りの Sub-Issue 作成を継続する (per-call non-blocking)。
- linkage 失敗は `link_failures` で計上し、Sub-Issue creation 自体は成功扱い (body meta fallback が残るため AC-1 の最終防衛は親 Issue body の `## 親 Issue` メタが担う)。
- ループ完了後、ステップ 5.6 完了レポートで成功 / 失敗 / linkage 失敗の件数を報告する。
- 失敗した Sub-Issue は user が手動で `/rite:issue:create` で retry 可能。

## Anti-pattern: Pre-amble + Per-Sub-Issue body 分割

❌ **以下の anti-pattern を絶対に行わないこと**:

```
# Bash tool 呼び出し 1 (Pre-amble のみ)
created_count=0
failed_count=0
link_failures=0
created_numbers=()
expected_sub_count={sub_count}

# Bash tool 呼び出し 2 (Sub-Issue 1 作成 + linkage)
... (counter は 0 にリセットされている、accumulator は空)

# Bash tool 呼び出し 3 (Sub-Issue 2 作成 + linkage)
... (依然として counter=0、accumulator は空)
```

Bash variable scope は tool invocation 境界で消失するため、上記分割では `created_count` / `created_numbers` が常に初期値に戻ってしまう。ステップ 5.4 末尾の zero-iteration guard が常に発火し (created_count==0)、loop-abort sanity check は意味を成さなくなる。CONTEXT marker (`SUB_ISSUE_NUMBERS=${created_numbers[*]}`) も常に空文字列を返し、ステップ 5.5 の Tasklist 編集が空 list を書き込むまま完了レポートに到達する。

✅ **正しい pattern**:

```
# Bash tool 呼び出し 1 (Pre-amble + Sub-Issue 1 (作成+linkage) + Sub-Issue 2 (作成+linkage) + ... + Sub-Issue N + post-loop sanity check を全部連結)
created_count=0
failed_count=0
link_failures=0
created_numbers=()
expected_sub_count={sub_count}

# (Sub-Issue 1 の Per-Sub-Issue body — 作成 + link-sub-issue.sh inline + counter 更新)
sub_tmpfile="$tmpdir/sub_1_body.md"
cat > "$sub_tmpfile" <<'SUB_BODY_EOF'
{sub_1_body}
SUB_BODY_EOF
... (link-sub-issue.sh inline 呼び出し) ...
created_numbers+=("$sub_number")
created_count=$((created_count + 1))

# (Sub-Issue 2 の Per-Sub-Issue body — 同型)
...

# ... (Sub-Issue N まで)

# (post-loop sanity check は ステップ 5.4 末尾で同一スクリプト内に実行)
if [ "$created_count" -eq 0 ] && [ "$expected_sub_count" -gt 0 ]; then
  bash {plugin_root}/hooks/workflow-incident-emit.sh --type sub_issue_zero_iteration_loop ...
fi
```

`commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 統合 bash block の AC-1 critical 警告で何度繰り返されているように、この single-Bash-invocation 要件は **本コマンドにおける silent-skip リスク最大の箇所** である。
