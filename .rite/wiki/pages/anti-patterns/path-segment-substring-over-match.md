---
title: "path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する"
domain: "anti-patterns"
created: "2026-06-01T18:27:24+00:00"
updated: "2026-06-01T18:27:24+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260601T180203Z-pr-1236.md"
tags: []
confidence: high
---

# path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する

## 概要

path 内の固定セグメント名 (`rite` 等) を `rite.*?/hooks/` のような **substring 正規表現** でマッチすると、`favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` のような **look-alike セグメント**を誤マッチし、本来保持すべき対象 (ユーザー定義 hook 等) を silent に over-remove する。`(?:^|/)rite/` のように **path セグメント境界に anchor** して排除すること。ただし anchor を厳格化する際は、cache 形の中間 version segment 等、実在する全 path 形状を列挙し false-negative を作らないこと。

## 詳細

### 検出された具体ケース (PR #1236)

`settings.local.json` から rite hook エントリを除去する cleanup の正規表現が `rite.*?/hooks/` だった。`rite` を path segment 境界に固定していないため、`favorite/hooks/` 等のユーザー定義の非 rite hook を誤マッチし silent 除去しうる。これは **user-controlled security config の integrity リスク** (ユーザーが意図した hook が黙って消える)。

修正は `(?:^|/)rite/(?:[^/]+/)?hooks/`:

- `(?:^|/)rite/` で `rite` を完全 path segment (先頭が文字列頭か `/`) に固定 → `favorite`・`prerite`・`rite-something` を排除
- `(?:[^/]+/)?` で間の version segment を 0 個 or 1 個許容 → 実 hook command の 2 形状を両方カバー

| 形状 | 例 | 判定 |
|------|-----|------|
| cache install | `.../rite/0.2.0/hooks/...` = `rite/<version>/hooks/` | ✅ 除去 |
| dev / 相対 | `plugins/rite/hooks/...` = `rite/hooks/` | ✅ 除去 |
| look-alike | `favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` | ❌ 保持 |

### 二重リスク: tightening で false-positive を false-negative にすり替えない

Issue が素朴に例示した anchor `(?:^|/)rite/hooks/` は cache 形の中間 version segment を考慮しておらず、本番インストール形 `rite/<version>/hooks/` を取りこぼして rite hook を**消し残す false-negative** を生む。

over-match (false-positive) を直すために pattern を厳格化するときは、**実在する全 path 形状を列挙してから** anchor を設計する。さもないと「look-alike を誤除去する」バグを「本物を除去し残す」バグに変えるだけで、どちらも silent regression として残る。anchor の妥当性は must-match 群 (cache/dev/相対) と must-not-match 群 (look-alike) の双方で verify する。

### security framing — over-match は fail-safe ではなく integrity 違反

substring over-match による「ユーザー hook の silent 除去」は user-controlled security config の黙示的 mutation であり、integrity 違反 (silent failure) に当たる。pattern を segment 境界へ厳格化する方向は **fail-safe 側**への是正である。なお本 regex は linear で nested quantifier を持たないため ReDoS リスクはない。

### root cause としての pattern class

このパターンは「**マッチ pattern が意図より広い入力を捕捉する over-capture class**」に属する。同型の事例:

- find glob の文字数/任意文字 wildcard が新規命名 token と偶発一致する collision ([find-glob-naming-collision](./find-glob-naming-collision-silent-removal.md))
- `case` の `*)` catch-all が未知の将来 prefix を吸収する ([catch-all-case-arm](./catch-all-case-arm-absorbs-future-prefix.md))

いずれも「区切り (segment / token / prefix) を明示せず広い pattern で済ませた」ことが root で、誤マッチ対象が削除・分岐吸収として silent に消費されるのが共通の failure mode。新しい pattern を導入・流用するときは、固定 token を **境界 anchor 付き**で書き、look-alike を negative test で固定する。

## 関連ページ

- [新規 file 命名と既存 find glob が collision して silent 削除を起こす](./find-glob-naming-collision-silent-removal.md)
- [prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する](./catch-all-case-arm-absorbs-future-prefix.md)

## ソース

- [PR #1236 review results](../../raw/reviews/20260601T180203Z-pr-1236.md)
