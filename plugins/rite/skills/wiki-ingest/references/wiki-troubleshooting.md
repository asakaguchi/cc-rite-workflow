# Wiki トラブルシューティング

Experience Wiki が期待通りに育たない／動作しないときの診断手順。`/rite:wiki-ingest` の実行前後、`/rite:lint` の Wiki growth check が alarm を出したときの参照先。

## アーキテクチャ概要

`.rite/wiki/` 配下に3層構造で経験則を管理する:

| 層 | 場所 | 所有者 | 性質 |
|---|---|---|---|
| **Raw Sources** | `.rite/wiki/raw/{reviews,retrospectives,fixes}/` | rite ワークフロー（自動生成） | 不変の一次データ |
| **Wiki Pages** | `.rite/wiki/pages/{patterns,heuristics,anti-patterns}/` | LLM（自動生成・更新） | 統合された加工済み知識 |
| **Schema** | `.rite/wiki/SCHEMA.md` | 人間 + LLM | 蓄積規約 |

raw source は `/rite:review`（Phase 6.5.W.2）、`/rite:fix`（Phase 4.6.W.2）、`/rite:issue-close`（Phase 4.4.W.2）で自動生成され、LLM によるページ統合は `/rite:wiki-ingest` が冪等に行う。raw 蓄積と page 統合を分離することで、page 統合が skip / 失敗しても raw source は失われない。

## raw source が増えていない場合

1. **wiki.enabled を確認**: `rite-config.yml` で `wiki.enabled: true` になっているか
2. **wiki.auto_ingest を確認**: `wiki.auto_ingest: true` になっているか（`false` だと raw 蓄積のトリガーが無効化される）
3. **wiki branch の存在を確認**: `git branch -a | grep wiki` で wiki branch が存在するか。存在しない場合は `/rite:wiki-init` を実行するか `git fetch origin wiki:wiki` を実行
4. **Phase X.X.W の sentinel を確認**: 完了レポートの `### 📚 Wiki ingest 状況` セクションで `SKIPPED` や `FAILED` のカウントを確認
5. **workflow incident を確認**: `[CONTEXT] WIKI_INGEST_SKIPPED=1` や `WIKI_INGEST_FAILED=1` がステップ 8.5 で検出・報告されているか

## raw は増えているがページが増えない場合

raw source は蓄積されているが `.rite/wiki/pages/` にページが生成されていない場合:

1. **`/rite:wiki-ingest` を手動実行**: ページ統合は `/rite:wiki-ingest` で実行される。自動発火は `/rite:cleanup` の Wiki Ingest 条件付きステップで行われるため、cleanup を実行していない場合はページが生成されない
2. **pending raw を確認**: `wiki-growth-check.sh` の出力で `pending` 数を確認。`ingested: false` のまま残っている raw source が多い場合は ingest が実行されていない
3. **ingest のエラーログを確認**: `/rite:wiki-ingest` 実行時に LLM 解析エラーが発生していないか確認
4. **SCHEMA.md の整合性を確認**: `.rite/wiki/SCHEMA.md` が正しくセットアップされているか。`/rite:wiki-lint` で品質チェックを実行

## 手動 `/rite:wiki-ingest` の実行タイミング

以下のタイミングで手動実行を推奨:

- **PR cleanup 後に自動発火しなかった場合**: `/rite:cleanup` の Wiki Ingest 条件付きステップで ingest が skip された場合
- **`wiki-growth-check.sh` が page stall を検出した場合**: `==> Page stall detected` の出力があった場合
- **大量の pending raw source がある場合**: `pending` 数が raw 総数の 50% を超えている場合
- **Wiki を初めて使い始める場合**: `/rite:wiki-init` 実行後、既存の raw source をページ化するため

実行方法: `/rite:wiki-ingest` を Claude Code で呼び出す。

## `wiki-growth-check.sh` の alarm の読み方

`wiki-growth-check.sh` は `/rite:lint` から呼び出される総合 health check。以下の alarm を出力する:

| alarm | 意味 | 対処 |
|-------|------|------|
| `Wiki growth stall detected` | wiki branch の最終 commit 以降に N 件以上の PR がマージされたが、raw source が追加されていない | Phase X.X.W が silent skip されている。`/rite:review` / `/rite:fix` / `/rite:issue-close` の Wiki Phase 到達を確認 |
| `PR↔raw correspondence gap` | 直近の merged PR に対応する raw source ファイル（`pr-{number}` 名）が wiki branch に存在しない | 個別 PR の Phase X.X.W 実行を確認。`wiki-ingest-trigger.sh` / `wiki-ingest-commit.sh` のログを確認 |
| `Page stall detected` | raw source は存在するがページ数がゼロ、または pending raw が多い | `/rite:wiki-ingest` を手動実行。cleanup 経路での自動発火が機能しているか確認 |

閾値の調整は `rite-config.yml` の `wiki.growth_check` セクションで可能:

```yaml
wiki:
  growth_check:
    threshold_prs: 5          # growth stall の閾値（デフォルト: 5）
    pr_raw_threshold: 3       # PR↔raw 対応の閾値（デフォルト: 3）
```
