---
description: Wiki Lint — Wiki の品質チェック（5 ブロッキング: 矛盾・陳腐化・孤児・欠落概念・壊れた相互参照 + 1 informational: 未登録 raw）
---

# /rite:wiki:lint

Wiki Lint エンジン。`.rite/wiki/pages/` の Wiki ページ、`.rite/wiki/raw/` の Raw Source、`.rite/wiki/index.md` の整合性を検査する。やることは以下のシーケンシャルなタスク列:

1. 事前チェック (Wiki 設定 / GNU date 検査 / 初期化判定 / 引数解析・カウンタ初期化)
2. 検査対象の収集 (pages_list / raw_list / index.md)
3. 矛盾検出 (タイトル衝突 / 方針逆転 / 重複情報)
4. 陳腐化検出 (`updated` frontmatter が閾値超過)
5. 孤児ページ検出 (`index.md` 未登録)
6. 欠落概念検出 (`missing_concept` + `unregistered_raw` の 3 分岐)
7. 壊れた相互参照検出 (Markdown link 解決失敗)
8. log.md 追記 (`lint:clean` / `lint:warning`)
9. 完了レポート (通常モード / `--auto` モード)

| 観点 | 検出対象 | ブロッキング |
|------|---------|--------------|
| **矛盾** | 同じトピックで異なる結論を持つページ（タイトル衝突・方針逆転・重複情報） | Yes |
| **陳腐化** | `updated` frontmatter が閾値（デフォルト 90 日）を超えて更新されていないページ | Yes |
| **孤児ページ** | `pages/` 配下に存在するが `index.md` の「ページ一覧」テーブルに登録されていないページ | Yes |
| **欠落概念 (missing_concept)** | `raw/` に `ingested: true` の Raw Source があるが、対応ページも `sources.ref` 登録も `ingest:skip` 記録も存在しない真の欠落 | Yes |
| **壊れた相互参照** | ページ本文の Markdown リンク `](...)` が `pages/` 配下の実在ファイルを指していない | Yes |
| **未登録 raw (unregistered_raw)** | `ingested: true` で `sources.ref` 未登録だが、`log.md` に `ingest:skip` 記録がある raw。意図的に経験則化しなかった件数の informational 指標 | **No** (`n_warnings` 不加算) |

**設計契約**: lint は **読み取り専用** (`log.md` への追記を除く)。**原則 exit 0**で終了し、検出件数・事前チェック失敗・ブランチ読取失敗は非ブロッキングとして扱う。例外は (a) `branch_strategy` 未知値検出 (ステップ 2.2 / 6.0 / 6.2 / 8.2 / 8.3 の 5 箇所で同型 fail-fast)、(b) `{mode}` / `{pages_list}` / `{log_entry}` / counter 等の Claude placeholder 残留検知 (各 site で同型 fail-fast)。いずれも設定ミス / 実装ミスを silent に通過させないための設計判断。

矛盾検出 (ステップ 3) と欠落概念検出 (ステップ 6) は LLM のセマンティック読解に依存する。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md) で解決する。共通パターン (ディレクトリ構造 / ブランチ管理 / テンプレート展開) は [Wiki Patterns](../../references/wiki-patterns.md) を参照。

## Arguments

| 引数 | 説明 |
|------|------|
| `--auto` | 自動実行モード（Ingest 完了時に呼び出される想定）。検出結果を `log.md` に `lint:warning` として追記し、通常モードよりも出力を最小化する |
| `--stale-days <N>` | 陳腐化判定の閾値を日数で指定（デフォルト: 90） |

## Examples

```
/rite:wiki:lint
/rite:wiki:lint --auto
/rite:wiki:lint --stale-days 30
```

---

## ステップ 1: 事前チェック

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から `wiki_enabled` / `wiki_branch` / `branch_strategy` を取得する。ingest.md ステップ 1.1 と同型の YAML パーサ。`branch_strategy` 未知値は fail-fast (silent default を撤廃):

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

# branch_strategy: 空文字列は legitimate fallback、未知値は fail-fast (5 site の case * fail-fast と対称化)
case "$branch_strategy" in
  "")
    echo "WARNING: rite-config.yml に wiki.branch_strategy が未設定のため 'separate_branch' を使用します" >&2
    echo "  対処: 意図しない場合は rite-config.yml の wiki.branch_strategy を明示的に設定してください" >&2
    branch_strategy="separate_branch"
    ;;
  separate_branch|same_branch) : ;;
  *)
    echo "ERROR: rite-config.yml の wiki.branch_strategy に未知の値: '$branch_strategy'" >&2
    echo "  受理値: 'separate_branch' / 'same_branch'" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください (typo の可能性)" >&2
    echo "[CONTEXT] LINT_BRANCH_STRATEGY_UNKNOWN=1; value=$branch_strategy" >&2
    exit 1
    ;;
esac

echo "wiki_enabled=$wiki_enabled"
echo "branch_strategy=$branch_strategy"
echo "wiki_branch=$wiki_branch"
```

分散実装の完全一覧と設計差異は [Wiki 有効判定パターン §分散実装ファイル一覧](../../references/wiki-patterns.md#分散実装ファイル一覧-single-source-of-truth) を SoT として参照する。本ファイルは ingest.md と対称な `extract_yaml_key` helper 経由の lenient 2-arm 経路 (#483 opt-out default)。

**Wiki が無効の場合**: 早期 return (`--auto` モードでは ステップ 9.2 の 3 行出力契約を必ず守る):

```bash
# Claude placeholder {mode} 残留 fail-fast gate (glob pattern 版、5 site で同型)
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: ステップ 1.1 早期 return の {mode} placeholder が literal substitute されていません" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  # ステップ 9.2 contract: Lint 1 行 + return signal comment + HTML sentinel の 3 行を出力
  # (stdout 空は ingest 側で「Lint 実行失敗」扱い)
  echo "Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0"
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "<!-- [lint:returned-to-caller:auto] -->"
else
  echo "Wiki 機能が無効です（wiki.enabled: false）。" >&2
  echo "有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki:init を実行してください。" >&2
fi
exit 0
```

`{mode}` placeholder には lint skill 起動時の引数文字列 (`--auto` 等) を Claude が literal substitute する。

### 1.2 GNU date 事前検査

ステップ 4 (陳腐化検出) は `date -d "ISO 8601 string"` に依存する。macOS/BSD 環境では GNU date 非互換のため silent に skip しないよう事前に検査する:

```bash
if date -d "2025-01-01" +%s >/dev/null 2>&1; then
  date_gnu_available="true"
else
  date_gnu_available="false"
  echo "WARNING: GNU date 非互換環境を検出しました。ステップ 4（陳腐化検出）は skip されます" >&2
  echo "  対処: macOS/BSD 環境では coreutils (gdate) のインストールを検討してください" >&2
fi
echo "date_gnu_available=$date_gnu_available"
```

`date_gnu_available=false` の場合、ステップ 4 全体を skip し `n_stale=0` のまま ステップ 5 へ進む (非ブロッキング契約維持)。

### 1.3 Wiki 初期化判定

ステップ 1.1 で取得した `branch_strategy` と `wiki_branch` を使い、Wiki が初期化済みかを判定する:

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
     git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
else
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
fi
```

**Wiki 未初期化の場合**: 早期 return (`--auto` モードでは ステップ 9.2 の 3 行出力契約を必ず守る):

```bash
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: ステップ 1.3 早期 return の {mode} placeholder が literal substitute されていません" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  echo "Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0"
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "<!-- [lint:returned-to-caller:auto] -->"
else
  echo "Wiki が初期化されていません。先に /rite:wiki:init を実行してください。" >&2
fi
exit 0
```

### 1.4 引数の解析とカウンタ変数の初期化

引数から `--auto` と `--stale-days N` を解析する:

| 変数 | 初期値 | 説明 |
|------|--------|------|
| `auto_mode` | `false` | `--auto` 指定時に `true` |
| `stale_days` | `90` | `--stale-days N` で上書き |

**カウンタ変数の初期化** (ステップ 9 完了レポートで参照される):

| 変数 | 初期値 | increment タイミング |
|------|--------|--------------------|
| `n_contradictions` | 0 | ステップ 3 で矛盾検出するごとに +1 |
| `n_stale` | 0 | ステップ 4 で陳腐化検出するごとに +1 |
| `n_orphans` | 0 | ステップ 5 で孤児ページ検出するごとに +1 |
| `n_missing_concept` | 0 | ステップ 6.2 で真の欠落（`ingest:skip` 記録も `sources.ref` 登録も無い）を検出するごとに +1。ingest から呼ばれた場合、ingest 側 ステップ 8.5 で `n_warnings` に加算される（ブロッキング相当） |
| `n_unregistered_raw` | 0 | ステップ 6.2 で `ingest:skip` 記録ありの未登録 raw を検出するごとに +1。意図的に経験則化しなかった raw の informational 指標で `n_warnings` には加算しない |
| `n_broken_refs` | 0 | ステップ 7 で壊れた相互参照検出するごとに +1 |
| `issues[]` | `[]` | 各検出結果を `{category, page, detail}` として append |

---

## ステップ 2: 検査対象の収集

### 2.1 検査対象ブランチの決定

ステップ 8 log.md 追記時を除き lint は **読み取り専用** のため、`git show <branch>:<path>` および `git ls-tree -r --name-only <branch>` で wiki ブランチの内容を読み出す。

### 2.2 branch_strategy の検証と検査対象の一括収集

未知の `branch_strategy` 値を silent に same-branch 扱いしないよう case 文で検証し、`pages_list` / `raw_list` を 1 回の `git ls-tree` で抽出する。非ブロッキング契約に従い `git ls-tree` 失敗時は exit 0 + WARNING + 空 list で継続:

```bash
# signal-specific trap (EXIT/INT/TERM/HUP) で tempfile orphan を防ぐ。
# 詳細は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照。
ls_err=""
_cleanup() { [ -n "${ls_err:-}" ] && rm -f "$ls_err"; return 0; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

pages_list=""
raw_list=""

case "$branch_strategy" in
  separate_branch)
    ls_err=$(mktemp /tmp/rite-wiki-lint-ls-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。ls-tree の詳細エラー情報は失われます" >&2
      ls_err=""
    }
    # 1 回の git ls-tree で pages と raw を抽出 (重複呼び出しの排除)
    if ls_out=$(git ls-tree -r --name-only "$wiki_branch" 2>"${ls_err:-/dev/null}"); then
      pages_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$' || true)
      raw_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/raw/(reviews|retrospectives|fixes)/[^/]+\.md$' || true)
    else
      rc=$?
      echo "WARNING: git ls-tree '$wiki_branch' に失敗しました (rc=$rc)" >&2
      [ -n "$ls_err" ] && [ -s "$ls_err" ] && head -3 "$ls_err" | sed 's/^/  /' >&2
      echo "  対処: wiki ブランチが存在するか確認してください (git rev-parse --verify $wiki_branch)" >&2
      echo "  影響: 検査対象を 0 件として扱い、ステップ 9 で「検査対象なし」を表示します（非ブロッキング）" >&2
    fi
    ;;
  same_branch)
    [ -d ".rite/wiki/pages" ] && pages_list=$(find .rite/wiki/pages -type f -name '*.md' 2>/dev/null || true)
    [ -d ".rite/wiki/raw" ]   && raw_list=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null || true)
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 2.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（5 箇所で同型）" >&2
    exit 1
    ;;
esac

[ -n "$ls_err" ] && rm -f "$ls_err"

# stdout 構造: pages_list 行 → "---" separator → raw_list 行 の 3 部構成
# 空文字列ガード: 旧 `printf '%s\n' ""` は blank line 1 行を emit するため、ステップ 6.2 が
# 「pages_list=1 件 (空文字列)」と誤解釈する余地があった。`[ -n ... ] && printf` で空時は何も emit しない。
[ -n "$pages_list" ] && printf '%s\n' "$pages_list"
echo "---"
[ -n "$raw_list" ] && printf '%s\n' "$raw_list"
```

LLM は stdout から `pages_list` と `raw_list` を会話コンテキストに保持する。両方空ならステップ 3-7 を skip し ステップ 9 に進む (検出結果なしの完了レポート)。

### 2.3 index.md の読み込み

`index_content` を会話コンテキストに保持する。失敗時は非ブロッキング契約に従い warning + ステップ 5（孤児検出）skip で継続する:

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

index_read_ok="true"
# mktemp 失敗時の loud WARNING (Pattern 3 規範: 3 行 emit)。silent fallback では pattern match が
# 不能になり index.md の真の IO エラーが silent に握り潰されて、本来 orphan となるページが
# 検出されない false negative に倒れる。
index_err=$(mktemp /tmp/rite-wiki-lint-index-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (index_err) の mktemp に失敗しました。index.md 読出の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒します (孤児検出 ステップ 5 が skip される可能性)" >&2
  index_err=""
}

if [ "$branch_strategy" = "separate_branch" ]; then
  if index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>"${index_err:-/dev/null}"); then
    # selective surface pattern: 成功時でも ambiguous ref 等の git hint が stderr に出る場合がある
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  WARNING(git hint): /' >&2
  else
    echo "WARNING: index.md を wiki ブランチから読み出せません" >&2
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  /' >&2
    echo "  影響: ステップ 5（孤児ページ検出）を skip します（非ブロッキング）" >&2
    index_content=""
    index_read_ok="false"
  fi
else
  # LC_ALL=C で locale 固定 (ja_JP.UTF-8 等で localize された diagnostic による silent regression を予防)
  if index_content=$(LC_ALL=C cat .rite/wiki/index.md 2>"${index_err:-/dev/null}"); then
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  WARNING(cat hint): /' >&2
  else
    echo "WARNING: .rite/wiki/index.md を読み出せません" >&2
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  /' >&2
    echo "  影響: ステップ 5（孤児ページ検出）を skip します（非ブロッキング）" >&2
    index_content=""
    index_read_ok="false"
  fi
fi

[ -n "$index_err" ] && rm -f "$index_err"
echo "index_read_ok=$index_read_ok"
```

`index_read_ok="false"` の場合、ステップ 5 全体を skip し `n_orphans=0` のまま ステップ 6 へ進む。

---

## ステップ 3: 矛盾検出

### 3.1 ページ frontmatter とタイトル・ドメインの抽出

ステップ 2.2 で収集した各ページについて、`git show` または `cat` で本文を取得し、以下のフィールドを抽出する:

| フィールド | 抽出元 | 用途 |
|-----------|--------|------|
| `title` | YAML frontmatter | タイトル衝突検出 |
| `domain` | YAML frontmatter | ドメイン単位での比較 |
| `updated` | YAML frontmatter | ステップ 4（陳腐化）で使用 |
| `confidence` | YAML frontmatter | 矛盾判定の優先度 |
| 本文（概要・詳細） | frontmatter 除外後 | 方針逆転・重複情報の検出 |

### 3.2 矛盾の判定

LLM が `pages_list` の全ページペアを意味的に比較し、以下の観点で矛盾を検出する:

| 観点 | 検出方法 | 判定例 |
|------|---------|--------|
| **タイトル衝突** | title フィールドが同一または 90% 以上類似 | `エラーハンドリングのパターン` と `エラーハンドリング パターン` |
| **方針逆転** | 同じトピックで `推奨` と `避けるべき` が直接対立 | Page A「X を使う」 / Page B「X は使わない」 |
| **重複情報** | 異なるページに同一の概要・結論が記載 | 概要テキストが 80% 以上一致 |

**セマンティック比較の指針**:

- ページ数が多い場合（> 20）は、まず同じ `domain` 内のペアのみを比較対象とし、cross-domain 比較は domain pair 単位で実施する
- `confidence` が両方 `low` の場合は矛盾判定の優先度を下げる
- 方針逆転の判定には必ず両ページの「詳細」セクションの該当箇所を引用する

### 3.3 検出結果の記録

矛盾を検出したら `issues[]` に append し `n_contradictions` を +1 する:

```
{
  "category": "contradiction",
  "page_a": ".rite/wiki/pages/patterns/error-handling.md",
  "page_b": ".rite/wiki/pages/anti-patterns/error-silent.md",
  "detail": "方針逆転: Page A は try-catch ラップを推奨、Page B は同パターンを anti-pattern として記載",
  "subcategory": "方針逆転"
}
```

`subcategory` は `タイトル衝突` / `方針逆転` / `重複情報` のいずれかを使用する（ステップ 9 の表示で使用）。

---

## ステップ 4: 陳腐化検出

### 4.1 事前条件

ステップ 1.2 で `date_gnu_available="false"` と判定された場合、ステップ 4 全体を skip し `n_stale=0` のまま ステップ 5 へ進む。

### 4.2 updated タイムスタンプの比較

```bash
stale_days="{stale_days}"
current_epoch=$(date +%s)
threshold_seconds=$((stale_days * 86400))
cutoff_epoch=$((current_epoch - threshold_seconds))
echo "cutoff_epoch=$cutoff_epoch"
```

以下のスニペットは LLM が各ページに対して for-loop 内で実行することを前提とする。`{cutoff_epoch}` / `{wiki_branch}` は LLM が ステップ 1.1 / 上の bash block の出力値を literal substitute する (ステップ 2.2 / 2.3 / 6.0 / 6.2 / 8.2 と同じ literal substitute 方式)。`while IFS= read -r page_path; do ...` 形式でループする (word-split 脆弱性を排除、ステップ 6.2 main loop と同型):

```bash
wiki_branch="{wiki_branch}"
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 4.2 の {wiki_branch} placeholder が literal substitute されていません" >&2
    exit 1 ;;
esac

while IFS= read -r page_path; do
  page_content=$(git show "${wiki_branch}:$page_path" 2>/dev/null || cat "$page_path" 2>/dev/null)

  updated_str=$(printf '%s' "$page_content" | awk '/^updated:/ { gsub(/^updated:[[:space:]]*"?|"$/, ""); print; exit }')

  if [ -z "$updated_str" ]; then
    echo "WARNING: $page_path に updated フィールドが存在しません。陳腐化判定を skip します" >&2
    continue
  fi

  date_err=$(mktemp /tmp/rite-wiki-lint-date-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (date_err) の mktemp に失敗しました。$page_path の date エラー詳細は失われます" >&2
    echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
    echo "  影響: stderr pattern match が実行不能になり、日付パース失敗の根本原因が不可視になります" >&2
    date_err=""
  }
  if updated_epoch=$(date -d "$updated_str" +%s 2>"${date_err:-/dev/null}"); then
    :
  else
    echo "WARNING: $page_path の updated フィールド '$updated_str' をパースできません。陳腐化判定を skip します" >&2
    [ -n "$date_err" ] && [ -s "$date_err" ] && head -3 "$date_err" | sed 's/^/  /' >&2
    echo "  対処: ISO 8601 形式（例: 2025-01-01T00:00:00+09:00）で記述してください" >&2
    [ -n "$date_err" ] && rm -f "$date_err"
    continue
  fi
  [ -n "$date_err" ] && rm -f "$date_err"

  if [ "$updated_epoch" -lt "{cutoff_epoch}" ]; then
    current_epoch=$(date +%s)
    days_diff=$(( (current_epoch - updated_epoch) / 86400 ))
    echo "STALE: $page_path (updated: $updated_str, ${days_diff} 日前)"
  fi
done <<< "$pages_list"
```

### 4.3 検出結果の記録

陳腐化を検出したら `issues[]` に append し `n_stale` を +1 する:

```
{
  "category": "stale",
  "page": ".rite/wiki/pages/heuristics/old-pattern.md",
  "updated": "2025-09-01T10:00:00+09:00",
  "days_since_update": 223,
  "detail": "90 日以上更新なし（223 日前）"
}
```

---

## ステップ 5: 孤児ページ検出

### 5.1 事前条件

ステップ 2.3 で `index_read_ok="false"` と判定された場合、ステップ 5 全体を skip し `n_orphans=0` のまま ステップ 6 へ進む。

### 5.2 index.md の「ページ一覧」テーブル解析

`./pages/` や `../pages/` 形式にも対応するよう正規表現を緩和し、pipefail を有効にして grep no-match を `|| true` で明示処理する:

```bash
set -o pipefail

indexed_pages=$(printf '%s\n' "$index_content" \
  | { grep -oE '\]\((\.{0,2}\/?pages/[^)]+)\)' || true; } \
  | sed -E 's/^\]\(//; s/\)$//' \
  | sed -E 's|^\.{0,2}/?||' \
  | LC_ALL=C sort -u)  # LC_ALL=C で locale 固定 (de-duplication 目的で locale 依存は不要)

set +o pipefail

orphan_check_ok="true"
if [ -z "$indexed_pages" ]; then
  echo "WARNING: index.md のページ一覧テーブルから登録済みページを抽出できませんでした" >&2
  echo "  対処: index.md のテーブルフォーマット（| [title](pages/foo.md) | ... |）を確認してください" >&2
  echo "  影響: ステップ 5.3 を skip します（全ページを orphan と誤検出しないため）" >&2
  orphan_check_ok="false"
fi

echo "orphan_check_ok=$orphan_check_ok"
```

### 5.3 孤児ページの判定

**事前条件**: ステップ 5.2 で `orphan_check_ok="false"` の場合は本ステップを skip し `n_orphans=0` のまま ステップ 6 へ進む。

`pages_list` は `.rite/wiki/` プレフィックス付きの相対パスを持つため、`indexed_pages` と比較する前に `.rite/wiki/` プレフィックスを除去して正規化する。LLM は両集合を比較し、差分 (`pages_list_normalized \ indexed_pages`) を `n_orphans` として +1 し `issues[]` に append する:

```
{
  "category": "orphan",
  "page": ".rite/wiki/pages/patterns/new-page.md",
  "detail": "index.md の「ページ一覧」テーブルに未登録"
}
```

---

## ステップ 6: 欠落概念検出

ステップ 6 は検出結果を 2 カテゴリに分ける:

- **`missing_concept`**: `ingested: true` の raw source のうち、対応ページも `sources.ref` 登録も `ingest:skip` 記録も存在しない真の欠落。`n_warnings` に加算（ブロッキング相当）
- **`unregistered_raw`**: `ingested: true` で `sources.ref` 未登録だが `log.md` に `ingest:skip` 記録がある raw source。意図的に経験則化しなかった informational 指標（`n_warnings` 不加算）

### 6.0 `ingest:skip` 済み raw source の集合構築

ステップ 6.2 で参照する `skipped_refs` 集合を `log.md` から抽出する。`branch_strategy` に応じて読み出し元を切り替え、非ブロッキング契約に従い読み出し失敗時は空集合で継続するが、**legitimate absence** (fresh branch / ENOENT / blob not found) と **真の IO error** (permission / 破損 / wiki_branch race) を stderr pattern matching で区別する:

```bash
# signal-specific trap (canonical 4 行パターン)。
# 詳細は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照。
log_err=""
awk_sort_err=""
_cleanup() {
  [ -n "${log_err:-}" ] && rm -f "$log_err"
  [ -n "${awk_sort_err:-}" ] && rm -f "$awk_sort_err"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# skipped_refs 空継続時の「影響」文言 helper (4 site の literal duplicate を集約)
_rite_log_read_impact_advice() {
  echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
}

# stderr 退避失敗 + tool 失敗の複合経路の helper (separate_branch / same_branch で tool 名のみ異なる)
_rite_log_read_sub_path_warning() {
  local tool_desc="$1" remedy_target="$2" rc="$3"
  echo "WARNING: .rite/wiki/log.md の ${tool_desc} に失敗し、かつ stderr 退避も失敗しました (rc=${rc}、原因区別不能のため io_error 扱い)" >&2
  _rite_log_read_impact_advice
  echo "  対処: /tmp の容量 / permission と ${remedy_target} を確認してください" >&2
}

log_err=$(mktemp /tmp/rite-wiki-lint-p60-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (log_err) の mktemp に失敗しました。log.md 読み出しの詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒れ、false positive note が常に表示される regression が起き得ます" >&2
  log_err=""
}

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

skipped_refs=""
log_content=""
# log_read_ok は 4 値 enum (unknown / true / absent / io_error)。
#   unknown: 初期値 (branch_strategy fail-fast 経路でのみ残る、後段未到達)
#   true:    log.md 読出成功
#   absent:  legitimate absence (fresh branch / ENOENT / blob not found) — skipped_refs="" は妥当
#   io_error: 真の IO error — false positive リスクあり、ステップ 9.1 完了レポートで note 表示
# canonical 定義: references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout
log_read_ok="unknown"

# branch_strategy を case で検証 (5 site で同型の fail-fast)
case "$branch_strategy" in
  separate_branch)
    # LC_ALL=C で locale 固定 — ja_JP.UTF-8 等で git の stderr メッセージが翻訳されると legitimate
    # absence 判別 regex (does not exist / No such file) と不一致になり io_error に誤分類される silent regression を防ぐ。
    if log_content=$(LC_ALL=C git show "${wiki_branch}:.rite/wiki/log.md" 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      # selective surface pattern: 成功時でも ambiguous ref hint 等の git stderr を surface する
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  WARNING(git hint): /' >&2
    else
      rc=$?
      # legitimate absence 判別 (4 pattern を OR):
      #   - "does not exist": blob not found (標準的な legitimate absence)
      #   - "path '...' exists on disk, but not in": git show の path 対 ref 不整合
      #   - "Not a valid object name": 古い git の revspec 不正メッセージ
      #   - "fatal: invalid object name '<ref>:<path>'": blob path 指定形式
      # 4 pattern いずれも match しない場合 (典型: blob path なしの "fatal: invalid object name 'wiki'") は
      # wiki_branch 自体の race 消失として io_error 扱いとする (ステップ 1.3 後の race 検出)。
      if [ -n "$log_err" ] && [ -s "$log_err" ] && \
         grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:\\.rite/wiki/log\\.md'" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の git show に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: wiki branch の integrity / 権限を確認してください" >&2
      else
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "git show" "wiki branch の integrity / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  same_branch)
    if log_content=$(LC_ALL=C cat .rite/wiki/log.md 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  WARNING(cat hint): /' >&2
    else
      rc=$?
      if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "No such file or directory|cannot open" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の cat に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: .rite/wiki/log.md の存在 / 権限を確認してください" >&2
      else
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "cat" ".rite/wiki/log.md の存在 / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 6.0)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# log.md から ingest:skip レコードを抽出 (field 3 厳密一致、field 4 prefix 正規化)
if [ -n "$log_content" ]; then
  set -o pipefail
  awk_sort_err=$(mktemp /tmp/rite-wiki-lint-p60-awk-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: awk/sort stderr 退避 tempfile の mktemp に失敗しました" >&2
    echo "  対処: /tmp の容量 / inode 枯渇 / read-only filesystem / permission を確認してください" >&2
    echo "  影響: pipeline 失敗時の詳細エラー情報 (awk syntax error / sort OOM 等) が失われます" >&2
    awk_sort_err=""
  }
  skipped_refs=$(printf '%s\n' "$log_content" \
    | awk -F'|' 'NF >= 4 {
        action=$3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", action)
        if (action == "ingest:skip") {
          target=$4
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
          sub(/^\.rite\/wiki\//, "", target)
          if (length(target) > 0) print target
        }
      }' 2>"${awk_sort_err:-/dev/null}" \
    | LC_ALL=C sort -u 2>>"${awk_sort_err:-/dev/null}")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: ステップ 6.0 の awk/sort pipeline が失敗しました (rc=$rc)" >&2
    [ -n "$awk_sort_err" ] && [ -s "$awk_sort_err" ] && head -3 "$awk_sort_err" | sed 's/^/  /' >&2
    echo "  対処: awk / sort バイナリと /tmp の容量を確認してください" >&2
    _rite_log_read_impact_advice
    skipped_refs=""
    # log_read_ok="true" のまま据え置くと ステップ 9.1 で false positive note が展開されず silent 表示
    # になる。awk/sort 失敗経路でも io_error に降格させ note 展開を発火させる
    # (canonical: references/bash-cross-boundary-state-transfer.md Pattern 3 の「後段 pipeline 失敗も同 enum の io_error 側に降格する」)。
    log_read_ok="io_error"
  fi
  set +o pipefail
fi

# 集合本体を marker block で stdout 出力 (ステップ 6.2 の (b) 分岐で LLM が会話コンテキストに保持する)。
# canonical: references/bash-cross-boundary-state-transfer.md#pattern-2-marker-delimited-multi-value-block
if [ -n "$skipped_refs" ]; then
  count=$(printf '%s\n' "$skipped_refs" | awk 'NF>0 {n++} END {print n+0}')
  echo "skipped_refs_count=$count"
  echo "---skipped_refs_begin---"
  printf '%s\n' "$skipped_refs"
  echo "---skipped_refs_end---"
else
  echo "skipped_refs_count=0"
  echo "---skipped_refs_begin---"
  echo "---skipped_refs_end---"
fi

# log_read_ok を stdout 出力 (LLM が ステップ 9.1 完了レポートで参照する契約)
echo "log_read_ok=$log_read_ok"

# 明示的 tempfile rm + 変数 reset (trap と冗長だが defense-in-depth: 後続 block の同名 path re-mktemp 競合防止)
[ -n "$log_err" ] && rm -f "$log_err"; log_err=""
[ -n "$awk_sort_err" ] && rm -f "$awk_sort_err"; awk_sort_err=""
```

**`log_read_ok` 4 値 enum による状態伝達**: bash 変数は Bash tool 呼び出し境界を超えて失われるため、`log_read_ok` を stdout に `log_read_ok={value}` 形式で出力する:

| 値 | 意味 | ステップ 9.1 完了レポートでの扱い |
|----|------|---------------------------------|
| `unknown` | 初期値 (branch_strategy fail-fast で後段未到達のときのみ残る) | 表示しない (後段未実行) |
| `true` | log.md 読出成功 | 通常表示 (false positive なし) |
| `absent` | legitimate absence (fresh branch / ENOENT / blob not found) | 通常表示 (skip 記録なしは妥当) |
| `io_error` | 真の IO error (permission / 破損 / race) | ⚠️ note 表示「log.md 読出失敗により `missing_concept` 件数に false positive を含む可能性あり」 |

**LLM による集合保持の契約**: 上記 bash block の stdout に `---skipped_refs_begin---` / `---skipped_refs_end---` で挟まれた行を LLM が会話コンテキストに保持し、ステップ 6.2 の (b) 分岐判定材料とする。0 件でも begin/end marker は必ず出力される (集合構築ステップが実行されたことの positive confirmation)。

### 6.1 Ingest 済み Raw Source の列挙

ステップ 2.2 で収集した `raw_list` から、frontmatter の `ingested: true` を持つファイルを抽出する。`ingested` フィールド不在は `false` 扱い (未統合) として明示する:

```bash
# 各 raw_file について:
raw_content=$(git show "${wiki_branch}:$raw_file" 2>/dev/null || cat "$raw_file" 2>/dev/null)

ingested=$(printf '%s' "$raw_content" | awk '/^ingested:/ { gsub(/^ingested:[[:space:]]*"?|"$/, ""); print; exit }')
ingested="${ingested:-false}"  # 未設定は false 扱い

raw_title=$(printf '%s' "$raw_content" | awk '/^title:/ { gsub(/^title:[[:space:]]*"?|"$/, ""); print; exit }')

if [ "$ingested" = "true" ]; then
  # ステップ 6.2 の対応ページ確認へ
  :
fi
```

### 6.2 対応ページの存在確認と 3 分岐

`raw_list` のパスは `.rite/wiki/` プレフィックス付き (例: `.rite/wiki/raw/reviews/20260410T...md`) で取得されているため、`sources[].ref` および ステップ 6.0 の `skipped_refs` と比較する前に両辺から `.rite/wiki/` を除去して `raw/{type}/{filename}` 形式に正規化する:

1. `pages_list` の各 Wiki ページ本文を取得し、frontmatter `sources[].ref` を抽出して `all_source_refs` 集合を保持する (step 3(a) で参照される)
2. `raw_list` の各 Raw Source について `.rite/wiki/` プレフィックスを除去した相対パスを計算
3. 相対パスを以下の優先順で 3 分岐する:
   - **(a) 登録済み**: step 1 の `all_source_refs` のいずれかに含まれる → 何もしない (健全)
   - **(b) 未登録だが skip 記録あり**: ステップ 6.0 の `skipped_refs` 集合に含まれる → ステップ 6.3 の `unregistered_raw` として記録
   - **(c) 真の欠落**: 上記いずれにも該当しない → LLM が Raw Source 本文を読み経験則として価値がある内容か判定した上で ステップ 6.3 の `missing_concept` として記録 (単なるエラーログや空コメントは除外)

**`all_source_refs` の集合構築** (ステップ 6.0 の `skipped_refs` と対称な marker block + io_error 3 値 enum) は `wiki-lint-source-refs.sh` に委譲する。

> **Reference**: 集合構築の canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-source-refs.sh`。helper は per-page の `git show`(separate_branch) / `cat`(same_branch) 読出・`sources[].ref` 抽出 (legacy 単行形式 `- ref:` と canonical multi-line 形式 ` ref:` の両対応)・legitimate absence と真の io_error の `LC_ALL=C` 固定 stderr pattern 判別・`sort -u` 重複排除・marker block / read_ok enum 出力・signal-specific trap cleanup をすべて内包する (旧 ~240 行 inline 実装を委譲)。placeholder residue gate / partial pollution gate も helper 内に移設済み。state machine 契約 (marker block + io_error 3 値 enum) は `references/bash-cross-boundary-state-transfer.md` の Pattern 1/2 を参照。

**Bash tool 呼び出し境界での state 伝達**: ステップ 1.1 の `branch_strategy` / `wiki_branch` と ステップ 2.2 の `pages_list` は別 Bash tool 呼び出しで定義されているため、Claude は会話コンテキストから literal substitute する。`branch_strategy` / `wiki_branch` は helper の `--branch-strategy` / `--wiki-branch` arg、`pages_list` は stdin (HEREDOC、single-quoted delimiter で shell expansion 抑制) で渡す。

**`{pages_list}` substitute 契約**: ステップ 2.2 stdout は「pages_list 行 → '---' separator → raw_list 行」の 3 部構成。LLM は **pages_list ブロックのみ** (separator より前の `.rite/wiki/pages/...` 行のみ) を HEREDOC に substitute する。`.rite/wiki/raw/...` 行を含めると helper の partial pollution gate が fail-fast (exit 1) する (旧 silent missing_concept 誤分類の再発防止契約)。空 HEREDOC は Wiki 初期化直後 / 0 件で legitimate。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-source-refs.sh" ]; then
  # helper 不在: all_source_refs を io_error 扱いにして ステップ 9.1 の false positive note を展開する。
  # silent 空集合だと真の欠落 (missing_concept) 判定が false positive になるため、
  # 「marker 未受信 → io_error 同等扱い」契約 (本節末尾) と整合する形で io_error を明示出力する。
  echo "WARNING: wiki-lint-source-refs.sh が見つからないため all_source_refs を io_error 扱いにします (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "  対処: rite プラグインのソースツリーから実行するか、.rite-plugin-root を確認してください" >&2
  echo "---all_source_refs_begin---"
  echo "---all_source_refs_end---"
  echo "all_source_refs_read_ok=io_error"
  echo "all_source_refs_read_errors=0"
else
  # branch_strategy / wiki_branch は arg、pages_list は stdin。
  # placeholder residue gate / partial pollution gate は helper 内で実行される。
  bash "$plugin_root/hooks/scripts/wiki-lint-source-refs.sh" \
    --branch-strategy "{branch_strategy}" \
    --wiki-branch "{wiki_branch}" <<'PAGES_LIST_EOF'
{pages_list}
PAGES_LIST_EOF
fi
```

**`skipped_refs` 集合の参照方法**: ステップ 6.0 の bash block 終了後、LLM は stdout から `---skipped_refs_begin---` と `---skipped_refs_end---` で囲まれた行を抽出して会話コンテキストに集合として保持する。ファイルパスの比較は両辺を `raw/{type}/{filename}` 形式に正規化してから完全一致で判定する。

**marker block 未受信時の fallback** (silent false positive 防止): step 3 の 3 分岐は LLM が stdout の marker block を会話コンテキストに保持する契約に依存する。bash block が途中異常終了 (SIGPIPE / OOM / 構文 error / LLM context truncation) で marker block 自体を受信できなかった場合、当該集合を「空」と同視してはならない:

- `---skipped_refs_begin---` / `---skipped_refs_end---` のいずれかが欠落 → `log_read_ok="io_error"` と同等扱い、ステップ 9.1 の false positive note を展開
- `---all_source_refs_begin---` / `---all_source_refs_end---` のいずれかが欠落 → `all_source_refs_read_ok="io_error"` と同等扱い、ステップ 9.1 の false positive note を展開

### 6.3 検出結果の記録

**真の欠落 (missing_concept)**:

```
{
  "category": "missing_concept",
  "raw_source": ".rite/wiki/raw/reviews/20260410T...md",
  "title": "PR #123 review findings",
  "detail": "Ingest 済みだが対応ページも ingest:skip 記録も存在しない"
}
```

`n_missing_concept` を +1。

**未登録 raw (unregistered_raw)**:

```
{
  "category": "unregistered_raw",
  "raw_source": ".rite/wiki/raw/reviews/20260417T...md",
  "title": "Final mergeable check after fix retries",
  "detail": "ingest:skip 済みで経験則化されなかった raw（log.md に skip 記録あり）"
}
```

`n_unregistered_raw` を +1 (`n_warnings` には加算されない informational カウンタ)。

---

## ステップ 7: 壊れた相互参照検出

### 7.1 ページ本文の Markdown リンク抽出

各 Wiki ページ本文から Markdown リンク `[text](path)` を抽出する。コードブロック (` ``` ` 囲み) と画像リンク (`![alt](path)`) はいずれも対象外:

```bash
set -o pipefail

# 順序:
#   1. コードブロック削除を最初に行わないと、内部の画像/通常リンクが個別に抽出されてしまう
#   2. 画像リンク除去はコードブロック外でのみ意味を持つため (1) の後
#   3. 通常リンク `[text](path)` 抽出
#   4. アンカー (#section) を除去してから pages_list と突合する
page_links=$(printf '%s' "$page_content" \
  | sed -E '/^```/,/^```/d' \
  | sed -E 's/!\[[^]]*\]\([^)]*\)//g' \
  | { grep -oE '\]\([^)]+\)' || true; } \
  | sed -E 's/^\]\(//; s/\)$//' \
  | sed -E 's/#.*$//')

# ステップ 7.2 の突合用に prefix 除去版を生成 ([Broken Reference Resolution](./references/broken-ref-resolution.md) L56-57 が要求する形式)
pages_list_normalized=$(printf '%s\n' "$pages_list" | sed -E 's|^\.rite/wiki/||' | grep -v '^$' || true)
raw_list_normalized=$(printf '%s\n' "$raw_list" | sed -E 's|^\.rite/wiki/||' | grep -v '^$' || true)

set +o pipefail
```

**コードブロック除外の限界**: `sed -E '/^```/,/^```/d'` は ` ``` ` が行頭にある case のみを削除する。インデント付きコードブロック (例: list 項目内の 2-space indent fence) や行中の ``` (例: `「```」` のような説明文中の引用) は対象外。awk -ベースで fence 開閉を indent 不問で track する改善は今後の課題。

### 7.2 相互参照の妥当性判定

| リンク種別 | 判定方法 |
|----------|---------|
| **相対パス (`./pages/...`, `../pages/...`)** | アンカー (`#section`) を除去し、ページファイルのディレクトリ (`page_dir`) 起点で正規化してから、ステップ 2.2 で取得した `pages_list` (`.rite/wiki/` プレフィックス付き) と突合する。突合前に両側から `.rite/wiki/` プレフィックスを除去する (詳細は [Broken Reference Resolution](./references/broken-ref-resolution.md) 参照) |
| **絶対パス (`/pages/...`)** | 対象外（HTTP URL 等の可能性） |
| **外部 URL (`http://...`, `https://...`)** | 対象外（lint 対象外） |
| **アンカーのみ (`#section`)** | 対象外（同一ファイル内参照） |
| **Raw Source 参照 (`raw/...`)** | `raw_list` に対し同様にアンカー除去 + `page_dir` 起点解決 + `.rite/wiki/` プレフィックス除去で突合 |

**解決規約**: 相対パスは「ページファイルのディレクトリを起点に `realpath -m -s` で正規化してから、`.rite/wiki/` プレフィックスを除去した `pages_list` と完全一致で突合」する。文字列マッチ (`grep -F` で生 link 値を直接突合) は禁止 — `./` / `../` / 連続スラッシュの差で false positive / negative が両方発生する。canonical bash 実装と edge case は [Broken Reference Resolution](./references/broken-ref-resolution.md) を参照。

**アンカー除去ルール**: 相対パスリンクの `#...` 部分を切り落としてから実在確認を行う（例: `pages/foo.md#section` → `pages/foo.md` として照合）。

**URL 内の `)` を含むリンク**: 現行の `[^)]+` regex では検出対象外とする既知の限界。実運用では Wiki 内で括弧付き URL を使わない規約で回避。

壊れた参照を検出したら `issues[]` に append し `n_broken_refs` を +1 する:

```
{
  "category": "broken_ref",
  "page": ".rite/wiki/pages/heuristics/pattern-a.md",
  "link": "../patterns/deleted-page.md",
  "detail": "リンク先ファイルが存在しない"
}
```

---

## ステップ 8: log.md 追記

### 8.1 検出結果の log.md 記録

Lint 完了後、`.rite/wiki/log.md` に以下の形式で **append-only** でエントリを追記する:

| 列 | 値 |
|----|-----|
| 日時 | 現在の ISO 8601 タイムスタンプ |
| アクション | `lint:clean` / `lint:warning`（下記判定基準参照） |
| 対象 | `—`（全体チェック） |
| 詳細 | `contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` |

**`lint:clean` / `lint:warning` の判定基準** (`n_unregistered_raw` は informational で判定に含めない):

- `lint:clean`: ブロッキングカテゴリ 5 種 (`n_contradictions`, `n_stale`, `n_orphans`, `n_missing_concept`, `n_broken_refs`) **すべてが 0** の場合。`n_unregistered_raw` の値に依存しない (`n_unregistered_raw > 0` でも他 5 カテゴリが全 0 なら `lint:clean`)
- `lint:warning`: 上記 5 カテゴリのいずれか 1 つ以上が `> 0` の場合。`n_unregistered_raw` は判定から除外する (Issue #563 の「`unregistered_raw` は informational で `n_warnings` 不加算」仕様に準拠、log.md に false warning を記録して growth_check を歪めることを防ぐ)

**`lint_action` 自動判定** (Pattern 1: `[CONTEXT] key=value` stdout emit、Issue #573): 上記 prose 判定基準を LLM 解釈から切り離し、bash block で機械的に決定して stdout に emit する。ステップ 8.3 の `{log_entry}` 組み立てはこの emit 値を **single source of truth** として参照する:

```bash
# ステップ 8.1 canonical lint_action decision logic (ステップ 8.3 sibling sync 契約相手)
# 本 bash block の判定ロジックは上記「`lint:clean` / `lint:warning` の判定基準」prose と一字一句同期する。
# canonical reference: references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout
set -o pipefail

n_contradictions={n_contradictions}
n_stale={n_stale}
n_orphans={n_orphans}
n_missing_concept={n_missing_concept}
n_broken_refs={n_broken_refs}
# 参考: n_unregistered_raw={n_unregistered_raw} — 判定式から意図的に除外 (informational、Issue #563)

# Placeholder residue fail-fast gate (5 site で同型): LLM が literal substitute を忘れると
# `[ "{n_contradictions}" -gt 0 ]` が rc=2 を返し、set -o pipefail のみでは検知できず else 分岐に
# 流れて `lint_action="lint:clean"` が silent emit される fail-silent regression を防ぐ。
for _n_var in n_contradictions n_stale n_orphans n_missing_concept n_broken_refs; do
  _n_val=$(eval echo \$"$_n_var")
  case "$_n_val" in
    ""|*[!0-9]*|"{"*"}")
      echo "ERROR: ステップ 8.1 の $_n_var が literal substitute されていないか非整数です (値: '$_n_val')" >&2
      echo "  LLM は ステップ 3-7 で累積したカウンタ値を非負整数の literal で置換する必要があります" >&2
      echo "[CONTEXT] LINT_PHASE_8_1_PLACEHOLDER_RESIDUE=1; variable=$_n_var; value=$_n_val" >&2
      exit 1
      ;;
  esac
done

if [ "$n_contradictions" -gt 0 ] \
   || [ "$n_stale" -gt 0 ] \
   || [ "$n_orphans" -gt 0 ] \
   || [ "$n_missing_concept" -gt 0 ] \
   || [ "$n_broken_refs" -gt 0 ]; then
  lint_action="lint:warning"
else
  lint_action="lint:clean"
fi
echo "[CONTEXT] lint_action=$lint_action"
```

### 8.2 書き込み先パスの決定

`branch_strategy` の値に応じて書き込み先パスを決定する (5 site で同型の case 文 + fail-fast):

```bash
branch_strategy="{branch_strategy}"

case "$branch_strategy" in
  same_branch)
    log_path=".rite/wiki/log.md"
    ;;
  separate_branch)
    log_path=".rite/wiki-worktree/.rite/wiki/log.md"
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 8.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac
echo "log_path=$log_path"
```

### 8.3 書き込み手順

**`{log_entry}` / `{log_path}` placeholder source 契約**:

| placeholder | source | 責務 |
|-------------|--------|------|
| `{log_path}` | ステップ 8.2 bash block の `echo "log_path=$log_path"` | LLM は会話コンテキストから `log_path=` 行を grep し literal substitute |
| `{log_entry}` | **LLM が ステップ 8.1 table から組み立てる** | LLM は ステップ 1.4 / 3-7 で蓄積された Lint カウンタ値を 6 フィールド形式 (`contradictions={n}, stale={n}, ...`) に埋め込み 1 行の log.md 追記文字列として生成する。**アクション列は LLM 独自判定ではなく、ステップ 8.1 bash block が emit する `[CONTEXT] lint_action=...` 行を first-match で抽出し、`=` 右辺の enum 値 (`lint:clean` / `lint:warning`) を literal 代入する** (Issue #573、Pattern 1 準拠 — prose 判定基準の LLM 解釈 drift を排除) |

**書き込み手順**:

1. Edit ツールで `{log_path}` (ステップ 8.2 で出力された値を literal substitute) に ステップ 8.1 table に基づく log.md 追記行を **append-only** で追加する。**注意**: シェル変数 `$log_path` は Bash ツール呼び出し境界を超えると失われ、Edit ツールはシェル変数を解釈しない。`echo "log_path=..."` 出力を会話文脈から拾って literal value で置換する
2. 以下の bash ブロックで commit + push する (`{log_entry}` は LLM が上記契約に従い ステップ 8.1 table から生成した literal 文字列で substitute する)

```bash
# ステップ 8.3: log.md 追記後の commit
# lint.md 内で唯一 set -euo pipefail を使う phase。他 phase は set -o pipefail のみ (非ブロッキング契約のため
# stdout 空吐き出し経路を意図的に許容)。本 phase は外部 script 呼出 + commit msg placeholder gate を持つため
# set -e が必要。外部 script rc capture は separate_branch 経路の commit_out capture 直前で `set +e` する。
set -euo pipefail

# plugin_root の inline 解決 (lint.md には専用解決ステップがないため inline)
branch_strategy="{branch_strategy}"
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi' || true)
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "WARNING: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}'). log.md 追記の commit を skip します (非ブロッキング契約)" >&2
  exit 0
fi

# {log_entry} placeholder 残留検知 fail-fast gate (5 site で同型)
log_entry="{log_entry}"
case "$log_entry" in
  "{"*"}")
    echo "ERROR: ステップ 8.3 の {log_entry} placeholder が literal substitute されていません (値: '$log_entry')" >&2
    echo "  対処: LLM は ステップ 8.1 table の Lint カウンタ値から 6 フィールド形式の 1 行文字列を組み立て、本 bash block 冒頭の log_entry= 行を実際の値で置換する必要があります" >&2
    exit 1
    ;;
esac

commit_msg="docs(wiki): lint report — ${log_entry}"

case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 8.3 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    exit 1
    ;;
  separate_branch)
    # set -euo pipefail 下で commit_out=$(bash ...) が rc != 0 のとき bash が即時 exit する罠を回避。
    # set +e で囲み rc capture を保証する。2>&1 は付けない (構造化 stdout / WARNING stderr の責務分離維持)。
    set +e
    commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
    commit_rc=$?
    set -e
    echo "$commit_out"
    # lint は非ブロッキング契約のため exit 1 はせず、すべて WARNING のみで継続する
    case "$commit_rc" in
      0) : ;;
      2) echo "[CONTEXT] WIKI_LINT_COMMIT=skipped; reason=wiki-disabled-or-no-pending" >&2 ;;
      3) echo "WARNING: wiki-worktree-commit.sh で git 操作失敗 (rc=3)。log.md 追記は非ブロッキングのため継続します" >&2 ;;
      4) echo "WARNING: wiki-worktree-commit.sh で commit landed but push 失敗 (rc=4)。次回再 push が必要" >&2 ;;
      *) echo "WARNING: wiki-worktree-commit.sh が予期しない rc=$commit_rc で失敗しました。log.md 追記は非ブロッキングのため継続します" >&2 ;;
    esac
    ;;
  same_branch)
    # signal-specific trap (canonical 4 行パターン)
    add_err=""
    commit_err=""
    _cleanup() {
      [ -n "${add_err:-}" ] && rm -f "$add_err"
      [ -n "${commit_err:-}" ] && rm -f "$commit_err"
      return 0
    }
    trap 'rc=$?; _cleanup; exit $rc' EXIT
    trap '_cleanup; exit 130' INT
    trap '_cleanup; exit 143' TERM
    trap '_cleanup; exit 129' HUP

    # mktemp 失敗時の loud WARNING (Pattern 3 規範): silent fallback では pre-commit hook /
    # gpg sign / index lock 等の根本原因が不可視になる。
    add_err=$(mktemp /tmp/rite-lint-add-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile (add_err) の mktemp に失敗しました。git add の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: index lock / permission denied 等の根本原因が不可視になります" >&2
      add_err=""
    }
    commit_err=$(mktemp /tmp/rite-lint-commit-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile (commit_err) の mktemp に失敗しました。git commit の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: pre-commit hook / gpg sign / author config 失敗の根本原因が不可視になります" >&2
      commit_err=""
    }

    if ! git add .rite/wiki/log.md 2>"${add_err:-/dev/null}"; then
      echo "WARNING: git add .rite/wiki/log.md に失敗しました" >&2
      [ -n "$add_err" ] && [ -s "$add_err" ] && head -3 "$add_err" | sed 's/^/  /' >&2
      echo "  対処: index lock / permission denied / path error のいずれかを確認してください" >&2
      exit 0
    fi

    if ! git commit -m "$commit_msg" 2>"${commit_err:-/dev/null}"; then
      echo "WARNING: log.md のコミットに失敗しました" >&2
      [ -n "$commit_err" ] && [ -s "$commit_err" ] && head -3 "$commit_err" | sed 's/^/  /' >&2
      echo "  対処: pre-commit hook / gpg sign / author config / permission のいずれかを確認してください" >&2
    fi

    [ -n "$add_err" ] && rm -f "$add_err"
    [ -n "$commit_err" ] && rm -f "$commit_err"
    trap - EXIT INT TERM HUP
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 8.3)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac
# 非ブロッキング契約: 失敗しても exit 0 で継続
```

**書き込み失敗時**: 検出結果は既に stdout に表示済みのため、log.md 追記失敗は WARNING を出して exit 0 で継続する (非ブロッキング契約維持)。

---

## ステップ 9: 完了レポート

### 9.1 通常モードの出力

```
Wiki Lint が完了しました。

検査サマリー:
- 検査した Wiki ページ: {n_pages} 件
- 検査した Raw Source: {n_raw} 件

検出結果:
- 矛盾: {n_contradictions} 件
- 陳腐化: {n_stale} 件
- 孤児ページ: {n_orphans} 件
- 欠落概念: {n_missing_concept} 件{log_read_ok_note}{all_source_refs_read_ok_note}
- 壊れた相互参照: {n_broken_refs} 件
- 未登録 raw（skip 済）: {n_unregistered_raw} 件（informational、`n_warnings` 不加算）

{log_read_ok_warning}{all_source_refs_read_ok_warning}

検出詳細:
{issues_list_formatted}

次のステップ:
- 矛盾は手動で該当ページを統合してください
- 陳腐化ページは /rite:wiki:ingest で新しい Raw Source を統合するか、手動で updated フィールドを更新してください
- 孤児ページは index.md に追加するか、不要なら削除してください
- 欠落概念は /rite:wiki:ingest で該当 Raw Source を再処理してください
- 壊れた相互参照は該当ページを手動で修正してください
- 未登録 raw（skip 済）は意図的な `ingest:skip` なら放置で OK。skip 記録を取り消して経験則化したい場合は /rite:wiki:ingest で再処理してください
```

**`{n_pages}` / `{n_raw}` 展開ルール**: LLM は ステップ 2.2 bash block stdout から `pages_list` / `raw_list` を会話コンテキストに保持している。各配列の要素数（空行と `---` separator を除いた非空行の数）を数えて展開する。両 list が空の場合は `0`。

**`{log_read_ok_note}` / `{log_read_ok_warning}` / `{all_source_refs_read_ok_note}` / `{all_source_refs_read_ok_warning}` 展開ルール**:

LLM は ステップ 6.0 stdout から `log_read_ok={value}`、ステップ 6.2 stdout から `all_source_refs_read_ok={value}` を読み取り、それぞれ独立に展開する。ステップ 6.0 / 6.2 が実行されなかった場合 (`pages_list` と `raw_list` が両方空でステップ 3-7 が skip された経路) は両 placeholder を空文字列として展開する:

| enum 値 | `{..._note}` (行末 note) | `{..._warning}` (block warning) |
|--------|------------------------|--------------------------------|
| `true` | 空文字列 | 空文字列 |
| `absent` (log_read_ok のみ) | 空文字列 | 空文字列 |
| `io_error` (log_read_ok) | ` ⚠️ (log.md 読出失敗により false positive を含む可能性あり)` | `⚠️ log.md 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。separate_branch なら wiki branch の log.md blob integrity、same_branch なら \`.rite/wiki/log.md\` の存在 / 権限を確認して /rite:wiki:lint を再実行してください。` |
| `io_error` (all_source_refs_read_ok) | ` ⚠️ (ページ frontmatter 読出失敗により sources.ref 集合が不完全、false positive を含む可能性あり)` | `⚠️ ページ frontmatter 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。Wiki ページ格納先 (wiki branch or \`.rite/wiki/pages/\` filesystem) の integrity / 権限を確認して /rite:wiki:lint を再実行してください。` |
| `unknown` | 空文字列 (この状態では通常 ステップ 9.1 に到達しない) | 空文字列 |
| `(未 emit: ステップ 6.0 / 6.2 skip、処理対象 0 件)` | 空文字列 | 空文字列 |

**空行処理ルール (3 行ブロック原子的扱い)**: template は `{log_read_ok_warning}{all_source_refs_read_ok_warning}` を中心に 3 行ブロック (直前空行 / placeholder 行 / 直後空行) を持つ。LLM は以下のルールで 3 行すべてを原子的に展開する:

| 2 warning placeholder の合成値 | 3 行ブロックの展開 |
|-------------------------------|-------------------|
| 両方とも空文字列 (`true` / `absent`) | **3 行すべて省略** (前段「未登録 raw」行の直後に後段「検出詳細:」行を隣接させる) |
| 片方が非空 + もう片方が空文字列 | **3 行すべて展開** (空行 + 非空 warning 1 行 + 空行) |
| 両方が非空 (両 enum が `io_error`) | **3 行展開 + 2 warning の間に改行挿入** (空行 + warning + 改行 + warning + 空行) |

`{issues_list_formatted}` は `issues[]` の各要素をカテゴリ別にグループ化し、以下の形式で表示する:

```
### 矛盾
- [方針逆転] pages/patterns/x.md ↔ pages/anti-patterns/y.md
  X を使う vs X は使わない

### 陳腐化
- pages/heuristics/old.md (223 日前)

### 孤児ページ
- pages/patterns/new.md

### 欠落概念
- raw/reviews/20260410T...md (PR #123 review findings)

### 壊れた相互参照
- pages/heuristics/a.md → ../patterns/deleted.md

### 未登録 raw（skip 済）
- raw/reviews/20260417T...md (cycle 5 final mergeable 確認のみ)
```

### 9.2 `--auto` モードの出力

Ingest 完了直後に呼ばれる場合、出力は最小化される。`--auto` モードの stdout は次の 3 行を **この順序で** 出力する:

```
Lint: contradictions={n_contradictions}, stale={n_stale}, orphans={n_orphans}, missing_concept={n_missing_concept}, unregistered_raw={n_unregistered_raw}, broken_refs={n_broken_refs}
<!-- skill return signal: caller must continue next step -->
<!-- [lint:returned-to-caller:auto] -->
```

1. **6 フィールド 1 行** (`Lint: contradictions=N, ...`): ingest 側の `^Lint: contradictions=` regex parser 互換 (形式不変)
2. **Return signal comment** (`<!-- skill return signal: caller must continue next step -->`): caller (ingest 等) が次 step を skip しないよう active disambiguation
3. **HTML コメント sentinel** (`<!-- [lint:returned-to-caller:auto] -->`): 最終行に出力。rendered view では不可視で `grep -F '[lint:returned-to-caller:auto]'` で検出可能

検出件数が全て 0 の場合も含めて常にこの 3 行を出力する。空 stdout は ingest 側で「lint 実行失敗」として扱われる。

> **Why `returned-to-caller` (not `completed`)**: 旧 `lint:completed:auto` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、caller skill (ingest 等) の次 step を skip して turn が暗黙終了する事象が複数回再発した (Issue #1165)。`returned-to-caller` は「caller に return した = caller の次 step に進む」という semantic に置換することで、terminal vocabulary を構造的に排除する。

### 9.3 exit code

- **原則 exit 0**: 検出件数・事前チェック失敗・ブランチ読取失敗のいずれも非ブロッキング
- **例外 (`exit 1` fail-fast)**:
  - `branch_strategy` 未知値 (ステップ 2.2 / 6.0 / 6.2 / 8.2 / 8.3 の 5 箇所で同型、設定ミスの silent 通過防止)
  - `{mode}` placeholder 残留 (ステップ 1.1 / 1.3 の 2 箇所)
  - ステップ 6.2 の placeholder 残留 (`{branch_strategy}` / `{wiki_branch}` / `{pages_list}` の 3 種 + partial pollution gate、LLM substitute 忘れによる silent `missing_concept` 誤分類防止)
  - ステップ 8.1 の counter placeholder (`n_*` 5 種) 残留 / 非整数検知 (silent `lint:clean` 誤 emit 防止)
  - ステップ 8.3 の placeholder 残留 (`{log_entry}` / `{branch_strategy}` の 2 種、literal 残留 commit landed 防止)
- 内部 bash 構文エラー等の unrecoverable error のみ非 0 exit となる可能性あり

---

## エラーハンドリング

| エラー | 対処 | ステップ |
|--------|------|---------|
| `wiki.enabled: false` | 早期 return (`--auto` モード時は ステップ 9.2 の 3 行出力後 exit 0、それ以外は警告のみ exit 0) | ステップ 1.1 |
| GNU date 非互換環境 | ステップ 4 skip（exit 0 + WARNING） | ステップ 1.2 |
| Wiki 未初期化 | `/rite:wiki:init` を案内 (`--auto` モード時は ステップ 9.2 の 3 行出力後 exit 0) | ステップ 1.3 |
| `{mode}` placeholder 残留 (2 箇所で同型) | **exit 1 で fail-fast** | ステップ 1.1 / 1.3 |
| ステップ 6.2 の placeholder 残留 (`{branch_strategy}` / `{wiki_branch}` / `{pages_list}` の 3 種 + partial pollution) | **exit 1 で fail-fast** (silent `missing_concept` 誤分類防止) | ステップ 6.2 |
| ステップ 8.1 の counter placeholder (`n_*` 5 種) 残留 / 非整数 | **exit 1 で fail-fast** (silent `lint:clean` 誤 emit 防止) | ステップ 8.1 |
| ステップ 8.3 の placeholder 残留 (`{log_entry}` / `{branch_strategy}` の 2 種) | **exit 1 で fail-fast** (literal 残留 commit landed 防止) | ステップ 8.3 |
| `git ls-tree` 失敗 | WARNING + `pages_list=""`/`raw_list=""` で継続（exit 0） | ステップ 2.2 |
| `branch_strategy` 未知値 (5 箇所で同型) | **exit 1 で fail-fast** | ステップ 2.2 / 6.0 / 6.2 / 8.2 / 8.3 |
| `index.md` 読出失敗 | WARNING + ステップ 5 skip（exit 0） | ステップ 2.3 |
| `log.md` 読出失敗 (legitimate absence) | WARNING 抑制 + `skipped_refs=""` + `log_read_ok=absent`（exit 0） | ステップ 6.0 |
| `log.md` 読出失敗 (真の IO error) | WARNING + `skipped_refs=""` + `log_read_ok=io_error` + ステップ 9.1 で false positive note 表示（exit 0） | ステップ 6.0 |
| awk/sort pipeline 失敗 | WARNING + `skipped_refs=""` で継続（exit 0） | ステップ 6.0 |
| `date -d` パース失敗 | 該当ページを skip し WARNING を stderr に出力（`n_stale` 非加算） | ステップ 4.2 |
| `grep` no-match（indexed_pages 空） | WARNING + ステップ 5 skip（全ページ orphan 誤検出防止） | ステップ 5.2 |
| 処理対象 0 件 | ステップ 3-7 を skip し ステップ 9 で「検査対象なし」表示 | ステップ 2.2 末尾 |
| log.md 追記失敗 | WARNING + exit 0 で継続（検出結果は stdout に表示済み） | ステップ 8 |
