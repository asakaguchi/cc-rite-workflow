# rite workflow スリム化リファクタリング指示書

この指示書は 2026-06-11 にプロジェクト全体を分析して作成された。実装担当（あなた）はこの指示書のみを根拠として作業する。記載の実測値は作成時点のもの — **削除・編集の前に必ず grep / wc で再検証し、前提が崩れていたら作業を止めて質問すること**（→ §5 Stop And Ask Conditions）。

ここに書かれた統廃合・削除はすべて**ユーザー（坂口さん）の承認済み**である。逆に、ここに書かれていない削除・機能変更は承認されていない（→ §11 Out-of-scope）。

---

## 1. Objective

rite workflow（Claude Code 用 Issue ドリブン開発ワークフロープラグイン）を、**既存のコアワークフローを壊さずに総量を減らし、一般公開に耐える変更しやすい状態にする**。

「コード」の実体は大半が Markdown プロンプトであるため、削減の正当化基準は常に次の 3 つであり、見た目の綺麗さではない:

1. **コンテキストコスト** — コマンド 1 回の呼び出しで LLM コンテキストに読み込まれる総行数
2. **同期コスト** — 同一内容の多重記述による修正時の同期漏れリスク
3. **腐敗した参照** — 実行時に読まれない reference、リンク切れ、未配線コード

### 数値目標（実測 2026-06-11 ベース）

| 領域 | 現状（行） | 目標 | 主な手段 |
|---|---|---|---|
| plugins/rite/commands | 27,491 | ≤ 24,500 | sprint 削除 −2,000 / recall 削除 −230 / 巨大ファイル圧縮 −1,000〜1,400 |
| plugins/rite/references | 6,892 | ≤ 4,700 | 実行時未使用 reference 削除 −2,039 / tdd-light 削除 −224 |
| plugins/rite/skills | 5,674 | ≤ 4,200 | reviewer 基準 13 ファイル廃止 / SKILL.md 縮小 / retired reference 削除 |
| plugins/rite/agents | 1,880 | ≈ 2,200〜2,400（**増えてよい**） | reviewer 基準の統合先になるため。sprint-teammate −100 |
| plugins/rite/hooks（tests 除く） | 16,577 | ≤ 16,350 | 未配線 notification/preflight 削除 −239 |
| docs/ | 15,948 | ≤ 5,500 | ja docs −3,307 / 堆積 artifact −約 7,000 |
| **個別ファイル** | review.md 4,111 / fix.md 4,020 / lint.md 1,503 / init.md 1,148 | ≤3,500 / ≤3,700 / ≤1,400 / ≤1,050 | 圧縮（分割より優先） |

**コンテキストコスト目標**: `/rite:pr:review` 1 回の main path で読まれるレビュアー関連ファイルを「縮小版 SKILL.md + spawn される agent 本体」のみにする（現状: SKILL.md 362 行 + reviewer ごとに skills/reviewers/{type}.md ~110 行 + _reviewer-base.md 抽出 450 行を追加 Read）。

行数は副次指標である。**「圧縮のために実行パスへ新しい必須 Read を増やす」のは本末転倒** — 各実行パスで読み込まれる総量で判断せよ。

---

## 2. Project Understanding

### 正体

Claude Code 用プラグイン。実体は Markdown プロンプト（commands / skills / agents / references / templates）+ bash hooks（一部 Python）+ shell scripts。1,300+ コミットの機能追加で肥大化した。現在のユーザーは坂口さん 1 人のみで、**外部ユーザー向け後方互換は一切不要**。

### コンポーネント間の関係

```
skills/（エントリポイント、SKILL.md が activation 時に全文ロード）
  → commands/（Skill ツール経由で実行される手順書。実行時に references/ を条件付き Read）
    → agents/（pr:review が named subagent として spawn。agent 本体 = system prompt）
    → references/、commands/*/references/（手順書から Read 指示される共有知識）
hooks/（Claude Code ライフサイクルから独立発火。hooks.json に 8 登録、
        それ以外の約 26 スクリプトは commands や登録 hook から呼ばれるライブラリ）
scripts/（gh CLI / GraphQL ラッパー。今回は大改修スコープ外）
```

### 重要な実行時メカニズム（変更判断の前提知識）

- **reviewer 呼び出し（v0.3〜）**: `commands/pr/review.md` ステップ 4.3 が `rite:{type}-reviewer` を named subagent として spawn する。agent ファイル本体が **system prompt** になる。さらにステップ 4.5 が `_reviewer-base.md`（{shared_reviewer_principles}）と `skills/reviewers/{type}.md`（{skill_profile}, {checklist}）を抽出して **user prompt に注入**する。この二重注入が二重管理の根因（→ Debt D-3）。
- **sentinel 契約**: 各コマンドは終了時に `[{cmd}:returned-to-caller]` 等の sentinel + HTML comment disambiguator を emit し、orchestrator（pr:open / pr:iterate / SKILL.md）がそれをルーティングする。sentinel 一覧の SoT は `skills/rite-workflow/SKILL.md` の sentinel テーブル（1 箇所に集中、優良）。
- **flow-state**: `.rite/sessions/{session_id}.flow-state`、`flow-state.sh {create|read|update|migrate}`。**schema_version は 3 が現行**（refactor 検討初期メモに「v2」とあったが docs/SPEC.md:1469 と flow-state.sh で v3 を確認済み。flow-state.sh が SoT）。
- **静的チェックの format pinning**: `hooks/scripts/distributed-fix-drift-check.sh` 等は review.md / fix.md 内の特定記述形式（reason テーブル、emit 構文）を前提に検査する。review.md:3026 周辺に「drift-check が拾う形式」についての明示注記がある。**プロンプト圧縮がこれらの pinned format を壊すと静的チェックが fail する**（fail したらチェックを直すのではなく、まず自分の変更を疑え）。

### ドッグフーディング上の特殊性

このリポジトリは rite 自体を rite で開発している。CLAUDE.md の「ドッグフーディング注意事項」を必ず読むこと。実装セッションの制約:

- **`/rite:` コマンドを使わない**（変更途中の定義が読み込まれる自己参照ループが起きる）
- `~/.claude/settings.json` の `enabledPlugins` で `rite@rite-marketplace: false` を維持する
- このリポジトリでは rite の hooks が実装セッション自身にも発火する。hooks.json 登録 hook（特に pre-tool-bash-guard.sh、post-tool-wm-sync.sh）を編集した直後は挙動変化に注意
- 最初に `git status` を確認し、既存の未コミット変更（`refactor-prompt.md`、`refactor-instructions.md`、`.rite/` 系の untracked）と自分の変更を混ぜない
- ブランチは `develop` ベース、`{type}/issue-{number}-{slug}` 命名（Issue を作らない場合は `refactor/phase-N-{slug}` でよい）。Conventional Commits 形式。PR は develop 向け、フェーズ単位で分ける

---

## 3. Behaviors To Preserve

以下は削除・圧縮後も**完全に同一に動作し続けなければならない**。各項目の現物を編集前に確認すること。

1. **コマンド分解と固定順序**: `pr:open → pr:iterate → pr:ready → pr:merge → pr:cleanup`。各コマンド単一責任。`/rite:resume` での中断復帰（`commands/resume.md` + `skills/rite-workflow/references/phase-mapping.md` が SoT）。
2. **sentinel 契約**: `[*:returned-to-caller]` 形式 + HTML comment disambiguator。SoT は `skills/rite-workflow/SKILL.md` の sentinel テーブル。meta-test `sentinel-disambiguator-adjacency.test.sh`（producer: cleanup/merge/ready/lint/ingest の 5 ファイル）と `create-md-invocation-symmetry.test.sh` が保護。
3. **review-fix ループの収束仕様（坂口さん確認済みの現行仕様）**: 「指摘ゼロになるまで無限ループ」+ **accepted-fingerprint suppression**（fix.md ステップ 2.1.A で accept した finding の fingerprint を `.rite/state/accepted-fingerprints-{pr}.txt` に永続化し、review.md ステップ 5.1.2.A で再出現を抑止）。N 回上限・同一 fingerprint cycling 検出・quality signal escalation は **#1136 で意図的に削除済み**（iterate.md:179 に明記）。**復活させないこと**。
4. **flow-state schema v3**: `.rite/sessions/{session_id}.flow-state`、`flow-state.sh {create|read|update|migrate}`、`PHASE_ENUM_V3`。`flow-state.test.sh` が保護。
5. **multi-session worktree 分離**: default ON、`.rite/worktrees/`、session ownership guard。`multi_session.*` config キーは現役（sprint 用の `parallel.*` と混同しないこと）。
6. **GitHub Projects 連携**: status 遷移 Todo → In Progress → In Review → Done。`scripts/create-issue-with-projects.sh` は issue/create.md から直接呼ばれる（config check なしの hard dependency — 既知。直すのは Out-of-scope）。
7. **Wiki の lint ↔ ingest contract 同期**: meta-test `wiki-lint-ingest-contract-sync.test.sh` が片側だけの修正を fail させる。Wiki 機能全体（commands/wiki/ + skills/wiki/ + wiki 系 hooks 約 7,300 行）は**今回触らない**。
8. **review result schema**: `commands/pr/references/review-result-schema.md`（schema 1.1.0）。findings[].scope enum（blocking / nit-noted / accept / suggest-separate-issue）と scope ベースの fix routing。`review-schema-version-check.sh` が保護。
9. **work memory**: Issue コメント同期（issue-comment-wm-sync.sh / post-tool-wm-sync.sh）、`work-memory-lock.sh` による排他、Issue body safe update（issue-body-safe-update.sh、上書き禁止）。work-memory-format.md の `[CONTEXT]` マーカー辞書は **contextual commits とは別物** — 削除対象に含めないこと。
10. **pr:iterate の Stop hook ループ継続**: `stop-loop-continuation.sh`（#1169）。

---

## 4. Non-Negotiables

- `bash plugins/rite/hooks/tests/run-tests.sh` を**各フェーズ後に必ず緑に保つ**。baseline は 69/69 pass（2026-06-11 実測）。Phase 1 で notification.test.sh / preflight-check.test.sh を削除した後の期待値は **67/67** — テスト削除はこの 2 本（+ 削除機能に紐づくと再検証で判明したもの）に限る。**fail を握りつぶすためのテスト削除・書き換えは禁止**。
- meta-test 3 本（sentinel-disambiguator-adjacency / create-md-invocation-symmetry / wiki-lint-ingest-contract-sync）の**ロジックを書き換えない**。これらが fail したらまず自分の変更を revert する。
- sentinel 文字列・disambiguator・schema 定義・flow-state の phase enum を変更しない。
- 削除はすべて「grep で被参照ゼロ（または参照元も同時に修正）」を確認してから行う。**証拠なき大規模削除・全面書き換えの禁止**。
- 各フェーズは独立に revert 可能なコミット/PR 単位にする。無関係な整形・ついでのリファクタリングをしない。
- `plugins/rite/scripts/`（7,354 行）は削除対象機能（sprint）に紐づくものを除き触らない。
- 新しい抽象・build step・自動生成機構を導入しない（reviewer 統合は「手で 1 箇所にまとめる」のであって manifest 生成系を作るのではない）。

---

## 5. Stop And Ask Conditions

以下に該当したら**作業を止めて坂口さんに質問する**（推測で進めない）:

1. この指示書が「被参照ゼロ」「未配線」と主張する対象に、再検証で**実行時参照が見つかった**場合
2. meta-test または静的チェックが fail し、**チェック側の修正が必要に見える**場合（自分の変更の revert で解決しない場合）
3. 削除・圧縮の過程で、§3 Behaviors To Preserve と実装の**矛盾を新たに発見**した場合
4. この指示書に載っていない機能・ファイルを削除したくなった場合（発見した追加候補は §10 の報告に「提案」として記載するに留める)
5. reviewer 統合（Phase 4）で、skills/reviewers/{type}.md に agent へ移せない内容（実行時に user prompt 側でなければ機能しない指示）が見つかった場合
6. review.md / fix.md の圧縮で、sentinel・schema・accepted-fingerprint・drift-check pinned format のいずれかに触れざるを得なくなった場合
7. docs/tests/ の陳腐化判定に迷う場合（「現行機構のテストだが手順が古い」のか「廃止機構のテスト」なのか判別できないとき）

---

## 6. Baseline Commands

すべて実在確認済み（2026-06-11）。

```bash
# hook テストスイート（69 本 → Phase 1 後 67 本）。着手前に全 pass を記録し、各フェーズ後に再実行
bash plugins/rite/hooks/tests/run-tests.sh

# 静的チェック群（hooks/scripts/ 配下、単体実行可能）
bash plugins/rite/hooks/scripts/orphan-reference-check.sh        # 死んだ相互参照（checked=125 orphans=0 が baseline）
bash plugins/rite/hooks/scripts/hardcoded-line-number-check.sh   # ハードコード行番号の陳腐化
bash plugins/rite/hooks/scripts/sh-cross-ref-check.sh            # bash スクリプト間参照の整合
bash plugins/rite/hooks/scripts/bash-heaviness-check.sh          # commands 内 bash の複雑度
bash plugins/rite/hooks/scripts/distributed-fix-drift-check.sh   # review/fix の出力契約 drift
bash plugins/rite/hooks/scripts/review-schema-version-check.sh   # review result schema バージョン
bash plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh

# 規模計測（フェーズごとの報告に使う）
for d in commands scripts references skills hooks agents templates; do
  printf "%-12s %s\n" "$d" "$(find plugins/rite/$d -type f \( -name '*.md' -o -name '*.sh' -o -name '*.py' -o -name '*.json' -o -name '*.yml' \) | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')"
done
find docs -type f -name '*.md' | xargs wc -l | tail -1
```

- CI: `.github/workflows/test-hooks.yml`（push / PR で run-tests.sh を実行）
- 手動 e2e: `docs/tests/rite-issue-create-e2e-smoke.test.md` — **最終フェーズ後に坂口さんが実施**（あなたは実施しない。依頼文を最終報告に含める）

**検証の限界**: commands / skills の Markdown には自動テストがない。プロンプト変更の検証は「meta-test + 静的チェック + grep による参照整合確認 + 人間の実機確認」の組み合わせになる。だからこそ各フェーズを小さく保つこと。

---

## 7. Debt Map

### D-1: 未配線機能（notification / preflight）【承認済み・削除】

- **根拠**: `hooks/notification.sh`（127 行）は呼び出し元ゼロ。SPEC.md:1181 は「PR 作成・Ready 変更・Issue クローズ時にコマンドから呼ばれる」と主張するが、pr/create.md・pr/ready.md・pr/merge.md・issue/close.md・pr/cleanup.md のいずれにも呼び出しなし（直接 grep で確認済み）。`notifications.*` config キーも読み取り実装ゼロ。`hooks/preflight-check.sh`（112 行）は hooks.json 未登録・コマンドからの呼び出しゼロ（コア 4 コマンドで直接 grep 確認済み）。
- **該当観点**: 腐敗した参照（未配線コード）+ ドキュメントと実装の乖離
- **注意**: `hooks/review-skip-notification.sh`（179 行）は**別物で現役**（pr/review.md ステップ 6.1.c から呼ばれる）。名前が似ているが触らないこと。
- **削減**: スクリプト 239 行 + テスト 2 本 + config/SPEC/README/CONFIGURATION の記載
- **検証**: run-tests.sh（67/67 になる）、orphan-reference-check.sh

### D-2: 実行時未使用 reference（7 ファイル、2,039 行）【承認方針に合致・削除】

`plugins/rite/references/` 配下で、**plugins 内の実行パスから一切 Read されない**ファイル。注意: `orphan-reference-check.sh` は docs/SPEC.md からの言及も「参照」と数えるため orphans=0 と報告する。ここでの判定基準は「コマンド・スキル・agent の実行時に読まれるか」である。

| ファイル | 行数 | 実態（2026-06-11 実測） |
|---|---|---|
| error-codes.md | 605 | plugins 内参照は priority-markers.md からの 1 件のみ（その priority-markers 自体が未使用） |
| priority-markers.md | 414 | docs/SPEC のみ参照 |
| gh-cli-commands.md | 346 | plugins 内参照は gh-cli-patterns.md からのリンク 1 件のみ |
| output-patterns.md | 234 | docs/SPEC のみ参照 |
| state-read-evolution.md | 252 | session-id-validation-contract.md との相互参照のみ（設計経緯メモ。経緯は git history に残る） |
| sub-issue-link-handler.md | 108 | docs/SPEC のみ参照 |
| session-id-validation-contract.md | 80 | state-read-evolution.md との相互参照のみ |

- **手順**: 削除前に各 basename を `grep -rn` で再検証 → 7 ファイル削除 → `gh-cli-patterns.md` 内の gh-cli-commands へのリンク削除 → docs/SPEC.md の言及箇所を削除 → orphan-reference-check.sh 再実行
- **追加**: `skills/rite-workflow/references/sub-skill-return-protocol.md`（45 行、本文に retired/historical と明記）も同様に削除し、SKILL.md からの参照を除去

### D-3: reviewer の二重管理（28 ファイル 3,981 行が 1 つのレビュープロセスを記述）【承認済み・agents/ に一本化】

- **根拠**: `agents/`（_reviewer-base.md 450 行 + 13 reviewer 定義 83〜207 行）と `skills/reviewers/`（SKILL.md 362 行 + 13 基準ファイル 92〜128 行）が 1:1 対応。実行時は agent 本体が system prompt になり、**さらに** review.md ステップ 4.5 が skill ファイルから {skill_profile} と {checklist} を抽出して user prompt に注入する。reviewer 1 つの修正で両側の同期が必要（例: コミット f74ed9a3 は agents/test-reviewer.md と skills/reviewers/test.md の 2 ファイル修正）。
- **該当観点**: 同期コスト + コンテキストコスト（review 1 回で SKILL.md 362 行 + 選定された reviewer 分の skill ファイルを追加 Read）
- **改善案（承認済みの方向）**:
  1. 各 `skills/reviewers/{type}.md` の固有内容（Role / Expertise Areas / Review Checklist / Finding Quality Guidelines の reviewer 固有部分）を対応する `agents/{type}-reviewer.md` に統合する（agent 本体は system prompt として注入されるので置き場として正しい）
  2. 各 skill ファイルの Activation パターン（ファイルパターン + 内容分析条件）は `skills/reviewers/SKILL.md` の Available Reviewers テーブルに統合する（review.md ステップ 2 の選定 SoT はもともと SKILL.md）
  3. 全 reviewer 共通の Finding Quality Policy（SKILL.md 内）は `_reviewer-base.md` へ移す（review.md ステップ 4.5 の {shared_reviewer_principles} 抽出で既に注入される経路があるため、新しい注入機構は不要）
  4. `skills/reviewers/{type}.md` 13 ファイルを削除。SKILL.md は「frontmatter + Available Reviewers テーブル（Activation 込み）」のみに縮小（目標 ≤ 150 行）
  5. review.md ステップ 4.5 から {skill_profile} / {checklist} placeholder と skill ファイル Read 手順を削除（チェックリストは agent system prompt に移ったため）。ステップ 2 の「各 skill ファイルの Activation 参照」記述も SKILL.md テーブル参照に書き換え
  6. `skills/reviewers/references/`（cross-validation.md 210 行等）は現役 — 参照元の記述だけ更新して残す
  7. fix.md・lint.md・docs/SPEC.md 内の skills/reviewers/{type}.md への言及を grep で洗い出して更新
- **リスクと緩和**: チェックリストの注入位置が user prompt → system prompt に変わるため reviewer の挙動が微妙に変わりうる。緩和: (a) 内容は一字一句移すだけにして編集しない、(b) 統合後に坂口さんへ「実 PR での /rite:pr:review 実機確認」を依頼する（最終報告に明記）
- **削減見込み**: skills 側 約 −1,700 行、agents 側 約 +400〜500 行、review.md ステップ 4.5 周辺 −100〜200 行。正味 −1,300〜1,500 行 + 同期コスト解消
- **検証**: run-tests.sh、orphan-reference-check.sh、grep（skills/reviewers/{type}.md への参照が残っていないこと）、distributed-fix-drift-check.sh

### D-4: 機能削除 — sprint / team-execute【承認済み】

- **根拠**: `commands/sprint/`（5 ファイル、list/current/plan/execute/team-execute、計約 1,900 行）+ `agents/sprint-teammate.md`（100 行）。コア pr フローとの結合点ゼロ、専用 hook テストゼロ（調査済み）。
- **波及（実測した言及数）**: SKILL.md 3 / getting-started.md 2 / README.md 7 / docs/SPEC.md 34 / docs/CONFIGURATION.md 12。`team.*` config キーと、sprint 並列実行専用の `parallel.*` config キー（worktree_base / max_agents / mode / enabled）。
- **注意**:
  - `multi_session.*`（worktree 分離）は **sprint とは別機能で現役**。`parallel.*` 削除前に各キーの参照元を grep し、multi-session 系から参照されていないことを確認すること
  - `iteration.*` config（GitHub Projects の Iteration フィールド連携）は sprint 以外（issue:create 等）からも参照される。**iteration.* は残し**、sprint 専用の参照だけ除去する
  - `scripts/` 内に sprint 専用スクリプトがないか grep（あれば一緒に削除、なければ scripts/ は触らない）
- **削減**: 約 2,000 行 + config + docs 記載

### D-5: 機能削除 — TDD Light【承認済み】

- **根拠**: `references/tdd-light.md`（224 行）+ `commands/issue/implement.md` 内の条件分岐（"tdd" 言及 20 箇所）。デフォルト `tdd.mode: off` で通常は不活性。
- **削除手順**: tdd-light.md 削除 → implement.md の TDD 分岐（skeleton 生成フェーズ）を削除 → `tdd.*` config キー削除 → templates/ 内に TDD 用テンプレートがないか grep → README.md（1 箇所）/ SPEC.md（6 箇所）/ CONFIGURATION.md（7 箇所）から記載削除
- **削減**: 約 350 行

### D-6: 機能削除 — recall / contextual commits【承認済み】

- **根拠**: `commands/issue/recall.md`（228 行）+ `skills/rite-workflow/references/contextual-commits.md`（実測して確認。約 170〜280 行）+ implement.md 内の contextual commit 生成記述（"contextual" 言及 7 箇所）+ `commit.contextual` config キー。
- **注意**:
  - work memory の `[CONTEXT]` マーカー（work-memory-format.md）と hooks の `[CONTEXT]` stderr emit は**完全に別物 — 触るな**。"contextual commits" はコミット body に workflow 文脈を記録する機能のみを指す
  - リポジトリ自身の `rite-config.yml`（dogfood）の `commit.contextual: true` も削除
  - 既存コミット履歴の contextual format は当然そのまま（履歴は変更しない）
- **削減**: 約 450 行 + config

### D-7: docs の英日二重と堆積 artifact（docs 15,948 行中 約 10,500 行）【承認済み】

| 対象 | 行数 | 手順 |
|---|---|---|
| README.ja.md / docs/SPEC.ja.md / docs/CONFIGURATION.ja.md | 3,307 | 削除。README.md の言語切替リンク削除。**`agents/_reviewer-base.md` の Cross-File Impact Check に i18n parity チェック（README.md ↔ README.ja.md ペア検査）があるため、その項目も削除**（grep "i18n" / "ja.md" で位置特定） |
| docs/i18n-style-guide.md | 66 | kept-English term リスト（Issue / PR / finding / severity 等を日本語 UI 文言中で英語のまま使う規約）は現役。**SPEC.md に統合してからファイル削除**。SPEC.md と skills/reviewers/SKILL.md 内の参照を更新 |
| docs/migration-guides/（v2-to-v3.md, review-named-subagent.md） | 350 | 削除。**plugins/ からの参照はゼロ**（直接 grep 確認済み）。参照元は README.md:14（v0.3 告知）、docs/SPEC.md:417, 534, 1312, 1469、docs/designs/、docs/tests/。README の v0.3 告知ブロックは外部ユーザー不在のため削除し、SPEC.md の各参照は 1〜2 文のインライン記述に置換 |
| docs/investigations/（9 ファイル） | 2,833 | 削除。pr/review.md に review-quality-gap-baseline.md への言及が 1 件ある — その言及行も削除 |
| docs/verification-results/ + docs/archive/ + docs/anti-patterns/ | 540 | 削除。plugins/ からの参照ゼロ（確認済み） |
| docs/designs/（17 ファイル 3,770 行） | 約 −2,800 | **未参照分のみ削除**。手順: 各ファイル basename を plugins/・README.md・docs/SPEC.md・docs/CONFIGURATION.md（削除予定ディレクトリは除く）に対して grep し、被参照ゼロのものを削除。既知の残留候補: multi-session-worktree.md / multi-session-state.md / experience-heuristics-persistence-layer.md（plugins から参照）。review-quality-gap-closure.md は要 grep 判定 |
| docs/tests/（9 ファイル 2,152 行） | 約 −1,400 | **陳腐化分のみ削除**。`start-*.test.md` 5 本は削除済みの start.md（#1136 で撤去）を前提とする — 各ファイル冒頭を読み、現行コマンド体系で実行不能なら削除。`rite-issue-create-e2e-smoke.test.md` と README.md は**必ず残す**（smoke 内の Historical 注記は migration-guides 削除に合わせて文言修正）。cleanup-1.7.3.2.1.test.md / skill-structure-358.test.md は現行機構を検証しているか確認して判断（迷ったら §5-7 で質問） |

- **重要**: docs 削除後に `orphan-reference-check.sh` を再実行すること。docs からのみ参照されていた plugins 内ファイルが新たに orphan として浮上したら、grep で実行時参照ゼロを確認のうえ削除してよい（確証が持てなければ §5-1 で質問）。

### D-8: 巨大ファイルの冗長性（review.md 4,111 / fix.md 4,020 / lint.md 1,503 / init.md 1,148）【圧縮を分割より優先】

**分割についての絶対基準**: `commands/issue/create.md` は過去に意図的に references を単一ファイルへ統合した（flat workflow 化）。LLM プロンプトでは「分割して都度 Read させる」より「常に読む 1 ファイルに収める」方が正しい場合がある。**分割/統合の判断基準は見た目の行数ではなく、各実行パスでコンテキストに読み込まれる単位とその総量**。main path で必ず Read される新 reference を作るくらいなら、その場で圧縮せよ。新 reference 化が正当なのは「条件付き path でしか読まれない」場合のみ。

圧縮対象（調査で特定済みの冗長性。編集前に現物の行範囲を再確認すること）:

- **review.md**:
  - READ-ONLY 原則の 3 重記述（冒頭 / ステップ 4.5 full template / verification template、計約 143 行）→ `_reviewer-base.md` の READ-ONLY Enforcement を SoT とし、template 内は 1 行参照に
  - Doc-Heavy 検出の分散（ステップ 1.2.7 定義 370 行 / 2.2.1 適用 217 行 / 4.5 条件 / 5.1.3 検証 100 行、計約 700 行）→ 重複説明を削り、定義は 1 箇所に
  - ステップ 4.5 template は D-3（reviewer 統合）で placeholder が減るため、合わせて縮む
  - mktemp + trap の同型 bash ブロックが 10+ 箇所 → 冗長なコメント・防御的説明の重複を削る（**bash の挙動自体は変えない**）
  - 目標: ≤ 3,500 行
- **fix.md**:
  - severity / scope / schema 定義が fix.md 内・review-result-schema.md・severity-levels.md の 3 箇所に散在 → 定義の SoT を `review-result-schema.md` と `severity-levels.md` に置き、fix.md 内は schema バージョン互換処理だけ残す（両 reference は fix.md が既に Read している — 新規 Read は増えない）
  - ステップ 1（レビューコメント取得、1,600 行）の説明的繰り返しを圧縮
  - 目標: ≤ 3,700 行
- **lint.md**: Phase 0.5 の deprecated config keys スキャン（lint.md:120-159、v0.4.0 #557 の 3 キー検出）は外部ユーザー不在のため**ブロックごと削除**。Phase 3 の 18 チェックの定型繰り返しを圧縮。目標: ≤ 1,400 行
- **init.md**: Phase 4.5（hook 設定、400 行）の散文圧縮。スクリプト化はしない（新規 hook を作らない）。目標: ≤ 1,050 行

**触ってはいけない箇所**（圧縮中に出会っても変更しない）: sentinel emit と disambiguator / accepted-fingerprint suppression（review.md 5.1.2.A、fix.md 2.1.A）/ schema 検証契約 / reason テーブルと `[CONTEXT]` emit の pinned format（distributed-fix-drift-check.sh の検査対象）/ 6.1.a〜c の helper 委譲契約

- **検証**: 各ファイル編集ごとに distributed-fix-drift-check.sh + review-schema-version-check.sh + doc-heavy-patterns-drift-check.sh + hardcoded-line-number-check.sh + run-tests.sh

### D-9: config の死蔵キー【削除（機能削除に連動する分 + 読み取りゼロの scaffolding）】

調査（2026-06-11）で「CONFIGURATION.md に記載があるが読み取り実装ゼロ」と判定されたキー。**各キーとも削除前に `grep -rn "{key名}" plugins/rite` で読み取りゼロを再確認**し、ゼロでなければ残して報告すること:

- 機能削除に連動: `notifications.*` / `tdd.*` / `team.*` / `parallel.*`（multi_session 非干渉を確認のうえ）/ `commit.contextual`
- 読み取りゼロの scaffolding: `flow_state.schema_version` / `branch.recognized_patterns` / `review.min_reviewers` / `review.criteria` / `review.loop.allow_new_findings_in_unchanged_code` / `review.loop.verification_mode` / `review.loop.convergence_monitoring` / `review.loop.auto_propagation_scan` / `review.loop.pre_commit_drift_check` / `review.doc_heavy.lines_ratio_threshold` / `review.doc_heavy.count_ratio_threshold` / `review.doc_heavy.max_diff_lines_for_count` / `review.security_reviewer.recommended_for_code_changes` / `review.fact_check.max_claims` / `review.fact_check.verify_internal_likelihood`
- CONFIGURATION.md 内の DEPRECATED 注記セクション（project.type / observed_likelihood_gate / fail_fast_first / fix.severity_gating / separate_issue_creation）も外部ユーザー不在のため削除
- 対象ファイル: `docs/CONFIGURATION.md`、`plugins/rite/templates/config/rite-config.yml`、リポジトリ直下 `rite-config.yml`（dogfood）

### D-10: workflow 説明の多重記述【小規模・実施】

- **根拠**: フロー図とコマンド一覧が workflow.md / SKILL.md / getting-started.md / README.md / SPEC.md の 3〜5 箇所に形式違いで存在。
- **改善**: フロー図の SoT は `commands/workflow.md`（表示専用コマンドなので適所）。getting-started.md の詳細図は削って `/rite:workflow` への誘導に。コマンド一覧の SoT は docs/SPEC.md の Command List とし、workflow.md Phase 3 は短い表に圧縮。README.md は外部向け概要なので現状維持。
- **削減**: 50〜100 行（sprint 削除に伴う各所の行削除と同時に実施すると効率的）

### D-11: リポジトリ衛生【小規模・実施】

- `plugins/rite/hooks/__pycache__/` が untracked で存在。`.gitignore` に `__pycache__/` と `*.pyc` を追加
- `plugins/rite/.rite/`、`plugins/rite/skills/reviewers/.rite/`（実行時状態の混入）が .gitignore で除外されているか確認し、漏れていればパターン追加

---

## 8. Implementation Phases

各フェーズ = 1 ブランチ = 1 PR（develop 向け）。フェーズ内のコミットは論理単位で分割。**フェーズ開始時に直前フェーズの PR がマージ済みであること**（人間のマージを待つ。待てない場合は前フェーズのブランチから派生させ、その旨を PR に明記）。

### Phase 0: baseline 記録（コミットなし）
1. `git status` — 自分の変更前の状態を記録（`refactor-prompt.md` / `refactor-instructions.md` / `.rite/` 系 untracked は既存のもの。触らない）
2. `run-tests.sh` 実行 → 69/69 pass を記録
3. §6 の静的チェック群と規模計測を実行 → 全結果を記録（これが全フェーズの比較基準）

### Phase 1: 安全な削除（D-1, D-2, D-11 + lint.md の deprecation スキャン）
- 未配線機能削除: notification.sh / preflight-check.sh / 対応テスト 2 本 / SPEC・README・CONFIGURATION の記載 / CLAUDE.md の hooks 列挙から preflight を除去
- 実行時未使用 reference 8 ファイル削除（D-2 の 7 + sub-skill-return-protocol.md）+ 参照元リンク修正
- lint.md:120-159 の deprecated キースキャン削除（D-8 の一部を前倒し — 削除系なのでここで）
- .gitignore 整備（D-11）
- **検証**: run-tests.sh = 67/67、orphan-reference-check.sh、sh-cross-ref-check.sh

### Phase 2: docs 堆積の削除（D-7）
- ja docs 3 ファイル + _reviewer-base.md の i18n parity 項目削除 → i18n-style-guide.md の SPEC 統合と削除 → migration-guides 削除と参照書換 → investigations / verification-results / archive / anti-patterns 削除 → designs 未参照分削除 → docs/tests 陳腐化分削除
- **検証**: orphan-reference-check.sh（新規 orphan の確認 → D-7 末尾の手順）、grep でリンク切れ確認（`grep -rn "docs/designs\|docs/investigations\|docs/migration-guides\|docs/archive\|docs/anti-patterns\|\.ja\.md\|i18n-style-guide" plugins/ docs/ README.md`）、run-tests.sh

### Phase 3: 機能削除（D-4, D-5, D-6, D-9）
- コミットを機能ごとに分ける: (a) sprint/team-execute、(b) TDD Light、(c) recall/contextual commits、(d) config 死蔵キー一掃 + CONFIGURATION.md 同期
- 各機能とも: コマンド/参照ファイル削除 → 結合点（implement.md 等)の分岐削除 → config キー削除（template + dogfood 両方） → README / SPEC / CONFIGURATION / SKILL.md / getting-started.md の記載削除
- **検証**: run-tests.sh、orphan-reference-check.sh、`grep -rni "sprint\|team.execute\|tdd\|recall\|contextual" plugins/rite README.md docs/SPEC.md docs/CONFIGURATION.md` で残骸ゼロ確認（wiki 等の無関係ヒットは除く。"tdd" は誤検知しにくいが "recall" は文章語として誤ヒットしうる — 文脈を見ること）

### Phase 4: reviewer 一本化（D-3）
- D-3 の手順 1〜7 を順に。コミット分割推奨: (a) Finding Quality Policy → _reviewer-base.md 移動 + SKILL.md テーブル拡張、(b) 13 reviewer の checklist 統合 + skill ファイル削除、(c) review.md ステップ 2 / 4.5 の書換
- **検証**: run-tests.sh、orphan-reference-check.sh、distributed-fix-drift-check.sh、`grep -rn "skills/reviewers/" plugins/rite docs/` で旧 13 ファイルへの参照ゼロ確認（SKILL.md と references/ は残る）
- **このフェーズの PR 説明に「マージ後、実 PR で /rite:pr:review の実機確認を推奨」と明記**

### Phase 5: 巨大ファイル圧縮 + workflow 重複整理（D-8, D-10）
- ファイルごとにコミットを分ける（review.md → fix.md → lint.md → init.md → workflow 重複）
- 各ファイル編集後に該当する静的チェックを即実行（D-8 の検証欄）
- **検証**: 全静的チェック + run-tests.sh + 目標行数の達成確認

### Phase 6: SPEC / CONFIGURATION 同期と最終検証
- docs/SPEC.md の Plugin Structure / Command List / Hook Specification を実態に合わせて全面同期（削除済みファイル・機能・キーの記載が残っていないこと）
- CLAUDE.md のアーキテクチャ図から削除済み要素（sprint/、preflight、notification 等）を除去
- README.md の機能リストを最終確認（Sprint Management / TDD Light / Preflight Check / notifications / contextual commits の記載が消えていること）
- §6 の全コマンド + 規模計測を実行し、Phase 0 比較の最終数値を報告
- **坂口さんへの依頼事項として最終報告に記載**: `docs/tests/rite-issue-create-e2e-smoke.test.md` の手順でコアフロー一周の実機確認

---

## 9. Verification Requirements

各フェーズ共通:

1. フェーズ着手前: `git status` クリーン（自分の未コミット変更なし）を確認
2. フェーズ完了時: `run-tests.sh` 全 pass（Phase 1 以降の期待値 67/67）+ そのフェーズの検証欄に指定された静的チェック
3. 削除を含むコミットの前: 削除対象 basename の `grep -rn`（plugins/ + docs/ + README.md + .github/）で被参照ゼロ、または参照元を同一コミットで修正していることを確認
4. プロンプト（.md）変更を含むコミットの前: 変更ファイルが emit する sentinel・参照する reference のパスが変わっていないことを目視確認
5. 静的チェックが fail した場合: まず自分の変更を疑い revert で切り分ける。チェック側が誤検知に見えても**チェックは書き換えず** §5-2 で質問

---

## 10. Reporting Format

フェーズごとに以下を報告する（PR 説明にも同内容を載せる）:

```markdown
## Phase N 完了報告: {タイトル}
- ブランチ / PR: {branch} / #{PR}
- 実行した検証コマンドと結果:
  - run-tests.sh: {X}/{X} passed
  - {静的チェック名}: {結果}
- 削除/変更ファイル一覧と行数増減（git diff --stat の要約）
- 規模計測（§6 のコマンド出力。Phase 0 比の差分付き)
- 想定との差異・発見した問題: {なし / あれば具体的に}
- 追加削除の提案（あれば。実施はしない）:
- 次フェーズへの引き継ぎ事項:
```

最終報告には追加で: 数値目標（§1 の表）に対する達成状況、坂口さんに依頼する実機確認 2 点（e2e smoke 一周、/rite:pr:review 実機確認）。

---

## 11. Out-of-scope Items（実施禁止。提案として記録するに留める）

1. **`plugins/rite/scripts/`（7,354 行）の大改修** — sprint 専用スクリプトの削除を除き触らない
2. **hooks のディレクトリ再編**（lib/ / util/ 分離等） — commands/*.md 内に hooks パス参照が 200 箇所超あり、リスクに対して利得が薄い。提案止まり
3. **Projects 連携の hard dependency 修正** — `issue/create.md` が `create-issue-with-projects.sh` を config check なしで直接呼ぶ問題。挙動変更になるため別 Issue 提案
4. **13 reviewer の数自体の削減**（統合は承認済みだが種類数は維持）
5. **Wiki 機能（約 7,300 行）のスリム化・変更**
6. **iterate.md / pr:open / issue:create の構造変更**（コアオーケストレータ）
7. **読み取り実装が薄い config キーの実装拡張**（issue.auto_decompose_threshold / verification.acceptance_criteria_check / metrics.* / safety.* 等は現状維持）
8. **新機能・新 hook・新自動生成機構の追加**
9. **バージョン番号の変更・リリース作業**（坂口さんが別途 /release で実施）
