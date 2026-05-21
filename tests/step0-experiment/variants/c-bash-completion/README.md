# Variant C: Bash worker + completion marker

## Setup

- Orchestrator: `/rite:test:step0:c-orchestrator`
- Worker: `plugins/rite/scripts/test/step0-worker.sh`
- Marker: `[trial:completed:N]` (completion-like)

## Boundary tool

`Bash` tool. Worker script executes in a sub-process and returns stdout to the
caller. The final stdout line is the completion-like marker.

## Hypothesis tested

**H3**: Bash worker boundary structurally avoids implicit stop because the
parent treats Bash output as data rather than a skill/agent handoff.

## Comparison

vs Variant A (Skill boundary, same marker): differential measures Bash vs Skill
boundary effect.
vs Variant D (no boundary, same marker): differential isolates the effect of
Bash boundary specifically vs pure inline execution.

## Results location

`tests/step0-experiment/results/c-bash-completion/trial-{N}-{step1,step3}.flag`
