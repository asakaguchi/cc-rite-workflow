---
okf_version: "0.1"
description: "rite Experience Wiki — プロジェクト固有の経験則 bundle（OKF v0.1 準拠）"
---

# Wiki Index

このファイルは Wiki 全ページのカタログです。Ingest サイクルごとに OKF v0.1 予約ファイル構造（箇条書き）で自動更新されます。

bundle-root の frontmatter で OKF（Open Knowledge Format）v0.1 への準拠を `okf_version: "0.1"` として宣言します。各ページは `* [タイトル](pages/{domain}/{slug}.md) - 説明` の箇条書きで登録されます。メタデータ（ドメイン / 確信度 / 更新日）は各ページの frontmatter を Source of Truth とし、index には重複保持しません（総ページ数は `/rite:wiki-lint` のレポート出力で確認できます。ドメイン別内訳は本 Sub のスコープ外）。

<!-- 登録箇条書きの形式例（ingest が自動追記。このコメント行は登録ではない）:
     * [ページタイトル](pages/{domain}/{slug}.md) - 1-2 文の説明 -->
