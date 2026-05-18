# Completion Report (Phase 5.6)

> **Source**: Extracted from `start-finalize.md` Phase 5.6 (originally in `start.md` before PR G2 #904 moved Phase 5.5-Termination to the start-finalize sub-skill). This file is the source of truth for the completion report procedure.

Execute the following steps **in order**. Do NOT skip any step. Always base your output on the template file read in Step 1 (or the inline fallback below if the Read tool fails).

**Step 1 — Read template** (MANDATORY):

Use the Read tool to read `{plugin_root}/templates/completion-report.md`. Select the appropriate section:
- PR created → **"一気通貫フロー完了時のフォーマット（Phase 5.6 用）"** section
- PR not created → **"PR 未作成時のフォーマット（エッジケース）"** section

If the Read tool fails, proceed to Step 2 using the inline fallback below instead.

**Step 2 — Substitute placeholders**:

Using the template content you just read in Step 1, replace **only** `{...}` placeholders with actual values. Do NOT alter table structure, headings, row order, or add/remove any rows.

| Placeholder | Value Source |
|-------------|-------------|
| `{number}`, `{title}` | Issue info from Phase 0.1 |
| `{owner}`, `{repo}` | Repository info from pre-Phase 0.1 |
| `{pr_number}` | PR number from Phase 5.3 |
| `{pr_state}` | Draft / Ready for Review / Merged |
| `{status}` | Current Projects Status |
| `{score}` | Quality score from Phase 1.1 |
| `{branch_name}` | Branch from Phase 2.1 |
| `{changed_files_count}` | `git diff --name-only origin/{base_branch}...HEAD \| wc -l` (`{base_branch}` = PR base ref from Phase 2.1, e.g. `develop`) |
| `{review_result}` | Review assessment from Phase 5.4 |

**Step 3 — Output**:

Output the substituted template as your response. First determine which case applies, then verify the output matches **all three required sections** for that case:

**Case A — PR was created** (normal case, `{pr_number}` is set):
1. **項目テーブル** (7 rows: Issue, Issue URL, PR, PR URL, PR 状態, 関連 Issue, Status)
2. **フェーズ進捗テーブル** (6 rows: Issue 分析, ブランチ作成, 実装, 品質チェック, PR 作成, セルフレビュー — all ✅)
3. **次のステップ** (3 items, using the content from the template read in Step 1)

**Case B — PR was NOT created** (edge case, no `{pr_number}`):
1. **項目テーブル** (5 rows: Issue, Issue URL, PR, ブランチ, Status)
2. **フェーズ進捗テーブル** (6 rows: completed phases ✅, incomplete phases ⏳)
3. **次のステップ** (3 items, using the content from the template read in Step 1)

**Step 3.4 — Append Recommendation Disposition section (Issue #1042 AC-3)**:

> **Output ordering** (must match `start-finalize.md` Phase 5.6.3 ordering note): After outputting フェーズ進捗 (Step 3) but **before** 次のステップ, **always** append the "推奨事項 disposition" subsection. This applies to both Case A and Case B.

The "推奨事項 disposition" subsection is generated per `start-finalize.md` Phase 5.6.3 by aggregating `recommendation_items` from the latest review cycle conversation context. The subsection breaks down the recommendations into three classification rows (actionable / boundary / design_confirmation) with explicit counts and details.

**Output rules**:

- When `recommendation_items` is non-empty (any classification count >= 1): render the full 3-row table per `templates/completion-report.md` 「推奨事項 disposition」 section.
- When `recommendation_items` is empty (all counts == 0): render `_推奨事項なし_` as the only content of the subsection.
- **PROHIBITED**: aggregate labels (「推奨 N 件」「follow-up 候補 N 件」「全て scope 外」「scope 外 follow-up」). See `start-finalize.md` Phase 5.6.3 Step 3 for the canonical prohibition list and rationale.

See `start-finalize.md` Phase 5.6.3 for the full procedure (classification aggregation, output table format, prohibition enforcement).

**Step 3.5 — Append Wiki ingest 状況 section (Issue #524 AC-5)**:

**Output ordering** (must match `start-finalize.md` Phase 5.6.2 ordering note): After outputting the case-specific sections (項目テーブル + フェーズ進捗 + 次のステップ), **always** append the "Wiki ingest 状況" table **before** the Phase 5.6.1 (Workflow Incident Reporting) section. The runtime sequence is: standard completion sections → Phase 5.6.2 (Wiki ingest 状況, this Step 3.5) → Phase 5.6.1 (workflow incidents). The section numbers in `start.md` reflect introduction order (#366 first, #524 second) and are intentionally NOT in execution order.

The "Wiki ingest 状況" table is generated per `start-finalize.md` Phase 5.6.2 by aggregating `[CONTEXT] WIKI_INGEST_DONE/SKIPPED/FAILED=1` lines from the conversation context. This section is mandatory in both Case A and Case B and is **never** skipped — the absence of any signal is itself a reportable state (silent-skip detection).

See `start-finalize.md` Phase 5.6.2 for the full procedure (signal aggregation, output table format, conditional warnings).

**Step 4 — Self-verification**:

After outputting, verify your output matches the case determined in Step 3:

For **Case A** (PR created):
- [ ] `## 完了報告` heading
- [ ] 項目テーブル with exactly **7** data rows
- [ ] `### フェーズ進捗` heading with exactly 6 data rows
- [ ] `### 推奨事項 disposition` heading (from Step 3.4, Issue #1042 AC-3) — either full 3-row table OR `_推奨事項なし_` line
- [ ] No aggregate labels (「推奨 N 件」「follow-up 候補」「全て scope 外」) appear anywhere in the report
- [ ] `### 次のステップ` heading with exactly 3 numbered items
- [ ] `### 📚 Wiki ingest 状況` heading with signal table (from Step 3.5, Issue #524 AC-5 — never skipped)

For **Case B** (PR not created):
- [ ] `## 完了報告` heading
- [ ] 項目テーブル with exactly **5** data rows
- [ ] `### フェーズ進捗` heading with exactly 6 data rows (with ⏳ for incomplete phases)
- [ ] `### 推奨事項 disposition` heading (from Step 3.4, Issue #1042 AC-3) — either full 3-row table OR `_推奨事項なし_` line
- [ ] No aggregate labels (「推奨 N 件」「follow-up 候補」「全て scope 外」) appear anywhere in the report
- [ ] `### 次のステップ` heading with exactly 3 numbered items
- [ ] `### 📚 Wiki ingest 状況` heading with signal table (from Step 3.5, Issue #524 AC-5 — never skipped)

If any check fails, re-read the template and regenerate.

**MUST NOT**: Omit any template rows, merge fields into a single line, invent fields not in the template, or change the table format (e.g., no ASCII box-drawing).

---

**Inline fallbacks** (use ONLY if Read tool fails on the template file). Select the matching case:

**Case A fallback — PR created**:

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | #{pr_number} |
| PR URL | https://github.com/{owner}/{repo}/pull/{pr_number} |
| PR 状態 | {pr_state} |
| 関連 Issue | #{number} |
| Status | {status} |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ✅ | lint 通過 |
| PR 作成 | ✅ | #{pr_number} |
| セルフレビュー | ✅ | {review_result} |

### 推奨事項 disposition (Issue #1042)

| 分類 | 件数 | 詳細 |
|------|------|------|
| actionable (Issue 化済) | {actionable_count} | {actionable_issues} |
| boundary (user 判断) | {boundary_count} | {boundary_details} |
| design_confirmation (観察のみ) | {design_confirmation_count} | {design_confirmation_details} |

<!-- 全件 0 件の場合は上記テーブルを `_推奨事項なし_` に置き換える。aggregate label (「推奨 N 件」「全て scope 外」) は禁止。 -->

### 次のステップ

1. レビュアーに PR レビューを依頼
2. レビューコメントに対応
3. PR マージ後、Issue は自動クローズ
```

**Case B fallback — PR not created**:

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | 未作成 |
| ブランチ | {branch_name} |
| Status | In Progress |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ⏳ | 未実施 |
| PR 作成 | ⏳ | - |
| セルフレビュー | ⏳ | - |

### 次のステップ

1. `/rite:pr:create` で PR を作成
2. `/rite:pr:review` でセルフレビュー
3. レビュアーに PR レビューを依頼
```

See template "エッジケース対応表" for other edge cases.
