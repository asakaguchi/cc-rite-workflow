<!--
使い方:
1. このプロンプト全文を Fable（Claude Code）セッションに渡す
2. Fable が分析の末、リポジトリ直下に refactor-instructions.md を生成する
3. 別セッション（Claude Code / Opus 4.8 xhigh）で次を実行する:
   /goal refactor-instructions.md に書かれたことを完遂しろ
-->

# rite workflow スリム化リファクタリング — 指示書生成プロンプト

あなたは、このコードベース（cc-rite-workflow）を深く分析し、実装担当モデルがリファクタリングを完遂するための指示書を作る役割です。

あなた自身は実装しないでください。あなたの仕事は、プロジェクト全体を読み、守るべき仕様・技術的負債・触ると危険な箇所を整理し、実装担当モデルに渡す Markdown 指示書 `refactor-instructions.md`（リポジトリ直下、日本語）を作ることです。

実装担当は **Claude Code（Opus 4.8 xhigh）の別セッション** で、人間が次の形で起動します:

> /goal refactor-instructions.md に書かれたことを完遂しろ

## このプロジェクトについて（前提知識）

rite workflow は Claude Code 用の Issue ドリブン開発ワークフロープラグインである。**「コード」の実体は大半が Markdown プロンプト**（commands / skills / agents / references / templates）であり、それに bash hooks（一部 Python）と shell scripts が付随する。

したがって技術的負債は、型や非同期処理ではなく次の形で現れる:

- **コンテキストコスト**: コマンド 1 回の呼び出しで LLM のコンテキストに読み込まれる総行数
- **プロンプト重複**: 同じ指示・手順・原則が複数ファイルに多重記述され、修正時に同期漏れを起こす
- **参照グラフの腐敗**: どこからも参照されない reference、リンク切れ、二重管理
- **契約の散在**: sentinel・schema・contract の定義が複数箇所に分散

度重なる機能追加と修正（1,300+ コミット）で肥大化しており、これをスリム化して一般公開可能な状態にすることが目的である。

## 確定済みの方針（質問不要。指示書の前提としてよい）

ユーザー（坂口さん）が既に決定済みの事項:

1. **現在のユーザーは坂口さん 1 人のみ**。外部ユーザー向け後方互換は不要。deprecated config keys の残骸、`docs/migration-guides/`、旧 sentinel 互換コードは削除してよい
2. **docs は英語に一本化する**。`docs/SPEC.ja.md`・`docs/CONFIGURATION.ja.md`・`README.ja.md` は削除対象として承認済み（i18n 機構自体は #1117 で廃止済みのはずなので `docs/i18n-style-guide.md` も削除候補として検証せよ）
3. **機能統廃合まで踏み込んでよい**。ただし個々の機能削減はプロダクト判断なので、後述のとおり AskUserQuestion で承認を取ってから指示書に載せること
4. 目的は見た目の整理ではなく、**既存のコアワークフローを壊さずに総量を減らし、今後変更しやすくする**こと

## まず読むべきファイル

推測で判断せず、証拠にもとづいて理解すること。最低限以下を確認する:

- `CLAUDE.md`（プロジェクト方針・エージェント振る舞い原則・ドッグフーディング注意）
- `README.md`（外部公開時にユーザーへ約束している内容）
- `docs/SPEC.md`（公式仕様書。実装との同期度が高く、ゴールドスタンダードとして機能している）
- `docs/CONFIGURATION.md`（全設定キーのリファレンス）
- `rite-config.yml`（このリポジトリ自身のドッグフード設定）と `plugins/rite/templates/config/rite-config.yml`（新規ユーザー向け最小デフォルト）
- `plugins/rite/.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json`（公開メタデータ）
- `plugins/rite/hooks/hooks.json`（ライフサイクルイベントへの hook 登録）
- `.github/workflows/test-hooks.yml`(唯一の CI)
- `plugins/rite/hooks/tests/`（69 個の .test.sh と run-tests.sh）
- `docs/tests/*.test.md`（手動 e2e テスト手順書、特に `rite-issue-create-e2e-smoke.test.md`）
- 主要コマンド: `plugins/rite/commands/pr/review.md`、`pr/fix.md`、`issue/create.md`、`lint.md`
- スキル: `plugins/rite/skills/rite-workflow/SKILL.md`、`skills/reviewers/SKILL.md`

## 初期観察（2026-06-11 時点の実測値。鵜呑みにせず、使う前に必ず再検証すること）

事前調査で判明している肥大化の兆候。数値・状況は変わっている可能性があるため、指示書に載せる前に grep / wc で再確認すること。

- **規模**: プラグイン本体 約 54,000 行（commands 27,491 / scripts 7,354 / references 6,892 / skills 5,658 / hooks 約 3,400 / agents 1,880 / templates 1,281）+ docs 約 16,000 行
- **巨大ファイル**: `commands/pr/review.md` 4,111 行と `commands/pr/fix.md` 4,020 行の 2 つだけでプラグイン全体の 15%。次点で `commands/lint.md` 1,503 行、`commands/init.md` 1,148 行
- **reviewer の二重管理**: `agents/`（13 reviewer + _reviewer-base.md、実行定義）と `skills/reviewers/`（13 基準ファイル + 21KB の SKILL.md、activation 層）が完全 1:1 対応。reviewer を 1 つ変更するたびに両方の同期が必要
- **孤児 reference**(`plugins/rite/references/` 配下、他ファイルからの参照 0 件): error-codes.md / gh-cli-commands.md / output-patterns.md / priority-markers.md / session-id-validation-contract.md / state-read-evolution.md / sub-issue-link-handler.md の 7 ファイル。参照 1〜2 件の低利用も 5 ファイル（bash-defensive-patterns.md / epic-detection.md / gh-cli-error-catalog.md / graphql-helpers.md / investigation-protocol.md）
- **hooks のライブラリ散在**: hooks.json 登録は 9 個だが、commands や登録済み hook から直接呼ばれる未登録スクリプトが 25 個・約 4,500 行（flow-state.sh、wiki-query-inject.sh、issue-comment-wm-sync.sh など）。hook とライブラリの区別がディレクトリ構造から読み取れない
- **workflow 定義の重複**: `commands/workflow.md` と `skills/rite-workflow/SKILL.md` が両方ともワークフロー全体のフロー図・コマンド説明を持つ
- **docs の堆積**: `docs/designs/`（30+ ファイル）、`docs/investigations/`、`docs/verification-results/`、`docs/archive/` に作業 artifact がそのまま保存されている

## 負債を洗い出す観点（rite 固有）

通常のコードベース向け観点（型、DB schema、認証、課金など）は使わない。代わりに以下で分析する:

1. **コンテキストコスト**: 各コマンド呼び出し時に実際に読み込まれるファイル群と総行数。最も呼ばれるパス（pr:open → iterate のループ）のコストを優先的に下げる
2. **プロンプト重複**: 同一の指示・原則・手順の多重記述。SoT（単一の置き場）を決めて他を参照化 or 削除
3. **参照グラフの腐敗**: 孤児 reference、リンク切れ、二重管理。`plugins/rite/hooks/scripts/orphan-reference-check.sh` の検出結果も活用
4. **巨大単一ファイル**: ただし後述の注意を厳守
5. **hooks / scripts の責務不明瞭**: 登録 hook とライブラリの混在、テストの有無
6. **設定項目の過剰さ**: rite-config.yml の設定キーのうち、実質使われていない・デフォルトから変える理由がないものはないか
7. **docs の多重化・堆積**: 英日二重（削除承認済み）、作業 artifact の本体 docs への混入
8. **機能の利用実態**: sprint / team-execute / TDD Light / notification / iteration など optional 機能のうち、複雑さに見合う価値がないものはないか（→ プロダクト判断、質問へ）

`plugins/rite/scripts/`（約 7,300 行）の大改修はスコープ外。問題を見つけたら提案として記録するに留める。

**ファイル分割についての重要な注意**: 分割は自動的に善ではない。`commands/issue/create.md` は過去に意図的に references を単一ファイルへ統合した経緯がある（flat workflow 化）。LLM プロンプトでは「分割して都度 Read させる」より「常に読む 1 ファイルに収める」方が正しい場合がある。分割/統合の判断基準は**見た目の行数ではなく、各実行パスでコンテキストに読み込まれる単位とその総量**であること。指示書にもこの基準を明記せよ。

## 各負債について書くこと

- 根拠となるファイルパスと箇所（再検証済みの実測値で）
- なぜ負債と言えるのか（上記観点のどれに該当するか）
- 影響範囲と変更リスク
- 改善案と、削減見込み（行数 / コンテキストコスト）
- 検証方法（後述の Baseline Commands のどれで担保するか）
- 実装担当が今実装してよいか、提案に留めるべきか

## 壊してはいけない挙動（指示書の Behaviors To Preserve の種）

事前調査で判明しているコア仕様。指示書に載せる前に各仕様の現物（該当ファイル・meta-test）を確認すること:

1. **コマンド分解と固定順序**: `pr:open → pr:iterate → pr:ready → pr:merge → pr:cleanup`、各コマンド単一責任、`/rite:resume` での中断復帰
2. **sentinel 契約**: `[*:returned-to-caller]` 形式 + HTML comment disambiguator。meta-test `sentinel-disambiguator-adjacency.test.sh` と `create-md-invocation-symmetry.test.sh` が保護
3. **review-fix の 4 品質シグナル**: fingerprint cycling / root-cause-missing / cross-validation disagreement / reviewer self-degradation（cycle-count ベースの打ち切りは v0.4.0 で廃止済み — 復活させない）
4. **flow-state schema v2**: `.rite/sessions/{session_id}.flow-state`、`flow-state.sh {create|read|update|migrate}`
5. **multi-session worktree 分離**: default ON、`.rite/worktrees/`、session ownership guard
6. **GitHub Projects 連携**: status 遷移 Todo → In Progress → In Review → Done
7. **Wiki の lint ↔ ingest contract 同期**: meta-test `wiki-lint-ingest-contract-sync.test.sh` が片側だけの修正を fail させる
8. **review result schema**: findings[].scope enum（blocking / nit-noted / accept / suggest-separate-issue）と scope-based fix routing
9. **work memory**: Issue コメント同期、`work-memory-lock.sh` による排他、Issue body safe update（上書き禁止）

機能統廃合で上記の一部が丸ごと不要になる場合は、その旨を質問で確認してから外すこと。

## 検証手段（指示書の Baseline Commands の種）

- `bash plugins/rite/hooks/tests/run-tests.sh` — 69 個の hook テスト。**着手前に全 pass を記録し、各フェーズ後に再実行**
- `plugins/rite/hooks/scripts/` 配下の静的チェック群（orphan-reference-check.sh、hardcoded-line-number-check.sh、sh-cross-ref-check.sh、bash-heaviness-check.sh 等）
- CI: `.github/workflows/test-hooks.yml`（push / PR で hook テストを実行）
- 手動 e2e: `docs/tests/rite-issue-create-e2e-smoke.test.md` の手順でコアフロー一周（最終フェーズ後に人間が実施）

commands / skills の Markdown には自動テストがない。プロンプト変更の検証は「meta-test + 静的チェック + grep による参照整合確認 + 人間の実機確認」の組み合わせになることを指示書に明記せよ。

## プロダクト判断が必要なとき

あなたは対話セッションで動いているので、質問を最終出力に積み残さず、**指示書を確定する前に AskUserQuestion で坂口さんに直接確認**すること。特に:

- 機能の削除・縮小（例: 13 reviewer の統合、sprint / team-execute / TDD Light / notification / iteration の扱い）
- `docs/designs/`・`docs/investigations/` 等の堆積 artifact の削除可否
- 正しい仕様がコードから判断できない、テスト（meta-test）と実装が矛盾している場合
- 削除候補が本当に不要か確証が持てない場合

コードから判断できることは質問しない。承認された統廃合だけを指示書の実施項目に載せ、未承認・保留のものは「提案（Out-of-scope）」として分離する。

## refactor-instructions.md に必ず含める章

1. **Objective** — スリム化の目的と数値目標（削減行数 / コンテキストコストの目安）
2. **Project Understanding** — プロジェクトの正体、コンポーネント間の関係（skills → commands → agents/references、hooks は独立発火）
3. **Behaviors To Preserve** — 上記コア仕様の具体列挙（ファイルパス付き）
4. **Non-Negotiables** — sentinel 契約、flow-state schema、meta-test を緑に保つ、等
5. **Stop And Ask Conditions** — 未承認の機能削除、meta-test の書き換えが必要になった場合、仕様の矛盾を発見した場合、等
6. **Baseline Commands** — 上記の検証手段（実在確認済みのコマンドのみ）
7. **Debt Map** — 負債一覧（根拠・リスク・改善案・検証方法付き）
8. **Implementation Phases** — 後述の推奨順序に沿った、小さく安全なフェーズ分割
9. **Verification Requirements** — フェーズごとの検証手順
10. **Reporting Format** — フェーズごとの報告様式（実行コマンド・結果・削減行数）
11. **Out-of-scope Items** — 未承認の提案、scripts/ 大改修、新機能追加

## 実装フェーズの推奨順序

1. **baseline 記録**: git status クリーン確認、`run-tests.sh` 全 pass の記録
2. **安全な削除**: 孤児 reference、`docs/migration-guides/`、deprecated config keys の処理コード、ja docs（承認済み）、承認済みの堆積 artifact
3. **二重管理解消**: agents ↔ skills/reviewers の SoT 一本化、workflow.md ↔ SKILL.md の重複排除
4. **巨大ファイルのスリム化**: pr/review.md / pr/fix.md / lint.md / init.md — 圧縮（冗長な繰り返し・防御的記述の削減）を分割より優先し、分割する場合はコンテキスト読み込み単位で判断
5. **機能統廃合**: 坂口さん承認済み項目のみ
6. **SPEC.md の同期と最終検証**: Plugin Structure / Command List / Hook Specification を実態に合わせて更新、`run-tests.sh` + 静的チェック + e2e smoke

各フェーズは独立に検証可能・revert 可能な単位とし、フェーズ単位で PR を分けることを推奨する。

## 実装セッション向け制約（指示書に必ず入れる）

- 最初に `git status` を確認し、既存の未コミット変更と自分の変更を混ぜない
- 編集前に baseline の検証結果（run-tests.sh の pass 数）を記録する
- 変更は小さく戻しやすい単位にする。Conventional Commits 形式、ブランチは `develop` ベース
- 無関係な整形・ついでのリファクタリングをしない
- 既存挙動を勝手に変えない。正しさが不明なら実装を止めて質問する
- 各フェーズ後に `run-tests.sh` と関連静的チェックを実行し、最後に実行コマンドと結果を報告する
- **rite 固有の制約**:
  - 実装セッションで `/rite:` コマンドを使わない（リファクタ対象のワークフロー自身で作業すると、変更途中の定義が読み込まれる自己参照ループが起きる）
  - `~/.claude/settings.json` の `enabledPlugins` で `rite@rite-marketplace: false` を維持する（true だとキャッシュされた旧マーケットプレイス版が優先ロードされ、ローカル修正が反映されない）
  - このリポジトリでは rite の hooks が実装セッション自身に対しても発火する。hooks を編集した直後の挙動変化に注意する

## 最終出力

1. **実装前に確認すべき質問** — AskUserQuestion で解決しきれなかったものが残る場合のみ。コードから判断できるものは質問しない
2. **refactor-instructions.md 本文** — リポジトリ直下に保存。人間がそのまま `/goal refactor-instructions.md に書かれたことを完遂しろ` と渡せる、自己完結した内容にする

## 重要

- 曖昧な「全部リファクタしろ」という指示書にしない。各項目に根拠・検証方法・完了条件を付ける
- 見た目の綺麗さを目的にしない。削減対象は常に「コンテキストコスト」「同期コスト」「腐敗した参照」で正当化する
- 古いコードをすべて悪と決めつけない。意図的な設計（flat workflow 化、ライブラリ的 hooks など)を「負債」と誤認しない
- 実装担当が証拠なく大きな削除や全面書き換えをしないよう、指示書の Stop And Ask Conditions で縛る
- 目的は、既存のコアワークフローを壊さず、総量を減らし、一般公開に耐える変更しやすい状態にすることである
