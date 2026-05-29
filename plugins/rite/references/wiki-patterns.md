---
description: Wiki 操作の共通パターン（ディレクトリ構造、Git ブランチ管理、テンプレート展開）
---

# Wiki Patterns

Wiki 操作で使用する共通パターンを定義します。Wiki コマンド（init, ingest, query, lint）はこのリファレンスを参照して一貫した操作を行います。

## ディレクトリ構造

Wiki データは `.rite/wiki/` 配下に3層構造で格納されます。

```
.rite/wiki/
├── SCHEMA.md                 # Schema: 蓄積規約（人間 + LLM 共同管理）
├── index.md                  # 全ページのカタログ（Ingest 時に自動更新）
├── log.md                    # 活動ログ（append-only）
├── raw/                      # Raw Sources（不変の一次データ）
│   ├── reviews/              #   レビュー結果
│   ├── retrospectives/       #   Issue 振り返り
│   └── fixes/                #   Fix 結果
└── pages/                    # Wiki ページ（LLM 所有）
    ├── patterns/             #   繰り返しパターン
    ├── heuristics/           #   経験則
    └── anti-patterns/        #   アンチパターン
```

### 層の役割

| 層 | 場所 | 所有者 | 性質 |
|---|---|---|---|
| **Raw Sources** | `.rite/wiki/raw/` | rite ワークフロー（自動生成） | 不変の一次データ |
| **Wiki** | `.rite/wiki/pages/` | LLM（自動生成・更新） | 読解・統合された加工済み知識 |
| **Schema** | `.rite/wiki/SCHEMA.md` | 人間 + LLM（共同管理） | 蓄積規約 |

## ブランチ管理

Wiki データは開発ブランチとは別に管理し、PR diff との分離を確保します。

### ブランチ戦略

`rite-config.yml` の `wiki.branch_strategy` で制御:

| 戦略 | 説明 | 推奨用途 |
|------|------|---------|
| `separate_branch` (推奨) | Wiki データを専用ブランチで管理 | 全プロジェクト（PR diff に Wiki 変更が混入しない） |
| `same_branch` | 開発ブランチと同じブランチで管理 | 小規模プロジェクト、Wiki 変更も PR でレビューしたい場合 |

### separate_branch 戦略のブランチ操作

#### Wiki ブランチの作成（初期化時）

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
current_branch=$(git branch --show-current)

# cleanup trap: 異常終了時に元のブランチに復帰を保証
# canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
_rite_wiki_init_cleanup() {
  git checkout "$current_branch" 2>/dev/null || true
  if [ "${stash_needed:-false}" = true ]; then
    git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
  fi
}
trap 'rc=$?; _rite_wiki_init_cleanup; exit $rc' EXIT
trap '_rite_wiki_init_cleanup; exit 130' INT
trap '_rite_wiki_init_cleanup; exit 143' TERM
trap '_rite_wiki_init_cleanup; exit 129' HUP

# dirty tree チェック: stash が必要な場合のみ実行
stash_needed=false
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
  git stash push -m "rite-wiki-init-stash"
  stash_needed=true
fi

# orphan ブランチとして作成（開発履歴を含まない）
git checkout --orphan "$wiki_branch" || { echo "ERROR: git checkout --orphan failed" >&2; exit 1; }
git rm -rf . 2>/dev/null || true
# Wiki ファイルを配置してコミット
git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
git commit -m "feat(wiki): initialize Wiki structure" || { echo "ERROR: git commit failed" >&2; exit 1; }
git push -u origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

# 元のブランチに戻る（git checkout - は --orphan 後に動作しないため明示的に指定）
git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# stash した場合のみ pop
if [ "$stash_needed" = true ]; then
  git stash pop
  stash_needed=false  # EXIT trap での二重 pop を防止
fi

# cleanup trap を解除（正常完了時は不要）
trap - EXIT INT TERM HUP
```

#### Wiki ブランチへの書き込み（Ingest 時）

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
current_branch=$(git branch --show-current)

# cleanup trap: 異常終了時に元のブランチに復帰を保証
# canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
_rite_wiki_ingest_cleanup() {
  git checkout "$current_branch" 2>/dev/null || true
  if [ "${stash_needed:-false}" = true ]; then
    git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
  fi
}
trap 'rc=$?; _rite_wiki_ingest_cleanup; exit $rc' EXIT
trap '_rite_wiki_ingest_cleanup; exit 130' INT
trap '_rite_wiki_ingest_cleanup; exit 143' TERM
trap '_rite_wiki_ingest_cleanup; exit 129' HUP

# dirty tree チェック: stash が必要な場合のみ実行
stash_needed=false
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
  git stash push -m "rite-wiki-stash"
  stash_needed=true
fi

# Wiki ブランチに切り替え
git checkout "$wiki_branch" || { echo "ERROR: git checkout '$wiki_branch' failed" >&2; exit 1; }

# Wiki ファイルの変更を適用
# ... (ingest/update operations)

git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
git commit -m "docs(wiki): {action} - {description}" || { echo "ERROR: git commit failed" >&2; exit 1; }
git push origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

# 元のブランチに戻る
git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# stash した場合のみ pop
if [ "$stash_needed" = true ]; then
  git stash pop
  stash_needed=false  # EXIT trap での二重 pop を防止
fi

# cleanup trap を解除（正常完了時は不要）
trap - EXIT INT TERM HUP
```

#### Wiki ブランチからの読み込み（Query 時）

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"

# ブランチ切り替えなしで Wiki ファイルを読み取り
if ! git show "${wiki_branch}:.rite/wiki/index.md" 2>/dev/null; then
  echo "ERROR: Wiki index not found on branch '${wiki_branch}'" >&2
  echo "  対処: Wiki が初期化済みか確認してください (/rite:wiki:init)" >&2
  exit 1
fi
if ! git show "${wiki_branch}:.rite/wiki/pages/{page_path}" 2>/dev/null; then
  echo "WARNING: Wiki page not found: .rite/wiki/pages/{page_path} on branch '${wiki_branch}'" >&2
fi
```

### same_branch 戦略

`same_branch` 戦略では Wiki データは開発ブランチに直接コミットされます。ブランチ切り替えは不要ですが、Wiki 変更が PR diff に含まれます。

```bash
# 直接ファイル操作（ブランチ切り替え不要）
# .rite/wiki/ 配下のファイルを Read/Write ツールで操作
git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
git commit -m "docs(wiki): {action} - {description}" || { echo "ERROR: git commit failed" >&2; exit 1; }
```

## テンプレート展開パターン

Wiki 初期化時にテンプレートを `.rite/wiki/` に展開します。

### テンプレートソース

テンプレートは `{plugin_root}/templates/wiki/` に配置:

| テンプレート | 展開先 | 説明 |
|-------------|--------|------|
| `schema-template.md` | `.rite/wiki/SCHEMA.md` | 蓄積規約 |
| `page-template.md` | (Ingest 時に使用) | 新規ページ作成テンプレート |
| `index-template.md` | `.rite/wiki/index.md` | インデックス |
| `log-template.md` | `.rite/wiki/log.md` | 活動ログ |

### プレースホルダー置換

テンプレート内の `{placeholder}` をランタイム値に置換:

| プレースホルダー | 値 |
|----------------|-----|
| `{initialized_at}` | 現在のタイムスタンプ（ISO 8601） |
| `{title}` | ページタイトル（Ingest 時） |
| `{domain}` | ドメイン名（Ingest 時） |
| `{created}` | 作成日時（Ingest 時） |
| `{updated}` | 更新日時（Ingest 時） |
| `{source_type}` | ソースタイプ（reviews/retrospectives/fixes） |
| `{source_ref}` | Raw Source へのファイルパス形式 (`raw/{type}/{filename}`、wiki-root 起点) の相対パス。**PR 識別子形式 (`pr-NNNN`) は禁止**。詳細は `plugins/rite/commands/wiki/ingest.md` ステップ 5.3 の `{source_ref}` 行 (dual-use 警告) を SoT として参照 |
| `{summary}` | ページ概要（1-2文、Ingest 時） |
| `{details}` | 詳細説明（Ingest 時） |
| `{related_page_title}` | 関連ページのタイトル（Ingest 時） |
| `{related_page_path}` | 関連ページへの **page-dir 相対パス**（Ingest 時）。新規 page 格納位置 `.rite/wiki/pages/{domain}/{slug}.md` の格納ディレクトリ `.rite/wiki/pages/{domain}/` を起点として resolve される。同ドメイン内は `./other.md` または `other.md`、別ドメインは `../{other_domain}/other.md` の形式で substitute する。`{source_ref}` (wiki-root 起点、template 側で `../../` prefix を hardcode) とは **起点が異なる** 点に注意。詳細は `plugins/rite/commands/wiki/ingest.md` ステップ 5.3 の「設計意図 (#941 fix)」を参照 |
| `{source_description}` | ソースの説明文（Ingest 時） |

> **F-14 fix（関連ページなし時の操作契約、Issue #944 由来）**: 確信ある関連ページが特定できない場合、`{related_page_title}` / `{related_page_path}` の両 placeholder への substitute は行わず、`## 関連ページ` セクション全体を Edit で `- （関連ページなし）` の平文 1 行に差し替える（空 placeholder のままにすると Markdown リンク `[]()` が破綻するため）。

> **canonical 階層** (ingest.md 内の 2 種 canonical の概念分離): ingest.md には (a) ステップ 4.3 = `{related_page_title}` / `{related_page_path}` の**値決定手順** canonical (L530 で明示宣言) と (b) ステップ 5.3 placeholder 表 = **F-14 fix 動作契約** canonical (ステップ 4.3 内 L559 で明示宣言、実体行は L821) が共存する。両者は別概念 (手順 vs 動作契約) で並立。本 NOTE は (b) を扱うため canonical = `plugins/rite/commands/wiki/ingest.md` L821 (ステップ 5.3 placeholder 表内の該当行)。なお #944 fix により ステップ 4.3 (詳細手順、L557-567) と ステップ 5.3 placeholder 表 (要約、L821) は同一の操作契約を併記する dual-site として維持される (L569 で dual-site 備考)。references → ingest.md 方向は本 NOTE のように要約参照に集約する方針 (ingest.md 内 dual-site 維持とは別方針)。

> **F-14 fix 識別子の disambiguation**: lint.md にも別文脈の F-14 fix (`{log_entry}` placeholder 残留検知、PR #564 由来) があるため、識別子のみで参照する場合は本 NOTE が指す F-14 fix が「関連ページなし時の操作契約」(Issue #944 由来) であることに注意。

> **confidence フィールド**: page-template.md の `confidence: medium` はリテラル値であり `{confidence}` プレースホルダーではない。Write 後に Edit で ステップ 4 の判定値 (`high` / `medium` / `low`) に置換する。

## Wiki 有効判定パターン

Wiki 操作の前に必ず有効判定を行います。**#483 以降 opt-out**: `wiki:` セクション自体や `enabled` キーが未指定の場合は default-on (有効) として扱います。明示的に `false|no|0` が指定された場合のみ無効化されます:

```bash
# #483: Wiki は opt-out — section/key 未指定時のデフォルトは true
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
wiki_enabled=$(echo "$wiki_enabled" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="true" ;;  # opt-out default
esac

if [ "$wiki_enabled" != "true" ]; then
  echo "Wiki is explicitly disabled (wiki.enabled: false in rite-config.yml)"
  exit 0
fi
```

### 分散実装ファイル一覧 (Single Source of Truth)

`wiki.enabled` パースを実装するファイルは以下の通り。本セクションが**唯一の同期一覧**。将来パース仕様を変更する PR は本一覧の全 site を漏れなく同期更新する義務がある:

- `plugins/rite/commands/wiki/query.md` ステップ 1.1 (probe 用簡易パーサ、本ファイル参照)
- `plugins/rite/commands/wiki/ingest.md` ステップ 1.1 (`extract_yaml_key` helper 経由、`wiki_enabled` のみ呼び出し側で lowercase 適用)
- `plugins/rite/commands/wiki/lint.md` ステップ 1.1 (ingest.md と対称な helper 経由、`wiki_enabled` のみ呼び出し側で lowercase 適用)
- `plugins/rite/commands/wiki/init.md` (init 時の状態判定)
- `plugins/rite/commands/init.md` Phase 4.7 (`/rite:init` 内 Wiki 自動初期化判定、独自 inline 実装 + typo 検出 WARNING 付き)
- `plugins/rite/commands/pr/cleanup.md` ステップ 9 (`parse_wiki_key` helper 経由、auto_ingest 起動条件)
- `plugins/rite/commands/pr/fix.md` ステップ 0.5.W / 4.6.W (Wiki query / ingest 起動条件)
- `plugins/rite/commands/pr/review.md` ステップ 4.0.W / 6.5.W (Wiki query / ingest 起動条件)
- `plugins/rite/commands/issue/implement.md` (Wiki query 起動条件)
- `plugins/rite/commands/issue/close.md` (Wiki ingest 起動条件)
- `plugins/rite/hooks/wiki-query-inject.sh` (auto_query 注入の前提判定、ローカル helper `_extract_yaml_value`)
- `plugins/rite/hooks/wiki-ingest-trigger.sh` (raw source staging の事前ゲート、`wiki.enabled` のみ参照、独自 inline 実装 — wiki-config.sh とは別経路。trigger.sh L226-231 self-comment で「3 sites still re-implement inline」の 1 つとして自身を列挙)
- `plugins/rite/hooks/scripts/wiki-growth-check.sh` (layer 3 growth stall 判定、独自 inline 実装 lenient)
- `plugins/rite/hooks/scripts/gitignore-health-check.sh` (gitignore drift 判定、独自 inline 実装 lenient)
- `plugins/rite/hooks/scripts/lib/wiki-config.sh` (共通 helper `parse_wiki_scalar`、lenient — callers: wiki-ingest-commit.sh / wiki-worktree-commit.sh / wiki-worktree-setup.sh が `source` 経由で再利用)

**設計差異**:
- **lenient 経路**: ingest.md / lint.md / query.md / inject.sh / wiki-config.sh / 各 caller (cleanup.md / fix.md / review.md / implement.md / close.md / init.md) と独立 inline 実装 (growth-check.sh / gitignore-health-check.sh) は **lenient** — `false`/`no`/`0` のみ reject、それ以外 (`true`/`yes`/`1` も不明値も空文字も) は `true` として opt-out default 化する (#483)。ingest.md / lint.md は `case "$wiki_enabled" in false|no|0) wiki_enabled=false ;; *) wiki_enabled=true ;; esac` の 2-arm 形式
- **fail-fast 経路**: `wiki-ingest-trigger.sh` のみ意図的に **strict 3-arm with fail-fast `*`** (L308-320 `case ... *) ... exit 2 ;;`) — staging hook の safe-default policy violation 防止のため、`ture` / `yse` 等の typo / 不明値を即座に reject する。本 site だけが lenient ファミリと意図的に非対称
- **`branch_strategy` 検証**: ingest.md ステップ 1.1 では silent default で fill (probe 段階)、ステップ 5.1 / 5.2 で `*` arm の fail-fast 検証を行う 2 段階構造。lint.md L72-86 も同型 fail-fast

## Wiki 初期化判定パターン

Wiki が既に初期化済みかを判定します:

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"
branch_strategy=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_strategy:' | head -1 | sed 's/[[:space:]]#.*//' \
  | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
branch_strategy="${branch_strategy:-separate_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # separate_branch: Wiki ブランチの存在で判定
  if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
     git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
else
  # same_branch: SCHEMA.md の存在で判定
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
fi
```
