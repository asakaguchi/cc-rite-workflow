# Bottleneck Detection Reference

Oracle discovery and step re-decomposition for implementation bottlenecks.

## Overview

During implementation (Phase 5.1), a step is a **bottleneck** when it is clearly outgrowing the granularity the plan assumed — repeated fix round-trips, or file/line changes far beyond what the step was scoped for. The judgment is semantic: compare the step's actual trajectory against the plan's granularity estimate. There are no fixed thresholds (the former round/file/line threshold table was removed in #1880 — the numbers made the check rigid at boundary cases and substituted counting for judgment).

When a bottleneck is recognized, pause the step, discover an Oracle in the codebase, and re-decompose the step into smaller sub-steps.

**Oracle pattern**: Using existing correct implementations in the codebase as structural guides for new or problematic implementations. Instead of building from scratch, the AI reads reference files with similar structure/purpose and uses their patterns (section organization, naming conventions, error handling) as a template for decomposition and implementation.

> **Note**: Section headings and definitions are in English. Output templates and user-facing messages are in Japanese per project i18n conventions.

## Oracle Discovery

Look for an Oracle in this order, stopping at the first level that yields a relevant reference (relevant = same file type and same directory / similar naming / similar functionality):

1. **Plan references**: 実装計画の「参考実装」に挙げたファイル（Phase 3.2.1 で発見済み、会話コンテキスト / work memory に保持）
2. **Same directory / pattern search**: 同ディレクトリの兄弟ファイルや命名パターンの一致するファイルを Glob で探す
3. **Test reverse lookup**: 対応するテストファイルがあれば、テストが期待する構造を分解のガイドにする

**When no Oracle is found**: Decompose using general heuristics — split by file boundary, by logical section, or by dependency order (data model → logic → integration) — whichever fits the step's actual shape.

## Step Re-decomposition

Use the Oracle's structural units (sections, functions, logical blocks) to map the remaining work into sub-steps with explicit dependencies. Sub-step IDs use dot notation to maintain traceability to the original step:

```
元のステップ: S{n} (ボトルネック検出)
分解後:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |
| S{n}.3 | {sub_step_3} | S{n}.1 |
```

Insert the sub-steps into the dependency graph replacing the original step, update the implementation plan in work memory, then execute the first sub-step. The user notification format is defined in `skills/issue-implement/SKILL.md` 5.1.0.5 (行き詰まり判断でステップを再分解した場合の display format).

## Work Memory Recording Format

Record bottleneck detection and re-decomposition events in the work memory's "ボトルネック検出ログ" section (after "計画逸脱ログ"):

```markdown
### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->

| 検出時刻 | Step | 検出理由 | Oracle | 再分解 |
|---------|------|---------|--------|-------|
| {timestamp} | S{n} | {reason} | {oracle_source}: {oracle_path} | S{n}.1, S{n}.2, ... |
```

| Field | Description | Example |
|-------|-------------|---------|
| 検出時刻 | ISO 8601 timestamp | `2026-02-15T12:00:00+09:00` |
| Step | Original step ID | `S3` |
| 検出理由 | なぜ膨らんでいると判断したか（自由記述） | `同一ガードの修正往復が継続、計画粒度を超過` |
| Oracle | Source and file path | `参考実装: implement.md` or `同ディレクトリ: create.md` or `なし` |
| 再分解 | List of sub-step IDs | `S3.1, S3.2, S3.3` |

**Recording timing**: Record in work memory at the next bulk update point (typically at commit time, per `skills/issue-implement/SKILL.md` 5.1.0.5). This avoids excessive API calls for work memory updates during implementation.

## Related

- [Implementation Guidance](../skills/issue-implement/SKILL.md) - 5.1.0.5 Adaptive Re-evaluation
- [AI Coding Principles](../skills/rite-workflow/references/coding-principles.md) - `reference_discovery` principle
- [Work Memory Format](../skills/rite-workflow/references/work-memory-format.md) - "ボトルネック検出ログ" section format
