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
4. ~~If the stop-guard hook blocks a stop attempt (exit 2), follow the `ACTION:` instructions in its stderr message instead of retrying the stop.~~ — Layer 2 hard gate was removed in #675 (`hooks/stop-guard.sh` no longer exists); this contract item is retained as historical context only and no longer triggers in practice. Detection of turn-boundary heuristic firing now relies entirely on Layer 1 (prompt contract — items 1-3 above) and Layer 3 (caller HTML hint + sub-skill plain-text reminder + sub-skill HTML continuation comment, see Defense-in-depth layers below).

## Self-check after every sub-skill return

Ask yourself: **"Has the orchestrator's terminal completion marker been output yet?"**

| Orchestrator | Terminal marker | When contract ends |
|-------------|----------------|-------------------|
| `/rite:issue:start` | Phase 5.6 completion report + Workflow Termination block | After the completion report text is displayed |
| `/rite:issue:create` | `<!-- [create:completed:{N}] -->` (HTML コメント形式、Issue #561 で変更) + user-visible な `✅ + 次のステップ` が末尾手前 | HTML コメント sentinel が出力され、その前に完了メッセージ (`✅ Issue #{N} を作成しました: {url}` 等) + 次のステップが display 済みの状態 |
| Other `/rite:*` commands | Check the command's "Output" / "Terminal Completion" section | Match the explicit contract there |

If the marker has **not** been output, you are NOT done — keep going in the same turn.

> **⚠️ Duplication note**: The anti-pattern / correct-pattern blocks below are **intentionally duplicated** with `commands/issue/create.md` Sub-skill Return Protocol section. The canonical source is `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract". When modifying either copy, **always update both files and SPEC.md together** to prevent drift. A future refactor may consolidate via @include.

## Anti-pattern (what NOT to do)

Issue #561 以降、sentinel は HTML コメント形式 (`<!-- [interview:skipped] -->` / `<!-- [create:completed:{N}] -->`) で emit される:

```
[WRONG]
<Skill rite:issue:create-interview returns>
<LLM output: "<!-- [interview:skipped] -->">
<LLM ends turn. User sees "Cooked for 2m 0s" and must type `continue`.>
```

This abandons the workflow with no Issue created and no flow-state cleanup. HTML コメント化によって sentinel 自体の turn 境界 heuristic triggering は弱まるが、Mandatory After を同 turn 内で実行しなければ本質的な bug は再発する。

## Correct-pattern (what to do)

```
[CORRECT]
<Skill rite:issue:create-interview returns>
<LLM output: "<!-- [interview:skipped] -->">
<In the SAME response turn, LLM IMMEDIATELY:>
  1. Runs Pre-write bash for Phase 0.6
  2. Evaluates Phase 0.6 triggers
  3. Runs Delegation Routing Pre-write bash
  4. Invokes skill: "rite:issue:create-register"
  5. Waits for <!-- [create:completed:{N}] --> (HTML コメント形式)
  6. Runs Mandatory After Delegation self-check
<Orchestrator terminal completion reached. Turn may end.>
```

## Defense-in-depth layers

The contract is enforced across multiple layers. Layer 2 (the runtime hard gate) was removed in #675; Layer 1 + Layer 3 are the active enforcement surfaces today. Violating any active layer is a bug:

| Layer | Mechanism | File | Status |
|-------|-----------|------|--------|
| 1. Prompt contract | Anti-pattern / correct-pattern + "same response turn" warnings | `commands/issue/start.md` (Sub-skill Return Protocol Global), `commands/issue/create.md` (Sub-skill Return Protocol), this reference | active |
| 2. ~~Flow state hard gate~~ | ~~Sub-skills write `*_post_*` phases + `active: true` before return; stop-guard blocks stop attempts until terminal state~~ | ~~`hooks/flow-state-update.sh` + `hooks/stop-guard.sh`~~ | **removed in #675** — `stop-guard.sh` was deleted; `flow-state-update.sh` still emits `*_post_*` phases for observability/sentinel emit, but no stop is blocked |
| 3. Caller-continuation hints | HTML comment `<!-- caller: ... -->` (issue creation paths) または `<!-- continuation: ... -->` (wiki ingest path) immediately before the sub-skill's result pattern | Defense-in-Depth sections in `commands/issue/create-interview.md`, `commands/issue/create-register.md`, `commands/issue/create-decompose.md`, `commands/wiki/ingest.md` | active |

With Layer 2 removed, the LLM receives the continuation signal from two independent sources: the prompt itself (Layer 1) and the inline HTML comment in the sub-skill output (Layer 3). The imperative strength of those two surfaces is therefore load-bearing — see the blockquote below.

> **⚠️ Important — prompt-side defense alone is insufficient**: Issue #910 で実証された通り、stop-guard.sh の撤去 (#674/#675) 以降は Layer 2 の hard gate が存在せず、Layer 1 (prompt contract) と Layer 3 (caller HTML hint) のみが残った状態では LLM の turn-boundary heuristic 起因の implicit stop を完全には防げない。`/rite:pr:cleanup` 実行中の `rite:wiki:ingest --auto` lint return 後 / `/rite:issue:create` 実行中の `rite:issue:create-interview` `[interview:skipped]` return 後の双方で `Sautéed for 7m 40s` 等の implicit stop が観測されている。**Mitigation**: Layer 3 (caller HTML hint) と sub-skill 側 plain-text reminder の **imperative 強度** が defense 強度を決定する。`IMMEDIATELY` 単独ではなく `MUST execute as VERY FIRST tool call BEFORE any text output, narrative, or response generation` のような命令形 + 否定形重ねがけが implicit stop の確率を下げる経験的観測 (Issue #910 D-01)。`継続中` のような現状報告ではなく `MUST continue (turn を閉じない)` のような命令形が natural stopping point を消去する。

> **3 layer canonical signaling pattern** (Issue #910 適用): caller HTML hint (Layer 3a) / sub-skill plain-text reminder (Layer 3b) / sub-skill HTML continuation comment (Layer 3c) の 3 layer で **共通 intent** (命令形 / natural stopping point の消去) を反復することで、LLM が任意の path で return block を read しても turn-boundary heuristic が発火しない構造にする。**phrasing は layer により意図的に異なる**:
>
> - **HTML comment 層 (3a / 3c)**: 英語 canonical full form (`MUST execute as VERY FIRST tool call BEFORE any text output`、`DO NOT end the turn`、`DO NOT output any narrative text before this bash call`)。LLM が機械的に grep して読み取る経路。
> - **Plain-text reminder 層 (3b)**: user-facing 短縮 Japanese imperative form (`MUST continue (turn を閉じない)`、`停止禁止` 等)。ユーザーにも可視な status indicator として簡潔さを優先 (詳細な caller 向け instruction は HTML comment 層に集約)。
>
> 両層で共通の intent (命令形であること、現状報告 phrasing でないこと) を維持しつつ、phrasing は層別に最適化する設計。これらの keyword (HTML comment 層の英語 canonical) は `hooks/tests/step0-immediate-bash-presence.test.sh` で 4 grep target (`commands/issue/create.md` Mandatory After Interview / Mandatory After Delegation, `commands/pr/cleanup.md` Mandatory After Wiki Ingest, `commands/wiki/ingest.md` continuation HTML comment) を pin する。

## Relationship to Workflow Incident Detection

When the contract is violated in practice — the user types `continue` to recover — the orchestrator MAY emit the `auto_continuation_failed` sentinel via `plugins/rite/hooks/workflow-incident-emit.sh` so the incident is auto-registered as an Issue via Phase 5.4.4.1. This is an **optional observability sentinel** (MAY) — it does not enforce the contract but records violations for later diagnosis. The detection heuristic has false-positive risk and is out of scope for Issue #525 MUST requirements. The 3 layers above are the actual enforcement; the sentinel is observability. See `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract" section for the full specification.

## References

- `docs/SPEC.md` — "Sub-skill Return Auto-Continuation Contract" (canonical specification)
- `commands/issue/start.md` — Sub-skill Return Protocol (Global) section
- `commands/issue/create.md` — Sub-skill Return Protocol + anti/correct-pattern examples
- `commands/issue/create-interview.md` — Defense-in-Depth + caller continuation comment
- `commands/issue/create-register.md` — Terminal Completion + caller continuation comment
- `commands/issue/create-decompose.md` — Terminal Completion (Normal path) + caller continuation comment
- ~~`hooks/stop-guard.sh`~~ — removed in #675; the file no longer exists. Historical context: previously emitted phase-aware continuation hints for `create_post_interview` / `create_delegation` / `create_post_delegation`. Layer 2 protection has been retired in favor of strengthened Layer 1 + Layer 3 imperative phrasing.
