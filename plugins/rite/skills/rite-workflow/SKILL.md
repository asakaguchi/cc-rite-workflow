---
name: rite-workflow
description: |
  Automates the complete Issue-to-PR lifecycle: create new Issues,
  start working on Issues, create branches, implement changes, run
  quality checks, and manage PRs — all through a single workflow.
  Essential for any /rite: command, workflow questions, or when
  working with Issues, branches, commits, or PRs.
  Activates on "create issue", "new issue", "起票", "Issue を作成",
  "タスクを登録", "Issue 化", "新規 Issue", "start issue", "create PR",
  "next steps", "workflow", "rite", "Issue作業", "ブランチ",
  "コミット規約", "PR作成", "作業開始", "ワークフロー", "次のステップ".
  Use for workflow state detection, phase transitions, and command
  suggestions.
---

# Rite Workflow Skill

This skill provides context for rite workflow operations.

## Auto-Activation Keywords

- Issue, PR, Pull Request
- workflow, rite
- branch, commit
- GitHub Projects
- review, lint
- recall, 決定事項検索, コンテキスト, なぜ

## Context

When activated, this skill provides:

1. **Workflow Awareness**
   - Current branch and associated Issue
   - Work memory state
   - Status in GitHub Projects

2. **Command Guidance**
   - Suggest appropriate commands
   - Remind about work memory updates
   - Guide through workflow steps

3. **Best Practices**
   - Conventional Commits format
   - Branch naming conventions
   - PR template usage

4. **Coding Principles**
   - Avoid common AI coding failure patterns
   - See [references/coding-principles.md](./references/coding-principles.md) for details

5. **Common Principles**
   - Reduce excessive AskUserQuestion usage
   - See [references/common-principles.md](./references/common-principles.md) for details

6. **Comment Best Practices**
   - WHY > WHAT, no journal comments, no line/cycle number references, jargon whitelist enforcement
   - See [references/comment-best-practices.md](./references/comment-best-practices.md) for details

## Workflow Identity (品質 > 時間/context)

rite workflow の identity は「定義された step を全て実行し、生成物の品質を担保する」ことである。**時間的制約や context 残量を理由にした step の省略は禁止**。残量の推論も禁止。context が実際に枯渇した場合の正規経路は `/clear` + `/rite:resume` の組合せであり、LLM が自己判断でワークフローを短縮する経路は存在しない。

**さらに、workflow は途中で止まらない。そして最後のわけのわからない出力で終わらない。** sub-skill の return tag (`[lint:*]` / `[pr:created:N]` / `[review:*]` / `[fix:*]` / `[ready:completed]`) は **turn 境界ではなく継続トリガ** である。ユーザー介入 (`continue` 入力) を要求せずに、同 turn 内で次 phase へ進む。

`create.md` の flat workflow 終端で出力される `[create:completed:{N}]` HTML コメント marker は sub-skill return tag ではなく、create.md 内で完結する terminal sentinel である (hook / grep 契約のため必須)。ワークフロー完了時の user-visible な最終行は sentinel marker ではなく「✅ Issue #{N} を作成しました: {url}」のような人間可読な完了メッセージとし、sentinel は HTML コメント化等で user-visible な末端に孤立させない。

| 禁止事項 | 正規経路 |
|---------|---------|
| 「時間が足りないので X を省略します」 | 手順どおり実行 |
| 「context が圧迫しているので要約します」 | 手順どおり実行 |
| 「残量が不安なので review を切り上げます」 | `/clear` + `/rite:resume` をユーザーに案内 |
| return tag 直後に turn を閉じる | 同 turn 内で次 phase に継続。途中で止まった場合の正規復帰経路は `/rite:resume` (`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の phase→step 表に従う) |
| sentinel marker `[create:completed:{N}]` を user-visible な最終行として残す | HTML コメント `<!-- [create:completed:{N}] -->` として末尾に配置し、user-visible な最終行は `✅ ...` 完了メッセージにする |

詳細と Anti-pattern / Correct Pattern は [references/workflow-identity.md](./references/workflow-identity.md) を参照。各 command (start / review / fix / ready / lint / cleanup / create / resume 等) からも同 reference を引いている。

## Multi-Step Workflow Task Tracking

3 step 以上の sequential workflow (`pr:cleanup`, `pr:iterate`, `pr:open`, `sprint:execute`, `wiki:ingest` 等) を実行する際は、開始時に TaskCreate でステップ列を登録し、各 step 完了時に TaskUpdate で進捗を更新すること。skill 呼び出しから return した時点で「未完了タスクが残っているか」を TaskList で確認してから turn を終了する。これにより skill ネスト時 (例: `cleanup → wiki:ingest → wiki:lint`) の最内側 sentinel を turn 終了と誤認する事故を防ぐ。

## Workflow State Detection

Detect current state from:
- Branch name pattern: `{type}/issue-{number}-*`
  - `{type}` values: `feat`, `fix`, `docs`, `refactor`, `chore`, `style`, `test`
  - `style` is used for code style/formatting changes (no logic changes)
- Git status
- Open PRs

## Suggested Actions

| State | Suggestion |
|-------|------------|
| On main/develop, no Issue | `/rite:issue:create` or `/rite:issue:list` |
| Have an Issue, want to start work | `/rite:pr:open <issue>` (Issue → branch → 実装 → lint → draft PR を一気通貫) |
| On feature branch, PR open / draft, review-fix cycle | `/rite:pr:iterate <pr>` (mergeable まで review ⇄ fix を無限ループ) |
| Review mergeable, want to mark Ready | `/rite:pr:ready <pr>` then `/rite:pr:merge <pr>` |
| Merge 完了、branch 削除 / Wiki ingest / Projects Status Done 後処理が必要 | `/rite:pr:cleanup <pr>` |
| Long session (30+ minutes elapsed) | `/rite:issue:update` |
| Sprint with Todo Issues available | `/rite:sprint:execute` to run Issues sequentially |
| Sprint with multiple independent Issues | `/rite:sprint:team-execute` to run Issues in parallel with worktrees |
| Want to recall past decisions or context | `/rite:issue:recall` or `/rite:issue:recall {scope}` |

## Question Management

> **Key Principle**: Always apply `question_self_check` (see [references/common-principles.md](./references/common-principles.md)) before asking questions. Most questions can be avoided through context inference and using sensible defaults.

### When Questions Are Necessary

Ask immediately (do not defer) when:
- **Blockers**: Issues that prevent further progress
- **Security-related**: Decisions affecting security
- **Destructive operations**: Actions that cannot be undone
- **External impacts**: Changes affecting users or external systems

### Work Memory Integration

If questions arise during work, record them in the work memory comment under "要確認事項" (Items to Confirm):

```markdown
### 要確認事項

1. [ ] {confirmation_item_1}
2. [ ] {confirmation_item_2}
```

### Expected Question Frequency

**Target**: Minimize questions through context inference and sensible defaults. Issue Start: 0-1 (score C/D only), Implementation: 0, PR Review: 0-1 (critical decisions only). Record non-blocking questions in work memory.

See [references/common-principles.md](./references/common-principles.md) for detailed frequency table by phase.

## Session Start Auto-Detection

Automatically detect work state at session start and notify if interrupted work exists.

See [references/session-detection.md](./references/session-detection.md) for details.

### Quick Reference

1. Extract Issue number from branch name (`{type}/issue-{number}-*` pattern)
2. Fetch work memory comment from the Issue
3. Extract and display phase information

See [references/phase-mapping.md](./references/phase-mapping.md) for phase list.

See [references/work-memory-format.md](./references/work-memory-format.md) for work memory format.

## 4 Command Architecture

`/rite:issue:start` は廃止され、**4 つの単機能コマンド** に分解されている (詳細は CHANGELOG 参照):

| コマンド | 責務 | 区分 |
|---|---|---|
| `/rite:pr:open <issue>` | Issue → branch → 実装 → lint → draft PR (Step 0 Resume Dispatch 含む) | orchestrator |
| `/rite:pr:iterate <pr>` | review ↔ fix を `[review:mergeable]` まで無限ループ (cycle counter なし、abort は Ctrl+C のみ) | orchestrator |
| `/rite:pr:ready <pr>` | Ready 化 + Projects Status + 親判定 + 完了レポート | self-contained command |
| `/rite:pr:merge <pr>` | `gh pr merge --squash` を叩くだけ (cleanup は分離) | self-contained command |

`/rite:issue:create` は引き続き flat single-file workflow を維持。マージ後の cleanup は `/rite:pr:cleanup` (既存) を別途実行する。

LLM が途中で停止した場合の正規復帰経路は `/rite:resume` で、`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の phase→新 4 コマンド routing 表に従う。implicit-stop 対策の hook 群 (`auto-fire-step0.sh` / `stop-create-interview-block.sh` / `verify-terminal-output.sh`) は撤去済み。

### Sub-skill sentinel 一覧 (orchestrator から grep される SoT)

| sub-skill | emit する sentinel | invoke 元 |
|---|---|---|
| `rite:issue:implement` | (現状 sentinel 未発火 — 完了は work memory / flow-state 側で確認する設計) | `pr:open` Step 4 |
| `rite:lint` | `[lint:success]` / `[lint:skipped]` / `[lint:error]` / `[lint:aborted]` | `implement` 内で autonomous invoke、`pr:open` Step 5 が結果を読む |
| `rite:pr:create` | `[pr:created:N]` / `[pr:create-failed]` | `pr:open` Step 6 |
| `rite:pr:review` | `[review:mergeable]` / `[review:fix-needed:N]` / `[review:error]` | `pr:iterate` 内ループ |
| `rite:pr:fix` | `[fix:pushed]` / `[fix:pushed-wm-stale]` / `[fix:replied-only]` / `[fix:cancelled-by-user]` / `[fix:error]` | `pr:iterate` 内ループ |
| `rite:pr:ready` | `[ready:completed]` / `[ready:error]` | ユーザーが直接 invoke (orchestrator 経由なし) |
| `rite:pr:merge` | `[merge:completed]` / `[merge:not-ready]` / `[merge:error]` | ユーザーが直接 invoke (orchestrator 経由なし) |

orchestrator (`pr:open` / `pr:iterate`) が sub-skill 出力の sentinel を grep で routing する。`pr:ready` / `pr:merge` は self-contained で他 sub-skill を起動しない。

過去の defense-in-depth model (Layer 1/3/4) と移行マップは [references/sub-skill-return-protocol.md](./references/sub-skill-return-protocol.md) を参照 (**retired by #1144**, historical reference only — Layer 1 prompt contract は cleanup.md flat 化と同時に物理排除されており、現行は Layer 3 caller-continuation hints + Layer 4a/4b orchestrator-side reinforcements + flat sequential structure が active enforcement)。

## AI Coding Principles (Summary)

Avoid common AI coding failure patterns: surface assumptions, manage confusion, push back when warranted, enforce simplicity, maintain scope discipline, clean dead code, plan inline, address all discovered issues, and keep documentation in sync with specification changes (`documentation_consistency`) — when the implementation changes user-visible behavior, update related README / docs / CLAUDE.md / plugin .md files in the same PR rather than deferring to a follow-up Issue.

See [references/coding-principles.md](./references/coding-principles.md) for the full principle list and details.

## Simplification Charter (rite plugin maintenance)

`plugins/rite/` 配下のファイルを編集する LLM・メンテナ、および rite workflow が生成する commit message / Issue body / PR description / review 指摘は、自己生成的に肥大化しないよう **Simplification Charter** に従う。runtime に効かない経緯記述は書かない / git log で代替できるものはコードに書かない / `Issue #` / `PR #` / `cycle #` の本文引用は禁止 / 重複 confirmation 禁止。

特に `commands/pr/cleanup.md` および `commands/pr/references/` 配下のファイル群（**pr/cleanup 系**）は本 charter の主要適用対象であり、各ファイル冒頭に charter SoT 参照行を持つ。

See [references/simplification-charter.md](./references/simplification-charter.md) for the 5 self-questions (5 つの自問) / prohibited patterns (禁止パターン) / recommended patterns (推奨パターン).

## Common Principles (AskUserQuestion Reduction)

Reduce excessive questions: self-check necessity, use defaults when available, infer from context.

See [references/common-principles.md](./references/common-principles.md) for details.

## Preflight Guard (All Commands)

Before executing any `/rite:*` command, run the preflight guard. Resolve `{plugin_root}` per [references/plugin-path-resolution.md](../../references/plugin-path-resolution.md#resolution-script-full-version).

```bash
bash {plugin_root}/hooks/preflight-check.sh --command-id "{current_command_id}" --cwd "$(pwd)"
```

Replace `{current_command_id}` with the slash command being executed (e.g., `/rite:lint`, `/rite:pr:review`).

If exit code is `1` (blocked), stop execution and display the preflight output. Do NOT proceed.

## gh CLI Safety Rules

All `gh` commands that accept `--body` or `--comment` parameters **MUST** use safe patterns to avoid shell injection:

- Use `--body-file` with `mktemp` for multi-line content
- Reference: See `references/gh-cli-patterns.md` for detailed safe patterns

**Never** pass user-generated content directly via `--body` or `--comment` flags.

## Workflow Failure Surfacing

When a step of `/rite:pr:open` / `/rite:pr:iterate` / `/rite:pr:ready` / `/rite:pr:merge` fails or is skipped (Skill load failure, hook abnormal exit, Wiki ingest skip/failure, etc.), the affected skill or hook emits a plain `WARNING` / `ERROR` line to **stderr**. The orchestrator surfaces it in the conversation context, and the user re-runs the affected step via `/rite:resume`. Failures are visible but not auto-registered as Issues; the user decides whether to file one.

> The earlier auto-registration mechanism (`workflow-incident-emit.sh` sentinel + `/rite:issue:start` detection + `workflow_incident:` config key) was removed in #1088 (実装: #1091、PR 2b リファクタリングシリーズ) in favor of this single-layer plain-stderr design. See `docs/SPEC.md` "Workflow Failure Surfacing" for details.

## Integration

This skill works with:
- All `/rite:*` commands
- GitHub CLI operations
- Git operations
