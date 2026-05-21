# Variant D: Inline (no boundary) + completion marker

## Setup

- Orchestrator: `/rite:test:step0:d-orchestrator`
- Marker: `[trial:completed:N]` (completion-like, embedded in inline Bash echo)

## Boundary tool

**None**. Parent performs all dummy work in a single inline Bash call. The
completion marker appears in Bash stdout but no separate skill/agent/worker
return event occurs.

## Hypothesis tested

This variant is a **control** to isolate marker effect from boundary effect:

- If A (Skill + marker) fails more than D (inline + marker), boundary tool
  matters
- If D fails as often as A, marker phrasing alone may be sufficient to trigger
  implicit stop

## Comparison

vs Variant A: isolates Skill boundary effect.
vs Variant C: isolates Bash boundary effect (vs no boundary at all).

## Results location

`tests/step0-experiment/results/d-inline-completion/trial-{N}-{step1,step3}.flag`
