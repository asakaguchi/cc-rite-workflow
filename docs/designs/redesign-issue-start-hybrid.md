# refactor(rite): /rite:issue:start を再設計 — ハイブリッド方針で 9 PR 段階的 slim・Phase 5 分割

> **Status: superseded**. 本 design doc が想定していた sub-skill アーキテクチャ (`start-execute` / `start-publish` / `start-finalize`、および Phase 5.x の分割) は flat single-file workflow (`start.md` ステップ 1-8) に統合され retire された。歴史的設計判断の参照用として残置。
>
> 本文中の `[start:execute:completed]` / `[start:publish:completed]` / `[start:finalize:completed]` 等の sentinel literal は **pre-#1165 naming の歴史的記述** として保持する（Issue #1165 で skill return sentinel は `:returned-to-caller` 形式に rename されたが、本 doc が記述していたのは設計当時の `:completed` 形式であり、historical 正確性のため書き換えない）。現行 sentinel 命名規約は `plugins/rite/commands/issue/create.md` ステップ 4.4 / 5.6 の `[create:returned-to-caller:{N}]` を参照。

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

`plugins/rite/commands/issue/start.md` (現 2303 行) を再設計する。Phase 5 (line 564 以降 1740 行) を 3 sub-skill (`start-execute` / `start-publish` / `start-finalize`) に分割し、charter 駆動 slim と references 抽出 (6-8 件) を組み合わせて適用、本体を約 600-700 行に圧縮する。9 PR で段階的に進行し、完全後方互換を維持する。

最終形:
- 本体 `start.md`: 600-700 行 (現 2303 から -70%)
- 新規 sub-skill: 3 ファイル (合計 750 行)
- 新規 references: 6-8 ファイル (合計 1250 行)
- 新規 charter test: 2 ファイル (機械検証)
- runtime 動作不変

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

start.md は現在、以下の構造的な肥大化を抱えている:

- **行数**: 2303 行 (create.md 350 行の 6.6 倍、cleanup.md 1496 行の 1.5 倍)
- **Phase 5 のモノリシック構造**: line 564 以降 1740 行で全体の 75% を占める
- **状態管理の散在**: `Mandatory After` セクション 42 個、各 phase の状態書込み・遷移検証が散文と bash literal で散らばる
- **Charter 違反の多発**: `Issue #` 引用 13 件 / `cycle N` 引用 26 件 / `🚨` 35 件で Simplification Charter 上限 (`Issue #` 1 件 / `🚨` 5 件) を大幅超過 (※ count は当時の start.md retire 前の値 — 現 start.md は #1136 で廃止済)

過去の同種再設計で蓄積された 2 つの成功パターンを継承する:

1. **`/rite:issue:create` の sub-skill 分割** (734→334 行): orchestrator + interview/decompose/register という責務分割
2. **`/rite:pr:cleanup` の charter 駆動 slim** (1810→1496 行): Simplification Charter 先行適用 + references 集約

start は規模・性質的に両者の中間以上にあり、片方だけのアプローチでは効果不足。サブスキル分割と charter slim を統合する **ハイブリッド方針** を採用することで、最大の slim 効果と responsibility 明確化を両立する。

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **本体 slim**: `start.md` を 600-700 行に圧縮する (-70%)
2. **Phase 5 分割**: Phase 5.0-5.7 を 3 sub-skill に垂直分割する
   <!-- ※ sub-skill 3 件は実装されず — flat workflow refactoring で覆された (Status: superseded)。-->
   - `start-execute.md` (約 250 行): Phase 5.0 (Stop Hook) + 5.1 (implement) + 5.2 (lint) + 5.2.1 (checklist) (※ 実装されず)
   - `start-publish.md` (約 220 行): Phase 5.3 (PR create) + 5.4 (review-fix loop + fingerprint cycling) (※ 実装されず)
   - `start-finalize.md` (約 280 行): Phase 5.5 (ready) + 5.5.1/5.5.2 (status/metrics) + 5.6 (completion) + 5.7 (parent close) + Workflow Termination (※ 実装されず)
3. **References 抽出**: 6-8 ファイルを `commands/issue/references/` 配下に新設
   <!-- ※ 当時の提案 list — 5 entry は後の refactoring で削除済 (4 entry は #1136/#1091、1 entry は #1162)、残り 3 entry のみ現存。 -->
   - `flow-state-scaffolding.md`: Pre-write + Mandatory After 契約の SoT (※ 削除済 — #1136 で start.md 廃止時に orphan 削除)
   - `pre-condition-gate.md`: state-read.sh fail-fast pattern の SoT (※ 削除済 — #1136 で start.md 廃止時に orphan 削除)
   - `workflow-incident-detection.md`: Phase 5.4.4.1 全体の SoT (※ 削除済 — #1091 で workflow-incident-emit 機構撤去時に削除)
   - `workflow-incident-emit-pattern.md`: orchestrator-direct emit pattern の SoT (※ 削除済 — #1091 で workflow-incident-emit 機構撤去時に削除)
   - `fingerprint-cycling.md`: Phase 5.4.1.0 + Quality Signal 検出の SoT
   - `checklist-auto-check.md`: Phase 5.2.1 + Auto-Check Evaluation の SoT
   - `metrics-recording.md`: Phase 5.5.2 全体の SoT
   - `projects-status-update-callsites.md`: Phase 2.4 / 5.5.1 / 5.7.2 delegation の SoT (※ 削除済 — 後の flat workflow refactoring で active caller 消失、#1162 で orphan file として removed。現 Projects Status update SoT は [`references/projects-integration.md §2.4`](../../plugins/rite/references/projects-integration.md))
4. **Charter 適用**: 機械的禁止パターン (`Issue #` 引用 / `cycle N` 引用 / `🚨` 濫用) を機械的に削除し、標準化された 2 文 contract phrase (`MUST execute in the SAME response turn` / `DO NOT stop`) を Mandatory After に導入する
5. **HTML sentinel 名前空間**: `[start:execute:completed]` / `[start:publish:completed]` / `[start:finalize:completed]` を新設し、orchestrator が継続トリガとして観測する
6. **Charter test**: `start-md-charter.test.sh` で上限 (`Issue #` ≤ 1 / `cycle N` ≤ 1 / `🚨` ≤ 5) と下限 (`AskUserQuestion` ≥ 30 / `Mandatory After` ≥ 30 / 標準化 phrase ≥ 30) を機械検証する (※ 実装されず — charter test は flat workflow refactoring 後に別形態で実装、本 file 名は使用されず)
7. **Symmetry test**: `flow-state-create-symmetry.test.sh` で `flow-state-update.sh create` の 5 引数対称性を検証する (※ 実装されず — symmetry test は flat workflow refactoring 後に別形態で実装、本 file 名は使用されず)

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

1. **完全後方互換**: `/rite:issue:start <N>` の引数・挙動は不変。既存ユーザーは何も変更不要
2. **resume.md routing 互換**: line 199-208, 496-504, 523-531 で参照される phase 名 (`phase5_implementation` / `phase5_lint` / `phase5_post_lint` / `phase5_pr` / `phase5_review` / `phase5_post_review` / `phase5_fix` / `phase5_post_fix` / `phase5_post_ready`) は維持し、サブスキル境界には新しい `*_post_*` marker のみ追加する
3. **whitelist 整合**: `phase-transition-whitelist.sh` の新エッジは sub-skill 切出 PR (F / G1 / G2) で同 PR 内に追加する
4. **ドッグフーディング維持**: 各 sub-skill 切出 PR で e2e 必須 (CLAUDE.md 「ドッグフーディング中の作者を破壊しない」要件)
5. **revert 可能性**: PR A の charter test は `STRICT_CHARTER=1` env gate で opt-in 化し、A 単独 revert で B 以降の CI が落ちない設計とする
6. **runtime 動作不変**: bash literal や MUST/MUST NOT 条文は維持し、散文の rationale 集約のみで slim を達成する

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

1. **ハイブリッド方針採用**: charter slim だけでは Phase 5 のモノリシック構造が残り、サブスキル分割だけでは散文肥大が解消しない。両者を統合することで最大効果
2. **Phase 5 を 3 分割**: create.md と対称な命名 (interview/decompose/register) ではなく、Phase 5 の責務単位 (execute/publish/finalize) で命名する。これは start の lifecycle (準備済み実装 → 公開 → 完結) と一致するため
3. **Sentinel 終端責務マトリクス**: `[start:finalize:completed]` のみが workflow 終端。`[start:execute:completed]` / `[start:publish:completed]` は continuation trigger
4. **2 文 contract 標準化**: 各 Mandatory After の rationale を以下の 2 文に統一する (※ 例中の `flow-state-scaffolding.md` は #1136 で削除済 — historical 参照)
   ```
   > See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
   > MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.
   ```
5. **Charter test の `STRICT_CHARTER` env gate**: PR A の test は CI で ON、ローカル revert 時は OFF にすることで、A 単独 revert 時の CI 失敗を防ぐ
6. **PR 順序**: A → B → C → D → E → F → G1 → G2 → H、各 sub-skill 切出は 1 PR 1 sub-skill 原則
7. **FSM 化は射程外**: phase 名 SoT 一本化や `--auto/--until/--resume` flag、コマンド分割は本プランでは扱わない (将来 Issue 候補)

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

```
plugins/rite/commands/issue/start.md (orchestrator, ~700 行)
  ├── Phase 0/1 (Detection / Quality Validation)
  ├── Phase 1.5/1.6 (Parent / Child routing)
  ├── Phase 2 (Branch / Projects / Iteration / WM init)
  ├── Phase 3 (Implementation Plan dispatcher)
  ├── Phase 4 (Work Start Guidance)
  └── Phase 5 (dispatcher のみ)
      <!-- ※ sub-skill 3 件 (start-execute / start-publish / start-finalize) は実装されず — flat workflow refactoring で覆された。本 tree は historical 設計図。 -->
      ├── start-execute.md (~250 行) (※ 実装されず)
      │   ├── Phase 5.0: Stop Hook registration
      │   ├── Phase 5.1: implement.md 呼び出し
      │   ├── Phase 5.2: rite:lint 呼び出し
      │   └── Phase 5.2.1: checklist auto-check
      │   └── sentinel: [start:execute:completed]  (continuation trigger)
      │
      ├── start-publish.md (~220 行) (※ 実装されず)
      │   ├── Phase 5.3: rite:pr:create 呼び出し
      │   ├── Phase 5.4.1: rite:pr:review 呼び出し
      │   ├── Phase 5.4.4: rite:pr:fix 呼び出し
      │   ├── Phase 5.4.6 routing (mergeable / fix-needed / replied-only / error)
      │   └── Phase 5.4.1.0: fingerprint cycling dispatcher
      │   └── sentinel: [start:publish:completed]  (continuation trigger)
      │
      └── start-finalize.md (~280 行) (※ 実装されず)
          ├── Phase 5.5: rite:pr:ready 呼び出し
          ├── Phase 5.5.1: Issue Status In Review
          ├── Phase 5.5.2: metrics recording
          ├── Phase 5.6: completion-report 呼び出し
          ├── Phase 5.7: parent Issue close (rite:issue:close)
          └── Workflow Termination
          └── sentinel: [start:finalize:completed]  (workflow 終端)

新規 references (commands/issue/references/):
  <!-- ※ 本 tree は start.md hybrid redesign 提案時の予定 file 一覧。実装後の現状とは乖離している。
       5 entry は後の refactoring で削除済 (4 entry は #1136/#1091、1 entry は #1162) — 注記参照。
       残り 3 entry (fingerprint-cycling.md / checklist-auto-check.md / metrics-recording.md) のみ現存。-->
  ├ flow-state-scaffolding.md  (Pre-write + Mandatory After 契約 SoT) (※ 削除済 — #1136 で start.md 廃止時に orphan 削除)
  ├ pre-condition-gate.md      (state-read.sh fail-fast SoT) (※ 削除済 — #1136 で start.md 廃止時に orphan 削除)
  ├ workflow-incident-detection.md      (Phase 5.4.4.1 SoT) (※ 削除済 — #1091 で workflow-incident-emit 機構撤去時に削除)
  ├ workflow-incident-emit-pattern.md   (5 caller 用 emit pattern SoT) (※ 削除済 — #1091 で workflow-incident-emit 機構撤去時に削除)
  ├ fingerprint-cycling.md     (Phase 5.4.1.0 + Quality Signal SoT)
  ├ checklist-auto-check.md    (Phase 5.2.1 + Auto-Check SoT)
  ├ metrics-recording.md       (Phase 5.5.2 SoT)
  └ projects-status-update-callsites.md (Phase 2.4/5.5.1/5.7.2 SoT) (※ 削除済 — #1162 で removed)
```

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

<!-- ※ 本データフローは hybrid redesign 提案時の sub-skill 連鎖を示す。実装されず — flat workflow refactoring で start.md ステップ 1-8 を single skill 内で逐次実行する形に変更された (Status: superseded)。-->

1. ユーザーが `/rite:issue:start <N>` を起動
2. orchestrator が Phase 0/1/1.5/1.6/2/3/4 を逐次実行 (現状とほぼ同じ)
3. Phase 5 dispatcher が以下の順で sub-skill 連鎖 dispatch:
   - `rite:issue:start-execute` → 完了時に `<!-- [start:execute:completed] -->` emit
   - orchestrator が sentinel 観測 → `rite:issue:start-publish` dispatch
   - `rite:issue:start-publish` → 完了時に `<!-- [start:publish:completed] -->` emit
   - orchestrator が sentinel 観測 → `rite:issue:start-finalize` dispatch
   - `rite:issue:start-finalize` → 完了時に `<!-- [start:finalize:completed] -->` emit (workflow 終端)
4. 各 sub-skill 内では Phase 内の各 step boundary で `flow-state-update.sh` patch、Mandatory After で 2 文 contract に従い continuation を保証
5. resume / compact / interrupt 時は orchestrator が flow-state を読み込み、対応する sub-skill から再開

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

#### 編集対象
- `plugins/rite/commands/issue/start.md` (本体、2303 → ~700 行)

#### 新規作成
<!-- ※ 当時の提案 list — sub-skill 3 件 + test 2 件は実際は flat workflow refactoring で覆され作成されず、reference 5 件は後の refactoring で削除済 (4 件は #1136/#1091、1 件は #1162)。残り 3 reference のみ現存。 -->
- `plugins/rite/commands/issue/start-execute.md` (sub-skill) (※ 実装されず — flat workflow refactoring で覆された)
- `plugins/rite/commands/issue/start-publish.md` (sub-skill) (※ 実装されず — flat workflow refactoring で覆された)
- `plugins/rite/commands/issue/start-finalize.md` (sub-skill) (※ 実装されず — flat workflow refactoring で覆された)
- `plugins/rite/commands/issue/references/flow-state-scaffolding.md` (※ 削除済 — #1136 で start.md 廃止時に orphan 削除)
- `plugins/rite/commands/issue/references/pre-condition-gate.md` (※ 削除済 — #1136 で start.md 廃止時に orphan 削除)
- `plugins/rite/commands/issue/references/workflow-incident-detection.md` (※ 削除済 — #1091 で workflow-incident-emit 機構撤去時に削除)
- `plugins/rite/commands/issue/references/workflow-incident-emit-pattern.md` (※ 削除済 — #1091 で workflow-incident-emit 機構撤去時に削除)
- `plugins/rite/commands/issue/references/fingerprint-cycling.md`
- `plugins/rite/commands/issue/references/checklist-auto-check.md`
- `plugins/rite/commands/issue/references/metrics-recording.md`
- `plugins/rite/commands/issue/references/projects-status-update-callsites.md` (※ 削除済 — #1162 で orphan file として removed、現 SoT は [`references/projects-integration.md §2.4`](../../plugins/rite/references/projects-integration.md))
- `plugins/rite/hooks/tests/start-md-charter.test.sh` (※ 実装されず — charter test は flat workflow refactoring 後に別形態で実装、本 file 名は使用されず)
- `plugins/rite/hooks/tests/flow-state-create-symmetry.test.sh` (※ 実装されず — symmetry test は flat workflow refactoring 後に別形態で実装、本 file 名は使用されず)

#### 同期更新が必要 (Critical Files に昇格)
- `plugins/rite/commands/resume.md`: phase routing 表 (line 199-208, 496-504, 523-531) の verify、必要なら sub-skill 境界 marker を追加
- `plugins/rite/skills/rite-workflow/SKILL.md`: sub-skill 名追記
- `plugins/rite/skills/rite-workflow/references/phase-mapping.md`: Phase 5 図の更新
- `plugins/rite/i18n/{ja,en}/{common,issue,other,pr}.yml`: i18n キー owner 移転確認
- `plugins/rite/hooks/phase-transition-whitelist.sh`: 新エッジ追加 (PR F/G1/G2)
- `plugins/rite/hooks/pre-tool-bash-guard.sh`: sentinel detection regex 同期 (PR F/G1/G2)
- `plugins/rite/hooks/verify-terminal-output.sh`: `[start:finalize:completed]` allow-list 追加 (PR G2)
- `plugins/rite/hooks/tests/run-tests.sh`: 新 test 登録 (PR A)
- `docs/SPEC.md`: Plugin Structure 節の更新 (PR H)
- `CHANGELOG.md` / `CHANGELOG.ja.md`: リリース履歴 (PR H)

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

1. **`stop-guard.sh` は実体不在**: 既存ドキュメントで通称として残るが、リポジトリの実体は `pre-tool-bash-guard.sh` (574 行)。同期更新時はこちらを編集する
2. **`phase5_implementation` の latent unaligned state**: resume.md は line 199, 496, 523 で hard-code 参照するが、whitelist には存在しない既存問題。本プランでは触らず、将来 Issue として分離
3. **Revert 互換性チェーン**: PR C (scaffolding/pre-condition references) を revert すると D-G2 が anchor リンク切れ → revert 単位は {C, D, E, F, G1, G2} セット。各 PR は独立 mergeable だが revert 時はセット扱い
4. **develop 並列開発の merge conflict**: 8 PR 中 7 PR が start.md を編集、他 Issue の start.md PR と高頻度競合。各 PR で develop 最新へ rebase 後 charter test を再実行し、機械的削除が rebase で復活していないか自動検証
5. **Silent regression リスク**: 散文の中に紛れた runtime contract を消す可能性。各 sub-skill 切出 PR で e2e 必須化 (PR F / G1 / G2 / H + B / D / E で計 7 回)
6. **Dogfooding recovery 手順**: 実装中に runtime regression を踏んだ場合、`~/.claude/settings.json` の `rite@rite-marketplace: true` 一時切替で marketplace 版に fallback (cache クリア後、修正完了後に false に戻す)
7. **HTML sentinel 名前空間衝突**: 既存 sentinel (`[interview:*]` `[create:*]` `[ingest:*]` `[cleanup:*]` `[review:*]` `[fix:*]` `[pr:*]` `[lint:*]` `[plan:*]` `[ready:*]`) と grep 確認で 0 件衝突を確認済み
8. **i18n キー owner 移転**: Phase 5 内の AskUserQuestion / ユーザー向けメッセージが sub-skill に移管された場合、参照キーの所有者 (caller-side or sub-skill-side) を明示的に決定する必要あり

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

以下は本プランでは扱わず、将来 Issue として分離する:

- **FSM yml 外部化** (`references/issue-start-fsm.yml`): phase 名 SoT 一本化
- **detection framework 統一** (`hooks/detect/*.sh`): 4 自動検出機能 (parent / out-of-scope / workflow-incident / fingerprint) の共通契約化
- **`--auto` flag**: AskUserQuestion 自動 resolve (sprint:execute / team-execute からの呼び出し安定化)
- **`--until` / `--resume` flag**: flag 化したライフサイクル制御
- **コマンド分割** (`/rite:issue:work` / `/rite:issue:finish`): 完全 lifecycle 分離
- **`implement.md` slim** (1001 行): TDD Light / Parallel impl / Adaptive re-eval の references 化
- **latent unaligned state の解消**: `phase5_implementation` を resume.md は要求するが whitelist にない問題

これらは本プラン完了後に効果測定し、必要があれば別 Issue として起票する。
