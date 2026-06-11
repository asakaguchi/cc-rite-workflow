# Implementation Contract Section Mapping — Type → Section 3 / Perspective → Section 1-9

> **SoT scope**: Issue body の rich template (Section 1-9 structure) における **Type → Section 3 mapping** と **Perspective → Section 1-9 mapping** の rubric。`templates/issue/default.md` から SoT として参照される。`create.md` ステップ 4.2 はこの rubric に従い Implementation Contract (Section 0-9) を生成する（Complexity Gate で確定 Complexity に応じてセクションをスケールする）。`create.md` ステップ 1.3 / 4.1 で得た入力をどの Section に反映するかは本 reference の Step 2-3 と Section Inclusion Rules で定める。

## 位置づけ

Rich template (Section 1-9) を生成する場合の 4 step 構成:

| Step | 役割 | SoT |
|------|------|-----|
| Step 1 | Apply Complexity Gate (MUST/SHOULD/OMIT 判定) | [`complexity-gate.md`](./complexity-gate.md) |
| Step 2 | Select Type Core Section (Section 3) | 本 reference |
| Step 3 | Map Perspective inputs to Sections (Section 1-9) | 本 reference |
| Step 4 | Section template 適用 | [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) |

## Implementation Contract Section 1-9 概観

`templates/issue/template-structure.md` で定義される rich Issue body の section 構成:

| Section | 名称 | 主な内容 |
|---------|------|---------|
| 0 | Meta | Type / Complexity / Parent Issue (任意) |
| 1 | Goal | Goal / Non-goal |
| 2 | Scope | In Scope / Out of Scope |
| 3 | Type Core Section | Type に応じた core section (Step 2 で 1 つ選択) |
| 4.1 | Target Files | 変更対象ファイルリスト |
| 4.2 | Non-Target Files | MUST NOT modify 対象 |
| 4.3 | Interface / Data Contract | Before / After |
| 4.4 | Behavioral Requirements | MUST / SHOULD / MAY / MUST NOT |
| 4.5 | Error Handling / Constraints | Error Condition × Expected Behavior |
| 5 | Acceptance Criteria | Given / When / Then 形式の AC リスト |
| 6 | Test Specification | T-xx ID と Related AC mapping |
| 7 | Important Conventions | CLAUDE.md からの MUST/MUST NOT 抜粋 (max 5) |
| 8 | Definition of Done | 完了条件チェックリスト |
| 9 | Decision Log | 実装中の意思決定記録 |

各 Section の正規 template は [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md)、Complexity Gate の MUST/SHOULD/OMIT 判定は [`complexity-gate.md`](./complexity-gate.md) を参照。

## Step 2: Type → Type Core Section (Section 3) Mapping

`create.md` ステップ 4.1 の AskUserQuestion で確定した Type に基づき、Section 3 として include する Type Core Section を選択する:

| Type | Section 3 内容 | template-structure.md 内 subsection |
|------|---------------|------------------------------------|
| Feature | User Scenarios | [`3-Feature: User Scenarios`](../../../templates/issue/template-structure.md#3-feature-user-scenarios) |
| BugFix | Bug Details (Reproduction / Root Cause Hypothesis) | [`3-BugFix: Bug Details`](../../../templates/issue/template-structure.md#3-bugfix-bug-details) |
| Refactor | Before / After Contract / Compatibility Policy | [`3-Refactor: Before / After Contract`](../../../templates/issue/template-structure.md#3-refactor-before--after-contract) |
| Chore | Operational Context | [`3-Chore: Operational Context`](../../../templates/issue/template-structure.md#3-chore-operational-context) |
| Docs | Documentation Target | [`3-Docs: Documentation Target`](../../../templates/issue/template-structure.md#3-docs-documentation-target) |

**Type 判定の優先順位**: Labels > title keywords > body content analysis。`create.md` ステップ 4.1 の AskUserQuestion option (`feat / fix / docs / refactor / chore`) は LLM がこの優先順位で推定したものを提示する。

## Step 3: Perspective → Target Sections Mapping

`create.md` ステップ 1.3 (What/Why/Where 抽出) + ステップ 4.1 (AskUserQuestion 確認) で得られた input を、Section 1-9 のどの section に反映するかの mapping:

| Perspective | Target Sections |
|-------------|----------------|
| Technical Implementation | 4.1 Target Files / 4.3 Interface / Data Contract / 4.4 Behavioral Requirements |
| User Experience | 1 Goal / 3 Type Core (Feature scenarios) / 5 AC (Happy Path) |
| Edge Cases | 5 AC (Boundary / Error) / 6 Test Specification |
| Existing Feature Impact | 2 Scope (Out) / 4.2 Non-Target / 4.4 MUST NOT |
| Non-Functional Requirements | 4.5 Error Handling / Constraints / 5 AC (NFR outcome) / 6 Test Specification |
| Tradeoffs | 1 Non-goal / 4.4 SHOULD / MAY / 9 Decision Log |

逆方向 mapping (section から perspective を引く) が必要な場合は本表の右列を起点に検索する。

## Section Inclusion Rules

Step 2 で Section 3 を確定し、Step 3 で input を section に mapping した後、各 section の include / omit / placeholder 挿入を以下の rule で決定する:

| Condition | Behavior |
|-----------|----------|
| Perspective に対応する情報が input から取得できなかった | Target sections を omit (Complexity Gate で MUST 指定でない限り) |
| Perspective に対応する情報が input から取得できた | Target sections に input 結果を populate |
| Section が MUST だが input data なし | Section に placeholder comment (`<!-- 情報未収集 -->`) を含めて include |
| Sub-Issue decompose path で `docs/designs/{slug}.md` が生成された場合 | 該当 design doc の内容を Section 4 (Implementation Details) の design context として include |

**MUST/SHOULD/OMIT の判定基準**: [`complexity-gate.md#complexity-heuristics-scoring`](./complexity-gate.md#complexity-heuristics-scoring) と [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) の Complexity Gate 表を参照。Complexity (XS/S/M/L/XL) ごとに各 section の include 必須度が決定される。

## 関連参照

- [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) — Section 1-9 の正規 markdown template
- [`templates/issue/default.md`](../../../templates/issue/default.md) — Complexity Gate / Type 定義の overview
- [`complexity-gate.md`](./complexity-gate.md) — Complexity (XS/S/M/L/XL) 判定基準と MUST/SHOULD/OMIT mapping
