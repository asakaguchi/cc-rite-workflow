# Anchor 命名規約 (Asymmetric Fix Transcription 予防)

> **Charter**: Subject to [Simplification Charter](./simplification-charter.md). Runtime に効かない経緯記述・cycle 番号引用・重複 confirmation は書かない。

対象: `plugins/rite/skills/` 配下の Markdown 文書中に存在する `# === ... ===` 形式の **grep anchor**。本ファイルは anchor literal の構造を定める canonical 規約と、anchor を中心に発生する Wiki 経験則「Asymmetric Fix Transcription (対称位置への伝播漏れ)」failure mode の予防策を集約する。Wiki 経験則本体は `/rite:wiki-query` で参照 (cf. §4)。

> **⚠️ コード層との境界**: 本 reference は anchor の **literal 構造** (文字列としての形態) を規定する。anchor が指し示す bash block の動作仕様・契約は anchor を抱える各文書 (`skills/fix/SKILL.md` / `skills/review/SKILL.md` / `skills/issue-close/SKILL.md`) に存在する。anchor literal を変更する場合は本 reference 更新後に、同 anchor を citation する全 site (note / blockquote / 他 anchor の rationale 段落) を grep で検出し同時更新すること。

---

## 1. anchor の役割

<a id="role"></a>

grep anchor は次の 2 つを満たすために挿入する:

1. **行番号 drift への耐性**: bash block 内に行番号 (`line 1118`, `L1090`) を埋め込まずとも、anchor literal を `git grep` / `grep -F` で機械検索することで citation 経路を再現できる
2. **citation 経路の機械検証**: note / blockquote / 他 anchor の rationale 段落から「あの bash block」を参照するとき、anchor literal の **byte 単位一致** を verify することで cross-reference の整合性を保つ

anchor は **文字列としての検索ターゲット** であり、人間が読む explanatory comment ではない。説明は隣接コメント行・anchor 直前直後の prose 段落に置く。

---

## 2. 基本原則

<a id="basic-principles"></a>

### 2.1 anchor literal は最小化する

anchor 自体は **mechanical literal** として最短形を採用する:

- 採用すべき形式: `# === <subject> <verb-or-state> ===`
- 例: `# === Phase 1.2.0 Selection logic block end ===` (subject = `Phase 1.2.0 Selection logic block`, state = `end`)
- 例: `# === severity_map build ===` (subject = `severity_map`, verb = `build`)
- 例: `# === Loop pre-amble ===`

> **不可分性**: subject を表す noun phrase 内のスペース・連字符は許容するが、anchor literal を後から「補足説明を足したい」モチベーションで拡張してはならない (§3 Anti-pattern 参照)。

### 2.2 文脈情報は隣接コメント行に分離する

「このブロックは何のために存在するか」「どの note から referenced されているか」等の文脈は **anchor の直前または直後のコメント行** に置く:

```bash
# (Block 1, referenced by Block 2 continuity note)
# === Phase 1.2.0 Selection logic block end ===
set +o pipefail
```

(出典: `skills/fix/SKILL.md:1083-1085`)

このパターンでは:

- L1: 文脈コメント (人間が読む、citation 経路を補足)
- L2: anchor literal (機械的に検索される、最短形)
- L3 以降: bash block 本体

文脈コメントは自由に書き換えてよいが、anchor literal は他 site での citation との byte 一致を保つため**容易に書き換えない**。

### 2.3 anchor literal の variant は事前列挙する

同一概念に対し複数 variant が許容される場合 (例: `cycle N` / `cycle-N`)、anchor literal で採用する正準形を本 reference に追記し、grep 検索時は `cycle[ -][0-9]+` のような alternation pattern を併用する。

---

## 3. Anti-pattern

<a id="anti-pattern"></a>

### 3.1 parenthetical context を anchor 内に含める

**禁止形式**:

```bash
# === severity_map build (local_file/explicit_file only — referenced by pr_comment state transitions note) ===
```

(本 anchor は現存しない)

**何が問題か**:

1. **byte-level drift 源**: 括弧内の文脈 (`local_file/explicit_file only — referenced by ...`) は将来書き換えられる可能性が高い。書き換えた瞬間、他 site の note / blockquote が anchor literal を citation していると **byte 不一致** が発生し、cross-reference が silent に壊れる
2. **anchor の役割逸脱**: anchor は grep ターゲットであるべきで、文脈解説の格納場所ではない。文脈を anchor に詰め込むと、機械検索の主たる対象 (subject + verb) が長文の中に埋没する
3. **recursive recurrence in fix layer**: parenthetical 付き anchor を導入すると、後続の fix サイクルで「note 側の citation を anchor literal に合わせる」or 「anchor literal を note 側に合わせる」の 2 方向の対称化作業が発生し、いずれを選んでも fix 自体が次 cycle の drift を生む経路を作る

**canonical 対策**: §2.1 / §2.2 に従い anchor を最小化し、parenthetical 内容を隣接コメント行・直前 prose 段落へ移動する。

### 3.2 anchor literal 内に行番号・PR 番号を埋め込む

**禁止形式**:

```bash
# === severity_map build (see L1090 note) ===
# === Phase 1.2.0 ===
```

**何が問題か**:

- 行番号は drift する (anchor 自体が drift 耐性のために存在するのに自己破壊)
- PR / cycle 番号は経緯記述であり Simplification Charter 違反
- 過去履歴は git log / Wiki 経験則 (`pages/anti-patterns/asymmetric-fix-transcription.md` 等) に集約する

---

## 4. 関連 Wiki 経験則

<a id="related-heuristics"></a>

本 reference の根拠となる経験則は `wiki` ブランチに格納されており、`/rite:wiki-query` でキーワード検索する:

| 経験則タイトル | キーワード例 | 根拠となる文脈 |
|----------------|-------------|---------------|
| Asymmetric Fix Transcription (対称位置への伝播漏れ) | `asymmetric-fix-transcription`, `anchor drift` | fix を 1 箇所に適用したとき同パターンを持つ対称位置に伝播させ忘れる failure mode の包括的記録。本 reference は **recursive recurrence in fix layer** (anchor literal 自身が parenthetical context を含む形で導入され、note との byte 不一致を新規導入する mode) への構造的予防として作成 |
| SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する | `sot-path-reference-existence-check`, `broken-ref` | 本 reference 内の path 参照は各記載時点の origin/develop で実在を verify した上で記載する運用とする。ただし記載後の refactor で参照先 anchor 自体が消滅することがあるため、path 参照は永続的な保証ではなく記載時点のスナップショットである点に注意する |
| Embedded markdown bash block の observability 三要素 | `embedded-bash-block-observability-trio` | anchor を citation する bash block 自体の observability 契約。anchor は observability 設計の一部 (citation 経路を機械検証する手段) として位置付ける |
| Asymmetric Fix Transcription 解決の hub 化戦略 | `option-b`, `hub creation` | anchor literal の drift 源を「両側で同期する」ではなく「anchor を SoT 化し他 site から citation する」hub-creation 戦略の根拠 |

> **Wiki page への直接リンクを使わない理由**: Wiki page (`.rite/wiki/pages/`) は `wiki` ブランチに格納されており、本 reference が存在する `develop` / `main` ブランチからは relative path で解決できない (broken-ref になる)。citation は `/rite:wiki-query` 経由のキーワード検索とし、page slug は変動しても keyword でマッチする運用を採る。

---

## 5. 適用範囲

<a id="scope"></a>

本 reference は **`plugins/rite/skills/` 配下の Markdown 文書中の `# === ... ===` 形式 anchor** にのみ適用する。

適用外:

- shell スクリプト (`plugins/rite/scripts/`, `plugins/rite/hooks/`) のコメント行 — bash 構文として有効なコメントであり anchor として citation されない限り本規約の対象外
- HTML anchor (`<a id="..."></a>`) — Markdown 内 cross-reference 用の slug、本 reference 内でも使用 (§の各冒頭)。命名は kebab-case を維持
- YAML frontmatter / JSON schema key — 別系統の命名規約に従う

新規に `# === ... ===` anchor を導入する PR では本 reference §2 基本原則への準拠を pre-commit 段階で grep verify することを推奨する (audit 自動化は別 Issue 候補)。
