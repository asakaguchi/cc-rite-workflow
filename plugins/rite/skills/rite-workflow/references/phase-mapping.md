# Phase Mapping Reference

Mapping information for phase details. Used in work memory session information.

## Phase Detail Mapping

`/rite:issue:start` (廃止済み) は新 4 コマンド `/rite:pr:open` / `/rite:pr:iterate` / `/rite:pr:ready` / `/rite:pr:merge` に分解された。本 mapping は work memory `フェーズ詳細` 欄および `flow-state.json` の `phase` field の表示文字列を定義する。

### `/rite:issue:create` (flat workflow)

`/rite:issue:create` は Issue 作成のみで work phase を持たず、flow-state を init / 所有しない。本コマンドは flow-state に phase を書き込まない (`completed` を含む) ため、phase detail mapping のエントリを持たない。完了は sentinel `[create:returned-to-caller:{N}]` (ステップ 4.4 / 5.6) で表現される。

### 新 4 コマンド

`/rite:resume` の routing は `commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) を SoT とする。

| Phase | Phase Detail | 担当コマンド |
|-------|-------------|------------|
| `init` | Issue 取得・親子判定 | `/rite:pr:open` ステップ 1 |
| `branch` | ブランチ作成完了 | `/rite:pr:open` ステップ 2 |
| `plan` | 実装計画生成完了 | `/rite:pr:open` ステップ 3 |
| `implement` | 実装作業中 / 完了 | `/rite:pr:open` ステップ 4 (内部で `rite:issue:implement` invoke) |
| `lint` | 品質チェック完了 | `/rite:pr:open` ステップ 5 |
| `pr` | PR 作成完了 | `/rite:pr:open` ステップ 6 |
| `review` | レビュー実施中 / 完了 | `/rite:pr:iterate` review side |
| `fix` | レビュー修正中 / 完了 | `/rite:pr:iterate` fix side |
| `ready` | Ready 成功 (Projects Status / 親 Issue 完結待ち) | `/rite:pr:ready` ステップ 3 |
| `ready_error` | Ready 失敗 (PR は作成済み、Ready 遷移のみ rollback。`/rite:pr:create` を再実行してはならない) | `/rite:pr:ready` リトライ |
| `cleanup` | クリーンアップ実行中 | `/rite:pr:cleanup` |
| `ingest` | Wiki ingest 実行中 (legacy transient phase — 現行 cleanup.md ステップ 9 / review.md ステップ 6.5.W / fix.md ステップ 4.6.W は phase=ingest を書き込まない) | `/rite:pr:cleanup` ステップ 9 (legacy state file の resume routing 用途のみ) |
| `completed` | ワークフロー完了 (`active: false`) | `/rite:pr:cleanup` 終端 |

### Legacy phase 名

旧 sub-skill chain アーキテクチャで使われていた `phase5_*` / `phase1_*` / `phase2_*` / `phase3_*` 系 phase 名は `flow-state.sh` の write path からは消滅した。古い state file が残っている環境では `/rite:resume` の `commands/resume.md` Phase 3.5 整合性判定 (cross-check) が legacy phase 値を v3 enum に解決して routing する。

旧 phase 名の遷移許可 graph（`phase-transition-whitelist.sh` の `_RITE_PHASE_TRANSITIONS` / `rite_phase_transition_allowed`）は v2→v3 移行で retired・削除済み。現在 phase 名の妥当性は `flow-state.sh` の `_phase_is_valid` が `PHASE_ENUM_V3` に対して検査するのみで、未知 phase は reject されず WARNING を出して forward-compat に受容される。legacy phase の v3 解決は下記の cross-check が担当する。

> **legacy phase の解決は `commands/resume.md` Phase 3.5 整合性判定 (cross-check) が担当**: cross-check の rule 1 は v3 enum (13 個) の値のみを直接採用するため、`phase5_*` 等の非 v3 enum legacy 値はそのまま採用されず、cross-check の判定を経て v3 phase へ解決される。解決後の v3 phase → 新 4 コマンドの routing は同 `commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) を参照する。

## Usage Example

Work memory session information section:

```markdown
### セッション情報
- **開始**: 2026-01-29T12:00:00+09:00
- **ブランチ**: feat/issue-123-feature-name
- **最終更新**: 2026-01-29T14:30:00+09:00
- **コマンド**: /rite:pr:open
- **フェーズ**: implement
- **フェーズ詳細**: 実装作業中
```

## Related

- [Session Detection](./session-detection.md) - Auto-detection at session start
- [Work Memory Format](./work-memory-format.md) - Work memory format
