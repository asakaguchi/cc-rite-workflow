# CLAUDE.md

Claude Code Rite Workflow - Claude Code 用 Issue ドリブン開発ワークフロープラグイン

## アーキテクチャ

```
.claude-plugin/                    # マーケットプレイスメタデータ（marketplace.json）
plugins/rite/.claude-plugin/       # プラグイン固有メタデータ（plugin.json）
plugins/rite/
├── skills/           # Claude Code が自動検出するスキル定義（SKILL.md）。/rite:<name> で起動
│   │                 #   各スキル = 薄い SKILL.md + 同梱 references/（行数原則は下記）
│   ├── PR lifecycle  #   open, iterate, review, fix, ready, merge, cleanup, run, pr-create
│   ├── issue 管理     #   issue-create, issue-list, issue-update, issue-close, issue-edit, issue-implement
│   ├── wiki          #   wiki-init, wiki-query, wiki-ingest, wiki-lint
│   ├── meta/top      #   setup, getting-started, workflow, investigate, learn, lint, recover, skill-suggest, template-reset
│   ├── rite-workflow/  # orchestration context（状態検出・phase routing）+ references/（コーディング原則 等）
│   └── reviewers/      # レビュアー調整（選定 + テーブル）+ references/（各 reviewer profile は agents/{type}-reviewer.md）
├── agents/           # PR レビュー用サブエージェント定義
│                     # _reviewer-base.md（共通原則）+ 13 reviewer agent
├── templates/        # config/（rite-config.yml 最小デフォルト）、
│                     # issue/, pr/, review/, wiki/ の各フォーマット
├── references/       # gh CLI パターン、GraphQL、severity-levels、investigation-protocol、
│                     # wiki-patterns、review-result-schema、bash-trap-patterns 等（複数スキル共有）
├── scripts/          # Projects 統合 Issue 作成、Sub-Issue リンク、レビュー結果抽出・計測 等
└── hooks/            # Claude Code ライフサイクルフック（session / compact /
    │                 # pre-tool-bash-guard / post-tool-wm-sync /
    │                 # wiki-ingest-trigger / wiki-query-inject /
    │                 # session-ownership / hook-preamble 等）+ hooks.json
    ├── scripts/      #   Wiki commit / worktree / backlink / gitignore-health / lint scanner 等のヘルパー
    └── tests/        #   hook レベルの自動テストスイート
rite-config.yml        # プロジェクト固有設定（ブランチ戦略、Projects連携、Wiki、review loop 等）
```

**コンポーネント間の関係**: スキル（`skills/`）が**エントリポイントかつ実行手順書**（v0.7 で旧 `commands/` を全廃しスキルへ統合）。orchestrator スキル（open / iterate / run 等）が sub-skill（review / fix / pr-create / issue-implement 等）を Skill ツール経由で呼び出し、各スキルは `agents/`（Task で spawn）や `references/`（自スキル内 `references/` + plugin-root `references/` の共有分）を参照する。hooks/ は Claude Code のライフサイクルから独立に発火し、orchestrator とコンテキスト注入・sentinel emit で連携する。ディレクトリ・ファイルの完全な一覧は `docs/SPEC.md` の Plugin Structure 節を参照。

**スキル行数原則**: 入口スキルの SKILL.md は 500 行未満に保つ。実行手順書スキル（review / fix / lint / setup など bash 実行ブロックを本体に持つもの）は 4,000 行以内を上限とし、rationale（設計理由・背景解説）は SKILL.md 本体に書かず同梱 references/ へ退避して該当箇所に 1 行ポインタ（`rationale: references/<file>.md#<anchor>`）を残す。実行時に必要な情報（分岐表・sentinel 表・エラー処理指示・reason 表）は本体に維持する。

## 開発ルール

- **ブランチ**: `develop` ベース、`{type}/issue-{number}-{slug}` 命名
- **コミット**: Conventional Commits 形式（`feat`, `fix`, `docs`, `refactor`, `chore`）
- **PR**: `develop` に向けて作成

## テスト・検証

現時点でビルド・テスト・lint コマンドは未設定（`rite-config.yml` の `commands` セクション参照）。変更の検証は以下で実施:

- `/rite:lint` でプロジェクト設定に基づく品質チェック
- `/rite:review` でセルフレビュー（マルチレビュアー方式）
- 手動: スキル・コマンドの変更は次回呼び出し時に反映されるため、実際に実行して動作確認

## メモリ機能

このプロジェクトでは Claude Code のメモリ機能（`~/.claude/projects/*/memory/`）を使用しない。ワークフローの方針は `rite-config.yml` と `skills/` で表現すること。メモリファイルの新規作成・更新は行わないこと。

## エージェント振る舞い原則

rite workflow はワークフロー定義そのものを LLM エージェントで編集するため、以下を厳守する。
（出典: Karpathy 2025-12 "claude coding" 観察）

### 仮定を表明し、確認する
- ユーザーの意図・前提・既存仕様について不確かな点があれば、推測で進めず質問する
- やむを得ず推測する場合は「〇〇と仮定して進めます」と明示してから着手する
- 仕様の矛盾・前提崩壊を見つけたら、修正案を進める前に必ず表面化する

### 押し返すべきときは押し返す
- ユーザーの指示が技術的に不適切・非効率・矛盾している場合、同意せず根拠とともに反論する
- 「いいですね」「もちろんです」で始まる追従的な応答を避ける
- 複数の選択肢があるときは、推奨と理由・トレードオフを提示してから実装に入る

### シンプルさを死守する
- 100 行で済むものを 1000 行にしない。新しい抽象・ラッパー・設定項目・hook を追加する前に「本当に必要か」「既存で表現できないか」を一度問う
- skills/hooks の既存パターンに合わせ、新しい構造を持ち込まない
- タスク完了時にデッドコード・未使用 reference・コメントアウト・旧フォーマットを残さない

### スコープを越えない
- 依頼されたタスクと無関係なコマンド・スキル・hook の変更/削除をしない
- リファクタやスタイル統一を「ついでに」やらない。気になった点は別途 Issue / 報告として切り出す
- 「理解できない」「気に入らない」を理由に既存のワークフロー仕様を書き換えない（rite では仕様変更が即座に他の作業を壊す）

## ドッグフーディング注意事項

このリポジトリは Rite Workflow 自体を Rite Workflow で開発している。

- **`rite@rite-marketplace: false` を維持すること**: `~/.claude/settings.json` の `enabledPlugins` で `rite@rite-marketplace` が `true` になっていると、キャッシュされた古いマーケットプレイス版が優先ロードされ、ローカルの修正が一切反映されない（実機検証で確認済み）
- **CLAUDE.md の変更は即座に影響する**: 編集内容は現在の Claude Code セッションで即座に参照される
- **skills/ の変更は次回呼び出しから反映**: Skill ツール経由で呼び出されるたびに最新のファイル内容が読み込まれる
- **自己参照ループに注意**: ワークフロー仕様の変更中にそのワークフローを使って作業するため、変更前後で動作が変わる可能性がある
