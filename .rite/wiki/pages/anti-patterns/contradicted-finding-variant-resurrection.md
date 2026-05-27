---
title: "Fact-check で CONTRADICTED 除外された主張の variant 再提起 (reviewer の observability gap)"
domain: "anti-patterns"
created: "2026-05-28T03:00:00+00:00"
updated: "2026-05-28T03:00:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260527T163952Z-pr-1164.md"
  - type: "reviews"
    ref: "raw/reviews/20260527T165719Z-pr-1164.md"
  - type: "reviews"
    ref: "raw/reviews/20260527T170947Z-pr-1164.md"
tags: ["fact-check", "reviewer-observability", "false-positive"]
confidence: high
---

# Fact-check で CONTRADICTED 除外された主張の variant 再提起 (reviewer の observability gap)

## 概要

reviewer agent が fact-check phase で CONTRADICTED 除外された主張 (例: 「ツールが存在しない」「概念が不在」) を、後続 cycle で **異なる variant に rephrase して再提起** する failure mode。根本原因は reviewer の grep 観測点が codebase 単一観測点 (`plugins/rite/` 内 grep) に限定され、Claude Code runtime environment の **deferred-tools registry** / **session 内実呼出履歴** といった外部観測点を fact-check に含めないこと。PR #1164 cycle 1-3 で 2 cycle 連続で同系統の主張 (TaskCreate 不在 → TaskCreate=Team 機能) が variant 再提起され、cycle 3 で orchestrator 側に「fact-check 履歴尊重 / TaskCreate 実在前提」を明示注入することで再提起が停止した。

## 詳細

### Failure Mode

1. **cycle N**: reviewer A が「概念 X は不在」と claim → fact-check で empirical evidence (実呼出履歴 / registry entry) により CONTRADICTED → finding 除外
2. **cycle N+1**: reviewer B (または同じ reviewer A) が「概念 X は別カテゴリ Y (例: Team 機能の付随 tool)」と variant rephrase で再提起
3. **cycle N+2**: 再度 fact-check で同じ empirical evidence により CONTRADICTED → finding 除外
4. cycle 数が消費されるだけで net progress なし

### PR #1164 実測 evidence

- **cycle 1 (code-quality F-X1)**: 「TaskCreate は SKILL.md で言及されていないため不在」(HIGH) → fact-check で session 内 TaskCreate 実呼出履歴 + deferred-tools registry entry を根拠に CONTRADICTED
- **cycle 2 (prompt-engineer F-X2)**: 「TaskCreate は TeamCreate description 内で言及される Team 機能の付随 tool であり、本 PR が想定する単独 workflow tracking には不適切」(HIGH variant) → 同じ empirical evidence (Claude Code 標準 task tool として team 未作成でも呼出成功) で CONTRADICTED
- **cycle 3 以降**: orchestrator が prompt 注入で「fact-check 履歴尊重 / TaskCreate 実在前提」を明示 → 両 reviewer から再提起なし、stop

### 根本原因: Reviewer Observability Gap

reviewer agent の fact-check は以下を観測点としていた:

- ✅ codebase grep (`plugins/rite/` 内 file)
- ✅ PR diff
- ❌ Claude Code runtime environment の deferred-tools registry
- ❌ session 内実呼出履歴

このため Claude Code native tool (TaskCreate / TaskUpdate / TaskList / TodoWrite 等) のように **codebase に hard-coded 参照されないが session 内で active な tool** は「不在」と誤判定される silent regression が発生する。reviewer agent が grep を codebase 単一観測点に限定すると、native tool registry を見落とす経路が構造的に存在する。

### Canonical 対策

1. **Reviewer agent の fact-check 観測点拡張**: reviewer agent の system prompt に「Claude Code runtime environment の deferred-tools registry + session 内実呼出履歴 + 標準 tool 一覧」を観測点として追加する義務を明記
2. **Orchestrator 側の fact-check 履歴注入**: cycle N+1 以降の reviewer prompt に cycle N で CONTRADICTED 除外された主張一覧と evidence を明示注入し、variant 再提起を構造的に抑止
3. **CONTRADICTED 主張の semantic 拡張**: variant rephrase を検出するため、CONTRADICTED 主張の semantic family (例: 「概念 X が不在」family) を fact-check 履歴に保存し、cycle N+1 reviewer が同 family の主張を出した時点で warning + 自動降格

## 関連ページ

- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [Reviewer の "本 PR では対応不要" 推奨は尊重する](../heuristics/respect-reviewer-no-action-recommendation.md)

## ソース

- [PR #1164 review cycle 1 (code-quality F-X1 TaskCreate 不在主張、CONTRADICTED)](../../raw/reviews/20260527T163952Z-pr-1164.md)
- [PR #1164 review cycle 2 (prompt-engineer F-X2 TaskCreate=Team variant 再提起、CONTRADICTED)](../../raw/reviews/20260527T165719Z-pr-1164.md)
- [PR #1164 review cycle 3 (再提起なし、orchestrator prompt 注入 effective)](../../raw/reviews/20260527T170947Z-pr-1164.md)
