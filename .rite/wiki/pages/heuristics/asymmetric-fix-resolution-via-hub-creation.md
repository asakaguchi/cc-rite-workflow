---
title: "Asymmetric Fix Transcription の解決は両側修正 (Option A) より hub 化 + 責務分離文書化 (Option B) を選ぶ"
domain: "heuristics"
created: "2026-05-06T04:50:00Z"
updated: "2026-05-07T00:30:00+09:00"
sources:
  - type: "retrospectives"
    ref: "raw/retrospectives/20260506T040636Z-issue-851.md"
  - type: "reviews"
    ref: "raw/reviews/20260506T035708Z-pr-858.md"
  - type: "reviews"
    ref: "raw/reviews/20260506T135719Z-pr-867.md"
tags: ["asymmetric-fix-transcription", "hub-creation", "single-source-of-truth", "responsibility-separation", "structural-drift-prevention", "option-selection-meta-heuristic", "bullet-list-threshold"]
confidence: medium
---

# Asymmetric Fix Transcription の解決は両側修正 (Option A) より hub 化 + 責務分離文書化 (Option B) を選ぶ

## 概要

[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) (対称位置への伝播漏れ) を解決する際、自然な選択肢は (A) 両側に同じ参照や fix を追加して symmetry を物理的に保つことだが、これは将来の drift 経路を温存する。代替案として (B) 一方を **hub (Single Source of Truth)** と宣言し、もう一方の責務範囲を明示的に narrow して「両者は別 layer の責務」と文書化することで、symmetry 自体を構造的に不要にできる。Option B は (a) DRY 違反を回避し、(b) 「将来同類の drift を提案する人」を SoT 行を通じて構造的に retract できるため、累積防御の収束効率が高い。

## 詳細

### 発生状況の例 (Issue #851)

`commands/issue/create-interview.md` の line 307 が Output rules の SoT で、line 27/247 にある bash block コメントは line 307 で定義された rule を参照する。PR #850 で line 307 に新しい test references を追加した際、line 27/247 の bash block コメントへの逆参照伝播を忘れた典型的な Asymmetric Fix Transcription pattern が発生。

### 2 つの解決オプション

| オプション | 内容 | 長期コスト |
|---|---|---|
| **Option A — 両側修正 (symmetric replication)** | line 27/247 の bash block コメントにも line 307 と同じ test references を追加し、3 箇所で同期維持 | 同期させる site が N 増えるごとに drift 発生確率が線形 (場合により組合せ的) に増加。N=3 でも drift で N+1 cycle の review-fix loop に膨らむ実例 (PR #548 の `21→17→2→7→3→0`) |
| **Option B — hub 化 + 責務分離文書化** | line 307 を「両 test の hub」と明示し、bash block コメント側 (line 27/247) は責務 (bash 引数 symmetry) のみ inline 言及。HTML literal symmetry など他の test 参照は **本セクションを single source として参照する責務分離**を明示的に文書化 | 同期 site 数を 1 に削減。さらに「責務分離の文書」自体が、将来 bash block コメントへ test references を追加しようとする drift 提案を **SoT 行を通じて構造的に retract** する。drift 経路を物理的に閉塞 |

### Option B が構造的に優位な理由

1. **DRY 違反の回避**: Option A は同じ意味を 3 箇所に literal copy する DRY 違反。Option B は 1 hub に集約。
2. **drift 経路の物理的閉塞**: 単に hub 化するだけでなく「bash block 側コメントは bash 引数 symmetry のみを inline 言及し、HTML literal symmetry は本セクションを single source として参照する責務分離を維持」という **責務範囲の明示文書** がカギ。これにより将来「両側にも書こう」という refactor 提案は、SoT 文書を読んだ瞬間に「責務分離契約に反する」と判定可能になり、drift が proposal 段階で止まる。
3. **minimal-diff doc PR で完結**: Option B の実装は 1 line edit (line 307 prose の hub 明示追加) で済むため、PR #858 のように 1 line minimal-diff doc PR として fast-track 可能。

### Option B 採用時の落とし穴 (PR #862 で実測)

Option B の hub 化は新しい SoT を作るため、**hub 自身の構造**が後続の review 対象になる。PR #858 で line 307 prose に hub 明示を 1 line 追加したところ、parenthetical 末尾の `):` が「半角 `)` + 半角 `:`」と「list 始端 colon」を兼ねる二重役割となり、style drift として LOW 推奨で再指摘された。これは hub 化の効果を否定するものではなく、**hub 行の prose 構造そのものが新たな品質ゲート対象になる**ことを示している。Option B の採用判断と並行して、hub 行の prose style (parenthetical 構造、style 統一) も style guide 対象に含めるべき。

### Option B 採用の判断基準

以下を全て満たすケースで Option B を選ぶ:

1. **hub 化対象の概念が単一 source-of-truth として記述可能**: 例 — test references / API 契約 / state machine 定義。物理的に分散せざるを得ない値 (例: 各 phase の literal 数値) には不適。
2. **責務分離が自然言語で明示記述可能**: 「A は X のみ、B は Y のみ参照」のような 1-2 文で記述できる責務分割であること。記述に複数段落必要なら hub 化のメリットは薄い (読者が責務境界を即座に理解できないため drift 防止効果が落ちる)。
3. **caller / consumer 数が小さく追跡可能**: 数百の caller がある場合は両側修正でも管理コストは同等になり、hub 化の delta 価値が減衰する。

### 実測収束 (Issue #851 → PR #858 → 関連 LOW 推奨 #859/#860/#861)

- **PR #858** (Option B 実装) — 1 line 最小差分 doc PR、両 reviewer (prompt-engineer + code-quality) で 0 blocking findings、merge 完了
- **PR #862** (PR #858 で導入された hub 行 prose の style 統一) — `**Output rules** (...):` parenthetical を `**Output rules**:` 独立行スタイルに分解、0 findings
- **scope 外 LOW 推奨を別 Issue 化** — prompt-engineer reviewer の 3 件の LOW 推奨は scope を超えるため #859/#860/#861 として登録。doc PR でも `rejected(scope-creep)` 判断ではなく followup-issue 化で記録する規律を維持

### Sub-pattern — hub 行が 3+ test を参照したら inline 連結から bullet list へ refactor する (PR #867 / Issue #854)

Option B の hub 化が成功した後、後続 PR で hub 行に test references が累積していくフェーズが訪れる。**inline 連結のまま 3 つ目の test reference を追加すると 1 段落が約 280 字を超えて各 test の責務境界が読み取りづらくなる**ため、PR #867 で「**3 件以上**で bullet list 化」を判断基準として明示文書化し事前 refactor を実施した。

**判断基準** (本 sub-heuristic の中核):

| test 参照数 | 表記方式 | 根拠 |
|---|---|---|
| 1 件 | inline (1 文中で完結) | 単一 test なら誤読リスクなし |
| 2 件 | inline 連結を許容 | 約 200 字以下で責務境界が文中の `かつ` / `および` で示せる |
| **3 件以上** | **bullet list 形式 + 各 bullet で responsibility を 1 行記述** | inline 連結だと 1 段落が約 280 字を超え、各 test の責務 (何を grep 検査するか / NEGATIVE か POSITIVE か) が文中で混線する |

**bullet 化が drift-prevention 効果を保つ条件**:

1. **判断基準の inline blockquote 文書化**: bullet list 自身に「将来 4+ test が追加された場合も bullet 維持」を blockquote で明記する。これにより hub 行が「単一 paragraph に戻す refactor 提案」を SoT を通じて構造的に retract する (Option B の元の設計原則の継承)
2. **test 側不変条件の独立性**: hub 行の prose 構造に test が依存しないこと (各 test が grep ベースの structural assertion で書かれており、line 番号 / paragraph 構造に依存しない) を pre-refactor verify。PR #867 では 3 test (`4-site-symmetry` / `caller-html-literal-symmetry` / `responsibility-separation`) すべて bullet list 化後も PASS することを手元実行で確認
3. **責務分離 test の POSITIVE check 維持**: `responsibility-separation.test.sh` は prose 内に `caller-html-literal-symmetry` 文字列が残っていることを POSITIVE check するため、bullet 化しても文字列自体は保持されることを確認
4. **0-finding clean review**: bullet 化が「ただの可読性改善」(機能変更なし) であることを両 reviewer (prompt-engineer / code-quality) で 0 blocking findings 確認 → 1 cycle 完了

**Option B → bullet list 化の 2 段階 evolution**:

- Stage 1 (PR #858, Issue #851): hub 化 + 責務分離宣言 — drift 経路を SoT 文書化で構造的閉塞
- Stage 2 (PR #867, Issue #854): hub 行が複数 test を参照する状態が 3 件以上に成長したら bullet list 化 — 可読性低下による「責務境界の誤読 → 後続 fix の drift 」を予防

両 stage を通じて Option B は「**初期 hub 化**で symmetry 経路を閉塞」+「**bullet list 化**で hub 行自体の可読性を維持」の 2 段階で運用され、累積防御として機能する。

### Mitigation — Option B 採用 PR の review checklist

1. **hub 行の prose style verification**: hub を新設する 1-line doc PR では、追加した行の parenthetical / colon / 強調記号の二重役割が起きていないかを sibling site (同 file 内の他 SoT 行) と比較
2. **責務分離記述の grep 可能化**: 「本セクションを single source として参照する」のような責務分離宣言は grep 可能な canonical phrase で書く (将来 lint pattern として再利用可能)
3. **既存 test の baseline 維持**: doc PR でも関連 test (本ケースでは `4-site-symmetry.test.sh` / `caller-html-literal-symmetry.test.sh`) を実行し、test の grep pin が prose 文字列に依存していないかを確認

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [DRIFT-CHECK ANCHOR は semantic name で参照する (line 番号 literal 不使用)](../patterns/drift-check-anchor-semantic-name.md)
- [State Machine の dual-location 同期は SoT 化で構造的に閉塞する](../patterns/state-machine-dual-location-sync.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](./identity-reference-documentation-unification.md)

## ソース

- [Issue #851 close retrospective (Option B hub 化採用の判断記録)](../../raw/retrospectives/20260506T040636Z-issue-851.md)
- [PR #858 review (1-line minimal-diff doc PR で SoT 化を実装、0 blocking findings)](../../raw/reviews/20260506T035708Z-pr-858.md)
- [PR #867 review (Issue #854: hub 行が 3+ test 参照に成長した時点で inline 連結から bullet list 化、両 reviewer 0 findings)](../../raw/reviews/20260506T135719Z-pr-867.md)
