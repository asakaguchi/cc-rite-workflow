# Flow State Schema v2 → v3 Migration Guide

PR 2a (Issue #1080) で flow-state の schema_version が v2 から v3 に bump されました。本ドキュメントは migration の自動化挙動、phase enum の縮約、手動 fallback 手順をまとめます。

## 何が変わったか

### Schema field の変更

| 項目 | v2 | v3 |
|------|----|----|
| schema_version | 2 | 3 |
| branch field 名 | `branch` または `branch_name` (caller 混在) | `branch` に統一 |
| `previous_phase` | あり (前 phase の記録) | **削除** |
| `last_synced_phase` | あり (WM 同期 phase) | **削除** |
| phase enum 数 | 18 種類 (`cleanup_pre_ingest` 等の sub-phase 含む) | 13 種類に縮約 |

### Phase enum 13 個 (v3 SoT)

```
init / branch / plan / implement / lint / pr / review / fix / ready /
ready_error / cleanup / ingest / completed
```

旧 phase 値の reduction matrix (`hooks/flow-state.sh` の `_phase_migrate` 関数が SoT):

| 旧 phase 値 (v1/v2) | 新 phase (v3) |
|---------------------|---------------|
| `cleanup_pre_ingest` | `cleanup` |
| `cleanup_post_ingest` | `cleanup` |
| `cleanup_completed` | `cleanup` |
| `ingest_pre_lint` | `ingest` |
| `ingest_post_lint` | `ingest` |
| `ingest_completed` | `ingest` |
| `create_interview` | `init` |
| `create_post_interview` | `init` |
| `create_delegation` | `init` |
| `create_post_delegation` | `init` |
| `create_completed` | `init` |
| `implementing` | `init` (= 開始時の暫定値) |
| `parent_progress_sync` | `init` |
| `unknown` | `init` |
| その他の旧値 | そのまま (warning emit + pass-through) |

新 enum で表現できなかった sub-phase は `next_action` テキストおよび `active` フラグで識別する設計。例:
- 旧 `phase=cleanup_completed, active=false` → 新 `phase=cleanup, active=false`
- 旧 `phase=ingest_pre_lint, active=true, next="..."` → 新 `phase=ingest, active=true, next="..."`

### 削除された helper script

PR 2a で以下 6 個の helper が削除され、新 `hooks/flow-state.sh` に統合されました:

| 削除 helper | 代替 |
|------------|------|
| `flow-state-update.sh` | `flow-state.sh set` (旧 create/patch 統合、merge semantics) |
| `state-read.sh` | `flow-state.sh get` |
| `_resolve-flow-state-path.sh` | `flow-state.sh path` |
| `_resolve-schema-version.sh` | (廃止、v3 固定) |
| `phase-transition-whitelist.sh` | (廃止、enum 13 個の whitelist は `flow-state.sh` 内 `PHASE_ENUM_V3`) |
| `resume-active-flag-restore.sh` | `flow-state.sh set --if-exists` の merge semantics に inline 化 |
| `scripts/migrate-flow-state.sh` | `flow-state.sh migrate` |

## 自動マイグレーション

PR 2a 適用後、`/rite:resume` 実行時に **Phase 2: 自動 migration** で `flow-state.sh migrate --verbose` が呼ばれ、以下の処理が走ります:

1. `.rite/sessions/*.flow-state` 配下のすべてのファイルを sweep
2. `.rite-flow-state` legacy single-file (もしあれば) も対象
3. 各ファイルについて:
   - `schema_version != 3` ならマイグレーション実行
   - phase 値を reduction matrix で v3 enum に変換
   - `previous_phase` / `last_synced_phase` を drop
   - `branch_name` フィールドを `branch` にリネーム
   - `schema_version` を 3 に bump
   - `updated_at` を現在時刻に更新

migration は atomic write (`mv` + `flock -w 3`) で行われ、中断しても整合性が崩れない。

## 手動 fallback

自動マイグレーションが失敗した場合、または事前に dry-run で確認したい場合:

```bash
# dry-run (変更内容を出力するのみ、ファイル更新なし)
bash plugins/rite/hooks/flow-state.sh migrate --dry-run --verbose

# 実行
bash plugins/rite/hooks/flow-state.sh migrate --verbose
```

出力例:
```
  migrated: .../48799e61-9827-4dd5-9f58-94033069966a.flow-state (v2→v3, cleanup_pre_ingest→cleanup)
  skip (already v3): .../another-session.flow-state
Migration complete: 1 file(s) processed
```

## ロールバック

v3 へのマイグレーションは「片方向」です (v3 → v2 への自動 downgrade は提供しません)。ロールバックが必要な場合:

1. PR 2a 適用前の `develop-pre-refactor` tag (@ `4df85682`) からの cherry-pick で旧 hook を復元
2. または、本 PR merge 前の develop HEAD へ revert

各 `.rite/sessions/*.flow-state` ファイルは個別に git で版管理されていないため、復元には実装者側で `schema_version` を 2 に戻し、`previous_phase` / `last_synced_phase` を再追加する必要があります。実用上はロールバック前提でない設計。

## Caller 側の API 変更

PR 2a で commands/ + hooks/ 配下の caller を新 API に統一しました。プロジェクトに直接 `bash {plugin_root}/hooks/flow-state-update.sh ...` などを書いていた場合は、以下の対応が必要:

| 旧 | 新 |
|----|----|
| `flow-state-update.sh create --phase X --issue N --branch B --pr P --next T` | `flow-state.sh set --phase X --issue N --branch B --pr P --next T` |
| `flow-state-update.sh patch --phase X --next T --if-exists` | `flow-state.sh set --phase X --next T --if-exists` (merge semantics で他フィールドは保持) |
| `flow-state-update.sh patch --active false --next "none"` | `flow-state.sh deactivate --next "none"` (または `flow-state.sh set --active false --next "none"`) |
| `state-read.sh --field phase --default ""` | `flow-state.sh get --field phase --default ""` |
| `_resolve-flow-state-path.sh "$STATE_ROOT"` | `flow-state.sh path` |

## まとめ

PR 2a 適用後:
1. 既存ユーザーは `/rite:resume` を実行するだけで自動マイグレーションが走る (手動操作不要)
2. 新 API は merge semantics により旧 patch mode と互換 (caller の引数省略時は既存値保持)
3. phase enum が 18 → 13 に縮約され、resume.md の cross-check ロジックがシンプル化
4. 削除 6 hook (約 2,140L) + scripts/migrate-flow-state.sh + 11 テスト (約 3,000L) = 合計 5,000L 超のコード削減

詳細は `plugins/rite/hooks/flow-state.sh` および `plugins/rite/commands/resume.md` を参照。
