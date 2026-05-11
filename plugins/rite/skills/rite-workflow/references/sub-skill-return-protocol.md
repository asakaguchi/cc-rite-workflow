# Sub-skill Return Auto-Continuation Contract

> **Scope**: This reference defines the **global** contract for how an orchestrator command (e.g., `/rite:issue:start`, `/rite:issue:create`) must handle control when a Skill tool invocation returns. It applies to **every** sub-skill return in the rite workflow.

## Why this contract exists

When Claude Code invokes a Skill tool and the sub-skill outputs its result pattern (e.g., `[interview:skipped]`, `[review:mergeable]`, `[fix:pushed]`), control returns to the orchestrator LLM in the same response turn. The orchestrator's natural inclination — trained by general assistant behavior — is to treat the sub-skill's completion as a task boundary and end the turn.

> **Scope note**: The example patterns above are drawn from `/rite:issue:create` and `/rite:pr:*` orchestrators. This contract applies to **all** sub-skill returns, but Issue #525 specifically addresses the `/rite:issue:create` failure mode (`[interview:skipped]` turn-end bug). Other orchestrators that already survive the failure mode in practice inherit the same contract as a safety invariant.

**This is a bug.** The sub-skill return is a hand-off signal, not a turn boundary. Ending the turn at this point forces the user to type `continue` manually, which:

1. Breaks the "single-command end-to-end" experience that orchestrator commands promise
2. Causes workflow state to decay (stale timestamps, compact-state drift)
3. May silently skip mandatory defense-in-depth steps (e.g., flow-state patches, Issue-comment backups)
4. In terminal sub-skills, may leave flow state in an `active: true` state indefinitely

## The contract

**When a sub-skill tool invocation returns control to the orchestrator:**

1. **DO NOT end your response.** You are still in the middle of the orchestrator's phase flow.
2. **DO NOT re-invoke the completed skill.** It already finished — re-invoking wastes context and may corrupt state.
3. **IMMEDIATELY** execute the orchestrator's 🚨 Mandatory After section for the current phase, starting with the flow state update, then proceeding to the next phase — **in the same response turn**.

> **Note (Layer 2 retirement)**: The historical contract item "If the stop-guard hook blocks a stop attempt..." was retired in #675 along with `hooks/stop-guard.sh`. See "Layer numbering note" below the Defense-in-depth layers table for retirement details and rationale.

## Self-check after every sub-skill return

Ask yourself: **"Has the orchestrator's terminal completion marker been output yet?"**

| Orchestrator | Terminal marker | When contract ends |
|-------------|----------------|-------------------|
| `/rite:issue:start` | Phase 5.6 completion report + Workflow Termination block | After the completion report text is displayed |
| `/rite:issue:create` | `<!-- [create:completed:{N}] -->` (HTML コメント形式、Issue #561 で変更) + user-visible な `✅ + 次のステップ` が末尾手前 | HTML コメント sentinel が出力され、その前に完了メッセージ (`✅ Issue #{N} を作成しました: {url}` 等) + 次のステップが display 済みの状態 |
| Other `/rite:*` commands | Check the command's "Output" / "Terminal Completion" section | Match the explicit contract there |

If the marker has **not** been output, you are NOT done — keep going in the same turn.

> **⚠️ Duplication note**: The anti-pattern / correct-pattern blocks below are **intentionally duplicated** with `commands/issue/create.md` Sub-skill Return Protocol section. The canonical source is `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract". When modifying either copy, **always update both files and SPEC.md together** to prevent drift on the structural skeleton (step ordering, sub-skill enumeration, terminal turn boundary marker). Drift is acceptable on **orchestrator-specific Phase numbers** (e.g. protocol doc references generic `Task Decomposition Decision triggers`, while create.md may reference its own internal phase numbering like `Phase 2`) — these are not sync targets. A future refactor may consolidate via @include.

## Anti-pattern (what NOT to do)

`create-interview` は parent-routing pattern (ADR `docs/designs/parent-routing-unification.md`) で **bare bracket form** `[interview:skipped]` / `[interview:completed]` / `[interview:error]` を emit する。`create-register` / `create-decompose` は依然 HTML-comment form `<!-- [create:completed:{N}] -->` を emit する (移行ロードマップは ADR 参照):

```
[WRONG]
<Skill rite:issue:create-interview returns>
<LLM output: "[interview:skipped]">
<LLM ends turn. User sees "Cooked for 2m 0s" and must type `continue`.>
```

This abandons the workflow with no Issue created and no flow-state cleanup. Sentinel 形式 (bare bracket / HTML-comment) に関わらず、return tag は turn 境界ではなく continuation trigger として扱い、同 turn 内で Phase 2 へ進まなければ本質的な bug は再発する。

## Correct-pattern (what to do)

```
[CORRECT]
<Skill rite:issue:create-interview returns>
<LLM output: "[interview:skipped]">
<In the SAME response turn, LLM IMMEDIATELY:>
  1. Evaluates Task Decomposition Decision triggers
     (orchestrator-specific phase number: create.md では Phase 2、他 orchestrator は別 phase 番号を持ちうる
      — Duplication note の "drift acceptable on orchestrator-specific Phase numbers" に従い generic 化)
  2. Runs Delegation Routing Pre-write bash
  3. Invokes skill: "rite:issue:create-register"
  4. Waits for <!-- [create:completed:{N}] --> (HTML コメント形式 — 移行計画は ADR 参照)
  5. Runs Mandatory After Delegation self-check
<Orchestrator terminal completion reached. Turn may end.>
```

## Defense-in-depth layers

The contract is enforced across two active layers (Layer 2 was retired in #675). Violating any active layer is a bug:

| Layer | Mechanism | File | Status |
|-------|-----------|------|--------|
| 1. Prompt contract | Anti-pattern / correct-pattern + "same response turn" warnings + Mandatory After orchestrator prose | `commands/issue/start.md` (Sub-skill Return Protocol Global), `commands/issue/create.md` (Mandatory After Delegation), `commands/pr/cleanup.md` (Mandatory After Wiki Ingest), `commands/wiki/ingest.md` (Mandatory After Auto-Lint), this reference (移行ロードマップは ADR `docs/designs/parent-routing-unification.md` 参照) | active |
| 3. Caller-continuation hints (3a/3b/3c は本 cell 内に inline 展開済) | (3a) caller HTML hint with `<!-- caller: ... -->` prefix (issue creation paths only — `create-register` / `create-decompose` のみ、いずれも PR-5 までの interim 状態で ADR §5 に従って parent-routing pattern に移行予定。`create-interview` は parent-routing pattern 移行で本 layer 適用外) immediately before the sub-skill's result pattern + (3b) plain-text Markdown blockquote reminder (`> ⏭ MUST continue (turn を閉じない): ...` 等の命令形) emitted by the sub-skill alongside the HTML hint + (3c) sub-skill HTML continuation comment with `<!-- continuation: ... -->` prefix (wiki ingest path only) that the caller greps | Defense-in-Depth sections in `commands/issue/create-register.md`, `commands/issue/create-decompose.md`, `commands/wiki/ingest.md`; Phase 9.2 三点セット blockquote (Layer 3b imperative) in `commands/wiki/lint.md`。`commands/issue/create-interview.md` は parent-routing pattern 移行で本 layer 廃止済 (sub-skill 内製化、ADR 参照) | active (3a は PR-5 で廃止予定) |

> **Layer numbering note**: Layer 2 (the former runtime hard gate via `hooks/stop-guard.sh`) was retired in #675. The numbering gap is intentional — `commands/wiki/ingest.md` and other documents that still use `Layer 2` as a grep-able marker do so to keep historical cross-references resolvable in-repo. See commit `e2dfae0` (or `git log -- plugins/rite/hooks/stop-guard.sh`) for the historical Layer 2 mechanism.

The LLM receives the continuation signal from two independent sources: the prompt itself (Layer 1) and the **inline HTML comment + plain-text reminder + sub-skill HTML continuation comment** in the sub-skill output (Layer 3 = 3a + 3b + 3c の internal decomposition は上記 table cell 内に inline 展開済)。The imperative strength of those two surfaces (Layer 1 と Layer 3 全体) is therefore load-bearing — see the Canonical imperative strengthening coverage blockquote below.

> **Canonical imperative strengthening coverage (parent-routing pattern 移行中)**: load-bearing な phrasing (`MUST execute as VERY FIRST tool call BEFORE any text output`, `DO NOT end the turn`, `DO NOT output any narrative text before this bash call`) は以下の現役 site に適用される。stop-guard.sh (Layer 2) 撤去 (#675) 以降は Layer 1 (prompt contract) と Layer 3 (caller HTML hint / sub-skill continuation comment) のみが残り、LLM の turn-boundary heuristic 起因 implicit stop を完全には防げないため、**imperative 強度** が defense 強度を決定する (命令形 + 否定形重ねがけが natural stopping point を消去する経験的観測):
>
> - **Layer 1 (orchestrator prompt contract)**:
>   - `create.md` Mandatory After Delegation pre-section prose (`VERY FIRST cognitive action` variant)
>   - `pr/cleanup.md` Mandatory After Wiki Ingest Step 0 prose
>   - `wiki/ingest.md` Mandatory After Auto-Lint Step 0 prose
> - **Layer 3 (caller HTML hint + sub-skill continuation comment)**:
>   - `wiki/ingest.md` Phase 9.1 continuation HTML comment (`<!-- continuation: ... -->`)
>   - `create-register.md` / `create-decompose.md` caller HTML hint (`<!-- caller: ... -->`)
> - **Layer 3b plain-text reminder** (`> ⏭ MUST continue (turn を閉じない): ...`): `wiki/lint.md` Phase 9.2 三点セット blockquote に適用 (旧 `> ⏭ 継続中: ...` 現状報告 → 命令形に recast、Issue #917)。
>
> **廃止済**: `create.md` Mandatory After Interview / `create-interview.md` caller HTML literal + Layer 3a/3b は parent-routing pattern (ADR `docs/designs/parent-routing-unification.md`) で sub-skill 内製化済 (caller-side hint 不要)。撤去済 invariant test: `4-site-symmetry.test.sh` / `caller-html-literal-symmetry.test.sh` / `step0-immediate-bash-presence.test.sh` / `create-interview-responsibility-separation.test.sh`。Interim coverage は `hooks/tests/parent-routing-pattern-interim.test.sh` が担う (統合計画は ADR 参照)。

## Relationship to Workflow Incident Detection

When the contract is violated in practice — the user types `continue` to recover — the orchestrator MAY emit the `auto_continuation_failed` sentinel via `plugins/rite/hooks/workflow-incident-emit.sh` so the incident is auto-registered as an Issue via Phase 5.4.4.1. This is an **optional observability sentinel** (MAY) — it does not enforce the contract but records violations for later diagnosis. The detection heuristic has false-positive risk and is out of scope for Issue #525 MUST requirements. The active layers (Layer 1 + Layer 3) above are the actual enforcement; the sentinel is observability. See `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract" section for the full specification.

## References

- `docs/SPEC.md` — "Sub-skill Return Auto-Continuation Contract" (canonical specification)
- `commands/issue/start.md` — Sub-skill Return Protocol (Global) section
- `commands/issue/create.md` — Sub-skill Return Protocol + anti/correct-pattern examples + Mandatory After Delegation (Issue #910 imperative strengthening; Mandatory After Interview は parent-routing pattern 移行で廃止済)
- `commands/pr/cleanup.md` — Mandatory After Wiki Ingest Step 0 (Issue #910 imperative strengthening)
- `commands/issue/create-interview.md` — Defense-in-Depth (Pre-flight + Return Output re-patch、parent-routing pattern — caller continuation comment は廃止済)
- `commands/issue/create-register.md` — Terminal Completion + caller continuation comment
- `commands/issue/create-decompose.md` — Terminal Completion (Normal path) + caller continuation comment
- `commands/wiki/ingest.md` — Mandatory After Auto-Lint (Layer 1) + Phase 9.1 caller continuation HTML comment (Layer 3c)
- `commands/wiki/lint.md` — Phase 9.2 三点セット blockquote (Layer 3b imperative recast、Issue #917)
