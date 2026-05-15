# Phase Mapping Reference

Mapping information for phase details. Used in work memory session information.

## Phase Detail Mapping

Issue #896 series (PR A-H) で `/rite:issue:start` は再設計され、Phase 5 は `start-execute` / `start-publish` / `start-finalize` の 3 sub-skill に分割された。本 mapping は work memory `フェーズ詳細` 欄の表示文字列を定義する。

### Phase 1.5 / 1.6 (Parent Routing)

| Phase | Phase Detail |
|-------|-------------|
| `phase1_5_parent` | 親 Issue routing 開始 |
| `phase1_5_post_parent` | 親 Issue routing 完了 |
| `phase1_6_child` | 子 Issue 選択中 |
| `phase1_6_post_child` | 子 Issue 選択完了 |

### Phase 2 (Work Preparation)

| Phase | Phase Detail |
|-------|-------------|
| `phase0` | Epic/Sub-Issues 判定 |
| `phase1` | 品質検証 |
| `phase2` | ブランチ作成・準備 (legacy single phase) |
| `phase2_branch` | ブランチ作成中 |
| `phase2_post_branch` | ブランチ作成完了 |
| `phase2_projects` | Projects Status 更新中 |
| `phase2_post_projects` | Projects Status 更新完了 |
| `phase2_iteration` | Iteration 割当中 |
| `phase2_post_iteration` | Iteration 割当完了 |
| `phase2_work_memory` | 作業メモリ初期化中 |
| `phase2_post_work_memory` | 作業メモリ初期化完了 |

### Phase 3 / 4 (Plan / Guidance)

| Phase | Phase Detail |
|-------|-------------|
| `phase3` | 実装計画生成 (legacy) |
| `phase3_plan` | 実装計画生成中 |
| `phase3_post_plan` | 実装計画生成完了 |
| `phase4` | 作業開始準備 |

### Phase 5 (E2E Execution — 3 sub-skill chain)

| Phase | Phase Detail | Owner |
|-------|-------------|-------|
| `phase5_execute_running` | start-execute 実行中 | orchestrator delegation pre-write |
| `phase5_stop_hook` | Stop Hook 検証中 | start-execute Phase 5.0 |
| `phase5_post_stop_hook` | Stop Hook 検証完了 | start-execute |
| `phase5_lint` | 品質チェック中 | start-execute Phase 5.2 |
| `phase5_post_lint` | チェックリスト確認中 | start-execute Phase 5.2 終端 |
| `phase5_post_execute` | start-execute 完了 | start-execute Return |
| `phase5_publish_running` | start-publish 実行中 | orchestrator delegation pre-write |
| `phase5_pr` | PR 作成中 | start-publish Phase 5.3 |
| `phase5_review` | レビュー中 | start-publish Phase 5.4 |
| `phase5_post_review` | レビュー後処理 | start-publish Phase 5.4 |
| `phase5_fix` | レビュー修正中 | start-publish Phase 5.4 |
| `phase5_post_fix` | レビュー修正後処理 | start-publish Phase 5.4 |
| `phase5_post_publish` | start-publish 完了 | start-publish Return |
| `phase5_finalize_running` | start-finalize 実行中 | orchestrator delegation pre-write |
| `phase5_ready_error` | Ready エラー terminal | ready.md Phase 3.1 |
| `phase5_post_ready` | Ready 処理完了 | ready.md / start-finalize |
| `phase5_status_in_review` | Issue Status In Review 更新中 | start-finalize Phase 5.5.1 |
| `phase5_post_status_in_review` | Status 更新完了 | start-finalize |
| `phase5_metrics` | Metrics 記録中 | start-finalize Phase 5.5.2 |
| `phase5_post_metrics` | Metrics 記録完了 | start-finalize |
| `phase5_completion` | Completion Report 出力中 | start-finalize Phase 5.6 |
| `phase5_parent_close` | 親 Issue クローズ中 | start-finalize Phase 5.7 |
| `phase5_post_parent_close` | 親 Issue クローズ完了 | start-finalize |
| `phase5_parent_completion` | 親 Issue completion 処理中 | start-finalize Phase 5.7 |
| `phase5_post_parent_completion` | 親 Issue completion 完了 | start-finalize |
| `completed` | ワークフロー完了 | start-finalize Workflow Termination |

## Phase 5 Sub-skill Chain Transitions

Phase 5 は 3 sub-skill delegation chain で構成される。各 sub-skill が emit する HTML-commented sentinel で orchestrator が次 sub-skill を invoke する:

```text
[Phase 5.0-5.2.1] start-execute (rite:issue:start-execute)
  phase5_execute_running → phase5_stop_hook → phase5_post_stop_hook → phase5_lint → phase5_post_lint → phase5_post_execute
  └→ <!-- [start:execute:completed] --> → orchestrator → Phase 5.3-5.4
  └→ <!-- [start:execute:aborted] --> → orchestrator → Phase 5.6 (skip 5.3-5.4)

[Phase 5.3-5.4] start-publish (rite:issue:start-publish)
  phase5_publish_running → phase5_pr → phase5_review ⇄ phase5_post_review ⇄ phase5_fix ⇄ phase5_post_fix → phase5_post_publish
  └→ <!-- [start:publish:completed] --> → orchestrator → Phase 5.5-Termination
  └→ <!-- [start:publish:aborted] --> → orchestrator → Phase 5.6 (skip 5.5/5.5.1/5.5.2/5.7)

[Phase 5.5-Termination] start-finalize (rite:issue:start-finalize)
  phase5_finalize_running → phase5_post_ready → phase5_status_in_review → phase5_post_status_in_review → phase5_metrics → phase5_post_metrics → phase5_completion → phase5_parent_close → phase5_post_parent_close → phase5_parent_completion → phase5_post_parent_completion → completed
  └→ <!-- [start:finalize:completed] --> → workflow terminal
  └→ <!-- [start:finalize:aborted] --> → workflow terminal (abort context)
```

- `phase5_review` ⇄ `phase5_post_review` ⇄ `phase5_fix` ⇄ `phase5_post_fix` は review-fix loop (start-publish 内部)
- `phase5_ready_error` は ready.md Phase 3.1 で skill エラー時に書込まれる terminal error state
- abort path は途中の phase 群を skip して直接 `completed` へ遷移する
- 全 transition は `phase-transition-whitelist.sh` で whitelist 化され stop-guard が検証する

## Usage Example

Work memory session information section:

```markdown
### セッション情報
- **開始**: 2026-01-29T12:00:00+09:00
- **ブランチ**: feat/issue-123-feature-name
- **最終更新**: 2026-01-29T14:30:00+09:00
- **コマンド**: rite:issue:start
- **フェーズ**: phase5_execute_running
- **フェーズ詳細**: start-execute 実行中
```

## Related

- [Session Detection](./session-detection.md) - Auto-detection at session start
- [Work Memory Format](./work-memory-format.md) - Work memory format
