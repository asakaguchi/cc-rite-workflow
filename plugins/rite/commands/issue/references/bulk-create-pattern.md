# Bulk Sub-Issue Creation Pattern — 単一 Bash invocation での Pre-amble + Per-Sub-Issue body + linkage 連結

> **SoT scope**: `/rite:issue:create` の XL 分解パスにおける **bulk Sub-Issue creation の連結 bash literal** の正規定義。caller は `commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 統合ブロック (単一 Bash tool invocation 内で連続実行される)。
>
> **本体保持原則**: AC-1 enforcement boundary に関する critical 警告 (`single-Bash-invocation requirement` / `silent-skip risk` の 2 文) は `create.md` ステップ 5.3-5.4 本体に残す。AC-1 enforcement boundary の同 turn 警告は空配列 fail-fast との因果関係を保つため、本体読込時に LLM が認識できる位置にある必要がある。本 reference は手順詳細とコードリテラルを集約する。

## 位置づけ

`commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 は単一 Bash tool invocation の連結ブロックとして実行される。その内訳:

| Step | 役割 | SoT |
|------|------|-----|
| ステップ 5.3 | Create the Parent Issue | `commands/issue/create.md` 本体 (作成 bash literal は `{spec_document}` を parent body として直接使用) |
| **ステップ 5.4 (Pre-amble + Per-Sub-Issue body)** | **Bulk Creation of Sub-Issues** | **本 reference** |
| ステップ 5.4 (continuation: Sub-Issues Linkage) | Sub-Issues API Linkage (Mandatory) | `commands/issue/create.md` 本体 + [`graphql-helpers.md`](../../../references/graphql-helpers.md#addsubissue-helper) |
| ステップ 5.5 Step 2-3 | Tasklist 編集 + apply | `commands/issue/create.md` 本体 |
| ステップ 5.6 | Completion Report | `commands/issue/create.md` 本体 |

本 reference は **ステップ 5.4 (Pre-amble + Per-Sub-Issue body の連結 bash literal)** の正規定義を集約する。

## なぜ単一 Bash invocation が要件か (AC-1 enforcement boundary)

ステップ 5.4 は 2 つの部分から構成され、両者は同一の Bash tool invocation で実行されることが MUST 要件:

1. **Pre-amble** (1 回のみ実行): accumulator arrays (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS`) を宣言する
2. **Per-Sub-Issue body** (ステップ 5.1 分解 list の項目数 N 回繰り返し実行): Sub-Issue を作成し accumulator に append する

**Bash 変数 (配列を含む) は別々の Bash tool 呼び出し境界で消失する**。これは Claude Code の Bash tool 仕様 — 各呼び出しで新規 shell process が起動するため、前の呼び出しで宣言した変数は次の呼び出しでは参照不可。

このため:

- Pre-amble + N 個の Per-Sub-Issue body + linkage のすべてを **1 回の Bash tool invocation 内で順次実行** する必要がある。
- 分割すると Sub-Issues API linkage が空配列を参照することになり、**linkage が silent skip され AC-1 が違反される** (linkage 失敗は per-call で non-blocking なため、log を見落とすと silent regression になる)。
- linkage が AC-1 enforcement boundary であり、空配列ガードで `exit 1` する fail-fast が最終防御層として機能する。

> **これは本コマンドにおける silent-skip リスク最大の箇所**。Bookkeeping (accumulator append) の省略 / script 分割は **いかなる事情でも許容されない**。

## Pre-amble (1 回のみ)

結合スクリプトの先頭に **1 回だけ** 配置する:

```bash
# === Loop pre-amble (このブロックは結合スクリプトの先頭で1回だけ実行) ===
# SUB_ISSUE_NUMBERS / SUB_ISSUE_URLS は Per-Sub-Issue body の全反復で蓄積され、
# 同一 Bash ツール呼び出し内の linkage 処理から参照される。
SUB_ISSUE_NUMBERS=()
SUB_ISSUE_URLS=()
```

## Per-Sub-Issue body (N 回複製)

ステップ 5.1 分解 list の各 Sub-Issue について、以下のブロックを **複製して同一スクリプトに連結** する。各複製ごとに `{sub_issue_title}` / `{sub_issue_body}` / `{estimated_complexity}` placeholder を **その反復の実値で置換** すること:

```bash
# === Per-Sub-Issue body (N 回複製して連結。各複製ごとに placeholder を実値で置換) ===
# {sub_issue_body} content is generated free-form by the LLM from the spec
# document (ステップ 5.1 で生成された設計仕様書) for the current Sub-Issue.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{sub_issue_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty for Sub-Issue '{sub_issue_title}'" >&2
else
  result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
    --arg title "{sub_issue_title}" \
    --arg body_file "$tmpfile" \
    --argjson projects_enabled {projects_enabled} \
    --argjson project_number {project_number} \
    --arg owner "{owner}" \
    --arg priority "{priority}" \
    --arg complexity "{estimated_complexity}" \
    --arg iter_mode "none" \
    '{
      issue: { title: $title, body_file: $body_file },
      projects: {
        enabled: $projects_enabled,
        project_number: $project_number,
        owner: $owner,
        status: "Todo",
        priority: $priority,
        complexity: $complexity,
        iteration: { mode: $iter_mode }
      },
      options: { source: "xl_decomposition", non_blocking_projects: true }
    }'
  )")

  if [ -z "$result" ]; then
    echo "ERROR: create-issue-with-projects.sh returned empty result for Sub-Issue '{sub_issue_title}'" >&2
    # Per-iteration body is concatenated as a flat sequence (not wrapped in a
    # loop), so `continue` would be a bash syntax error here. The else-branch
    # below handles the skip without changing control-flow structure.
  else
    sub_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
    sub_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
    sub_project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
    printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done

    # === MANDATORY: 配列に蓄積（後続 linkage が参照） ===
    # 数値であることを検証してから追加（"null" や空文字を弾く）
    if [[ "$sub_issue_number" =~ ^[0-9]+$ ]]; then
      SUB_ISSUE_NUMBERS+=("$sub_issue_number")
      SUB_ISSUE_URLS+=("$sub_issue_url")
    else
      echo "⚠️ Sub-Issue '{sub_issue_title}' の番号が不正のため linkage 配列に追加しません: '$sub_issue_number'" >&2
    fi
  fi
fi
# === Per-Sub-Issue body 終了。次の Sub-Issue があれば、ここに次の複製を連結する ===
```

> **Alternative (advanced)**: 明示的な loop 構造を好む場合、上記 Per-Sub-Issue body を `for sub_entry in ...; do ... done` で wrap し、ステップ 5.1 分解 list を bash array entries として展開する形でも実装可能。その場合は else-branch skip ではなく `continue` が syntactically valid となる。**Pre-amble が 1 回だけ実行され、すべての反復が同一 Bash tool invocation で実行される** という contract を満たせばどちらの approach も許容。

## Placeholder descriptions

Per-Sub-Issue body の placeholder は以下の通り:

| Placeholder | 値の source |
|-------------|-------------|
| `{sub_issue_title}` | ステップ 5.1 分解 list の各エントリの title |
| `{sub_issue_body}` | LLM が ステップ 5.1 設計仕様書 (該当 Sub-Issue 部分) から該当反復の値で free-form 生成 |
| `{estimated_complexity}` | ステップ 5.1 で見積もった complexity (XS / S / M / L / XL の per-Sub-Issue 値) |
| `{priority}` | 親 Issue から継承 |
| `{owner}` | `github.projects.owner` (`rite-config.yml`) または `gh repo view --json owner --jq '.owner.login'` |
| `{repo}` | `gh repo view --json name --jq '.name'`。linkage 呼び出しで必須。欠落すると GraphQL `repository(owner:..., name:"{repo}")` lookup が常に "Could not resolve to a Repository" で失敗し、AC-1 が silent 違反される (per-call 失敗が non-blocking なため)。 |
| `{parent_issue_number}` | ステップ 5.3 で作成した親 Issue 番号 (Sub-Issues 作成対象) |
| `{projects_enabled}` | `rite-config.yml` の `github.projects.enabled` が `true` なら `true`、それ以外 `false` |
| `{project_number}` | `github.projects.project_number` (`rite-config.yml`) |
| `{plugin_root}` | [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) で解決 |

## Error handling for partial failures

- Sub-Issue creation がループ途中で失敗した場合、エラーを log して残りの Sub-Issue 作成を継続する (per-call non-blocking)。
- ループ完了後、ステップ 5.6 完了レポートで **どの Sub-Issue が成功し、どの Sub-Issue が失敗したか** を報告する。
- 失敗した Sub-Issue は user が手動で `/rite:issue:create` で retry 可能。

各 Sub-Issue 作成成功後の post-processing:

1. `sub_issue_url` / `sub_issue_number` を ステップ 5.5 Step 2 (Tasklist update) のために retain する
2. accumulator (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS`) に append する (後続 linkage が参照)
3. `create-issue-with-projects.sh` script が Projects 登録 + field 設定を内部で処理する

## Anti-pattern: Pre-amble + Per-Sub-Issue body 分割

❌ **以下の anti-pattern を絶対に行わないこと**:

```
# Bash tool 呼び出し 1 (Pre-amble のみ)
SUB_ISSUE_NUMBERS=()
SUB_ISSUE_URLS=()

# Bash tool 呼び出し 2 (Sub-Issue 1 作成)
... (SUB_ISSUE_NUMBERS は空配列にリセットされている)

# Bash tool 呼び出し 3 (Sub-Issue 2 作成)
... (依然として空配列)
```

Bash variable scope は tool invocation 境界で消失するため、上記分割では `SUB_ISSUE_NUMBERS` は常に空のままで、linkage が空配列ガードで `exit 1` する。fail-fast が無ければ、AC-1 (parent-child linkage) が silent 違反されたまま完了レポートまで到達する。

✅ **正しい pattern**:

```
# Bash tool 呼び出し 1 (Pre-amble + Sub-Issue 1 + Sub-Issue 2 + ... + Sub-Issue N + linkage を全部連結)
SUB_ISSUE_NUMBERS=()
SUB_ISSUE_URLS=()

# (Sub-Issue 1 の Per-Sub-Issue body)
tmpfile=$(mktemp); trap ...
... SUB_ISSUE_NUMBERS+=("$sub_issue_number") ...

# (Sub-Issue 2 の Per-Sub-Issue body)
tmpfile=$(mktemp); trap ...
... SUB_ISSUE_NUMBERS+=("$sub_issue_number") ...

# ... (Sub-Issue N まで)

# (linkage を同一スクリプトで実行)
for issue_num in "${SUB_ISSUE_NUMBERS[@]}"; do
  bash {plugin_root}/scripts/link-sub-issue.sh ...
done
```

`commands/issue/create.md` ステップ 5.3 + 5.4 + 5.5 Step 1 統合 bash block の AC-1 critical 警告で何度繰り返されているように、この single-Bash-invocation 要件は **本コマンドにおける silent-skip リスク最大の箇所** である。
