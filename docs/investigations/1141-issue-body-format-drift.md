# Issue #1141: Issue body 出力フォーマット drift の調査レポート

| 項目 | 値 |
|------|-----|
| 調査日 | 2026-05-26 |
| 対象 Issue | [#1141](https://github.com/B16B1RD/cc-rite-workflow/issues/1141) |
| 調査ブランチ | `docs/issue-1141-issue-body-format-drift` |
| 種別 | コード変更を伴わない調査（修正は別 Issue に切り出し） |

## Summary

`/rite:issue:create` で作成される Issue body の構造が、SoT である `plugins/rite/templates/issue/default.md` の **9 セクション Implementation Contract format** ではなく、`plugins/rite/commands/issue/create.md` Step 4.2 (line 128-147) の **6 セクション inline テンプレート** (What / Why / Where / Acceptance Criteria / Implementation Notes / Out of Scope) に従って生成されている。

Drift の発生経緯は **PR #1079 (commit `6de86343`, 2026-05-23) の "PR 1 — Step A+B sub-skill 廃止と implicit-stop 対策層撤去"** で、Issue 作成フローが「`create.md` orchestrator → `create-register.md` sub-skill が Implementation Contract format を生成」から「`create.md` 単一フロー + inline 6 セクションテンプレート」へ整理された際に、SoT (`templates/issue/default.md` + `template-structure.md`) のみ取り残された。

修正方向は本 Issue のスコープ外（Implementation Notes 指示）で、別 Issue として 3 つの選択肢 (`create.md` を SoT に揃える / SoT を実装に揃える / 中間案) の判断材料を AC-4 セクションに整理する。

---

## AC-1: 最近作成 Issue 5 件 vs 過去 Issue 5 件の body 構造比較

`gh issue view <N> --json body --jq '.body'` で取得した body のトップレベル見出し (`^## `) を採用セクションとして抽出した。

### 最近の Issue（2026-05-24 以降、本 Issue 起票直前まで）

| Issue | 作成日 | Title 抜粋 | 採用セクション (順) | 形式判定 |
|-------|--------|-----------|---------------------|----------|
| [#1131](https://github.com/B16B1RD/cc-rite-workflow/issues/1131) | 2026-05-24 | `docs: SPEC フィールド表の v2→v3 schema drift...` | 概要 / 問題の詳細 / スコープ / 発生元 / 実装ステップ | カスタム (自由形式) |
| [#1134](https://github.com/B16B1RD/cc-rite-workflow/issues/1134) | 2026-05-24 | `docs: flow-state v2→v3 移行 prose / 設計 doc...` | 概要 / 問題の詳細 / スコープ / 発生元 / 実装ステップ | カスタム (#1131 と同型) |
| [#1136](https://github.com/B16B1RD/cc-rite-workflow/issues/1136) | 2026-05-24 | `refactor(workflow): /rite:issue:start を廃止...` | Context / 目指す姿 / レビュー修正ポリシー / 主要な変更 / 受け入れ条件 / リスクと緩和 / ロールバック戦略 / 補足 | カスタム (大型 refactor 専用) |
| [#1138](https://github.com/B16B1RD/cc-rite-workflow/issues/1138) | 2026-05-25 | `docs: v0.5.0 リリース前の公式ドキュメント見直し` | What / Why / Where / Acceptance Criteria / Implementation Notes / Out of Scope / 実装ステップ | **6 セクション inline + 追加 1 (`## 実装ステップ` は手動追加されたチェックリストで inline テンプレ外)** |
| [#1140](https://github.com/B16B1RD/cc-rite-workflow/issues/1140) | 2026-05-25 | `fix(pr): /rite:pr:fix の Phase 2.2.A 俯瞰...` | What / Why / Where / Acceptance Criteria / Implementation Notes / Out of Scope | **6 セクション (create.md inline 一致)** |

### 過去の Issue（2026-04-26 より前、本 Issue 起票から 1 ヶ月以上前）

| Issue | 作成日 | Title 抜粋 | 採用セクション (順) | 形式判定 |
|-------|--------|-----------|---------------------|----------|
| [#669](https://github.com/B16B1RD/cc-rite-workflow/issues/669) | 2026-04-25 | `fix(workflow): /rite:issue:start から派生する Issue...` | Meta / 1. Goal / 2. Scope / 3. Bug Details / ... | **9 セクション Implementation Contract** |
| [#662](https://github.com/B16B1RD/cc-rite-workflow/issues/662) | 2026-04-25 | `fix(workflow): LLM が context 残量を推論して...` | Type/Complexity/Priority (Meta 簡略) / 1. Goal / 2. Scope / 3. Bug Details / ... | **9 セクション Implementation Contract** |
| [#658](https://github.com/B16B1RD/cc-rite-workflow/issues/658) | 2026-04-24 | `fix(pr-cleanup): Issue クローズ時に Projects Status...` | 概要 / 背景 / Meta / 1. Goal / 2. Scope / 3. Bug Details / ... | 9 セクション IC + 序文 (混合) |
| [#650](https://github.com/B16B1RD/cc-rite-workflow/issues/650) | 2026-04-24 | `fix(pr-cleanup): wiki:ingest sub-skill return 後...` | 概要 / 関連 / Meta / 1. Goal / 2. Scope / 3. Bug Details / ... | 9 セクション IC + 序文 (混合) |
| [#639](https://github.com/B16B1RD/cc-rite-workflow/issues/639) | 2026-04-21 | `docs(spec): reflect v1.0.0+ plugin structure...` | 背景 / やること / 受入条件 / 関連 | カスタム (自由形式) |

### 集計

| グループ | Implementation Contract 形式 (完全一致 + 序文混合含む) | 6 セクション inline 形式 (完全一致 + 拡張含む) | カスタム/自由形式 |
|---------|------------------------------|--------------------------|--------------------|
| 最近 5 件 (#1131-#1140) | 0 件 | **2 件** (#1140 = 完全一致 / #1138 = inline + `## 実装ステップ` 拡張 1) | 3 件 (#1131, #1134, #1136) |
| 過去 5 件 (#639-#669) | **4 件** (#669, #662, #658, #650) | 0 件 | 1 件 (#639) |

**観察**: PR #1079 (2026-05-23) の前後で Implementation Contract 形式が消え、6 セクション inline 形式と自由形式に切り替わっている。Implementation Contract → 6 セクション/自由形式の方向性が明確に出ている。

---

## AC-2: `commands/issue/create.md` Step 4.2 と `templates/issue/default.md` のセクションレベル差分

### SoT: `templates/issue/default.md` + `template-structure.md` (9 セクション Implementation Contract)

| # | Section | XS | S | M | L | XL | Source |
|---|---------|-----|-----|-----|-----|-----|--------|
| 0 | Meta (Type/Complexity/Parent) | M | M | M | M | M | `template-structure.md:13` |
| 1 | Goal (+ Non-goal) | M | M | M | M | M | `template-structure.md:21` |
| 2 | Scope (In/Out) | M | M | M | M | M | `template-structure.md:33` |
| 3 | Type Core Section (Feature/BugFix/Refactor/Chore/Docs のいずれか) | S | M | M | M | M | `template-structure.md:47-118` |
| 4 | Implementation Details (4.1-4.5 parent) | M | M | M | M | M | `template-structure.md:120-184` |
| 5 | Acceptance Criteria (Given/When/Then) | M | M | M | M | M | `template-structure.md:186-220` |
| 6 | Test Specification (T-xx 表) | O | S | M | M | M | `template-structure.md:222-247` |
| 7 | Important Conventions (CLAUDE.md 引用) | O | S | M | M | M | `template-structure.md:249-263` |
| 8 | Definition of Done (checklist) | M | M | M | M | M | `template-structure.md:265-275` |
| 9 | Decision Log | O | O | S | M | M | `template-structure.md:278-284` |

`default.md` には Complexity Gate 表（M/S/O 必須度マトリクス）と Type 別の Type Core 分岐ルールが含まれる。`template-structure.md` には各セクションの具体的テンプレート (`{placeholder}` 形式) が記載されている。

行 4 は Implementation Details 全体の parent 行で `default.md:37` と同じく全 Complexity で **M**。section 全体としては Acceptance Criteria や Goal と同じく必須セクションだが、内部の sub-section 4.1〜4.5 で個別に必須度が分岐する。詳細は `default.md:38-42`:

- 4.1 Target Files / 4.4 Behavioral Requirements: 全 Complexity で M (parent と一致)
- 4.2 Non-Target Files: XS=S / S 以上は M
- 4.3 Interface / Data Contract / 4.5 Error Handling: XS=O / S=S / M 以上は M

### Implementation: `commands/issue/create.md` Step 4.2 line 128-147 (6 セクション inline)

```markdown
## What
{what}

## Why
{why}

## Where
{where}

## Acceptance Criteria
- [ ] AC-1: {ac1}
- [ ] AC-2: {ac2}

## Implementation Notes
{notes_if_any}

## Out of Scope
- {out_of_scope_if_any}
```

### セクションレベルの差分表

| SoT セクション | create.md Step 4.2 inline 対応 | drift 種別 |
|---------------|--------------------------------|------------|
| 0. Meta (Type/Complexity/Parent) | **欠落** | dropped |
| 1. Goal (Non-goal 含む) | `## What` のみ (Non-goal 欠落) | partial / renamed |
| 2. Scope (In Scope / Out of Scope) | `## Where` (In Scope 相当のみ) + `## Out of Scope` | split + renamed |
| 3. Type Core Section (Feature/BugFix/Refactor/Chore/Docs 分岐) | **欠落** | dropped (Type 識別子なし) |
| 4. Implementation Details (4.1-4.5) | `## Implementation Notes` (自由記述、構造化なし) | flatten + downgrade |
| 5. Acceptance Criteria (Given/When/Then) | `## Acceptance Criteria` (構造ルール明示なし) | format spec lost |
| 6. Test Specification (T-xx 表) | **欠落** | dropped |
| 7. Important Conventions | **欠落** | dropped |
| 8. Definition of Done | **欠落** | dropped |
| 9. Decision Log | **欠落** | dropped |
| (SoT になし) | `## Why` (動機セクション、SoT では 1. Goal に統合) | added |

**ギャップサマリー** (Section 0 Meta は「メタヘッダ」扱いで本体 1-9 と区別する立場で記載。Summary 節 / AC-2 SoT heading / AC-3 史的説明等の「9 セクション」表記と一貫):
- SoT 本体 9 セクション (1. Goal 〜 9. Decision Log) + Meta ヘッダ中、create.md Step 4.2 では **Meta + 5 本体セクションが完全欠落** (Meta / Type Core / Test Spec / Important Conventions / Definition of Done / Decision Log)
- 残り 4 本体セクション (Goal / Scope / Implementation Details / AC) は名称・構造ともに drift
- create.md Step 4.2 にしかない `## Why` セクションは、SoT では `1. Goal` の本文に統合されており、本来は独立セクションではない
- Complexity Gate（XS/S/M/L/XL ごとの MUST/SHOULD/OMIT）が create.md 側に存在しないため、生成 body の必須度ロジックは inline テンプレでは適用されない

---

## AC-3: drift の発生経緯（git log ベース）

### `commands/issue/create.md` の変更履歴（直近）

```
0dee5b22 refactor(workflow): /rite:issue:start を廃止し /rite:pr:{open,iterate,merge} に分解 (#1136) (#1137)  ← 2026-05-24
a6311288 refactor(workflow): PR 2b — workflow-incident-emit.sh 撤去と全 caller 削除 (#1091)                ← 2026-05-23
b6272a7e refactor(workflow): PR 2a — phase enum 簡素化 + flow-state.sh 新設 (#1089)                       ← 2026-05-23
6de86343 refactor(workflow): PR 1 — Step A+B sub-skill 廃止と implicit-stop 対策層撤去 (#1079)              ← 2026-05-23  ★ Divergence point
832c29c8 fix(workflow): add Stop event hook back-stop for create-interview implicit stop (#920)            ← 2026-05-15
...
```

### `templates/issue/default.md` の変更履歴

```
6de86343 refactor(workflow): PR 1 — Step A+B sub-skill 廃止と implicit-stop 対策層撤去 (#1079)  ← 2 行のみ変更
abec75de fix(create): #801 PR 7/8 cycle 2 review 5 cosmetic 対応
5002fa16 fix(create): #801 PR 7/8 cycle 1 review 6 findings 対応
4ca5da50 fix(review): #773 PR 4/8 — レビュー指摘 F-01/F-02 対応
9f7d9286 Merge pull request #713 from B16B1RD/fix/issue-709-low-medium-cross-file-impact
4502a9e2 Initial commit: Rite Workflow v0.1.0
```

### Divergence point: `6de86343` (PR #1079, 2026-05-23)

**コミットメッセージ抜粋**:

> refactor(workflow): PR 1 — Step A+B sub-skill 廃止と implicit-stop 対策層撤去
>
> * refactor(issue/start): consolidate 9 sub-skills into single flat workflow
>
>   start.md (891L) を「ステップ 1〜8」のシンプルな単一フローに再構成し、9 sub-skill の核心機能を inline 化した。

このコミットでの drift の発生メカニズム:

1. **PR #1079 以前**: `create.md` は orchestrator として動作し、`create-register.md` sub-skill を呼び出していた。`create-register.md` 内には「Issue Body Generation (Implementation Contract Format)」セクションが存在し、SoT (`templates/issue/default.md` + `template-structure.md`) を実際に読みに行く設計で 9 セクション形式の body を生成していた（commit `832c29c8` 時点の `create-register.md` 内 line 196 で "Implementation Contract Format" 明示）。
2. **PR #1079 で**: 9 sub-skill (Step A + Step B 系) を `start.md` / `create.md` に inline 化する大規模リファクタが行われた。`create.md` は 695 行差分の全面書き換えで、Step 4.2 として **新規の 6 セクション inline テンプレ** が導入された。
3. **PR #1079 後**: `create-register.md` の Implementation Contract Format 生成ロジックは消滅し、代わりに `create.md` Step 4.2 inline テンプレが実行時の唯一の体となった。一方で SoT (`templates/issue/default.md` + `template-structure.md`) は 2 行の軽微な編集のみで本質的に変更されず、9 セクション形式の定義が残った。

### 補強観察

- Divergence の同コミット (`6de86343`) で `default.md` は **2 行のみ変更**（実質ノーチェンジ）。Inline 化リファクタの際、SoT との対応取りが省略されたことが drift の機械的原因。
- Implementation Contract format への移行自体は `4ca5da50` (Issue #773 のサブ PR `4ca5da50` — commit message の "#773 PR 4/8" は「Issue #773 内の 4 番目 PR」を意味する慣用表記。`default.md` を大幅刷新) で行われたと推定されるが、当時の `create-register.md` は IC format を生成していたため drift は発生していなかった。
- 言い換えると、**SoT は IC format を保持したまま、その消費者（実装側 inline テンプレ）が旧 6 セクション形式に書き戻された**のが本 drift の本質。

---

## AC-4: 修正方向の判断材料

3 つの選択肢それぞれについて「影響範囲 / 既存 Issue 互換性 / 利用者観点」の判断材料を整理する。

### 選択肢 A: `create.md` を SoT (`templates/issue/default.md`) に揃える（IC format 復活）

| 観点 | 判断材料 |
|------|---------|
| 影響範囲 | `create.md` Step 4.2 を `template-structure.md` の 9 セクションテンプレに差し替え + Complexity Gate (XS/S/M/L/XL × M/S/O) ロジックを Step 4.2 に組み込む。create.md は既に 576 行規模で、IC format 化は本質的に 100+ 行追加の見込み（PR #1079 で削減した分が戻る）。 |
| 既存 Issue 互換性 | 新規 Issue から IC format に切り替わる。既存 Issue body の遡及書換は Out of Scope (本 Issue Implementation Notes 指示)。後続コマンド (`/rite:pr:open` ステップ 1.3 Issue 品質評価 / ステップ 3.1 Issue 内容分析 — Acceptance Criteria 抽出 等) は `## Acceptance Criteria` 見出しを期待するが、IC format の `## 5. Acceptance Criteria` でも `^## .*Acceptance Criteria` パターンであれば match できる（`commands/pr/open.md` の heading match rules 確認要）。`## Where` (旧) → `## 2. Scope` (新) の置換で「Where」を参照している箇所 (例: `commands/issue/create.md` Step 1.3 入力解析) との整合性確認が必要。 |
| 利用者観点 | IC format は構造化情報量が多い（Type Core / Test Spec / Definition of Done 等）が、坂口さん自身が手動編集する Issue でも 9 セクション全部を埋めるのは負荷が高い。Complexity Gate で XS/S 時の omit ルールが効くため、軽量 Issue では 4-5 セクションに収まる設計。LLM が body を生成する場合、9 セクション分の placeholder を埋めるコストは増加。 |

### 選択肢 B: SoT (`templates/issue/default.md`) を実装 (`create.md` Step 4.2) に揃える（6 セクション化）

| 観点 | 判断材料 |
|------|---------|
| 影響範囲 | `templates/issue/default.md` (105 行) と `template-structure.md` (289 行) を 6 セクション形式に書き換え。Complexity Gate / Type Core / Test Spec 等の構造化機能は削除。`commands/issue/references/complexity-gate.md`, `commands/issue/references/contract-section-mapping.md` 等の関連 reference も sweep 対象。 |
| 既存 Issue 互換性 | 既に最近の Issue (#1138, #1140 等) は 6 セクション形式で揃っているため、format の連続性は最も高い。過去の IC format Issue 群 (#669, #662, #658, #650 等) は body 構造が異なるが、本 Issue Implementation Notes で遡及書換は Out of Scope。 |
| 利用者観点 | LLM/手動どちらでも記述コストが低く、What/Why/Where/AC の 4 つを埋めれば最低限成立する。複雑な Issue では Implementation Notes 内で自由記述する余地がある。Type Core / Test Spec を失うため、BugFix の reproduction 手順や Refactor の Before/After interface などの構造化が弱くなる。 |

### 選択肢 C: 中間案

| サブ案 | 内容 | トレードオフ |
|--------|------|-------------|
| C-1: SoT を IC format に保ちつつ「常時 MUST セクションのみ強制」 | Complexity Gate を簡略化し、すべての Complexity で Meta / Goal / Scope / AC / Definition of Done の 5 セクションを MUST、残り 4 セクションは OMIT デフォルト + 利用者明示時のみ含める | 9 セクションテンプレの利点 (構造化) を保ちつつ、6 セクション現状とほぼ同等の最小要件にできる。Complexity Gate の M/S/O マトリクスは縮退する。 |
| C-2: SoT を 6 セクション化 + 「拡張オプション」として IC format を別テンプレに残す | `default.md` を 6 セクション化、`extended-contract.md` を別ファイルで保管。`/rite:issue:create` に `--contract` flag を導入 | 標準ユースケースは軽量、IC format 必要時は明示的に opt-in。flag 1 つ追加 + テンプレファイル 1 つ追加で実装可能。 |
| C-3: create.md 側で `template-structure.md` を実 runtime 読み込みする復活 | PR #1079 以前の `create-register.md` 方式に戻す（template ファイルから読んで render） | inline の単純さは失うが、SoT 単一管理になり drift 不能。create.md のサイズは増えない（template が外部化されたまま）。PR #1079 の simplification 方針と衝突する可能性。 |

### 推奨判断のための補助情報

- **直近の利用者意向**: 本 Issue 自体が 6 セクション形式 (`## What / Why / Where / Acceptance Criteria / Implementation Notes / Out of Scope`) で起票されている。坂口さん自身が IC format ではなく 6 セクション形式を選好している可能性。
- **後続コマンドの依存**: `/rite:pr:open` Step 1.3 (Issue 品質評価) は **What/Why/Where/Scope** の 4 軸で評価する設計 (本 Issue 起票時に確認)。これは 6 セクション inline 形式に親和的で、IC format に切り替える場合は評価基準を `Goal / Scope / Type Core / Acceptance Criteria` 等へ rewire する必要がある。
- **simplification charter (PR #1079) の方針**: 「単一 flat workflow」「implicit-stop 対策層撤去」「シンプル化」が PR #1079 の明示的な目的だった。IC format 復活は charter の方向と逆行する可能性があり、合意の確認が必要。

---

## Recommendation

本 Issue の Implementation Notes (「実際の修正は別 Issue に切り出す」) に従い、修正自体は本レポートのスコープ外とする。以下を別 Issue として起票することを推奨する:

1. **本命 Issue**: 「Issue body フォーマット drift の修正方向決定 (選択肢 A/B/C の選定)」
   - 上記 AC-4 の選択肢 A / B / C (C-1 / C-2 / C-3) を `AskUserQuestion` 形式で坂口さん判断仰ぐ
   - 選定後、追従 Issue (sub-issue or follow-up) で具体的書換を実施
2. **依存清掃 Issue (オプション)**: `/rite:pr:open` / `/rite:issue:update` / `/rite:issue:edit` 等の他 Issue 系コマンドが期待する body 構造との整合性チェック
   - 特に `/rite:pr:open` ステップ 1.3 (Issue 品質評価 — What/Why/Where/Scope 充足度で A-D 評価) と ステップ 3.1 (Issue 内容分析 — What/Why/Where/Acceptance Criteria 抽出) の対応
3. **SoT 集約 Issue (オプション)**: 選択肢 C-3 (template-structure.md を runtime 読み込み復活) を取らない限り、SoT は `commands/issue/create.md` Step 4.2 inline に移ることになる。`templates/issue/default.md` / `template-structure.md` の deprecation or archive 計画

---

## 補足: 調査時に使用した主なコマンド

```bash
# Section 構造の抽出
gh issue view <N> --json body --jq '.body' | grep -E '^##'

# 過去 Issue サンプリング
gh issue list --state all --search "created:<2026-04-26" --limit 30 --json number,title,createdAt

# git log で divergence point 探索
git log --oneline --follow -- plugins/rite/commands/issue/create.md
git log --oneline --follow -- plugins/rite/templates/issue/default.md

# 過去スナップショット比較
git show 4502a9e2:plugins/rite/templates/issue/template-structure.md | grep -E '^##|^###'
git show 6de86343:plugins/rite/commands/issue/create.md | sed -n '/### 4.2 Issue Body 生成/,/### 4.3/p'
git show 832c29c8:plugins/rite/commands/issue/create-register.md | sed -n '/Phase 2.2/,/Phase 2.3/p'

# diff 統計
git show --stat 6de86343 | grep -E "issue/create.md|issue/default.md|issue/template-structure"
```
