# 設定リファレンス

このドキュメントは Claude Code Rite Workflow のすべての設定オプションを説明する。

> 🇺🇸 English version: [CONFIGURATION.md](./CONFIGURATION.md)
> 📘 翻訳方針・用語ルール: [i18n-style-guide.md](./i18n-style-guide.md) (`finding` などの kept-English term を含む)

## 設定ファイル

設定ファイルは `rite-config.yml` という名前で、以下のいずれかに配置する:
- プロジェクトルート (`./rite-config.yml`)
- もしくは `.claude/` ディレクトリ (`./.claude/rite-config.yml`)

## 設定例（フル）

```yaml
# Claude Code Rite Workflow 設定ファイル
schema_version: 2

# DEPRECATED (#1118): project.type プリセット機能は完全に削除されました。
# `generic` / `webapp` / `library` / `cli` / `documentation` のプリセットと
# `templates/project-types/*.yml` は #1118 で削除済。プロジェクト固有設定は
# 個別キー (`branch.pattern`, `commands.*`, `iteration.*` 等) を YAML で
# 直接指定する方式に統一されました。
# rite-config.yml から `project:` ブロックを削除して構わない (キーは効果を持たない)。
# project:
#   type: webapp

# GitHub Projects 連携
github:
  projects:
    enabled: true
    project_number: null  # Project number (null = リポジトリから自動検出)
    owner: null           # Project owner (null = リポジトリの owner を使用)
    fields:
      status:
        enabled: true
        options:
          - { name: "Todo", default: true }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
      priority:
        enabled: true
        options:
          - { name: "High" }
          - { name: "Medium", default: true }
          - { name: "Low" }
      complexity:
        enabled: true
        options:
          - { name: "XS" }
          - { name: "S" }
          - { name: "M", default: true }
          - { name: "L" }
          - { name: "XL" }
      # カスタムフィールド (プロジェクト固有)
      # GitHub Projects の Single Select フィールドはここに任意で追加可能
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
          - { name: "Chore" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }
    # 明示的なフィールド ID (任意、自動検出を上書き)
    # field_ids:
    #   status: "PVTSSF_..."      # Status フィールドの ID
    #   priority: "PVTSSF_..."    # Priority フィールドの ID
    #   complexity: "PVTSSF_..."  # Complexity フィールドの ID
    #   # カスタムフィールド
    #   work_type: "PVTSSF_..."   # カスタム Single Select フィールドの ID

# ブランチ命名ルール
branch:
  base: "main"       # フィーチャーブランチのベース (Git Flow の場合は "develop")
  pattern: "{type}/issue-{number}-{slug}"

# コミットメッセージ
commit:
  contextual: true    # コミット body に Contextual Commits の action 行を含めるか

# ビルド/テスト/lint コマンド
commands:
  build: null  # 自動検出
  test: null   # 自動検出
  lint: null   # 自動検出

# Issue 設定
issue:
  auto_decompose_threshold: M  # XS | S | M | L | XL | none (default: M)

# レビュー設定
review:
  min_reviewers: 1      # マッチするレビュアーが居ない時のフォールバック
  criteria:
    - file_types
    - content_analysis
  loop:
    verification_mode: false    # フルレビューに加えて verification mode を有効化 (default: false)
    allow_new_findings_in_unchanged_code: false  # 未変更コードでの新規 finding を blocking 扱いにするか (default: false)
    # レビュー・フィックスループの終了 (post-#1136)
    # サイクル数ベースの degradation (v0.4.0 #557 で 4 品質シグナルが異常終了機構として導入) は
    # #1136 で quality-signal escalation 全体ごと撤去済。現行ループは以下のいずれかでのみ終了する:
    #   (a) 残り finding が 0 件 → [review:mergeable] (正常終了)
    #   (b) Ctrl+C 中断 → /rite:resume (または fix.md AskUserQuestion 「中止」 → [fix:cancelled-by-user])
    # 以下のキーは historical 互換性のため config scaffolding として残置されているが、
    # ループ終了に対する runtime 効果はない — live spec は commands/pr/iterate.md ループ仕様 と
    # commands/pr/references/fix-relaxation-rules.md 「Loop Termination」節 を参照。
    convergence_monitoring: true          # (post-#1136 では scaffolding のみ — 上記コメント参照)
    auto_propagation_scan: true           # fix 後に類似パターンの propagation スキャンを実行 (default: true)
    pre_commit_drift_check: true          # commit 前に distributed-fix-drift-check を実行 (default: true)
  doc_heavy:
    enabled: true                   # Doc-Heavy PR 検出と override を有効化 (default: true)
    lines_ratio_threshold: 0.6      # doc_lines / total_diff_lines のしきい値 (default: 0.6)
    count_ratio_threshold: 0.7      # doc_files / total_files のしきい値 (default: 0.7)
    max_diff_lines_for_count: 2000  # count ratio を参照する diff 行数の上限 (default: 2000)
  security_reviewer:
    mandatory: false                          # すべての PR で security reviewer を必須化 (default: false)
    recommended_for_code_changes: true        # 実行コードの変更時に推奨 (default: true)
  debate:
    enabled: true            # レビュアー間 debate フェーズを有効化 (default: true)
    max_rounds: 1            # コスト制御のための最大 debate ラウンド数 (default: 1)
  confidence_threshold: 80   # findings テーブルに含める最小 confidence スコア (default: 80)
  fact_check:
    enabled: true                      # レビュー finding の fact-check フェーズを有効化 (default: true)
    max_claims: 20                     # 1 回のレビューで検証する External claim の最大数 (default: 20)。Internal Likelihood claim は Grep ベースで、この上限の対象外
    use_context7: true                 # 検証に context7 MCP ツールを使う (default: true)。context7 が利用不可な場合は WebSearch に自動フォールバック
    verify_internal_likelihood: true   # Grep ベースで Sub-Phase B (Internal Likelihood Claim Verification) を有効化 (default: true)
  # DEPRECATED (#1118): observed_likelihood_gate キーは無視される。
  # これらは #506 で導入された scaffolding キーで、conditional runtime logic に
  # 一度も配線されないまま削除された。Observed Likelihood Gate の挙動 (Observed /
  # Demonstrable / Hypothetical 軸の強制) は `_reviewer-base.md` / `fix.md` /
  # `review.md` の prose にハードコードされており、config で無効化できない。
  # rite-config.yml から observed_likelihood_gate: ブロックを削除してよい。
  # observed_likelihood_gate:
  #   enabled: true
  #   security_exception: true
  #   hypothetical_exception_reviewers:
  #     - security
  #     - database
  #     - devops
  #     - dependencies
  #   minimum: "demonstrable"
  # DEPRECATED (#1118): fail_fast_first キーは無視される。
  # これらは #506 で導入された scaffolding キーで、conditional runtime logic に
  # 一度も配線されないまま削除された。Fail-Fast First 原則 (フォールバック推奨前の
  # throw/raise 伝播考慮) は `_reviewer-base.md` / `fix.md` の prose にハードコード
  # されており、config で無効化できない。rite-config.yml から fail_fast_first: ブロックを削除してよい。
  # fail_fast_first:
  #   enabled: true
  #   allow_skill_exceptions: true
  #   wiki_query_required: true
  # DEPRECATED (#1136): separate_issue_creation キーは無視される。
  # 「Automatic Separate Issue Creation」機構 (fix.md Phase 4.3) と
  # [fix:issues-created:N] sentinel は完全に削除された。レビュアーの推奨は
  # ループ内で処理される (fix / accept / reply) のみで、review 出力からの
  # 自動 Issue 作成は行われない。report_pre_existing_issues も同様に無視されるため、
  # rite-config.yml から separate_issue_creation: ブロックを削除してよい。
  # separate_issue_creation:
  #   require_user_confirmation: true
  #   report_pre_existing_issues: false

# Fix 設定 (#506)
fix:
  fail_fast_response: true             # fix.md Phase 2 で Fail-Fast Response Principle を有効化 (default: true)
  # DEPRECATED (#1118): fix.severity_gating キーは無視される。
  # severity_gating 収束戦略 (#506) は #1118 で完全に削除された。
  # 現行のレビュー・フィックスループは非収束の自動処理機構を持たない —
  # 残り finding が 0 件 (normal exit) か、ユーザーが Ctrl+C で中断 (manual exit、
  # /rite:resume で復帰) のいずれかでのみ終了する。終了条件は commands/pr/iterate.md
  # (ループ仕様) と commands/pr/references/fix-relaxation-rules.md の
  # 「Loop Termination」節を参照。severity_gating 戦略も旧 Phase 4.3.3 AskUserQuestion
  # (retry / 別 issue / withdraw) 機構も #1118 / #1136 で削除済 — 現行ループには
  # cycle counter / N 回上限 / quality-signal escalation のいずれも存在しない。
  # rite-config.yml から fix.severity_gating: ブロックを削除してよい。
  # severity_gating:
  #   enabled: false

# Iteration / Sprint 設定 (任意)
iteration:
  enabled: false          # true で iteration 機能を有効化 (default: false)
  field_name: "Sprint"    # Projects の iteration フィールド名 (default: "Sprint")
  auto_assign: true       # /rite:pr:open 時に現在の iteration へ自動 assign (default: true)
  show_in_list: true      # issue:list で iteration 列を表示 (default: true)

# Verification gate 設定
verification:
  run_tests_before_pr: true          # commit/PR 前にテスト実行 (commands.test 必須) (default: true)
  acceptance_criteria_check: true    # PR 作成前に Issue body の acceptance criteria をチェック (default: true)

# TDD Light モード設定
tdd:
  mode: "off"              # off | light (default: off)
  tag_prefix: "AC"         # テストスケルトンのマーカープレフィックス (default: "AC")
  run_baseline: true       # スケルトン生成前にベースラインテストを実行 (default: true)
  max_skeletons: 20        # 1 つの Issue で生成するスケルトンの上限 (default: 20)

# 並列実装設定
parallel:
  enabled: true          # 並列実装を有効化 (default: true)
  max_agents: 3          # 同時実行する agent の最大数 (default: 3)
  mode: "shared"         # "shared" (default) または "worktree"
  worktree_base: ".worktrees"  # mode が "worktree" の時の worktree ベースディレクトリ (default: ".worktrees")

# チームベース sprint 実行設定
team:
  enabled: true              # /rite:sprint:team-execute を有効化 (default: true)
  max_concurrent_issues: 3   # バッチごとに並列処理する Issue の最大数 (default: 3)
  teammate_model: "sonnet"   # teammate agent のモデル (default: "sonnet")
  auto_review: true          # すべての PR 作成後に /rite:pr:review を自動実行 (default: true)

# PR レビュー結果の記録 (#443)
# 上の `review:` セクションは PR レビューの**実行** (reviewer 選定 / debate / fact_check 等) を、
# この `pr_review:` セクションは PR レビューの**出力** (post_comment) を設定する。
# 既定ではレビュー結果はタイムスタンプ付きローカルファイル
# (`.rite/review-results/{pr_number}-{timestamp}.json`) に保存され、PR コメントには投稿されない。
# `/rite:pr:fix` は優先順位 conversation > local file > PR comment で結果を自動読込する。
pr_review:
  post_comment: false   # true で PR コメント記録を有効化 (--post-comment 相当, default: false)

# Safety 設定 (fail-closed しきい値)
safety:
  max_implementation_rounds: 20    # 1 Issue あたりの implementation round の上限 (default: 20)
  # max_review_fix_loops は v0.4.0 (#557) で廃止、それを置き換えた 4 シグナル escalation も #1136 で全廃済。
  # 現行ループは 0 件の finding (正常終了) または Ctrl+C 中断 (/rite:resume で再開) のみで終了する。
  time_budget_minutes: 120         # 1 Issue あたりの time budget (アドバイザリ) (default: 120)
  auto_stop_on_repeated_failure: true   # 同一クラスの失敗が連続したら停止 (default: true)
  repeated_failure_threshold: 3         # 自動停止をトリガする連続失敗回数 (default: 3)

# Experience Wiki (opt-out, 詳細は下の wiki セクションを参照)
wiki:
  enabled: true                        # Wiki 機能を有効化 (default: true, opt-out)
  branch_strategy: "separate_branch"   # "separate_branch" (推奨) または "same_branch"
  branch_name: "wiki"                  # Wiki データ用のブランチ名 (branch_strategy が "separate_branch" の時のみ)
  auto_ingest: true                    # review/fix/close で自動 ingest (default: true)
  auto_query: true                     # start/review/fix/implement で自動 query (default: true)
  auto_lint: true                      # ingest 後に /rite:wiki:lint --auto を自動実行 (default: true)

# メトリクス設定
metrics:
  enabled: true            # メトリクス記録の有効/無効 (default: true)
  baseline_issues: 3       # ベースライン収集の Issue 数 (default: 3)

# 通知設定
notifications:
  slack:
    enabled: false
    webhook_url: null
  discord:
    enabled: false
    webhook_url: null
  teams:
    enabled: false
    webhook_url: null

# 言語設定
language: auto  # auto | ja | en
```

## 設定セクション

### ~~project~~ (DEPRECATED in #1118)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| ~~`project.type`~~ | — | — | **DEPRECATED (#1118)**: 完全に削除済み。`generic` / `webapp` / `library` / `cli` / `documentation` のプリセットと `templates/project-types/*.yml` は #1118 で削除済。プロジェクト固有設定は個別キー (`branch.pattern`, `commands.*`, `iteration.*` 等) を YAML で直接指定する方式に統一された。`rite-config.yml` から `project:` ブロックを削除して構わない (キーは効果を持たない) |

### github.projects

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | GitHub Projects 連携を有効化 |
| `project_number` | integer | `null` | Project number (null の場合はリポジトリから自動検出) |
| `owner` | string | `null` | Project owner — user / organization (null の場合はリポジトリの owner を使用) |
| `fields` | object | - | カスタムフィールド定義 |
| `field_ids` | object | - | 明示的なフィールド ID (任意、自動検出を上書き) |

### github.projects.field_ids

このフィールドが指定されている場合、`gh project field-list` による自動検出ではなく、指定された ID が直接使われる。以下のケースで有用:
- API 自動検出が失敗する場合 (例: 権限問題、organization ポリシーによる制限)
- 自動検出に依存せず一貫したフィールド ID を使いたい場合

**Note:** Option ID (例: "In Progress", "Done") はこの設定に関わらず常に API 経由で取得される。

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Status フィールドの ID (例: `PVTSSF_...`) |
| `priority` | string | Priority フィールドの ID |
| `complexity` | string | Complexity フィールドの ID |
| *(任意のカスタムフィールド)* | string | カスタム Single Select フィールドの ID (例: `work_type`, `category`) |

**例:**

```yaml
github:
  projects:
    field_ids:
      status: "PVTSSF_your-status-field-id"      # 実際の ID に置き換えること
      priority: "PVTSSF_your-priority-field-id"  # 実際の ID に置き換えること
      # カスタムフィールド
      category: "PVTSSF_your-category-field-id"  # 実際の ID に置き換えること
```

**挙動:**
- `field_ids` でフィールド ID が指定されていれば、それが直接使われる (このフィールドの自動検出用 API 呼び出しは発生しない)
- 指定されていなければ `gh project field-list` で自動検出される
- 部分指定にも対応: `status` のみ指定した場合、`priority` と `complexity` は (`fields` で有効化されていれば) 自動検出される

**フィールド ID の調べ方:**

以下のコマンドを実行する (`1` を自分の project number に、`myorg` を owner に置き換える):

```bash
gh project field-list 1 --owner myorg --format json
```

出力に含まれる各フィールドの `id` を確認する。

### github.projects.fields

各フィールドは以下を持つ:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | このフィールドを有効化 |
| `options` | array | `name` と任意の `default: true` を持つオプションのリスト |

**標準フィールド:**

以下は GitHub Projects で一般的に使われ、ビルトインサポートがある:

| Field | Description |
|-------|-------------|
| `status` | Issue / PR の状態追跡 (Todo, In Progress 等) |
| `priority` | 優先度 (High, Medium, Low) |
| `complexity` | 推定 complexity (XS, S, M, L, XL) |

**カスタムフィールド:**

GitHub Projects 側で定義したフィールド名と同じ名前で、プロジェクト固有の Single Select フィールドを任意に追加可能。`work_type`, `category`, `team` などが代表例。

```yaml
github:
  projects:
    fields:
      # 標準フィールド
      status: { enabled: true, options: [...] }
      priority: { enabled: true, options: [...] }

      # カスタムフィールド (プロジェクト固有)
      # フィールド名は GitHub Projects 側のフィールド名と一致させる (大文字小文字は区別しない)
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }
```

**カスタムフィールドの要件:**
- `rite-config.yml` のフィールド名は GitHub Projects 側のフィールド名と一致させる (大文字小文字は区別しない)
- フィールドは GitHub Projects 側で Single Select 型である必要がある
- options は GitHub Projects 側の利用可能な選択肢と一致させる

### branch

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `base` | string | `main` | フィーチャーブランチのベース (PR のターゲット)。Git Flow の場合は `develop` を指定 |
| `pattern` | string | `{type}/issue-{number}-{slug}` | ブランチ名のパターン |

**Git Flow サポート:**

Git Flow ワークフローでは以下のように設定する:

```yaml
branch:
  base: "develop"    # フィーチャーブランチは develop から作成される
```

この設定は以下のコマンドに影響する:
- `/rite:pr:open`: `branch.base` からフィーチャーブランチを作成
- `/rite:pr:create`: `branch.base` を PR のターゲットに設定
- `/rite:pr:cleanup`: cleanup 後に `branch.base` に切り替え
- `/rite:lint`: diff 検出に `origin/{branch.base}...HEAD` を使用 (例: `origin/develop...HEAD`)

**Recognized Patterns (標準外ブランチ):**

マイグレーションプロジェクト等、標準の `{type}/issue-{number}-{slug}` パターンに従わないブランチを認識させたい場合、追加のパターンを定義可能:

```yaml
branch:
  recognized_patterns:
    - "migration/phase{n}-{category}"
    - "i18n/{locale}"
    - "hotfix/{date}-{description}"
```

**`recognized_patterns` 用のパターン変数:**

以下の変数は `recognized_patterns` 専用で、既存の標準外ブランチをマッチさせるために使われる:

| Variable | Description | Example Match |
|----------|-------------|---------------|
| `{n}` | 任意の数値 | `1`, `42`, `100` |
| `{category}` | 任意の文字列 (英数字とハイフン) | `admin-tutorials`, `api-docs` |
| `{locale}` | locale コード | `ja`, `zh-tw`, `en-us` |
| `{date}` | 日付文字列 (任意のフォーマット) | `20250109`, `2025-01-09` |
| `{description}` | 任意の説明文字列 | `fix-login`, `update-deps` |
| `{*}` | ワイルドカード (任意の文字) | 何でも可 |

**ユースケース:**

- マイグレーションプロジェクト: `migration/phase4-admin-tutorials`
- 国際化: `i18n/zh-tw`
- Issue を伴わない hotfix: `hotfix/20250109-critical-fix`

`/rite:pr:open` がこれらのパターンに一致する既存ブランチを検出した場合 (Step 2.2 既存ブランチチェック参照)、Issue 番号を含まなくてもそのブランチを使う選択肢を提示する。

**`branch.pattern` 用のパターン変数:**

以下の変数は `branch.pattern` で新規ブランチ名の生成に使われる:

| Variable | Description | Example |
|----------|-------------|---------|
| `{type}` | 作業タイプの prefix | `feat`, `fix`, `docs` |
| `{number}` | Issue 番号 | `123` |
| `{slug}` | slug 化された Issue タイトル | `add-auth-feature` |
| `{date}` | 現在日付 (YYYYMMDD) | `20250103` |
| `{user}` | GitHub ユーザー名 | `octocat` |

### commit

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `contextual` | boolean | `true` | コミット body に Contextual Commits の action 行を含めるか |

### commands

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `build` | string | `null` | ビルドコマンド (null の場合は自動検出) |
| `test` | string | `null` | テストコマンド (null の場合は自動検出) |
| `lint` | string | `null` | lint コマンド (null の場合は自動検出) |

### issue

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `auto_decompose_threshold` | string | `M` | decomposition プロンプトを自動スキップする complexity しきい値 |

**auto_decompose_threshold の値:**

| Value | Behavior |
|-------|----------|
| `XS` | XS で body 解析、S 以上で提案を表示 |
| `S` | XS はスキップ、S で body 解析、M 以上で提案を表示 |
| `M` | XS/S はスキップ、M で body 解析、L 以上で提案を表示 (default) |
| `L` | XS〜M はスキップ、L で body 解析、XL で提案を表示 |
| `XL` | XS〜L はスキップ、XL のみ body 解析 (XL は最大なので提案なし) |
| `none` | 常に decomposition プロンプトを表示 (旧挙動) |

**3 段階判定ロジック:**

| Condition | Behavior |
|-----------|----------|
| Complexity < threshold | decomposition をスキップ (直接作業に進む) |
| Complexity == threshold | Issue body を解析してスコープを推定し、判定 |
| Complexity > threshold | decomposition 提案を表示 |

Issue の complexity がしきい値未満の場合、`/rite:issue:create` は decomposition 提案をスキップして Issue をそのまま作成し、後続の `/rite:pr:open` は確認なしで作業を開始する。complexity がしきい値と一致する場合、Issue body を解析して変更スコープ (言及されているファイル数) を推定して判定する。これにより単純な Issue で不要なプロンプトが減り、複雑な Issue では引き続きプロンプトが表示される。

**Body 解析基準:** complexity がしきい値と一致する場合、Issue body を解析する。1〜2 ファイルが言及されていれば decomposition をスキップ、3 ファイル以上なら decomposition 提案を表示する。

**例:**

```yaml
issue:
  auto_decompose_threshold: S  # XS はスキップ、S で body 解析、M 以上でプロンプト
```

### review

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `min_reviewers` | integer | `1` | 最小レビュアー数 (マッチするレビュアーが居ない時のフォールバック) |
| `criteria` | array | `[file_types, content_analysis]` | レビュー基準 |
| `loop.verification_mode` | boolean | `false` | フルレビューに加えて verification mode を有効化。有効時は、最初のサイクル以降のレビューでフルレビューと過去の fix の verification (incremental diff regression チェック) の両方を実施 |
| `loop.allow_new_findings_in_unchanged_code` | boolean | `false` | 未変更コードに対する新規 finding を blocking 扱いにするか。`false` の場合、未変更コードの新規 MEDIUM/LOW finding は "stability concerns" (非 blocking) として報告される |
| `loop.convergence_monitoring` | boolean | `true` | **post-#1136 では scaffolding のみ** — 元々のフィンガープリントベース cycling 検出 (#557 Quality Signal 1) は `AskUserQuestion` でエスカレートしていたが、quality-signal escalation 機構全体が #1136 で撤去された。現行のレビュー・フィックスループは 0 件の finding (正常終了) または手動中断 (Ctrl+C → `/rite:resume`) でのみ終了する。本キーは runtime 効果を持たない — live spec は `commands/pr/iterate.md` を参照 |
| `loop.auto_propagation_scan` | boolean | `true` | fix 適用後、コードベース内の類似パターンを自動でスキャンして propagation の取りこぼしを検出 |
| `loop.pre_commit_drift_check` | boolean | `true` | fix の変更を commit する前に `distributed-fix-drift-check` を実行し、partial application の不整合を検出 |
| `doc_heavy.enabled` | boolean | `true` | Doc-Heavy PR 検出を有効化。PR の diff がドキュメント変更で占有されている場合、`tech-writer` レビュアーがブーストされ Grep/Read/Glob で 5 種類の doc-implementation 整合性をチェックする |
| `doc_heavy.lines_ratio_threshold` | float | `0.6` | PR を doc-heavy としてマークする `doc_lines / total_diff_lines` のしきい値 |
| `doc_heavy.count_ratio_threshold` | float | `0.7` | `doc_files / total_files` のしきい値 (小規模 diff のフォールバックとして使用) |
| `doc_heavy.max_diff_lines_for_count` | integer | `2000` | `count_ratio_threshold` を参照する diff 行数の上限 |
| `security_reviewer.mandatory` | boolean | `false` | ファイルタイプに関わらず、すべての PR で security reviewer を必須化 |
| `security_reviewer.recommended_for_code_changes` | boolean | `true` | 実行可能コードが変更された時に security reviewer を含める |
| `debate.enabled` | boolean | `true` | レビュアー間 debate フェーズを有効化 |
| `debate.max_rounds` | integer | `1` | 最大 debate ラウンド数 (コスト制御) |
| `confidence_threshold` | integer | `80` | findings テーブルに含める finding の最小 confidence スコア |
| `fact_check.enabled` | boolean | `true` | レビュー finding の fact-check フェーズを有効化 |
| `fact_check.max_claims` | integer | `20` | 1 回のレビューで検証する **External** claim の最大数 (Sub-Phase A)。Internal Likelihood claim は Grep ベースで、この上限の対象外 |
| `fact_check.use_context7` | boolean | `true` | 検証に context7 MCP ツールを使う。context7 が利用不可な場合は WebSearch に自動フォールバック |
| `fact_check.verify_internal_likelihood` | boolean | `true` | Grep ベースの呼び出し箇所 / エントリポイントチェックで Sub-Phase B (Internal Likelihood Claim Verification) を有効化 |
| ~~`observed_likelihood_gate.*`~~ | — | — | **DEPRECATED (#1118)**: 完全に削除済み。これらは #506 で導入された scaffolding キーで、conditional runtime logic に一度も配線されないまま削除された。Observed Likelihood Gate の挙動 (Observed / Demonstrable / Hypothetical 軸の強制) は `_reviewer-base.md` / `fix.md` / `review.md` の prose にハードコードされている。`rite-config.yml` から `observed_likelihood_gate:` を削除して構わない (キーは効果を持たない) |
| ~~`fail_fast_first.*`~~ | — | — | **DEPRECATED (#1118)**: 完全に削除済み。これらは #506 で導入された scaffolding キーで、conditional runtime logic に一度も配線されないまま削除された。Fail-Fast First 原則 (fallback 推奨前の throw/raise 伝播考慮) は `_reviewer-base.md` / `fix.md` の prose にハードコードされている。`rite-config.yml` から `fail_fast_first:` を削除して構わない (キーは効果を持たない) |
| ~~`separate_issue_creation.*`~~ | — | — | **DEPRECATED (#1136)**: **runtime 機構**を完全削除済み — fix-side の post-loop 経路 `fix.md` Phase 4.3 (「Automatic Separate Issue Creation」) と `[fix:issues-created:N]` sentinel を撤去した。**Note**: review-side の `pr/review.md` Phase 7 (Automatic Issue Creation、`source: pr_review`、`AskUserQuestion` 承認 gate 付き) は依然 live で、reviewer の「別 Issue として作成」推奨を tracking Issue に変換する canonical な経路。`/rite:pr:fix` のレビュー・フィックスループ内では reviewer recommendation は per-finding で fix / accept / reply (Phase 2.1 menu) として処理され、fix-side の post-loop auto-creation は無い。**Template 状態**: `templates/config/rite-config.yml` には v0.5.0 時点で `separate_issue_creation:` の scaffolding block が残置されている — runtime 効果は無く、follow-up PR で削除予定。既存ユーザーは local `rite-config.yml` から本 block を安全に削除できる |

**レビュー・フィックスループの終了 (post-#1136):**

レビュー・フィックスループは 2 つの終了パスのみを持ち、自動的な異常終了機構は存在しない:

| Exit | Trigger |
|------|---------|
| Normal | 残り finding が 0 件 → `[review:mergeable]` |
| Manual abort | ユーザーが `Ctrl+C` で中断 → `/rite:resume` (または `fix.md` AskUserQuestion で「中止」選択 → `[fix:cancelled-by-user]`) |

> **Historical note (#557 → #1136)**: v0.4.0 (#557) で 4 つの品質シグナル (フィンガープリント cycling / 根本原因欠落 / クロスバリデーション不一致 / レビュアー自己 degraded) を異常終了機構として導入し、発火時に `AskUserQuestion` で `本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション` のオプションを提示していた。#1136 でこの機構全体を撤去 — 設計判断は「指摘ゼロになるまでループ + 手動中断のみ」(`commands/pr/iterate.md` 設計判断 (Issue #1136) 参照)。4 つの検出ポイント自体は依然 reviewer-side ヒューリスティクスとしてコードに残存する (フィンガープリント cycling: `commands/issue/references/fingerprint-cycling.md`、根本原因欠落: `fix.md` Phase 3.2.1 commit body gate、クロスバリデーション: `review.md` Phase 5.2 + debate フェーズ、レビュアー自己 degraded: `_reviewer-base.md` Finding Quality Guardrail) が、`AskUserQuestion` への escalation や early loop exit は発生しない。

**Fix 設定 (#506):**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `fix.fail_fast_response` | boolean | `true` | `fix.md` Phase 2 で Fail-Fast Response Principle を有効化。fix アプローチ採用前に 4 項目チェックリスト (throw/raise 伝播 / 既存のエラー境界 / null-check で隠していないか / テスト側を修正すべきでないか) を要求する。fallback 採用はコミットメッセージで正当化が要求される。**⚠️ Known limitation (#506)**: 設定スキャフォールドのみで、まだ wired されていない。原則は `fix.md` Phase 2 のプロンプトで強制されている。`false` に設定しても現状効果がない |
| ~~`fix.severity_gating.*`~~ | — | — | **DEPRECATED (#1118)**: 完全に削除済み。severity_gating 収束戦略 (#506) は #1118 で削除された。非収束緩和は #1136 までは 4 つの品質シグナル (#557) で処理されていたが、#1136 で quality-signal escalation 全廃済 — 現行のレビュー・フィックスループは残り finding が 0 件 (normal exit) か、ユーザーが Ctrl+C で中断 (manual exit、`/rite:resume` で復帰) のいずれかでのみ終了する (`commands/pr/iterate.md` ループ仕様 / `commands/pr/references/fix-relaxation-rules.md` 「Loop Termination」節 参照)。`rite-config.yml` から `fix.severity_gating:` を削除して構わない (キーは効果を持たない) |

**Doc-Heavy PR モード** (`doc_heavy.enabled: true` がデフォルト): PR は `doc_lines / total_diff_lines >= lines_ratio_threshold` の場合、または小規模 diff (`total_diff_lines < max_diff_lines_for_count`) では `doc_files / total_files >= count_ratio_threshold` の場合に doc-heavy として分類される。doc-heavy モードでは `tech-writer-reviewer` が Grep/Read/Glob を使って 5 種類の整合性 (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) を実装と照合する。完全なプロトコルは `plugins/rite/commands/pr/references/internal-consistency.md` を参照。

**Verification モード** (`verification_mode: false` がデフォルト): 明示的に `true` に設定すると、サイクル 2 以降はフルレビューと過去の fix の verification (incremental diff regression チェック) の両方を実施する。未変更コードでの新規 MEDIUM/LOW finding は "stability concerns" (非 blocking) として分類される。既定の `false` では毎サイクルでフルレビューのみを実施し、レビュー品質を最大化する。

**レビュー実行:**

`/rite:pr:review` は Claude Code の Task tool を使い、各レビュアーロールに対して並列サブエージェントを spawn する。これによりコンテキスト効率が向上し並列実行が可能になる。

**利用可能なレビュアー:**

以下の専門レビュアーが、変更されたファイルに基づいて自動的に選定される:

| Reviewer | Focus Area |
|----------|------------|
| `security-reviewer` | セキュリティ脆弱性、認証、データハンドリング |
| `performance-reviewer` | N+1 クエリ、メモリリーク、アルゴリズム効率 |
| `code-quality-reviewer` | 重複、命名、エラーハンドリング、構造 |
| `api-reviewer` | API 設計、REST 規約、インターフェース契約 |
| `database-reviewer` | スキーマ設計、クエリ、マイグレーション、データ操作 |
| `devops-reviewer` | インフラ、CI/CD パイプライン、デプロイ設定 |
| `frontend-reviewer` | UI コンポーネント、スタイリング、アクセシビリティ、クライアントサイドコード |
| `test-reviewer` | テスト品質、カバレッジ、テスト戦略 |
| `dependencies-reviewer` | パッケージ依存、バージョン、サプライチェーンセキュリティ |
| `prompt-engineer-reviewer` | Claude Code skill / command / agent 定義 |
| `tech-writer-reviewer` | ドキュメントの明瞭さ、正確性、完全性 |
| `error-handling-reviewer` | silent failure、エラー伝播、catch ブロック品質 |
| `type-design-reviewer` | 型のカプセル化、不変条件の表現、強制 |

**レビュアー選定:**

レビュアーは以下に基づいて自動選定される:
1. ファイルパターン (例: `*.test.*` は `test-reviewer` をトリガ)
2. コンテンツ解析 (例: SQL クエリは `database-reviewer` をトリガ)
3. 変更の complexity とスコープ

**フォールバック挙動:**

サブエージェントが失敗 / タイムアウトした場合:
1. 残りのサブエージェントでレビューが継続される
2. 失敗したサブエージェントの結果は "incomplete" としてマークされる
3. レビューサマリーで失敗がユーザーに通知される

### iteration

GitHub Projects との Sprint / Iteration 連携設定。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | iteration 機能を有効化 |
| `field_name` | string | `"Sprint"` | GitHub Projects 内の iteration フィールド名 |
| `auto_assign` | boolean | `true` | `/rite:pr:open` 時に現在の iteration に Issue を自動 assign |
| `show_in_list` | boolean | `true` | `/rite:issue:list` 出力で iteration 列を表示 |

**例:**

```yaml
iteration:
  enabled: true
  field_name: "Sprint"
  auto_assign: true
  show_in_list: true
```

有効化すると、`/rite:pr:open` は作業開始時に Issue を現在アクティブな iteration に自動 assign する。iteration の一覧表示は `/rite:sprint:list`、現在の sprint 詳細は `/rite:sprint:current` を使う。

### verification

PR 作成前の品質 verification gate 設定。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `run_tests_before_pr` | boolean | `true` | commit/PR 前にテストを実行 (`commands.test` の設定が必要) |
| `acceptance_criteria_check` | boolean | `true` | PR 作成前に Issue body の acceptance criteria をチェック |

**例:**

```yaml
verification:
  run_tests_before_pr: true
  acceptance_criteria_check: true
```

### tdd

TDD (Test-Driven Development) Light モード設定。有効化すると、実装前に acceptance criteria からテストスケルトンが生成される。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | string | `"off"` | TDD モード: `"off"` (無効) または `"light"` (acceptance criteria からテストスケルトンを生成) |
| `tag_prefix` | string | `"AC"` | テストスケルトンのマーカープレフィックス (例: `AC-1`, `AC-2`) |
| `run_baseline` | boolean | `true` | スケルトン生成前にベースラインテストスイートを実行し既存テストが pass することを保証 |
| `max_skeletons` | integer | `20` | 1 Issue あたり生成するテストスケルトンの最大数 |

**例:**

```yaml
tdd:
  mode: "light"
  tag_prefix: "AC"
  run_baseline: true
  max_skeletons: 20
```

**TDD Light の動作:**

1. Issue body から acceptance criteria を抽出
2. マーカー付きテストスケルトン (例: `// AC-1: User can log in`) を生成
3. スケルトンテストを pass させる形で実装を進める
4. PR 作成前にテスト結果を verify する

### parallel

Task tool を使った並列実装の設定。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | 並列実装を有効化 |
| `max_agents` | integer | `3` | 同時実行する agent の最大数 |
| `mode` | string | `"shared"` | Agent の作業モード: `"shared"` (全 agent が作業ディレクトリを共有) または `"worktree"` (各 agent が独立した git worktree を持つ) |
| `worktree_base` | string | `".worktrees"` | `mode` が `"worktree"` の時の worktree ベースディレクトリ |

**並列実装が使われる条件:**

以下のすべての条件を満たした時に並列実装が自動で起動する:
1. `parallel.enabled` が `true`
2. Issue complexity が M 以上
3. 実装計画で独立した複数のファイル / コンポーネントが特定されている

**動作:**

1. Phase 5.1 (Implementation) で実装計画が解析される
2. 独立したタスク (互いに依存しない別ファイル等) が特定されると、Task tool で並列実行される
3. 各並列タスクは別の agent に割り当てられる
4. 次フェーズに進む前に結果が集約・統合される

**Agent モード:**

- `"shared"` (default): 全 agent が同じ作業ディレクトリを共有する。シンプルだが、同時 `git checkout` などの競合を避けるための慎重な調整が必要。
- `"worktree"`: 各 agent が `worktree_base` ディレクトリ配下に独立した git worktree を持つ。完全な isolation が得られるが、より多くのディスク容量を要する。

**例:**

```yaml
parallel:
  enabled: true          # 並列実装を有効化 (default)
  max_agents: 3          # 最大 3 agent まで同時実行
  mode: "worktree"       # isolation のために独立 worktree を使用
  worktree_base: ".worktrees"
```

並列実装を無効化:

```yaml
parallel:
  enabled: false
```

**エラーハンドリング:**

- 1 タスクが失敗しても、他のタスクの実行は継続される
- 失敗したタスクの結果は最後に集約・報告される
- メインワークフローは成功した結果で続行される
- 失敗したタスクは手動でリトライするか、後続のコミットで対応する

### team

`/rite:sprint:team-execute` を使ったチームベース Sprint 実行の設定。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | `/rite:sprint:team-execute` コマンドを有効化 |
| `max_concurrent_issues` | integer | `3` | バッチごとに並列処理する Issue の最大数 (未設定時は `parallel.max_agents` にフォールバック) |
| `teammate_model` | string | `"sonnet"` | teammate agent のモデル: `"sonnet"`, `"opus"`, `"haiku"` |
| `auto_review` | boolean | `true` | すべての PR 作成後に `/rite:pr:review` を自動実行 |

**例:**

```yaml
team:
  enabled: true
  max_concurrent_issues: 3
  teammate_model: "sonnet"
  auto_review: true
```

**チーム実行の動作:**

1. `/rite:sprint:team-execute` が複数の teammate agent を spawn する
2. 各 teammate は Sprint から Issue を 1 つピックアップし、新 3 コマンド合成 (`/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:ready`) を順次実行する (#1136 で旧 `/rite:issue:start` orchestrator は廃止)
3. teammate は並列で作業する (`parallel.mode` が `"worktree"` の場合はそれぞれ独立した worktree で)
4. すべての PR が作成された後、`auto_review` が `true` ならレビューが自動実行される

### safety

暴走ワークフローを防ぐための fail-closed セーフティしきい値。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_implementation_rounds` | integer | `20` | 1 Issue あたりの implementation round のハードリミット (checklist 失敗による re-entry を含む) |
| `time_budget_minutes` | integer | `120` | 1 Issue あたりの time budget (アドバイザリ、タイマーによる強制終了はなし) |
| `auto_stop_on_repeated_failure` | boolean | `true` | 同一クラスの失敗が連続した時にワークフローを停止 |
| `repeated_failure_threshold` | integer | `3` | 自動停止をトリガする連続同一クラス失敗回数 |

**例:**

```yaml
safety:
  max_implementation_rounds: 20
  time_budget_minutes: 120
  auto_stop_on_repeated_failure: true
  repeated_failure_threshold: 3
```

**セーフティ上限到達時:**

上限に達した時、ワークフローは以下のオプションを提示する:
1. 続行 (上限を引き上げる)
2. 中止 (work memory に状態を保存して後で resume)
3. 手動介入 (ユーザーが直接対応)

### metrics

ワークフロー実行メトリクスの記録としきい値評価の設定。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | メトリクス記録の有効/無効 |
| `baseline_issues` | integer | `3` | しきい値評価開始前に完了する必要のある Issue 数 (測定のみの期間) |

> **Note**: メトリクスのしきい値 (`plan_deviation_rate`, `test_pass_rate`, `review_fix_loops` 等) は現状実装にハードコードされている。`rite-config.yml` から設定可能にする対応は将来リリースで予定されている。

**例:**

```yaml
metrics:
  enabled: true
  baseline_issues: 3
```

**メトリクスの動作:**

1. **ベースライン期間**: 最初の `baseline_issues` 件の完了 Issue 中、メトリクスは記録されるがしきい値とは評価されない
2. **ベースライン後**: メトリクスは per-Issue しきい値および移動平均 (MA5) しきい値と評価される
3. **失敗分類**: しきい値超過時、失敗が分類される (例: scope creep、品質 regression) と、修正アクションが提案される
4. **連続失敗検出**: `safety.auto_stop_on_repeated_failure` が有効な場合、同一クラスの連続失敗で自動停止する

### pr_review

PR レビュー **出力** の記録設定。このセクションは `review:` セクション (レビュー **実行** を設定) とは意図的に分離されており、将来の出力先 (Slack 通知等) を `review:` の子キーを破壊することなく追加できるようになっている。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `post_comment` | boolean | `false` | `true` の時、レビュー結果は PR コメントとして投稿される (`--post-comment` 相当)。`false` (default) の時は `.rite/review-results/{pr_number}-{timestamp}.json` にのみ保存される |

`/rite:pr:fix` は優先順位 **conversation > local file > PR comment** でレビュー結果を自動読込する。ほとんどのユーザーは PR コメント履歴をクリーンに保つため `post_comment: false` のままにすべき。PR 自体に監査可能なレビュー痕跡を残したい時のみ有効化する。背景は #443 を参照。

### wiki

Experience Wiki の設定 — レビュー / fix / Issue の outcome から経験則を抽出して永続化する LLM 駆動のプロジェクト知識ベース。LLM Wiki パターン (Karpathy) に基づく。完全な設計は `docs/designs/experience-heuristics-persistence-layer.md` を参照。

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Wiki 機能を有効化 (opt-out)。`false` に設定するとすべての Wiki hook / コマンドがスキップされる |
| `branch_strategy` | string | `"separate_branch"` | Wiki データの配置先: `"separate_branch"` (推奨、専用の orphan-like ブランチ) または `"same_branch"` (作業ブランチ上にコードと並べて commit) |
| `branch_name` | string | `"wiki"` | Wiki ブランチ名 (`branch_strategy` が `"separate_branch"` の時のみ使用) |
| `auto_ingest` | boolean | `true` | review/fix/close イベントで `/rite:wiki:ingest` を自動実行し raw source から経験則を抽出 |
| `auto_query` | boolean | `true` | Issue 作業開始時および review/fix/implement フェーズで `/rite:wiki:query` を自動実行し、関連する経験則をコンテキストに注入 |
| `auto_lint` | boolean | `true` | 各 ingest 後に `/rite:wiki:lint --auto` を自動実行し、矛盾 / 陳腐化 / 孤児 / 欠落概念 (`missing_concept`) / 未登録 raw source (`unregistered_raw`、informational — `n_warnings` には加算されない) / 壊れた相互参照を検出 |
| `growth_check.threshold_prs` | integer | `5` | Issue #524 layer 3 (lint growth check) — 前回の `branch_name` 上のコミット以降に開発ベースブランチでこの件数の merged PR が累積した時、`/rite:lint` Phase 3.8 が非 blocking な warning を emit する (Phase X.X.W が silent にスキップされている可能性のシグナル)。大きくすれば緩和される。非常に大きな値にすると lint warning は実質無効化されるが layer 1-2 は維持される |
| `growth_check.pr_raw_threshold` | integer | `3` | Issue #536 — 直近 `threshold_prs` 件の merged PR のうち、対応する raw source が wiki ブランチに存在しない PR がこの件数を超えた時に warning。PR が merge されたが Phase X.X.W が起動しなかった regression を検出する。実行時に `--pr-raw-threshold N` で上書き可能 |

**例 (完全に opt out):**

```yaml
wiki:
  enabled: false
```

**例 (auto-lint なしの same-branch Wiki):**

```yaml
wiki:
  enabled: true
  branch_strategy: "same_branch"
  auto_ingest: true
  auto_query: true
  auto_lint: false
```

> **`same_branch` ユーザーへの Note**: プロジェクトの `.gitignore` は既定の `separate_branch` 戦略向けの silent-leak 防御線として `.rite/wiki/` を除外している。`same_branch` に切り替える場合、Wiki ファイルが無視されないように negation エントリを必ず追加する必要がある。完全な verification-first セットアップ — 必要な negation エントリ (`!.rite/wiki/` および `!.rite/wiki/**`)、必須の `mkdir -p .rite/wiki/raw && touch .rite/wiki/raw/.negation-probe && git add --dry-run .rite/wiki/raw/.negation-probe` サニティチェック、既に追跡されているファイルに対する冪等性ノート、そして canonical な verification ステップとして `git check-ignore -v` ではなく `git add --dry-run` を使う理由 — は `.gitignore` 内の `# >>> gitignore-wiki-section-start` と `# <<< gitignore-wiki-section-end` のアンカーマーカー間のコメントブロックを参照すること (`grep -n 'gitignore-wiki-section-start' .gitignore` でジャンプ可能)。

**例 (低頻度更新リポジトリ向けの緩い growth-check しきい値):**

```yaml
wiki:
  enabled: true
  growth_check:
    threshold_prs: 20   # 前回の wiki commit 以降に 20 PR 累積するまで warning を出さない
    pr_raw_threshold: 5  # 直近 20 PR のうち 5 件以上に raw source が無い時に warning (Issue #536)
```

**関連コマンド:** `/rite:wiki:init` (初回セットアップ), `/rite:wiki:ingest`, `/rite:wiki:query`, `/rite:wiki:lint`.

### notifications

各通知サービス (slack, discord, teams) は以下を持つ:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | この通知サービスを有効化 |
| `webhook_url` | string | サービスの webhook URL |

### language

| Value | Description |
|-------|-------------|
| `auto` | ユーザー入力から自動検出 |
| `ja` | 日本語 |
| `en` | 英語 |

## 最小構成

ほとんどのプロジェクトでは最小構成で十分:

```yaml
schema_version: 2
```

その他の設定は妥当なデフォルトもしくは自動検出が使われる。プロジェクト固有のカスタマイズは個別キー (`branch.pattern`, `commands.*`, `iteration.*` 等) を YAML で直接指定する。

## ~~プロジェクトタイプのプリセット~~ (DEPRECATED in #1118 — historical reference only)

> **DEPRECATED (#1118)**: `project.type` プリセット機能 (`generic` / `webapp` / `library` / `cli` / `documentation`) は #1118 で廃止された。`templates/project-types/*.yml` のプリセットファイルと `templates/pr/{cli,library,webapp,documentation,fix-report}.md` の PR テンプレートも削除済。プロジェクト固有設定は個別キー直書きの方式に統一された。以下のサブセクションは、廃止前にサポートされていたプリセット挙動の歴史的リファレンスとして残置する。

### ~~webapp~~ (retired)

Web アプリケーション向けの最適化:
- Frontend / Backend / Database 変更の追跡
- PR テンプレートでのスクリーンショット要求
- E2E テストチェックリスト

### ~~library~~ (retired)

OSS ライブラリ向けの最適化:
- Breaking change の追跡
- マイグレーションガイドのプロンプト
- CHANGELOG リマインダー

### ~~cli~~ (retired)

CLI ツール向けの最適化:
- コマンド変更の追跡
- 後方互換性チェック
- Help / マニュアル更新のリマインダー

### ~~documentation~~ (retired)

ドキュメントサイト向けの最適化:
- ビルド検証
- リンクチェック
- スタイルガイド準拠
