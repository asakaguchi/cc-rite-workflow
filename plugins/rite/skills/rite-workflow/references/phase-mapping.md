# Phase Mapping Reference

Mapping information for phase details. Used in work memory session information.

## Phase Detail Mapping

`/rite:issue:start` は flat single-file workflow に統合された (旧 3 sub-skill chain `start-execute` / `start-publish` / `start-finalize` は retire)。本 mapping は work memory `フェーズ詳細` 欄および `flow-state.json` の `phase` field の表示文字列を定義する。

### `/rite:issue:create` (flat workflow)

| Phase | Phase Detail |
|-------|-------------|
| `completed` | Issue 作成完了 (`create.md` Step 6 の終端のみ書き込む。中間 phase は書かない) |

### `/rite:issue:start` (flat workflow)

`start.md` のステップ番号と 1:1 対応する 11 phase。`/rite:resume` の routing は `commands/resume.md` Phase 3.2 表を SoT とする。

| Phase | Phase Detail | Step in start.md |
|-------|-------------|------------------|
| `init` | Issue 取得・親子判定 | ステップ 1 |
| `branch` | ブランチ作成完了 | ステップ 2 |
| `plan` | 実装計画生成完了 | ステップ 3 |
| `implement` | 実装作業中 / 完了 | ステップ 4 |
| `lint` | 品質チェック完了 | ステップ 5 |
| `pr` | PR 作成完了 | ステップ 6 |
| `review` | レビュー実施中 / 完了 | ステップ 7.1 |
| `fix` | レビュー修正中 / 完了 | ステップ 7.2 |
| `ready` | Ready 成功 (`/rite:pr:ready` 完了、後続の Status / 親 Issue 完結待ち) | ステップ 8.3 |
| `ready_error` | Ready 失敗 (PR は作成済み、Ready 遷移のみ rollback。`/rite:pr:create` を再実行してはならない) | ステップ 8 |
| `completed` | ワークフロー完了 (`active: false`) | ステップ 8 終端 |

### Legacy phase 名

旧 sub-skill chain アーキテクチャで使われていた `phase5_*` / `phase1_*` / `phase2_*` / `phase3_*` 系 phase 名は `flow-state-update.sh` の write path からは消滅した。古い state file が残っている環境では `/rite:resume` が `commands/resume.md` Phase 3.2 の legacy alias 行で routing する。

旧 phase 名は `phase-transition-whitelist.sh` 内の `_RITE_PHASE_TRANSITIONS` から削除済。`rite_phase_transition_allowed` の forward-compat 経路で未知 prev phase は accept される (terminal phase 以外への遷移は許可、terminal phase への遷移のみ canonical predecessor set による厳密 check)。caller 側 (production hook は predicate のみ使用) の WARNING / ERROR は、predicate の戻り値ではなく caller の判定で生じる。

> **詳細 routing は `commands/resume.md` Phase 3.2 "For rite:issue:start" Legacy phase 名 compatibility 表が SoT**。legacy `phase5_implementation` → ステップ 4 等、具体的なマッピングは resume.md を参照する。

## Usage Example

Work memory session information section:

```markdown
### セッション情報
- **開始**: 2026-01-29T12:00:00+09:00
- **ブランチ**: feat/issue-123-feature-name
- **最終更新**: 2026-01-29T14:30:00+09:00
- **コマンド**: rite:issue:start
- **フェーズ**: implement
- **フェーズ詳細**: 実装作業中
```

## Related

- [Session Detection](./session-detection.md) - Auto-detection at session start
- [Work Memory Format](./work-memory-format.md) - Work memory format
- [Sub-skill Return Auto-Continuation Contract (Retired)](./sub-skill-return-protocol.md) - migration map
