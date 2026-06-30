# Broken Reference Resolution

このドキュメントは `plugins/rite/skills/wiki-lint/SKILL.md` の **ステップ 7 (壊れた相互参照検出)** で使用する
**相対パス解決の規約**を定義する。runtime 実装は `plugins/rite/hooks/scripts/wiki-lint-broken-refs.sh`
(ステップ 7 の委譲先 helper) が保持し、本ドキュメントは解決規約と edge case の SoT として helper と同期する。

判定テーブルだけでは「相対パス (`./pages/...`, `../pages/...`) を `pages_list` に
どう突合するか」が文字列マッチか path 解決か曖昧で、実装ごとに結果が乖離していた。本ドキュメントは
その解決規約を明文化し、bash 実装サンプルを提供する。

---

## 解決規約

| 項目 | 規約 |
|------|------|
| **基準ディレクトリ** | リンクが書かれた **ページファイルのディレクトリ** (`page_dir`) を起点とする |
| **解決関数** | `realpath -m -s --relative-to "$wiki_root" -- "$page_dir/$link"` で正規化 |
| **`$wiki_root` の値** | `.rite/wiki` (cwd 相対 fixed string)。`realpath -m -s` は path 文字列処理のみでディレクトリの実在を要求しないため、separate_branch 戦略 (working tree に `.rite/wiki` が存在しない) でも動作する。cwd=repo root 前提は helper が `--repo-root` (default: `git rev-parse --show-toplevel`) への cd で保証する |
| **`$page_path` の値** | cwd 相対パス (例: `.rite/wiki/pages/heuristics/foo.md`)。helper の per-page ループで `pages_list` (stdin) の各要素として渡される |
| **アンカー除去** | `#section` 部分は解決前に除去 (`sed -E 's/#.*$//'`) |
| **照合先 (pages 参照)** | `pages_list_normalized` — helper が `printf '%s\n' "$pages_list" \| sed -E 's\|^\.rite/wiki/\|\|' \| grep -v '^$'` で生成する相対パスのリスト (`pages/...` 形式) |
| **照合先 (raw 参照)** | `raw_list_normalized` — 同様に `raw_list` から `.rite/wiki/` プレフィックスを除去した相対パスのリスト (`raw/...` 形式)。`resolved_path` の prefix で `pages/*` / `raw/*` を判別して照合先 list を切り替える |
| **絶対パス (`/...`)** | HTTP URL 等の可能性があるため対象外 (lint.md ステップ 7 の除外規約参照) |
| **外部 URL (`http://`, `https://`)** | 対象外 |
| **コードブロック内** | helper のリンク抽出前処理で除外。fence は awk による indent 不問の開閉トラッキング (`awk '/^[[:space:]]*```/{f=!f; next} !f'`) で、インライン code span (`` ` `` 囲み) も `sed 's/`[^`]*`//g'` で除去する |

**`page_dir` の意味**: lint 対象 Wiki ページが `.rite/wiki/pages/heuristics/foo.md` の場合、
`page_dir` は `.rite/wiki/pages/heuristics`。リンク `../patterns/bar.md` は
`.rite/wiki/pages/heuristics/../patterns/bar.md` → `realpath -m -s --relative-to=.rite/wiki` で
正規化後 `pages/patterns/bar.md` として `pages_list_normalized` と突合する。

文字列マッチ (生 link 値を直接 `grep -F`) は **禁止**。`./` / `../` / 連続スラッシュ等の差で false
positive / negative が両方発生する。

---

## Canonical Bash 実装

> ⚠️ **以下のスニペットは `wiki-lint-broken-refs.sh` が各 link に対して per-link loop 内で実行する解決規約の参照実装**です。
> `continue` は enclosing loop の次 iteration へ進む制御です。loop の骨組みは
> `while IFS= read -r link; do ... done <<< "$page_links"`。
> Wiki branch 戦略 (`separate_branch`) で page が filesystem に存在しない場合でも本実装は動作します
> (path 文字列処理のみ、`realpath -m -s` は missing components を許容し symlink を解決しない)。
> helper 実装を変更する際は本ドキュメントの規約・edge case と同期すること。

```bash
# 前提 (lint.md ステップ 2.2 の収集契約 / helper のリンク抽出・normalized list 生成と整合):
#   $page_path             — lint 対象ページの cwd 相対パス
#                            (例: .rite/wiki/pages/heuristics/foo.md)
#   $link                  — helper のリンク抽出 pipeline で抽出された生リンク文字列
#                            (例: "../patterns/bar.md#section")
#   $pages_list_normalized — helper が生成する pages 相対パスのリスト
#                            (改行区切り、例: "pages/heuristics/foo.md")
#   $raw_list_normalized   — 同 raw 相対パスのリスト (例: "raw/reviews/...md")
# 出力:
#   $resolved_path     — 正規化された相対パス (例: "pages/patterns/bar.md")
#   $broken            — "true" / "false"

# wiki_root を cwd 相対の固定値で初期化。realpath -m -s は path 文字列処理のみで
# ディレクトリの実在を要求しないため、separate_branch 戦略 (working tree に
# .rite/wiki が存在しない) でも動作する。cwd=repo root 前提は helper 冒頭の
# --repo-root cd で保証済み (破綻すると --relative-to の結果が
# pages_list_normalized と一致せず全 link が broken-ref と silent 誤判定される)。
wiki_root=".rite/wiki"

# 1. アンカー除去
link_no_anchor=$(printf '%s' "$link" | sed -E 's/#.*$//')

# 2. 絶対パス / 外部 URL / 空文字列は対象外
case "$link_no_anchor" in
  /*|http://*|https://*|"")
    # lint.md ステップ 7 の除外規約参照、broken_refs カウントから除外
    continue
    ;;
esac

# 3. page_dir 起点で正規化 (realpath -m -s)
# - -m (--canonicalize-missing): missing components を許容 (ファイル不在でも path 解決可能)
# - -s (--no-symlinks):           symlink を解決しない (lint 対象では symlink を想定しない)
# 両者を組み合わせることで `./` / `../` / 連続スラッシュを正規化しつつ symlink resolve を回避する。
# GNU coreutils realpath(1) の仕様: -m 単独では symlink は resolve される (-s 必須)。
page_dir=$(dirname "$page_path")
resolved_abs=$(realpath -m -s -- "$page_dir/$link_no_anchor" 2>/dev/null) || resolved_abs=""

if [ -z "$resolved_abs" ]; then
  # 解決失敗 (極端に異常な path 構造) は broken として扱う
  broken="true"
else
  # 4. wiki_root 起点の相対パスに変換
  # 失敗時 (--relative-to 自体のエラー等) は明示的に "" 設定し silent failure を回避
  resolved_path=$(realpath -m -s --relative-to="$wiki_root" -- "$resolved_abs" 2>/dev/null) || resolved_path=""

  if [ -z "$resolved_path" ]; then
    # --relative-to 失敗 = wiki_root 外への解決等 → broken として扱う
    broken="true"
  else
    # 5. resolved_path の prefix で照合先 list を切り替え (pages / raw)
    # case ベースの判別により pages_list_normalized と raw_list_normalized の混在 list を
    # 作る必要がない (各 list は helper 内で独立に生成される)。
    case "$resolved_path" in
      pages/*)
        if printf '%s\n' "$pages_list_normalized" | grep -qxF -- "$resolved_path"; then
          broken="false"
        else
          broken="true"
        fi
        ;;
      raw/*)
        if printf '%s\n' "$raw_list_normalized" | grep -qxF -- "$resolved_path"; then
          broken="false"
        else
          broken="true"
        fi
        ;;
      *)
        # pages/ でも raw/ でもない解決結果 (例: wiki_root 直下の README.md, log.md, index.md 等)
        # は broken_refs 検出対象外として扱う (index.md の整合性は孤児検出 helper が別途扱う)
        broken="false"
        ;;
    esac
  fi
fi

# loop の 1 iteration 完了。$broken / $resolved_path を呼び出し側で issues[] に集約してから次 link へ
```

**`realpath -m -s` の意味**: `-m -s` の組み合わせは missing components を許容しつつ symlink を解決
しないため、`./` / `../` / 連続スラッシュを正規化しつつ symlink を literal path として扱う動作になる。
GNU coreutils `realpath(1)` の仕様上、`-m` 単独では symlink は default で resolve される。`-s`
(`--no-symlinks`, `--strip`) を併用することで symlink を literal path として扱う動作になる。
lint 対象では symlink を想定しないため `-s` を必須とする。

---

## Edge Case

| ケース | 期待挙動 |
|--------|---------|
| `link="./foo.md"` | `page_dir/foo.md` に解決 (page_dir 内のページ参照) |
| `link="../patterns/foo.md"` | `page_dir` の親ディレクトリの `patterns/foo.md` に解決 (page_dir=`.rite/wiki/pages/heuristics` → `pages/patterns/foo.md` で `pages_list_normalized` と突合) |
| `link="../../raw/reviews/x.md"` | page_dir=`.rite/wiki/pages/heuristics` → `raw/reviews/x.md` に解決 → `raw_list_normalized` と突合 |
| `link="foo.md#section"` | アンカー除去後 `foo.md` として `page_dir/foo.md` に解決 |
| `link="http://example.com/x.md"` | 対象外 (broken_refs にカウントしない) |
| `link="/absolute/path.md"` | 対象外 (broken_refs にカウントしない) |
| `link=""` (空文字列) | 対象外 (helper の抽出時点で空は来ない想定だが防御) |

**注 (重要)**: `pages_list_normalized` の実エントリは `pages/{patterns,heuristics,anti-patterns}/*.md` 形式のみ
(lint.md ステップ 2.2 grep filter `^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$` 由来)。
Wiki ルート直下に単独で配置されるページ (例: `pages/foo.md` 形式) は構造上存在しないため、
そのような参照を canonical 実装で解決しようとしても `pages_list_normalized` にはヒットしない
(=必ず broken 判定になる)。`pages/` 配下に置く場合は必ず `patterns` / `heuristics` / `anti-patterns`
のいずれかのサブディレクトリに格納する。

**リンク表記規約**: Wiki ページ内の相対パスリンクは `./pages/...` / `../pages/...` 形式のみを使用し、
「Wiki ルート起点の参照 (`pages/...` prefix なし)」は使用しない。
本 reference の Edge Case も同方針で、`foo.md` (prefix なし) や `pages/x.md` (Wiki ルート起点意図)
のような曖昧な形式は **使用しない** ことを推奨する。万一そのような link が抽出された場合、
本実装は `page_dir` 起点で解決するため Wiki ルート直下にはヒットせず broken と判定される
(これは structural な仕様であり、helper と reference 双方で禁止する形式である)。

---

## 既知の限界

| 限界 | 対処方針 |
|------|---------|
| `realpath -m -s` は GNU coreutils 依存 | macOS/BSD 環境では `coreutils` brew パッケージ (`grealpath`) または `python3 -c "import os.path; print(os.path.normpath(...))"` で代替。lint hook は GNU 環境を前提とする |
| URL 内に `)` を含むリンクは helper の `[^)]+` regex で検出されない | Wiki 内で括弧付き URL を使わない規約で回避 (lint.md ステップ 7 既述) |
| 相対パスが Wiki ルート外を指す場合 (`../../etc/passwd` 等) | `realpath -m -s --relative-to=$wiki_root` は wiki_root 外への path に対して `../../etc/passwd` のような相対パスを返す (空文字列ではない、GNU coreutils 9.x で実機検証済み)。canonical 実装の `case` 文では `pages/*` でも `raw/*` でもないため `*)` 分岐に matched して `broken="false"` (検出対象外) として扱われる。実用上 Wiki ページに `../../etc/passwd` 形式を書く実例は想定されないため実害なし。厳密な escape 検出が必要な場合は別途 `*)` 分岐に「`../` を含む resolved_path は broken="true"」のような明示的 escape check を追加すること |
| シンボリックリンク先のページ | lint 対象では symlink を想定しない。`-m -s` の組み合わせで symlink を解決せず literal path 文字列として比較するため、symlink path がそのまま `pages_list_normalized` に存在する必要がある (実用上 Wiki に symlink は使わないため影響なし) |
| 複数行にまたがる inline code span | fence は awk の indent 不問トラッキング、単一行の inline code span は `sed 's/`[^`]*`//g'` で除去済み (helper 実装)。backtick が複数行にまたがる code span は行単位 sed では除去できない残存限界 (実用上 Wiki ページでは未観測) |
| Wiki ルート起点参照 (`pages/foo.md` を Wiki ルートからのパスと意図する形式) | 本実装では `page_dir` 起点解決のため検出不可能。`pages_list_normalized` の実エントリが `pages/{patterns,heuristics,anti-patterns}/*.md` のみであることと整合し、ルート直下ページ自体が存在しないため実害なし。リンクは必ず `./` または `../` prefix 付きで書く規約 |

---

## 参考

- `plugins/rite/skills/wiki-lint/SKILL.md` ステップ 7 (壊れた相互参照検出、helper 委譲)
- `plugins/rite/hooks/scripts/wiki-lint-broken-refs.sh` (runtime 実装)
- 本実装の根拠: realpath ベースの相互参照解決が誤検出していた false positive 問題の報告
- GNU coreutils `realpath(1)` man page
