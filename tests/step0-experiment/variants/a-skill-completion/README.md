# Variant A: Skill boundary + completion marker (baseline)

## Setup

- Orchestrator: `/rite:test:step0:a-orchestrator`
- Sub-skill: `/rite:test:step0:a-subskill`
- Marker: `[trial:completed:N]` (completion-like)

## Boundary tool

`Skill` tool. The orchestrator invokes `rite:test:step0:a-subskill` and the
sub-skill emits the completion-like marker before returning control.

## Hypothesis tested

**H1**: Skill tool boundary increases the probability of `stop_reason: end_turn`
after the sub-skill returns the completion-like marker.

This variant is the **baseline** — its failure rate is the reference point that
B/C/D/E variants are compared against.

## Results location

`tests/step0-experiment/results/a-skill-completion/trial-{N}-{step1,step3}.flag`
