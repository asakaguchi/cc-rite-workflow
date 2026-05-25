# 翻訳スタイルガイド (i18n Style Guide)

このドキュメントは rite workflow の日本語ドキュメント・UI 文言を作成・翻訳する際の方針をまとめる。`docs/CONFIGURATION.ja.md` をはじめとする既存の日本語訳との一貫性を保つために参照する。

> 🇺🇸 English version: (本ガイドは現状日本語のみ。英語化が必要になれば別途整備する)

## 1. kept-English term (英語のまま使用する語)

以下の語は日本語訳せず、英語のまま使用する。`finding` (#1083 の決定) を含む。

| Term | 用例 | 補足 |
|------|------|------|
| `Issue` | 「Issue #123 を作成」 | GitHub Issue を指す固有概念 |
| `PR` | 「PR をマージ」 | Pull Request の略称。`Pull Request` も可 |
| `Sprint` | 「Sprint 計画」 | Iteration の上位概念 |
| `Iteration` | 「Iteration を作成」 | GitHub Projects の Iteration フィールド |
| `finding` | 「review finding」「3 件の findings」 | レビューによる発見事項。「指摘」(UI の行為) とは概念的に別物 |
| `fingerprint` | 「finding fingerprint」 | finding を識別するハッシュ |
| `severity` | 「BLOCKER severity」 | finding の重大度 |
| `confidence` | 「confidence score」 | finding の確からしさスコア |
| `blocking` / `non-blocking` | 「blocking 扱い」 | finding の merge gate 効果 |
| `review-fix loop` | 「レビュー・フィックスループ」 | 一語のみ片仮名化可 (慣用) |
| GitHub Projects フィールド名 (`Status`, `Todo`, `In Progress`, `In Review`, `Done`, `Iteration` 等) | 「Status を In Progress に更新」 | GitHub UI と一致させる |
| `rite-config.yml` キー名 (`branch.base`, `github.projects.enabled` 等) | 「`branch.base` を `develop` に設定」 | YAML キーは原文ママ |
| コマンド名 (`/rite:pr:open`, `gh issue view` 等) | 「`/rite:pr:open` を実行」 | コマンドは原文ママ |

> **Note**: 上記以外の英語固有概念 (例: `worktree`, `hook`, `sentinel`, `marker`) も、原文の意味を保つ必要がある場合は英語のまま使用してよい。

## 2. 翻訳ルール

### 2.1 文体

- **常体 (である調) を基本とする**。「です・ます調」は混在させない。
- 例: 「`finding` は review によって生成される発見事項である」("です" は使わない)

### 2.2 半角英数字と日本語の間のスペース

- 半角英数字と日本語の間には半角スペースを入れる。
- 例: 「Issue #123 を作成」「`branch.base` を `develop` に設定」

### 2.3 コード・YAML・テーブル

- YAML キー名・コマンド名・GitHub Projects フィールド名は翻訳しない (上記 kept-English term の表参照)。
- テーブルの `Field` / `Type` / `Default` 列はそのままで、`Description` 列のみ日本語化する。
- コード例 (YAML / bash) の中身は変更せず、コメント・前後の説明文のみ日本語化する。

### 2.4 相互参照リンク

- `docs/CONFIGURATION.ja.md` ↔ `docs/CONFIGURATION.md` のように、対応する英語版を冒頭に明示する。
- 内部 markdown リンク (例: `plugins/rite/references/severity-levels.md`) は英語版と同じパスを保持し、リンク切れを起こさない。

## 3. UI 文言 (i18n/ja/) との関係

`plugins/rite/i18n/ja/` 配下の UI 文言ファイルでは、以下の使い分けが既に定着している:

- 「指摘」: ユーザーに表示される **UI 文言の中の `finding`** を指す行為的表現
  - 例: `pr_review_issues_list: "指摘事項一覧"`、`pr_fix_addressed_count: "対応した指摘"`
- 素の `finding` / `findings`: **技術的な概念** として参照する場合
  - 例: `review_observed_likelihood_demotion_notice: "🔽 Observed Likelihood Gate: 指摘 {finding_id} は..."`
- `pr_review_findings: "所見"` のように別訳語が定着している箇所はそのまま (個別文脈に依存)

ドキュメント (`docs/*.ja.md`) では UI 文言と異なり、`finding` を英語のまま使う (kept-English term)。「指摘」と `finding` の混在は許容するが、同一段落内で意図的に使い分ける場合は概念区別を明示する。

## 4. 改訂履歴

- **2026-05-23 (Issue #1083)**: 初版作成。`finding` を kept-English term に追加 (Option A 採用)。
