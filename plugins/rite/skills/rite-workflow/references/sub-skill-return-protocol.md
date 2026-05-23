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
> `/rite:issue:start` and `/rite:issue:create` are now single flat workflows.
> When the LLM stops mid-flow, recovery is via `/rite:resume` — read
> `commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) for the
> phase → step routing table.
>
> Inbound references in `wiki/ingest.md`, `pr/cleanup.md`, `SKILL.md`, and
> `docs/SPEC.md` that point here for "the canonical layer model" are stale
> historical context; the layered model no longer exists at runtime.

## Migration map

| Pre-#1079 mechanism | Post-#1079 equivalent |
|---|---|
| Layer 1 prompt contract in sub-skill files | Single flat workflow in `commands/issue/start.md` / `commands/issue/create.md` |
| Layer 2 `stop-guard.sh` Stop hook | Removed (#675) |
| Layer 3 caller HTML hint + sub-skill continuation comment | N/A — no sub-skill delegation, no continuation hand-off |
| Layer 4 `auto-fire-step0.sh` PostToolUse Skill hook | Removed (#1079); recovery via `/rite:resume` |
| Layer 4a/4b orchestrator self-check | Inlined into flat workflow steps |

If you reached this file from a runtime documentation link, the surviving
`rite:lint`, `rite:pr:create`, `rite:pr:review`, `rite:pr:fix`,
`rite:pr:ready` sub-skills each emit a single sentinel pattern
(`[lint:*]`, `[pr:created:N]`, `[review:*]`, `[fix:*]`, `[ready:completed]`)
that the flat orchestrator captures and branches on. No HTML comment or
hook-side enforcement is involved.
