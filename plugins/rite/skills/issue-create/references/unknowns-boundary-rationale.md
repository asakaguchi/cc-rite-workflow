---
description: /rite:unknowns と /rite:issue-create ステップ 4.0/5.0 の役割分担 rationale
---

# unknowns ↔ issue-create の線引き

## 線引き

`/rite:unknowns` と `/rite:issue-create` ステップ 4.0（Assumption Surfacing、ステップ 5.0 も同様）は、どちらも「不確実性を減らす」対話フェーズだが、目的とコストモデルが異なるため統合しない:

| | `/rite:unknowns` | `/rite:issue-create` 4.0/5.0 |
|---|---|---|
| 性質 | 発散的・対話的 | 収束的・Contract 化 |
| 位置づけ | Issue 起票**前**の構想フェーズ | Issue body（Implementation Contract）生成の直前 |
| 終了条件 | 新しい unknown が出なくなる / ユーザーが方向性を確信する | 質問上限（見込み Complexity M 以上で最大 3 問）に達する、または (b) が解消する |
| 出力 | 探索サマリ（構造化されない自由記述の発見の集積） | Section 0-9 の Implementation Contract（構造化された仕様） |
| 質問数の制約 | 明示的な上限なし（往復が前提） | Complexity 連動の上限あり |

## なぜ探索サマリ検出で 4.0/5.0 を丸ごとスキップしないか

探索サマリは「発見の集積」であって「Contract 化された仕様」ではない。4.0/5.0 の質問上限・3 分類・Complexity Gate は Contract の品質を担保する仕組みであり、探索セッションの有無に関わらず必要になる。そのため:

- 探索サマリで既に解決済みの問い（確定したこと・発見した盲点）は 4.0/5.0 の該当手順を**スキップ**する（重複対話の防止）
- 探索サマリでも未解決のまま残った問い（未解決の問い）は 4.0/5.0 の 3 分類へ**合流**させ、Contract 化の一部として扱う
- Contract の Section 構造・AC/Test 数の整合・Complexity Gate は探索サマリの有無に関わらず不変

**前提**: 「発見した盲点」を手順 2（盲点列挙）スキップの根拠として扱えるのは、`/rite:unknowns` の終了判定（[`skills/unknowns/SKILL.md`](../../unknowns/SKILL.md) セクション 3）が「新しい unknown が出なくなった」まで対話を続けた場合に限る。ユーザーが実装に進みたがって探索セッションを早期終了したケースでは、「発見した盲点」に記載されたまま「未解決の問い」へ転記されていない項目が残りうる。探索サマリを書く側（`/rite:unknowns` 実行者）は、セッション終了時点で未解決のまま残る盲点を「未解決の問い」へ転記してからサマリを出力すること（早期終了時ほど転記漏れが起きやすいため要注意）。issue-create 側はこの前提の成立をサマリの記述から検証しない（サマリの構造を信頼する）。

## なぜマッピングロジックを issue-create 側に置くか

探索サマリの形式（Source of Truth）は `/rite:unknowns` 側にあるが、それを Contract のどの Section にマッピングするかは Contract 構造（[`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md)）に依存する消費側の関心事であり、`/rite:issue-create` 側の責務。unknowns 側は出力形式を安定させることにのみ責任を持ち、消費方法には関与しない（疎結合）。
