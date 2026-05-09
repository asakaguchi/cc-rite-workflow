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

> **Note (Layer 2 retirement)**: The historical contract item "If the stop-guard hook blocks a stop attempt..." was retired in #675 along with `hooks/stop-guard.sh`. Detection of turn-boundary heuristic firing now relies entirely on Layer 1 (prompt contract — items 1-3 above) and Layer 3 (caller HTML hint + sub-skill plain-text reminder + sub-skill HTML continuation comment, see Defense-in-depth layers below). See commit history for the original phrasing.

## Self-check after every sub-skill return

Ask yourself: **"Has the orchestrator's terminal completion marker been output yet?"**

| Orchestrator | Terminal marker | When contract ends |
|-------------|----------------|-------------------|
| `/rite:issue:start` | Phase 5.6 completion report + Workflow Termination block | After the completion report text is displayed |
| `/rite:issue:create` | `<!-- [create:completed:{N}] -->` (HTML コメント形式、Issue #561 で変更) + user-visible な `✅ + 次のステップ` が末尾手前 | HTML コメント sentinel が出力され、その前に完了メッセージ (`✅ Issue #{N} を作成しました: {url}` 等) + 次のステップが display 済みの状態 |
| Other `/rite:*` commands | Check the command's "Output" / "Terminal Completion" section | Match the explicit contract there |

If the marker has **not** been output, you are NOT done — keep going in the same turn.

> **⚠️ Duplication note**: The anti-pattern / correct-pattern blocks below are **intentionally duplicated** with `commands/issue/create.md` Sub-skill Return Protocol section. The canonical source is `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract". When modifying either copy, **always update both files and SPEC.md together** to prevent drift on the structural skeleton (step ordering, sub-skill enumeration, terminal turn boundary marker). Drift is acceptable on **orchestrator-specific Phase numbers** (e.g. protocol doc references generic `Phase 0.6`, while create.md may reference its own internal phase numbering) — these are not sync targets. A future refactor may consolidate via @include.

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

The contract is enforced across two active layers (Layer 2 was retired in #675). Violating any active layer is a bug:

| Layer | Mechanism | File | Status |
|-------|-----------|------|--------|
| 1. Prompt contract | Anti-pattern / correct-pattern + "same response turn" warnings | `commands/issue/start.md` (Sub-skill Return Protocol Global), `commands/issue/create.md` (Sub-skill Return Protocol), this reference | active |
| 3. Caller-continuation hints | HTML comment `<!-- caller: ... -->` (issue creation paths) or `<!-- continuation: ... -->` (wiki ingest path) immediately before the sub-skill's result pattern | Defense-in-Depth sections in `commands/issue/create-interview.md`, `commands/issue/create-register.md`, `commands/issue/create-decompose.md`, `commands/wiki/ingest.md` | active |

> **Layer numbering note**: Layer 2 (the former runtime hard gate via `hooks/stop-guard.sh`) was retired in #675. The numbering is preserved (Layer 1 / Layer 3) so cross-document references remain stable. See commit `e2dfae0` (or `git log -- plugins/rite/hooks/stop-guard.sh`) for the historical Layer 2 mechanism.

The LLM receives the continuation signal from two independent sources: the prompt itself (Layer 1) and the inline HTML comment in the sub-skill output (Layer 3). The imperative strength of those two surfaces is therefore load-bearing — see the blockquote below.

> **Scope note — Layer 3 imperative strengthening coverage** (Issue #910): The canonical imperative phrasing (`MUST execute as VERY FIRST tool call BEFORE any text output`, `DO NOT end the turn`, `DO NOT output any narrative text before this bash call`) is currently applied to the **interview path** (`create-interview.md` / `create.md` Mandatory After Interview + Delegation) and the **wiki ingest path** (`wiki/ingest.md` continuation HTML comment, `pr/cleanup.md` Mandatory After Wiki Ingest). The terminal sub-skills `create-register.md` and `create-decompose.md` retain older phrasing (`MUST run in the SAME response turn`, `DO NOT stop before the orchestrator's self-check completes`) and are tracked for canonical recast in a follow-up issue — they appear in the Layer 3 file list above as legitimate Layer 3 sites, just not yet at the Issue #910 imperative strength.

> **⚠️ Important — prompt-side defense alone is insufficient**: Issue #910 で実証された通り、Layer 2 (`stop-guard.sh`) の撤去 (#674/#675) 以降は hard gate が存在せず、Layer 1 (prompt contract) と Layer 3 (caller HTML hint) のみが残った状態では LLM の turn-boundary heuristic 起因の implicit stop を完全には防げない。`/rite:pr:cleanup` 実行中の `rite:wiki:ingest` (内部で `rite:wiki:lint --auto` 呼出) lint return 後 / `/rite:issue:create` 実行中の `rite:issue:create-interview` `[interview:skipped]` return 後の双方で `Sautéed for 7m 40s` 等の implicit stop が観測されている。**Mitigation**: Layer 3 (caller HTML hint) と sub-skill 側 plain-text reminder の **imperative 強度** が defense 強度を決定する。`IMMEDIATELY` 単独ではなく `MUST execute as VERY FIRST tool call BEFORE any text output, narrative, or response generation` のような命令形 + 否定形重ねがけが implicit stop の確率を下げる経験的観測 (Issue #910 D-01)。`継続中` のような現状報告ではなく `MUST continue (turn を閉じない)` のような命令形が natural stopping point を消去する。

> **3 layer canonical signaling pattern** (Issue #910 適用): caller HTML hint (Layer 3a) / sub-skill plain-text reminder (Layer 3b) / sub-skill HTML continuation comment (Layer 3c) の 3 sub-layer で **共通 intent** (命令形 / natural stopping point の消去) を反復することで、LLM が任意の path で return block を read しても turn-boundary heuristic が発火しない構造にする。Layer 3a/3b/3c は Layer 3 の **3 sub-layer** であり、上記 Defense-in-depth table の `Layer 3` の機構を internal に分解したもの。**phrasing kind は 2 種類に分類される** (3 sub-layer × 2 phrasing kind):
>
> | sub-layer | phrasing kind | 内容 |
> |-----------|--------------|------|
> | 3a (caller HTML hint) | English canonical | `MUST execute as VERY FIRST tool call BEFORE any text output`、`DO NOT end the turn`、`DO NOT output any narrative text before this bash call` (LLM が機械的に grep して読み取る経路) |
> | 3b (sub-skill plain-text reminder) | Japanese imperative | `MUST continue (turn を閉じない)`、`停止禁止` 等 (user-facing 短縮形、簡潔さ優先) |
> | 3c (sub-skill HTML continuation comment) | English canonical | 3a と同じ canonical full form (sub-skill 側で emit、caller が grep して読み取る経路) |
>
> 両 phrasing kind で共通の intent (命令形であること、現状報告 phrasing でないこと) を維持しつつ、phrasing は層別に最適化する設計。canonical 英語 keyword (3a / 3c) は `hooks/tests/step0-immediate-bash-presence.test.sh` で **4 cross-orchestrator grep targets** (`commands/issue/create.md` Mandatory After Interview / Mandatory After Delegation の 2 site、`commands/pr/cleanup.md` Mandatory After Wiki Ingest の 1 site、`commands/wiki/ingest.md` continuation HTML comment の 1 site = 計 4 site) に加えて、補完的に **2 caller HTML literal pins** (`commands/issue/create-interview.md` の 2 caller HTML block) を pin する。test scope は合計 6 site で、4 grep target は主たる canonical site、2 caller HTML literal pin は asymmetric weakening 検出のための補完 site という主従構造を持つ。

## Relationship to Workflow Incident Detection

When the contract is violated in practice — the user types `continue` to recover — the orchestrator MAY emit the `auto_continuation_failed` sentinel via `plugins/rite/hooks/workflow-incident-emit.sh` so the incident is auto-registered as an Issue via Phase 5.4.4.1. This is an **optional observability sentinel** (MAY) — it does not enforce the contract but records violations for later diagnosis. The detection heuristic has false-positive risk and is out of scope for Issue #525 MUST requirements. The active layers (Layer 1 + Layer 3) above are the actual enforcement; the sentinel is observability. See `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract" section for the full specification.

## References

- `docs/SPEC.md` — "Sub-skill Return Auto-Continuation Contract" (canonical specification)
- `commands/issue/start.md` — Sub-skill Return Protocol (Global) section
- `commands/issue/create.md` — Sub-skill Return Protocol + anti/correct-pattern examples
- `commands/issue/create-interview.md` — Defense-in-Depth + caller continuation comment
- `commands/issue/create-register.md` — Terminal Completion + caller continuation comment
- `commands/issue/create-decompose.md` — Terminal Completion (Normal path) + caller continuation comment
- `commands/wiki/ingest.md` — Phase 9.1 caller continuation HTML comment
