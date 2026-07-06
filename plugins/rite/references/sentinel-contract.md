# Sentinel Contract (SoT)

rite workflow のスキル間連携は、各 sub-skill が bash 出力に埋め込む機械可読な sentinel 文字列（`[skill:action]` 形式）を通じて行われる。emitter（emit する skill）と consumer（読み取って分岐する skill）は文字列一致という暗黙の契約で結合しており、型・enum による保証はない。本ファイルは全 sentinel の emitter/consumer 対応を列挙する唯一の SoT である。

新しい sentinel を追加・変更・削除する場合は、本ファイルの表と実体（emit 側 skill / consume 側 skill）を同一 PR 内で同期させること。同期の機械検証は [`sentinel-contract-check.sh`](../hooks/scripts/sentinel-contract-check.sh)（`/rite:lint` から実行）および CI（`.github/workflows/sentinel-contract-check.yml`）が行う。

## 表記規約

- **Sentinel**: `[skill:action]` 形式のリテラル文字列。可変部分（PR 番号・cycle 番号等）は `N` で表す
- **Emitter**: その sentinel を emit する責務を持つ skill（`plugins/rite/skills/{emitter}/SKILL.md`）
- **Consumer**: sentinel を読み取って分岐する skill。`skills/rite-workflow/` は個別に invoke される skill ではなく、orchestrator 共有のルーティング表（`references/`）を指すため独立した列に区別する
- **意味**: sentinel が示す状態・結果
- **Numbered Sentinel（`:N]` で終わる行）の emitter 表記**: emitter 側の SKILL.md 本体は実際に emit する際の bash 変数置換前提のため、`{number}` / `{pr_number}` / `{issue_number}` のようなテンプレート placeholder で表記する（リテラル `N` はコンシューマ側ドキュメントが「任意の数値」を表すための表記規約であり、emitter 自身の実装コメントには現れないことがある）。`sentinel-contract-check.sh` の emitter 存在確認は `:N]` サフィックスを検出すると `[prefix:(\{[A-Za-z_]+\}|[0-9]+|N)]` パターンの正規表現一致に切り替え、テンプレート placeholder 表記・具体的な数値例（例: `[pr:created:123]`）・リテラル `N` のいずれも許容する

## Sentinel 一覧

| Sentinel | Emitter | Consumer | 意味 |
|----------|---------|----------|------|
| `[review:mergeable]` | review | iterate, run | レビュー結果が mergeable（blocking finding 0 件） |
| `[review:fix-needed:N]` | review | iterate | レビューで N 件の blocking finding を検出、fix へ。iterate のループ内部状態のため run へは bubble しない |
| `[review:error]` | review | iterate | review 実行中にエラー発生。iterate 内部で処理され run へは bubble しない |
| `[fix:error]` | fix | iterate, run | fix 実行中にエラー発生 |
| `[fix:pushed]` | fix | iterate | fix 完了・push 済み、review へ再突入。iterate のループ内部状態のため run へは bubble しない |
| `[fix:pushed-wm-stale]` | fix | iterate | fix push 完了だが work memory 更新が失敗（non-blocking）。iterate 内部で処理され run へは bubble しない |
| `[fix:replied-only]` | fix | iterate, run | 対応不要判定のみで push なし（コメント返信のみ） |
| `[fix:cancelled-by-user]` | fix | iterate, run | ユーザーが fix 実行をキャンセル |
| `[lint:success]` | lint | open, pr-create, ready | lint 全チェック pass |
| `[lint:error]` | lint | issue-implement, open | lint でエラー検出、修正が必要 |
| `[lint:skipped]` | lint | open | lint 未設定のためスキップ |
| `[lint:aborted]` | lint | issue-implement, open | lint 実行が中断 |
| `[lint:returned-to-caller:auto]` | wiki-lint | wiki-ingest | `--auto` モードでの wiki-lint 完了、caller (wiki-ingest) へ制御を返す |
| `[ready:returned-to-caller]` | ready | run | Ready for review 化完了、caller へ制御を返す |
| `[ready:error]` | ready | run | Ready 化中にエラー発生 |
| `[merge:returned-to-caller]` | merge | run | マージ完了、caller へ制御を返す |
| `[merge:not-ready]` | merge | run | PR が draft または mergeable でないため merge 不可 |
| `[merge:error]` | merge | run | merge 実行中にエラー発生 |
| `[cleanup:returned-to-caller]` | cleanup | run | クリーンアップ完了、caller へ制御を返す |
| `[ingest:returned-to-caller]` | wiki-ingest | (caller の turn 継続マーカー、literal consumer なし) | Wiki ingest 完了。cleanup 側は本 sentinel を literal grep で consume せず、独自の `[CONTEXT] WIKI_INGEST_DONE/FAILED` 等で成否判定する。sentinel 自体は turn-boundary heuristic 誤発火を防ぐ active disambiguation 目的 |
| `[create:returned-to-caller:N]` | issue-create | (terminal、consumer なし) | Issue #N 作成完了。issue-create は他 skill から呼ばれない flat workflow のため、caller への継続ルーティングは持たない terminal sentinel |
| `[pr:created:N]` | pr-create | open, resume, run | PR #N を作成完了 |
| `[pr-create-failed]` | pr-create | open, run | PR 作成に失敗 |
| `[iterate:max-cycles-reached]` | iterate | run | review⇄fix ループが `safety.max_cycles` の上限に到達 |
| `[iterate:max-cycles-stopped]` | iterate | (iterate 内部完結) | 上限到達によりループを停止した最終状態表示 |
| `[run:all-completed]` | run | (run 内部完結、最終出力) | バッチ処理対象の全 Issue が完了 |
| `[run:stopped]` | run | (run 内部完結、最終出力) | サーキットブレーカー等でバッチ処理を中断 |
| `[projects:fetch-failed]` | issue-list | (issue-list 内部完結) | GitHub Projects からのフィールド取得に失敗 |
| `[learn:complete]` | learn | (learn 内部完結) | 学習セッション完了 |

## Non-Sentinel な類似記法（検証対象外）

以下は本表の対象外であり、`sentinel-contract-check.sh` は固定 denylist で無視する:

- `[CONTEXT] key=value` 形式（`references/bash-cross-boundary-state-transfer.md` の state 伝達パターン。sentinel ではなく任意の key=value ペア。先頭大文字のため検出 regex が自然に除外する）
- ドキュメント内の汎用プレースホルダ例: `[skill:returned-to-caller]` / `[name:returned-to-caller]`（`hooks/tests/sentinel-disambiguator-adjacency.test.sh` のテストフィクスチャが使う抽象 skill 名）、`[file:line]`（`fix/SKILL.md` の `scope_map[file:line]` データ構造キー表記）、`[tag:value]`（`rite-workflow/references/workflow-identity.md` の HTML コメント化を説明する抽象例）
- コード中の正規表現文字クラス（例: `[a-z_-]`、`[A-Za-z0-9_]`）。検出 regex はコロン必須のため自然に除外される
- 検証スクリプトの denylist は `plugins/rite/hooks/scripts/sentinel-contract-check.sh` 冒頭の `NON_SENTINEL_DENYLIST` 配列を参照（本節と同期させること）
