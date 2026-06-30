# Slug Generation — Pre-generation Rules + Translation Guidelines

> **SoT scope**: `/rite:issue-create` における **Issue slug 生成** の正規 rubric。`skills/issue-create/SKILL.md` ステップ 1.4 (slug 生成) が consumer。slug は ステップ 4.1 で Issue title の baseline として再利用される。

## Slug Generation Rules

Tentative と confirmed のいずれの場合も同一のルールが適用される。

| # | ルール | 補足 |
|---|--------|------|
| 1 | 日本語入力の場合、Claude が文脈を考慮して適切な英語に翻訳する | 例: `テトリスゲームを作る` → `tetris-game` / `ユーザー認証システム` → `user-auth-system` / `EC サイト基盤構築` → `ec-site-infrastructure` |
| 2 | すべて小文字に変換する | `Tetris-Game` → `tetris-game` |
| 3 | 空白をハイフン (`-`) に置換する | `user auth system` → `user-auth-system` |
| 4 | 特殊文字を除去する | `user@auth#` → `userauth` |
| 5 | 30 文字以下に切り詰める | 長文タイトルは concept を保持しつつ truncate |

---

## Translation Guidelines

ルール 1 の Japanese→English 翻訳に関する細則。

| ガイドライン | 対応 |
|-------------|------|
| **技術用語は直接英語化** | `API` → `api` / `データベース` → `database` / `フロントエンド` → `frontend` |
| **固有名詞はローマ字化を許容** | `お知らせ機能` → `oshirase-feature` または `notification-feature`（より検索しやすい方を選択） |
| **迷う場合は一般的・検索可能な英語表現を選択** | プロジェクト内の既存命名と整合する表現を優先 |
