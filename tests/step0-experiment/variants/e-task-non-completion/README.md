# Variant E: Task subagent + non-completion marker

## Setup

- Orchestrator: `/rite:test:step0:e-orchestrator`
- Subagent: `test-step0-e` (agents/test-step0-e.md)
- Marker: `[next: step_3]` (next-instruction, not completion-like)

## Boundary tool

`Agent` (Task) tool, same as Variant B. Only the marker form differs.

## Hypothesis tested

**H5**: Non-completion marker (next-instruction phrasing) reduces implicit stop
even on the same Task boundary as Variant B.

## Comparison

vs Variant B (same boundary, completion marker): direct measurement of marker
form effect with all else held constant.

If E succeeds dramatically more than B, marker phrasing is a major factor
independent of boundary tool. This would suggest **marker redesign alone**
might be a viable patch (cf. Plan §20.13 Alternative C).

## Results location

`tests/step0-experiment/results/e-task-non-completion/trial-{N}-{step1,step3}.flag`
