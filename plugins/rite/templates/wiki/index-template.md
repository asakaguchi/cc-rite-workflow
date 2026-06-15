---
okf_version: "0.1"
description: "rite Experience Wiki — プロジェクト固有の経験則 bundle（OKF v0.1 準拠）"
---

# Wiki Index

このファイルは Wiki 全ページのカタログです。Ingest サイクルごとに OKF v0.1 予約ファイル構造（箇条書き）で自動更新されます。

bundle-root の frontmatter で OKF（Open Knowledge Format）v0.1 への準拠を `okf_version: "0.1"` として宣言します。各ページは `* [タイトル](pages/{domain}/{slug}.md) - 説明` の箇条書きで登録されます。メタデータ（ドメイン / 確信度 / 更新日）は各ページの frontmatter を Source of Truth とし、index には重複保持しません（統計は `/rite:wiki:lint` のレポート出力で算出されます）。

<!-- ページ登録箇条書き（ingest が自動追記）。例:
* [タイトル](pages/heuristics/foo.md) - 1-2 文の説明
-->
