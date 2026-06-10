# Sub-skill Return Auto-Continuation Contract

> **Status: Retired**: This reference and the Layer 1/3/4 defense-in-depth model
> it described are **retired**. The implicit-stop defense layer (3 hooks:
> `auto-fire-step0.sh`, `stop-create-interview-block.sh`, `verify-terminal-output.sh`)
> and the 12 sub-skill files (`start-execute`, `start-publish`, `start-finalize`,
> `create-interview`, `create-register`, `create-decompose`,
> `implementation-plan`, `parent-routing`, `child-issue-selection`,
> `branch-setup`, `work-memory-init`, `completion-report`) were removed in
> flat workflow consolidation.
>
> `/rite:issue:create` is a single flat workflow. `/rite:issue:start`
> (formerly `commands/issue/start.md`, deleted in a later refactor) was
> further decomposed into `/rite:pr:open` / `/rite:pr:iterate` /
> `/rite:pr:ready` / `/rite:pr:merge`. When the LLM stops mid-flow,
> recovery is via `/rite:resume` — read `commands/resume.md` Phase 5.3
> (Phase enum → Step mapping (SoT)) for the phase → command routing
> table.
>
> Inbound references in `SKILL.md`, `docs/SPEC.md`, and `phase-mapping.md`
> that point here for "the canonical layer model" are stale historical
> context; the layered model no longer exists at runtime.

## Migration map

| Pre-#1079 mechanism | Post-#1079 equivalent |
|---|---|
| Layer 1 prompt contract in sub-skill files | `commands/issue/create.md` is a single flat workflow. `commands/issue/start.md` was removed in a later refactor and decomposed into `commands/pr/{open,iterate,ready,merge}.md` |
| Layer 2 `stop-guard.sh` Stop hook | Removed (#675) |
| Layer 3 caller HTML hint + sub-skill continuation comment | N/A — no sub-skill delegation, no continuation hand-off |
| Layer 4 `auto-fire-step0.sh` PostToolUse Skill hook | Removed (#1079); recovery via `/rite:resume` |
| Layer 4a/4b orchestrator self-check | Inlined into flat workflow steps |

If you reached this file from a runtime documentation link, the surviving
`rite:lint`, `rite:pr:create`, `rite:pr:review`, `rite:pr:fix`,
`rite:pr:ready` sub-skills each emit a single sentinel pattern
(`[lint:*]`, `[pr:created:N]`, `[review:*]`, `[fix:*]`, `[ready:returned-to-caller]`)
that the flat orchestrator captures and branches on. No HTML comment or
hook-side enforcement is involved.

> **Sentinel naming policy**: `:returned-to-caller` 形式は旧
> `:completed` 形式の置換語彙。旧形式は LLM の turn-boundary heuristic と
> 衝突し caller の次 step を skip する事象を構造的に誘発したため、新形式
> で terminal vocabulary を排除した。各 emit site では sentinel 直前に
> `<!-- skill return signal: caller must continue next step -->` を併記。
