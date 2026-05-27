---
description: Wiki Ingest — Raw Source から経験則を抽出・統合し Wiki ページを更新
---

# /rite:wiki:ingest

Wiki Ingest エンジン。`.rite/wiki/raw/` の Raw Source を読解し、`.rite/wiki/pages/` に経験則として統合する。やることは以下のシーケンシャルなタスク列:

1. 事前チェック（Wiki 設定 / plugin root / worktree セットアップ）
2. Raw Source の候補列挙と `ingested: false` 判定
3. 既存 Wiki インデックス (`index.md`) の読み込み
4. LLM による読解と統合判定（新規 / 更新 / スキップ）
5. ページの書き込み + commit/push（worktree ベース）
6. `index.md` の更新
7. `log.md` への append-only 追記
8. 自動 Lint (`/rite:wiki:lint --auto`)
9. 完了レポート

Raw Source の wiki branch 着地は `wiki-ingest-commit.sh` が `pr:review` / `pr:fix` / `issue:close` から直接呼ばれて完了している前提。本コマンドが扱うのは page 統合の LLM 責務のみ。

`separate_branch` 戦略では `.rite/wiki-worktree/` worktree のツリーに対して Read/Write/Edit を行う。dev ブランチは ingest 実行中も常にそのまま。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md) で解決する。共通パターン (ディレクトリ構造 / ブランチ管理 / テンプレート展開) は [Wiki Patterns](../../references/wiki-patterns.md) を参照。

## Arguments

| Argument | Description |
|----------|-------------|
| `[raw-file-path]` | 単一の Raw Source ファイルを指定して Ingest（省略時は `.rite/wiki/raw/` 配下の `ingested: false` 全ファイルを処理） |

## Examples

```
/rite:wiki:ingest
/rite:wiki:ingest .rite/wiki/raw/reviews/20260413T...md
```

---

## ステップ 1: 事前チェック

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から `wiki_enabled` / `wiki_branch` / `branch_strategy` を**単一の bash ブロック**で取得する (本ブロックはプローブ用。各失敗を `|| fallback=""` で個別処理するため `set -euo pipefail` は意図的に省略する。strict mode はステップ 5.1 / 5.2 で明示宣言する):

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""

extract_yaml_key() {
  local key=$1
  printf '%s\n' "$wiki_section" | awk -v k="$key" '$0 ~ "^[[:space:]]+" k ":" { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed "s/.*$key:[[:space:]]*//" | tr -d '[:space:]"'\'''
}

wiki_enabled=$(extract_yaml_key enabled | tr '[:upper:]' '[:lower:]')
wiki_branch=$(extract_yaml_key branch_name)
branch_strategy=$(extract_yaml_key branch_strategy)

case "$wiki_enabled" in false|no|0) wiki_enabled=false ;; *) wiki_enabled=true ;; esac  # opt-out default
wiki_branch="${wiki_branch:-wiki}"
branch_strategy="${branch_strategy:-separate_branch}"

echo "wiki_enabled=$wiki_enabled branch_strategy=$branch_strategy wiki_branch=$wiki_branch"
```

分散実装の完全一覧と設計差異は [Wiki 有効判定パターン §分散実装ファイル一覧](../../references/wiki-patterns.md#分散実装ファイル一覧-single-source-of-truth) を SoT として参照する。本ファイルは `extract_yaml_key` helper 経由でパースする lenient 2-arm 経路 (wiki-config.sh / inject.sh と同型の lenient ファミリ、#483 opt-out default)。trigger.sh は意図的に strict 3-arm fail-fast で別経路 — 詳細は SoT を参照。

**`wiki_enabled=false` の場合**: 早期 return:

```
Wiki 機能が無効です（wiki.enabled: false）。
有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki:init を実行してください。
```

### 1.2 Plugin Root の解決

ステップ 1.3 の `wiki-worktree-setup.sh` 呼び出しが `$plugin_root` に依存するため、Wiki 初期化判定よりも前に解決する:

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

以降のすべての Bash ブロックでは `plugin_root` / `branch_strategy` / `wiki_branch` をリテラル値として埋め込んで使用する（Claude Code の Bash ツール間でシェル変数は保持されない）。

### 1.3 Wiki 初期化判定と worktree セットアップ

ステップ 1.1 で取得した `branch_strategy` / `wiki_branch` とステップ 1.2 の `plugin_root` を使い、wiki ブランチの存在と worktree の有効性を確認する。`separate_branch` 戦略では、ブランチがローカル/リモートのどちらかに存在することと worktree が有効に存在することを両方確認する:

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"
plugin_root="{plugin_root}"

if [ "$branch_strategy" = "separate_branch" ]; then
  if ! ( git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
         git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1 ); then
    echo "WIKI_INITIALIZED=false"
    echo "WIKI_INIT_REASON=branch_missing"
  else
    # `if ! cmd; then rc=$?` は bash 仕様で常に rc=0 を返すため、set +e/-e で明示的に rc を捕捉する。
    # setup.sh の stderr は ERROR / WARNING / hint をユーザーに届けるため stderr に透過させ、
    # stdout のみ /dev/null に捨てる。
    set +e
    bash "$plugin_root/hooks/scripts/wiki-worktree-setup.sh" >/dev/null
    setup_rc=$?
    set -e
    if [ "$setup_rc" -ne 0 ]; then
      echo "WIKI_INITIALIZED=false"
      echo "WIKI_INIT_REASON=worktree_setup_failed; rc=$setup_rc"
    else
      echo "WIKI_INITIALIZED=true"
    fi
  fi
else
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
    echo "WIKI_INIT_REASON=schema_missing"
  fi
fi
```

**Wiki 未初期化の場合**: 早期 return:

```
Wiki が初期化されていません ({reason})。先に /rite:wiki:init を実行してください。
```

`reason=worktree_setup_failed` の場合は `wiki-worktree-setup.sh` のエラー出力を確認し、`git worktree prune` / `git fetch origin wiki:wiki` 等で復旧してから再実行する。

`separate_branch` の場合、以降のすべての Wiki 書き込みは `.rite/wiki-worktree/.rite/wiki/...` の完全相対パスで指す。Read / Write / Edit ツールには常にこのパスを渡すこと。

---

## ステップ 2: Raw Source の解決

### 2.1 引数の判定とカウンター変数の初期化

引数 `<raw-file-path>` が指定されている場合は単一ファイルを Ingest 対象とし、省略時は `.rite/wiki/raw/` 配下から `ingested: false` を持つ Raw Source を全て列挙する。

以下のカウンターを会話コンテキストに保持し、各ステップで incrementate する。値は ステップ 5 commit message と ステップ 9 完了レポートで literal substitute されるため、placeholder のまま使用してはならない:

| 変数 | 初期値 | 確定 / incrementate するタイミング |
|------|:--:|---|
| `n_raw_sources` | 0 | ステップ 2.3 末尾で処理対象件数に上書き |
| `n_pages_created` | 0 | ステップ 4 で「新規ページ作成」決定ごとに +1 |
| `n_pages_updated` | 0 | ステップ 4 で「既存ページ更新」決定ごとに +1 |
| `n_skipped` | 0 | ステップ 4 で「スキップ」決定ごとに +1 |
| `n_warnings` | 0 | ステップ 8.5 で Lint の検出件数合計（`n_unregistered_raw` を除く 5 カテゴリ）を加算。加えて ステップ 8.3 の Lint 実行異常検出時 `n_warnings += 1` と `n_lint_anomaly += 1` を並行加算 |
| `n_lint_anomaly` | 0 | ステップ 8.3 step 1/3/4 (ERROR 行検出 / stdout 空 / regex mismatch) でそれぞれ +1。`n_warnings` と並行加算 |
| `n_contradictions` / `n_stale` / `n_orphans` / `n_missing_concept` / `n_unregistered_raw` / `n_broken_refs` | 0 | ステップ 8.3 step 2 (6 フィールド regex match) で Lint stdout から抽出 |

`n_unregistered_raw` は informational 指標で `n_warnings` には加算しない（意図的に経験則化しなかった件数は警告ではない）。`auto_lint=false` 経路で ステップ 8.2-8.5 が skip された場合も、本ステップで 0 初期化されているためステップ 9 完了レポートの placeholder 残留は発生しない。

### 2.2 候補 Raw Source の列挙 (worktree ベース)

`separate_branch` 戦略では Raw Source は wiki ブランチ上にあり、`.rite/wiki-worktree/.rite/wiki/raw/` を直接 find する。dev ブランチ側 (`.rite/wiki/raw/`) は通常存在しないが、過去バージョンからのマイグレーション残骸を検出するために存在チェックして WARNING を出す:

```bash
branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_raw_root=".rite/wiki-worktree/.rite/wiki/raw"
else
  wiki_raw_root=".rite/wiki/raw"
fi

candidates=()
if [ -d "$wiki_raw_root" ]; then
  # signal-specific trap (EXIT/INT/TERM/HUP) で find_err tempfile orphan 防止。
  # 詳細は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照。
  find_err=""
  _cleanup() { [ -n "${find_err:-}" ] && rm -f "$find_err"; return 0; }
  trap 'rc=$?; _cleanup; exit $rc' EXIT
  trap '_cleanup; exit 130' INT
  trap '_cleanup; exit 143' TERM
  trap '_cleanup; exit 129' HUP

  find_err=$(mktemp /tmp/rite-wiki-ingest-find-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (find_err) の mktemp に失敗しました。find の詳細エラー情報は失われます" >&2
    echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
    echo "  影響: permission denied で raw source が silent 脱落する可能性があります" >&2
    find_err=""
  }
  while IFS= read -r f; do candidates+=("$f"); done < <(find "$wiki_raw_root" -type f -name '*.md' 2>"${find_err:-/dev/null}")
  if [ -n "$find_err" ] && [ -s "$find_err" ]; then
    echo "WARNING: find '$wiki_raw_root' が stderr 出力を返しました (permission denied / IO error の可能性):" >&2
    head -3 "$find_err" | sed 's/^/  /' >&2
    echo "  影響: 一部候補が silent に脱落した可能性があります。ディレクトリ権限を確認してください" >&2
  fi
  [ -n "$find_err" ] && rm -f "$find_err"
fi

# 旧 stash+checkout 経路の残骸検出 (separate_branch のみ)
if [ "$branch_strategy" = "separate_branch" ] && [ -d ".rite/wiki/raw" ]; then
  drift_count_raw=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  drift_count="${drift_count_raw:-0}"
  [[ "$drift_count" =~ ^[0-9]+$ ]] || drift_count=0
  if [ "$drift_count" -gt 0 ]; then
    echo "WARNING: dev ツリー側 '.rite/wiki/raw/' に $drift_count 件の Raw Source が残留しています" >&2
    echo "  対処: 本 Ingest では処理されません。wiki-ingest-commit.sh で移送するか手動削除してください" >&2
  fi
fi

printf 'Found %d candidate raw source(s)\n' "${#candidates[@]}"
for c in "${candidates[@]}"; do echo "  - $c"; done
```

### 2.3 Ingested フラグの判定

各候補ファイルの YAML frontmatter から `ingested:` を読み、`false` / `no` / `0` / 未設定のものを処理対象とする（YAML spec 準拠の lowercase + quote 除去で正規化）。引数で単一ファイル指定時は値に関わらず処理対象とする（再 Ingest 許可）。

`for candidate in "${candidates[@]}"; do ... done` ループ内で以下を実行する:

```bash
ingested_value=$(awk '
  BEGIN { in_fm=0 }
  /^---$/ { in_fm++; next }
  in_fm == 1 && /^ingested:[[:space:]]*/ {
    sub(/^ingested:[[:space:]]*/, "")
    sub(/[[:space:]]*$/, "")
    print
    exit
  }
' "$candidate_file")
ingested_norm=$(printf '%s' "$ingested_value" | tr -d '"'\''' | tr '[:upper:]' '[:lower:]')
case "$ingested_norm" in
  false|no|0|"") process="yes" ;;
  *) process="no" ;;
esac
```

候補は worktree (separate_branch) または dev ツリー (same_branch) を直接 Read / `cat` で読み取れる（`git show` / `git checkout` は不要）。読み取り失敗時は WARNING を出して次の候補へ:

```bash
# signal-specific trap (EXIT/INT/TERM/HUP) は反復ごとに再設定される (bash 仕様で idempotent)。
cat_err=""
_cleanup() { [ -n "${cat_err:-}" ] && rm -f "$cat_err"; return 0; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

cat_err=$(mktemp /tmp/rite-wiki-ingest-cat-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (cat_err) の mktemp に失敗しました。cat の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: file body 読取失敗の根本原因 (permission / IO error) が不可視になります" >&2
  cat_err=""
}
if ! file_body=$(cat "$candidate" 2>"${cat_err:-/dev/null}"); then
  echo "WARNING: failed to read $candidate" >&2
  [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | sed 's/^/  /' >&2
  echo "  この候補をスキップして次の Raw Source に進みます" >&2
  [ -n "$cat_err" ] && rm -f "$cat_err"
  continue
fi
[ -n "$cat_err" ] && rm -f "$cat_err"
```

**処理対象が 0 件の場合**: 早期 return:

```
未 Ingest の Raw Source は見つかりませんでした。
新しい経験則を蓄積するには /rite:pr:review や /rite:pr:fix の完了後に再実行してください。
```

**処理対象が確定したら**: ステップ 2.1 で初期化した `n_raw_sources` を件数に上書きする。各 Raw Source の完全な本文 (frontmatter + body) を Read ツールで取得し、会話コンテキストに保持する（ステップ 5 の Write/Edit phase で参照）。

---

## ステップ 3: 既存 Wiki インデックスの読み込み

統合判定 (新規 vs 更新) のため `index.md` を読み込む:

```bash
branch_strategy="{branch_strategy}"
if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_index_path=".rite/wiki-worktree/.rite/wiki/index.md"
else
  wiki_index_path=".rite/wiki/index.md"
fi

if [ -f "$wiki_index_path" ]; then
  index_content=$(cat "$wiki_index_path")
else
  echo "INFO: '$wiki_index_path' not found (initial state). Treating all pages as new." >&2
  index_content=""
fi
```

LLM は Read ツールで `$wiki_index_path` を直接開き、既存ページのタイトル一覧・ドメイン分布・最終更新日を把握する。

---

## ステップ 4: LLM による読解と統合判定

ステップ 2.3 で確定した処理対象 Raw Source 1 件ずつに対して、LLM が以下を行う:

1. **読解**: Raw Source 本文から抽出可能な経験則を特定
2. **ドメイン判定**: `patterns` / `heuristics` / `anti-patterns` に分類
3. **既存ページ照合**: `index.md` に同テーマの既存ページが存在するかを意味的に判定 (厳密一致ではなく、一行サマリーとタイトルから判断)
4. **アクション決定**: 下表に従い 新規 / 更新 / スキップ を決定
5. **関連ページ特定**: ステップ 5.3 の `{related_page_title}` / `{related_page_path}` の値を決定 (詳細はステップ 4.3)

| 判定 | アクション |
|------|----------|
| 同テーマの既存ページなし | 新規ページ作成 |
| 同テーマの既存ページあり | 既存ページ更新（追記 or 統合） |
| 経験則が抽出できない（一時的な情報のみ） | スキップ（理由を log に記録） |

### 4.1 タイトル/ドメイン/サマリーの生成

新規ページ作成時、LLM は以下を生成する:

| フィールド | ガイドライン |
|-----------|-------------|
| `title` | 経験則を 1 行で表現（30-60 字推奨） |
| `domain` | `patterns` / `heuristics` / `anti-patterns` |
| `summary` | 1-2 文の要約（index.md に掲載される） |
| `details` | 背景・具体例・根拠を含む詳細 |
| `confidence` | `high` / `medium` / `low`（根拠の強さ） |

ファイル名は `pages/{domain}/{slug}.md`、`slug` は `title` を kebab-case 化（最大 60 文字）。

### 4.2 既存ページ更新時の統合方針

- **追記**: 既存内容と矛盾せず補強する場合は「## 詳細」セクションに追記
- **統合**: 一部矛盾するが新情報の方が確度が高い場合は該当箇所を書き換え（`updated` フィールド更新）
- **`sources` 配列追記**: 新しい Raw Source への参照を必ず追加
- **`updated` 更新**: 現在の ISO 8601 タイムスタンプに更新

### 4.3 関連ページの特定

新規ページ作成・既存ページ更新のいずれの場合も、ステップ 5.3 で展開する `{related_page_title}` / `{related_page_path}` placeholder の値を本ステップで決定する（本セクションが値決定手順の canonical source。ステップ 5.3 placeholder 表との矛盾発生時は本 4.3 を優先）。

**実行タイミング**: ステップ 4.1 でタイトル/ドメイン決定後、ステップ 5 の Write/Edit に進む前。

**選定基準**:

| 基準 | 説明 |
|------|------|
| Semantic 近接性 | `index.md` のページ一覧から、本ページと同ドメインの隣接トピック、または別ドメインだが概念的に関連するページを選定する |
| 確信度 | LLM の判定として確信があるもの 1-3 件に絞る（量より質） |
| index.md との照合 | ステップ 3 で読み込んだ `index_content` の一行サマリーとタイトルから判断する |

**title 規約**: `{related_page_title}` は対象ページの frontmatter `title` フィールド (= `index.md` ページ一覧表の title 列) と **literal 一致** させる。link text の独自言い換えは禁止 (index.md ↔ link text の drift 防止)。

**path 計算規約**: `{related_page_path}` には **page-dir 相対** の path を substitute する。新規 page 格納位置 `.rite/wiki/pages/{domain}/{slug}.md` の page-dir = `.rite/wiki/pages/{domain}/` を起点として相対 path を計算する:

| ケース | path 例 (推奨形) |
|--------|------------------|
| 同ドメイン内 | `./other-page.md` (`./` prefix 付き推奨。page-dir 相対の意図を視覚的に表現する) |
| 別ドメイン | `../{domain}/other-page.md` |

`{source_ref}` (template 側で `../../` prefix を hardcode、wiki-root 起点) とは起点が異なるため、`{related_page_path}` には template リテラル側で prefix を付けず、placeholder 値そのものに page-dir 相対 path を入れる。

**該当ページなし時の処理**: 確信ある関連ページが特定できない場合、`## 関連ページ` セクション全体を Edit ツールで以下に置き換える（空 placeholder のままだと Markdown リンク `[]()` が破綻するため）:

```
## 関連ページ

- （関連ページなし）
```

`{related_page_title}` / `{related_page_path}` の両 placeholder への substitute は行わず、セクション全体差し替えを優先する。

---

## ステップ 5: ページの書き込み

ステップ 4 で決定したアクション (新規 / 更新) を、ブランチ戦略に応じて適用する。

### 5.0 LLM が実行すべき具体的手順 (worktree ベース)

`separate_branch` では `.rite/wiki-worktree/` worktree のツリーに対して、`same_branch` では dev ツリーに対して直接 Write/Edit する。LLM は以下を順に実施するだけ:

1. **Raw Source 本文の確保**: ステップ 2.3 末尾で取得した本文を作業メモリに展開
2. **Raw Source の `ingested: true` 化** (全戦略共通 — create / update / skip いずれでも実施):
   - **separate_branch**: Edit ツールで `.rite/wiki-worktree/.rite/wiki/raw/{type}/{filename}` の frontmatter `ingested: false` を `ingested: true` に書き換える
   - **same_branch**: Edit ツールで `.rite/wiki/raw/{type}/{filename}` を書き換える
3. **新規 Wiki ページの作成** (ステップ 4 で新規決定): `{plugin_root}/templates/wiki/page-template.md` を Read で読み、ステップ 5.3 のプレースホルダーを置換した内容を Write:
   - **separate_branch**: `.rite/wiki-worktree/.rite/wiki/pages/{domain}/{slug}.md`
   - **same_branch**: `.rite/wiki/pages/{domain}/{slug}.md`

   `n_pages_created` を +1 する
4. **既存 Wiki ページの更新** (ステップ 4 で更新決定): 対象ページを Read で読み、Edit で `## 詳細` 追記・`updated` 更新・`sources` 配列追記。`n_pages_updated` を +1 する
5. **スキップ決定の処理** (ステップ 4 で skip 決定): step 2 と同じ手順で `ingested: true` 化し、ステップ 7 の log.md に `ingest:skip` エントリを追加 (reason 記録)。`n_skipped` を +1 する
6. **index.md の更新**: ステップ 6 の指示に従い Edit する
7. **log.md への追記**: ステップ 7 の指示に従い Edit で append-only 追加する

### 5.0.c canonical commit message 契約

ステップ 5.1 (separate_branch) と ステップ 5.2 (same_branch) の両 bash block で使用する commit message は以下を **唯一の真実源** とする。両 phase は独立した bash block (Bash tool 呼び出し間でシェル状態が継承されない) のため、両サイトで以下と literal 一致する実装を保持する。drift 検出は将来 /rite:lint が本 section と ステップ 5.1 / 5.2 を grep で比較する予定。

**canonical template**:

```
docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})
```

**canonical placeholder-residue gate**:

```bash
case "$commit_msg" in
  *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
    echo "ERROR: ステップ 5.{X} の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
    echo "  対処: ステップ 2.1 / 4 / 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する" >&2
    exit 1
    ;;
esac
```

ステップ 5.1 / 5.2 では `commit_msg=` 行を上記 canonical と literal 一致させ、placeholder-residue gate のサイト識別子 (`ステップ 5.{X}`) のみを 5.1 / 5.2 で置換する。template を変更する際は本セクション + ステップ 5.1 + ステップ 5.2 の **3 箇所を必ず同時に更新する**。

### 5.1 separate_branch 戦略 (worktree ベース)

ステップ 5.0 手順 1-7 を Write/Edit ツールで実施した後、以下の bash ブロックを実行して worktree 内の変更を commit + push する。commit 処理は `wiki-worktree-commit.sh` に委譲されており、LLM が bash 契約を書く必要はない:

```bash
# ステップ 5.2 と対称に set -euo pipefail を宣言する (strict mode)
set -euo pipefail

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  plugin_root="{plugin_root}"

  # script の rc は $(...) 代入では伝播しないため、事前に存在確認する
  if [ ! -x "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" ]; then
    echo "ERROR: wiki-worktree-commit.sh が見つからないか実行権限がありません: $plugin_root/hooks/scripts/wiki-worktree-commit.sh" >&2
    exit 1
  fi

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} は
  # ステップ 2.1 で初期化され ステップ 4 / 5.0 step 5 で incrementate されたカウンター値を literal substitute する。
  # ステップ 5.0.c canonical commit message と literal 一致させること。
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  case "$commit_msg" in
    *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
      echo "ERROR: ステップ 5.1 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
      echo "  対処: ステップ 2.1 / 4 / 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する" >&2
      exit 1
      ;;
  esac

  # set -e 下で script の非 0 exit を許容して rc を capture する
  set +e
  commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
  commit_rc=$?
  set -e
  echo "$commit_out"

  case "$commit_rc" in
    0) echo "[CONTEXT] WIKI_INGEST_COMMIT=ok" ;;
    2) echo "[CONTEXT] WIKI_INGEST_COMMIT=skipped; reason=wiki-disabled" >&2 ;;
    3)
      echo "ERROR: wiki-worktree-commit.sh 内部で git 操作失敗 (rc=3)" >&2
      echo "  対処: git -C .rite/wiki-worktree status で worktree の状態を確認" >&2
      exit 1
      ;;
    4)
      echo "WARNING: commit は landed したが push に失敗しました (rc=4)" >&2
      echo "  手動回復: git -C .rite/wiki-worktree push origin $wiki_branch" >&2
      # push 失敗は非 fatal — ユーザーが後で回復可能
      ;;
    *)
      echo "ERROR: wiki-worktree-commit.sh が予期しない exit code ($commit_rc) を返しました" >&2
      exit 1
      ;;
  esac

elif [ "$branch_strategy" = "same_branch" ]; then
  # same_branch はステップ 5.2 で扱う
  :
else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy' (受け付け: separate_branch / same_branch)" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi
```

### 5.2 same_branch 戦略

`same_branch` では Raw Source / ページ / index.md / log.md はすべて dev ブランチのワークツリーに存在する。ステップ 5.0 手順 1-7 を Write/Edit で実施した後、以下の bash ブロックで一括 commit する (ブランチ切り替え不要、worktree も不要):

```bash
set -euo pipefail
branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  # signal-specific trap (EXIT/INT/TERM/HUP) で _reset_err tempfile orphan 防止。
  # 詳細は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照。
  _reset_err=""
  _cleanup() { [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"; return 0; }
  trap 'rc=$?; _cleanup; exit $rc' EXIT
  trap '_cleanup; exit 130' INT
  trap '_cleanup; exit 143' TERM
  trap '_cleanup; exit 129' HUP

  # same_branch 戦略では .gitignore に `!.rite/wiki/` negation が必要。
  # 失敗時は anchor marker (gitignore-wiki-section-start) を案内する。
  add_err=$(mktemp /tmp/rite-wiki-ingest-add-err-XXXXXX 2>/dev/null) || add_err=""
  if ! git add .rite/wiki/ 2>"${add_err:-/dev/null}"; then
    echo "ERROR: git add .rite/wiki/ failed" >&2
    if [ -n "$add_err" ] && [ -s "$add_err" ]; then
      echo "  詳細 (git add stderr 先頭 5 行):" >&2
      head -5 "$add_err" | sed 's/^/    /' >&2
    fi
    echo "  原因候補: same_branch 戦略で .gitignore に '!.rite/wiki/' negation が未設定の可能性" >&2
    echo "  対処:" >&2
    echo "    1. grep -n 'gitignore-wiki-section-start' .gitignore で anchor 位置を特定" >&2
    echo "    2. 同ブロック内の手順に従い '!.rite/wiki/' negation を追加し、git add --dry-run で verification してから再実行" >&2
    echo "    3. それ以外の原因 (permission / disk full / corrupt index 等) は上記 stderr の詳細を確認" >&2
    [ -n "$add_err" ] && rm -f "$add_err"
    exit 1
  fi
  [ -n "$add_err" ] && rm -f "$add_err"

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} を literal substitute する。
  # ステップ 5.0.c canonical commit message と literal 一致させること。
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  case "$commit_msg" in
    *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
      echo "ERROR: ステップ 5.2 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
      echo "  対処: ステップ 2.1 / 4 / 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する" >&2
      exit 1
      ;;
  esac

  if ! git commit -m "$commit_msg"; then
    echo "ERROR: git commit failed" >&2
    echo "  ロールバック: staging area の .rite/wiki/ 変更を unstage します" >&2
    _reset_err=$(mktemp /tmp/rite-wiki-ingest-reset-err-XXXXXX 2>/dev/null) || {
      echo "  WARNING: stderr 退避 tempfile (_reset_err) の mktemp に失敗しました。git reset の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: git reset 失敗の根本原因 (index lock / permission denied 等) が不可視になります" >&2
      _reset_err=""
    }
    if ! git reset HEAD .rite/wiki/ 2>"${_reset_err:-/dev/null}"; then
      echo "  WARNING: git reset HEAD .rite/wiki/ に失敗。手動で unstage してください: git reset HEAD .rite/wiki/" >&2
      [ -n "${_reset_err:-}" ] && [ -s "${_reset_err:-}" ] && head -3 "$_reset_err" | sed 's/^/    /' >&2
    fi
    [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"
    _reset_err=""
    echo "  注意: Write/Edit した ingested:true 化と index.md / log.md 変更はワークツリーに残っています" >&2
    echo "  対処: git status で変更内容を確認後、手動で commit するか git checkout で破棄してください" >&2
    exit 1
  fi
  # same_branch では raw cleanup は不要 (PR diff に含めるのが意図的選択)
  trap - EXIT INT TERM HUP
fi
```

### 5.3 新規ページのテンプレート展開

新規ページ作成時は `{plugin_root}/templates/wiki/page-template.md` を読み込み、以下のプレースホルダーを置換した上で書き込む:

| プレースホルダー | 値 |
|----------------|-----|
| `{title}` | ステップ 4.1 で生成したタイトル |
| `{domain}` | `patterns` / `heuristics` / `anti-patterns` |
| `{created}` / `{updated}` | 現在の ISO 8601 タイムスタンプ |
| `{source_type}` | Raw Source の `type` フィールド (`reviews` / `retrospectives` / `fixes` の 3 値のみ — `wiki-ingest-trigger.sh` が受理する値と一致) |
| `{source_ref}` | Raw Source の wiki-root 起点ファイル相対パス（例: `raw/reviews/20260413T...md`）。template 側で `../../` prefix を hardcode するため、placeholder 値自体には prefix を含めない |
| `{summary}` | ステップ 4.1 のサマリー |
| `{details}` | ステップ 4.1 の詳細 |
| `{related_page_title}` / `{related_page_path}` | ステップ 4.3 で決定した値。**該当ページがない場合は `## 関連ページ` セクション全体を `- （関連ページなし）` の平文 1 行に Edit で書き換える** (空 placeholder のままにすると Markdown link `[]()` が破綻) |
| `{source_description}` | Raw Source の `title` フィールド (空なら `source_ref` を使用)。`## ソース` セクションのリンク表示テキストに使われ、URL には `{source_ref}` が使われることで両者を分離する |

**confidence フィールド**: page-template.md の `confidence: medium` はリテラル値で、placeholder 走査の誤置換を避けるため上表とは別管理。Write 後に Edit で ステップ 4 の判定値 (`high` / `medium` / `low`) に置換する。

---

## ステップ 6: index.md の更新

`.rite/wiki/index.md` の「ページ一覧」テーブルに新規ページの行を追加し、既存ページが更新された場合は該当行の「更新日」を更新する。「統計」セクションの総ページ数とドメイン別カウントも再計算する。

**更新ルール**:

- **新規ページ**: テーブル末尾に `| [{title}]({path}) | {domain} | {summary} | {updated} | {confidence} |` を追加
- **既存ページ更新**: 該当行の「更新日」と必要に応じて「サマリー」「確信度」を上書き
- **統計再計算**: テーブルの全行を数えてカウントを更新

書き込みはステップ 5 と同じブランチコンテキスト (separate_branch なら worktree、same_branch なら dev ツリー) で行う。

---

## ステップ 7: log.md の追記

`.rite/wiki/log.md` の「活動ログ」テーブルに **append-only** で新しいエントリを追記する。各 Raw Source 1 件につき 1 行を追加する:

| 列 | 値 |
|----|-----|
| 日時 | 現在の ISO 8601 タイムスタンプ |
| アクション | `ingest:create` (新規) / `ingest:update` (更新) / `ingest:skip` (スキップ) |
| 対象 | 対象ページの相対パス（スキップ時は Raw Source の相対パス） |
| 詳細 | Raw Source の `source_ref` や Issue/PR 番号、スキップ理由など |

log.md は append-only。既存行を変更してはいけない。

---

## ステップ 8: 自動 Lint

Ingest 直後、Wiki 全体の品質チェックを `/rite:wiki:lint --auto` として実行する。**5 ブロッキング観点** (矛盾・陳腐化・孤児ページ・欠落概念・壊れた相互参照) + **1 informational 指標** (未登録 raw、`ingest:skip` 済み) で計 6 フィールドを検査する。

### 8.1 auto_lint 設定の確認

`rite-config.yml` の `wiki.auto_lint` をステップ 1.1 と同じ YAML パーサで読み取る:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
auto_lint=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_lint:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*auto_lint:[[:space:]]*//' | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')
case "$auto_lint" in
  false|no|0) auto_lint=false ;;
  *) auto_lint=true ;;  # default: true
esac
echo "auto_lint=$auto_lint"
```

**`auto_lint=false` の場合**: ステップ 8.2-8.5 を skip しステップ 9 へ進む。Lint カウンタ 6 種はステップ 2.1 で 0 初期化済みのため placeholder 残留は発生しない。ステップ 9 完了レポートの「Wiki 品質警告」行は「スキップ (auto_lint disabled)」、「未登録 raw」行は `0` 件として表示する。

### 8.2 Lint エンジンの呼び出し

LLM は `skill: "rite:wiki:lint", args: "--auto"` 形式で `/rite:wiki:lint` を `--auto` モードで呼び出す。`--auto` モードの契約:

- `Lint: contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` 形式の 1 行 + `<!-- [lint:returned-to-caller:auto] -->` HTML コメント sentinel の 2 行を出力する (0 件でも必ず出力)
- log.md への追記は lint.md 側がブランチ状態を判定し自律実行する
- 常に exit 0 (非ブロッキング)

呼び出し時の CWD は常に dev ブランチ。lint.md ステップ 8.2 は `separate_branch` 戦略時に worktree 内で log.md 追記 → `wiki-worktree-commit.sh` 呼び出しを行う。

Skill return 後、ステップ 8.3 (パース) → 8.4 (完了レポート統合) → 8.5 (n_warnings 加算) → ステップ 9 を順に実行する。

### 8.3 Lint 実行結果の取得とパース

LLM は Skill 応答テキスト (= `lint.md` ステップ 9.2 の最終 stdout 出力) を会話コンテキストからパースする。Skill ツール呼び出しはシェル exit code を返さないため、**Skill 応答テキストの内容**で成否を判定する。以降の「stdout」はすべて Skill 応答テキストを指し、lint.md 内部の中間出力 (`pages_list=` 等) ではない。

判定優先順位 (step 番号は **項目の論理的役割の名称** であり実行順とは異なる):

```
優先 1: step 2 (6 フィールド regex match) を試行
  ├─ match 成功 → 6 変数を抽出して continue (step 1 / 3 / 4 は skip)
  └─ match 失敗 → 優先 2 へ

優先 2: step 1 (ERROR 行 scan) を試行
  ├─ ERROR: 行検出 → n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
  └─ ERROR 行なし → 優先 3 へ

優先 3: step 3 (stdout 空 check) を試行
  ├─ stdout 空 → n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
  └─ stdout 非空 → 優先 4 へ

優先 4: step 4 (format mismatch fallback)
  └─ n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
```

通常時は step 2 のみで完結する (lint.md ステップ 9.2 が必ず 6 フィールド 1 行を emit する契約のため)。

1. **ERROR 行の検出**: Skill 応答テキストに `ERROR:` で始まる任意行 (例: `ERROR: 未知の branch_strategy 値を検出しました`) が含まれるかを検査する。検出時:

   - `n_warnings += 1` + `n_lint_anomaly += 1`
   - 6 変数 (`n_contradictions` 等) はすべて `0` に fallback
   - stderr に WARNING を出力 (検出行を 4 スペース prefix で展開):

     ```
     WARNING: /rite:wiki:lint --auto の Skill 応答テキストに ERROR: 行を検出しました（Lint 実行失敗）。
       検出行: {error_line_first1line}
       考えられる原因: lint.md 内の echo "ERROR: ..." 経由の fail-fast 経路が発火
       Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
       対処: /rite:wiki:lint を手動実行してエラー内容を確認してください。
     ```

   - ステップ 8.4 では「Lint 結果: 実行失敗（ERROR: 行検出のため詳細取得不可）」と表示

2. **stdout のパース** (優先 1): exit 0 の場合、stdout の **全行を上から scan し、最初に以下の正規表現にマッチした行から** 6 つの変数を抽出する: `^Lint: contradictions=([0-9]+), stale=([0-9]+), orphans=([0-9]+), missing_concept=([0-9]+), unregistered_raw=([0-9]+), broken_refs=([0-9]+)$`

   | 変数 | regex group |
   |------|-------------|
   | `n_contradictions` | group 1 |
   | `n_stale` | group 2 |
   | `n_orphans` | group 3 |
   | `n_missing_concept` | group 4 |
   | `n_unregistered_raw` | group 5 |
   | `n_broken_refs` | group 6 |

   全行 scan + 最初の match 採用とすることで、lint.md 側で preamble の echo / debug 出力が混入しても決定論的に `Lint:` 行を拾う (`set -x` debug / observability echo / informational banner 等の追加変更に対する resilience)。

3. **stdout が空の場合**: **Lint 実行失敗として扱う** (lint.md の契約では 0 件でも必ず 1 行出力するため、stdout 空は bash syntax error / 未捕捉 fatal error / SIGPIPE / OOM 等の異常経路):

   - `n_warnings += 1` + `n_lint_anomaly += 1`
   - 6 変数を `0` に fallback
   - stderr に WARNING を出力:

     ```
     WARNING: /rite:wiki:lint --auto の stdout が空でした（Lint 実行失敗）。
       期待される出力: Lint: contradictions=N, stale=N, orphans=N, missing_concept=N, unregistered_raw=N, broken_refs=N
       考えられる原因: lint.md の bash syntax error / 未捕捉 fatal error / SIGPIPE / OOM
       Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
       対処: /rite:wiki:lint を手動実行してエラー内容を確認してください。
     ```

   - ステップ 8.4 では「Lint 結果: 実行失敗（stdout が空のため詳細取得不可）」と表示

4. **stdout のどの行も regex にマッチしない場合**: Lint 側のフォーマット変更を検出した警告として扱う (silent に 0 件と誤認することを防ぐ):

   - `n_warnings += 1` + `n_lint_anomaly += 1` (format drift を Lint 異常経路として計上)
   - 6 変数を `0` に fallback
   - stderr に WARNING を出力 (stdout 先頭 3 行を 4 スペース prefix で展開):

     ```
     WARNING: /rite:wiki:lint --auto の出力形式が期待と異なります（stdout のいずれの行も 6 フィールド regex にマッチしませんでした）。
       stdout の先頭 3 行:
         {lint_stdout_first3lines}
       期待される形式: Lint: contradictions=N, stale=N, orphans=N, missing_concept=N, unregistered_raw=N, broken_refs=N
     ```

### 8.4 Ingest 完了レポートへの統合

ステップ 9 の完了レポートに以下を埋め込む:

```
Lint 結果: 矛盾 {n_contradictions} 件 / 陳腐化 {n_stale} 件 / 孤児 {n_orphans} 件 / 欠落 {n_missing_concept} 件（未登録 skip {n_unregistered_raw} 件）/ 壊れた相互参照 {n_broken_refs} 件
```

**全カテゴリが 0 件の場合** (`n_contradictions + n_stale + n_orphans + n_missing_concept + n_unregistered_raw + n_broken_refs == 0`): 「Lint 結果: 問題なし」とのみ表示する。1 件以上検出された場合は必ず全カテゴリを表示する (`n_unregistered_raw` は informational だが表示判定には含める)。

ERROR / stdout 空 / regex mismatch 経路では「Lint 結果: 実行失敗（{原因}）」と表示する。

### 8.5 `n_warnings` カウンタへの加算

本ステップは **ステップ 8.3 step 2 (6 フィールド regex match 成功) 経路でのみ実行する**。step 1/3/4 経路ではステップ 8.3 内で既に `n_warnings += 1` と `n_lint_anomaly += 1` が加算済みのため skip する。

ステップ 2.1 で初期化した `n_warnings` に、Lint の検出件数合計を加算する (step 2 経路のみ):

```
n_warnings += n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs
```

**`n_unregistered_raw` は加算しない**: `ingest:skip` 済み raw は意図的に経験則化しなかった件数 (log.md に skip 理由が記録済み) であり、警告として数えると skip 運用が膨らむほど警告カウンタが無意味に肥大する。informational 指標として完了レポートの内訳にのみ表示する。

**詳細な修正対応**: 検出結果の詳細確認は、Ingest 完了後に `/rite:wiki:lint`（`--auto` なし）で再実行して取得する。

---

## ステップ 9: 完了レポート

```
Wiki Ingest が完了しました。

処理サマリー:
- 処理した Raw Source: {n_raw_sources} 件
- 新規作成したページ: {n_pages_created} 件
- 更新したページ: {n_pages_updated} 件
- スキップした Raw Source: {n_skipped} 件
- {wiki_warnings_line}
- 未登録 raw（skip 済、warnings 不加算）: {n_unregistered_raw} 件

新規/更新ページ:
- {path1} ({action1})
- {path2} ({action2})

次のステップ:
- /rite:wiki:query で経験則を参照
- 詳細な品質チェックは /rite:wiki:lint で確認してください（ステップ 8 で自動実行済み）
```

`{wiki_warnings_line}` の展開ルール (lint.md ステップ 9.1 と設計対称):

| `auto_lint` | 「Wiki 品質警告:」行の展開 |
|-------------|-----------------------|
| `true` (通常経路) | `Wiki 品質警告: {n_warnings} 件（内訳: 矛盾 {n_contradictions} / 陳腐化 {n_stale} / 孤児 {n_orphans} / 欠落 {n_missing_concept} / 壊れた相互参照 {n_broken_refs} / Lint 異常経路 {n_lint_anomaly}）` |
| `false` (skip 経路) | `Wiki 品質警告: スキップ (auto_lint disabled)` (内訳は表示しない) |

「未登録 raw」行は `auto_lint=false` の場合も `0` 件として展開する (ステップ 2.1 で 0 初期化済みの値)。

**等式**: `n_warnings = n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs + n_lint_anomaly`。step 2 成功時は `n_lint_anomaly=0` のため 5 カテゴリ合計が `n_warnings` と一致。step 1/3/4 anomaly 経路では 5 カテゴリは 0 fallback だが `n_lint_anomaly >= 1` のため `n_warnings >= 1` となる。

### 9.1 Return-to-Caller Signal

完了レポート本体 (処理サマリー + 新規/更新ページ + 次のステップ) を出力した後、**最終 2 行**に HTML コメント sentinel を出力する:

```
<!-- skill return signal: caller must continue next step -->
<!-- [ingest:returned-to-caller] -->
```

sentinel は grep 可能 (`grep -F '[ingest:returned-to-caller]'`) で rendered view では不可視。bare bracket `[ingest:returned-to-caller]` は LLM turn-boundary heuristic 誤発火のため禁止 (Issue #561)、HTML コメント形式のみ許容する。

> **Why `returned-to-caller` (not `completed`)**: 旧 `ingest:completed` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、caller skill (cleanup / pr:open 等) の次 step を skip して turn が暗黙終了する事象が複数回再発した (Issue #1165)。`returned-to-caller` は「caller skill に return した = caller の次 step に進む」というネスト構造を semantic に内包し、terminal vocabulary を構造的に排除する。

---

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| `wiki.enabled: false` | 早期 return（ステップ 1.1） |
| Wiki 未初期化 / worktree セットアップ失敗 | `/rite:wiki:init` を案内、または `wiki-worktree-setup.sh` のエラー出力を確認して `git worktree prune` / `git fetch origin wiki:wiki` で復旧 (ステップ 1.3) |
| 処理対象 0 件 | 静かに終了し情報メッセージのみ表示（ステップ 2.3） |
| `wiki-worktree-commit.sh` exit 3 (git add/commit 失敗) | exit 1 で fail-fast。`git -C .rite/wiki-worktree status` で worktree の状態を確認 |
| `wiki-worktree-commit.sh` exit 4 (push 失敗) | 非 fatal で継続。`git -C .rite/wiki-worktree push origin {wiki_branch}` で手動回復 |
| `wiki-worktree-commit.sh` 未知の exit code | exit 1 で fail-fast |
| `branch_strategy` が未知の値 | ステップ 5.1 / 5.2 末尾の else 分岐で fail-fast (`rite-config.yml` の `wiki.branch_strategy` を確認) |
| LLM が経験則を抽出できない | 該当 Raw Source は `ingest:skip` として log.md に記録、`ingested: true` に変更、`n_skipped` を +1 |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query / Lint は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ (`ingested: true` フラグで重複防止)
- **append-only な log**: 活動ログは履歴として残し、追加のみ
- **PR diff からの分離**: `separate_branch` 戦略では Wiki 変更は `.rite/wiki-worktree/` worktree 内に閉じ、dev ブランチのツリーは一切変更されない (`.gitignore` で worktree path を除外)
- **opt-out**: `wiki.enabled: true` がデフォルト。`wiki:` セクション未指定でも有効扱い
