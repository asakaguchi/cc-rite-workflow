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
| 1. Prompt contract | Anti-pattern / correct-pattern + "same response turn" warnings + Mandatory After orchestrator prose | `commands/issue/start.md` (Sub-skill Return Protocol Global), `commands/issue/create.md` (Sub-skill Return Protocol + Mandatory After Interview/Delegation), `commands/pr/cleanup.md` (Mandatory After Wiki Ingest), `commands/wiki/ingest.md` (Mandatory After Auto-Lint), this reference | active |
| 3. Caller-continuation hints (decomposed into 3 sub-layers 3a/3b/3c — see "3 layer canonical signaling pattern" blockquote below) | (3a) caller HTML hint with `<!-- caller: ... -->` prefix (issue creation paths only) immediately before the sub-skill's result pattern + (3b) plain-text Markdown blockquote reminder (`> ⏭ MUST continue (turn を閉じない): ...` 等の命令形) emitted by the sub-skill alongside the HTML hint + (3c) sub-skill HTML continuation comment with `<!-- continuation: ... -->` prefix (wiki ingest path only) that the caller greps | Defense-in-Depth sections in `commands/issue/create-interview.md`, `commands/issue/create-register.md`, `commands/issue/create-decompose.md`, `commands/wiki/ingest.md`; Phase 9.2 三点セット blockquote (Layer 3b imperative) in `commands/wiki/lint.md` | active |

> **Layer numbering note**: Layer 2 (the former runtime hard gate via `hooks/stop-guard.sh`) was retired in #675. The numbering gap is intentional — `commands/wiki/ingest.md` and other documents that still use `Layer 2` as a grep-able marker do so to keep historical cross-references resolvable in-repo. See commit `e2dfae0` (or `git log -- plugins/rite/hooks/stop-guard.sh`) for the historical Layer 2 mechanism.

The LLM receives the continuation signal from two independent sources: the prompt itself (Layer 1) and the **inline HTML comment + plain-text reminder + sub-skill HTML continuation comment** in the sub-skill output (Layer 3 = 3a + 3b + 3c の internal decomposition、下記 blockquote 参照)。The imperative strength of those two surfaces (Layer 1 と Layer 3 全体) is therefore load-bearing — see the blockquote below.

> **Scope note — Issue #910 / #917 imperative strengthening coverage (Layer 1 + Layer 3, 5 site canonical)**: The canonical imperative phrasing (`MUST execute as VERY FIRST tool call BEFORE any text output`, `DO NOT end the turn`, `DO NOT output any narrative text before this bash call`) is applied across two layers — **Layer 1 sites** (orchestrator prompt contract): `create.md` Mandatory After Interview Step 0 prose (canonical `VERY FIRST tool call`), `create.md` Mandatory After Delegation pre-section prose (`VERY FIRST cognitive action` variant — Self-check is cognitive, not a tool call; rationale at `create.md` Mandatory After Delegation pre-section prose), `pr/cleanup.md` Mandatory After Wiki Ingest Step 0 prose (canonical `VERY FIRST tool call`), `wiki/ingest.md` Mandatory After Auto-Lint Step 0 prose (canonical `VERY FIRST tool call` — Issue #917 で 4 site → 5 site canonical recast、cleanup.md Step 0 と byte-equal 相当の二重 patch 構造、`Step 0 Immediate Bash Action` 名称で `--preserve-error-count` + `--if-exists` 付与); **Layer 3 sites** (caller HTML hint + sub-skill continuation comment): `create-interview.md` caller HTML literal + plain-text reminder, `wiki/ingest.md` continuation HTML comment (canonical `VERY FIRST tool call`). Layer 3b plain-text reminder (`> ⏭ MUST continue (turn を閉じない): ...`) は `wiki/lint.md` Phase 9.2 三点セット blockquote にも Issue #917 で recast (旧 `> ⏭ 継続中: ...` 現状報告 → 命令形)、`create-interview.md` Return Output Format と表記対称化。 The terminal sub-skills `create-register.md` and `create-decompose.md` retain older phrasing (`MUST run in the SAME response turn`, `DO NOT stop before the orchestrator's self-check completes`); they appear in the Layer 3 file list above as legitimate Layer 3 sites, just not yet at the Issue #910 imperative strength. Canonical recast is to be tracked separately if recast becomes necessary (no follow-up Issue is currently filed — the older phrasing remains operational for terminal sub-skill paths and may be left as-is unless empirical observation reveals an implicit-stop regression on those specific paths). (Prose mentions of `stop-guard.sh` in `commands/pr/cleanup.md` and `commands/wiki/ingest.md` are stale post-#675 and tracked separately for incremental cleanup; they do not affect runtime behavior since the helper file no longer exists.)

> **Issue #917 historical context — 5th canonical site addition**: Pre-#917 baseline で `wiki/ingest.md` の Mandatory After Auto-Lint Layer 1 prose は意図的に canonical phrasing 適用対象外 (older `MUST execute in the SAME response turn` phrasing) のまま残置されていた (理由: `[lint:completed:auto]` return path の orchestrator 役割で簡素な return contract で十分という設計判断)。しかし PR #916 マージ直後の `/rite:pr:cleanup` 実機実行で、`rite:wiki:ingest` (caller) が `rite:wiki:lint --auto` return 後に Mandatory After Auto-Lint Step 0 を発火させず implicit stop する事象 (累積 27 回目) を直接観測。Issue #917 D-01 で「pre-#917 phrasing は不十分、5 site canonical 対称化が必要」と判定し、本 site を canonical に格上げ。これにより 4 site (`create.md` ×2 / `cleanup.md` / `ingest.md` continuation HTML comment) → 5 site (前 4 site + `ingest.md` Mandatory After Auto-Lint Step 0) に拡張。

> **⚠️ Important — prompt-side defense alone is insufficient**: Issue #910 で実証された通り、Layer 2 (`stop-guard.sh`) の撤去 (#674/#675) 以降は hard gate が存在せず、Layer 1 (prompt contract) と Layer 3 (caller HTML hint = 3a + plain-text reminder = 3b + sub-skill HTML continuation = 3c の 3 sub-layer) のみが残った状態では LLM の turn-boundary heuristic 起因の implicit stop を完全には防げない。`/rite:pr:cleanup` 実行中の `rite:wiki:ingest` (内部で `rite:wiki:lint --auto` 呼出) lint return 後 / `/rite:issue:create` 実行中の `rite:issue:create-interview` `[interview:skipped]` return 後の双方で `Sautéed for 7m 40s` 等の implicit stop が観測されている。**Mitigation**: Layer 3 全体 (3a/3b/3c の 3 sub-layer 共通) の **imperative 強度** が defense 強度を決定する。`IMMEDIATELY` 単独ではなく `MUST execute as VERY FIRST tool call BEFORE any text output, narrative, or response generation` のような命令形 + 否定形重ねがけが implicit stop の確率を下げる経験的観測 (Issue #910 D-01)。`継続中` のような現状報告ではなく `MUST continue (turn を閉じない)` のような命令形が natural stopping point を消去する。

> **3 layer canonical signaling pattern** (Issue #910 適用): caller HTML hint (Layer 3a) / sub-skill plain-text reminder (Layer 3b) / sub-skill HTML continuation comment (Layer 3c) の 3 sub-layer で **共通 intent** (命令形 / natural stopping point の消去) を反復することで、LLM が任意の path で return block を read しても turn-boundary heuristic が発火しない構造にする。Layer 3a/3b/3c は Layer 3 の **3 sub-layer** であり、上記 Defense-in-depth table の `Layer 3` の機構を internal に分解したもの。**phrasing kind は 2 種類に分類される** (3 sub-layer × 2 phrasing kind):
>
> | sub-layer | emit 主体 / prefix | phrasing kind | 内容 |
> |-----------|-------------------|--------------|------|
> | 3a (caller HTML hint) | sub-skill 出力末尾の caller-targeted HTML comment / prefix `<!-- caller: ... -->` (issue creation paths: `create-interview.md` / `create-register.md` / `create-decompose.md`) | English canonical | `MUST execute as VERY FIRST tool call BEFORE any text output`、`DO NOT end the turn`、`DO NOT output any narrative text before this bash call` (caller 側の LLM が機械的に grep して読み取る経路) |
> | 3b (sub-skill plain-text reminder) | sub-skill 出力本文の Markdown blockquote / 行頭 `> ⏭ MUST continue (turn を閉じない):` 形式 (`create-interview.md` 等) | Japanese imperative | `MUST continue (turn を閉じない)`、`停止禁止` 等 (user-facing 短縮形、簡潔さ優先) |
> | 3c (sub-skill HTML continuation comment) | sub-skill 出力末尾の continuation-targeted HTML comment / prefix `<!-- continuation: ... -->` (wiki ingest path: `wiki/ingest.md`) | English canonical | 3a と同じ canonical full form (caller 側で grep して読み取る経路、prefix のみ 3a と区別) |
>
> 3a/3b/3c の機構的差異は **HTML/plain-text の出力形式** と **prefix literal** (3a: `<!-- caller: -->` for issue creation paths / 3c: `<!-- continuation: -->` for wiki ingest path) で、両者とも sub-skill が emit して caller LLM が grep する経路は共通。共通の intent (命令形であること、現状報告 phrasing でないこと) を維持しつつ、phrasing は層別に最適化する設計。
>
> **Historical note (PR-2 #926 / ADR docs/designs/parent-routing-unification.md)**: 旧 `hooks/tests/step0-immediate-bash-presence.test.sh` (および 4-site-symmetry / caller-html-literal-symmetry / create-interview-responsibility-separation の 3 件) は parent-routing pattern 移行に伴い PR-2 で撤去された。`create-interview.md` の caller HTML literal / Layer 3a / step0 site は廃止済 (parent-routing pattern では caller-side Step 0 不要)。残存対象 (`wiki/ingest.md` continuation HTML comment / Mandatory After Auto-Lint Step 0 / `cleanup.md` Mandatory After Wiki Ingest Step 0) は PR-3 / PR-4 で parent-routing pattern に移行予定。PR-7 で `parent-routing-pattern-uniformity.test.sh` が代替の対称性 pin となる。本セクションの 5 cross-orchestrator pin / 3 supplementary pin の記述は PR-8 で全面 rewrite 予定の historical reference として残す。

## Relationship to Workflow Incident Detection

When the contract is violated in practice — the user types `continue` to recover — the orchestrator MAY emit the `auto_continuation_failed` sentinel via `plugins/rite/hooks/workflow-incident-emit.sh` so the incident is auto-registered as an Issue via Phase 5.4.4.1. This is an **optional observability sentinel** (MAY) — it does not enforce the contract but records violations for later diagnosis. The detection heuristic has false-positive risk and is out of scope for Issue #525 MUST requirements. The active layers (Layer 1 + Layer 3) above are the actual enforcement; the sentinel is observability. See `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract" section for the full specification.

## References

- `docs/SPEC.md` — "Sub-skill Return Auto-Continuation Contract" (canonical specification)
- `commands/issue/start.md` — Sub-skill Return Protocol (Global) section
- `commands/issue/create.md` — Sub-skill Return Protocol + anti/correct-pattern examples + Mandatory After Interview/Delegation (Issue #910 imperative strengthening)
- `commands/pr/cleanup.md` — Mandatory After Wiki Ingest Step 0 (Issue #910 imperative strengthening)
- `commands/issue/create-interview.md` — Defense-in-Depth + caller continuation comment
- `commands/issue/create-register.md` — Terminal Completion + caller continuation comment
- `commands/issue/create-decompose.md` — Terminal Completion (Normal path) + caller continuation comment
- `commands/wiki/ingest.md` — Mandatory After Auto-Lint (Layer 1) + Phase 9.1 caller continuation HTML comment (Layer 3c)
- `commands/wiki/lint.md` — Phase 9.2 三点セット blockquote (Layer 3b imperative recast、Issue #917)
