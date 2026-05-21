# Variant B: Task subagent + completion marker

## Setup

- Orchestrator: `/rite:test:step0:b-orchestrator`
- Subagent: `test-step0-b` (agents/test-step0-b.md)
- Marker: `[trial:completed:N]` (completion-like, same as Variant A)

## Boundary tool

`Agent` (Task) tool. Subagent runs in an isolated context and returns a textual
report ending with the completion-like marker.

## Hypothesis tested

**H2**: Task subagent boundary isolates `stop_reason: end_turn` to the
subagent's own context, so the parent continues normally after Task return.

## Comparison

vs Variant A (Skill boundary, same marker): differential measures Task vs Skill
boundary effect.
vs Variant E (Task boundary, non-completion marker): differential measures the
effect of marker form on Task boundary.

## Results location

`tests/step0-experiment/results/b-task-completion/trial-{N}-{step1,step3}.flag`
