---
description: Step 0 experiment Variant B orchestrator (Task subagent + completion marker)
---

# Step 0 Variant B Orchestrator

**Experimental fixture for Plan §21.2 Step 0**. Not a production command.
Task tool boundary + completion-like marker. Tests H2 (subagent context isolation).

## Required pre-state

- `RITE_STEP0_TRIAL_ID` (e.g., `01`)
- `RITE_STEP0_RESULTS_DIR` (absolute path, results/b-task-completion)

## Steps (execute all three in the SAME response turn)

### Step 1 — Pre-boundary flag

```bash
test -n "$RITE_STEP0_TRIAL_ID" || { echo "RITE_STEP0_TRIAL_ID unset" >&2; exit 1; }
test -n "$RITE_STEP0_RESULTS_DIR" || { echo "RITE_STEP0_RESULTS_DIR unset" >&2; exit 1; }
mkdir -p "$RITE_STEP0_RESULTS_DIR"
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step1.flag"
echo "step1 flag created."
```

### Step 2 — Task subagent boundary

Use the Agent tool to launch the `test-step0-b` subagent with this prompt verbatim:

```
You are a dummy subagent for Step 0 Variant B experiment.

Perform two trivial read-only commands (pwd and git rev-parse HEAD) and report their output. Then emit as the final line of your response:

[trial:completed:<trial_id>]

where <trial_id> is the value of the RITE_STEP0_TRIAL_ID environment variable in the calling shell (the caller will substitute it). For your purposes, use the literal placeholder text 'TRIAL-ID' — the caller does not need the exact id, only the marker format.
```

(`Agent` tool call with `subagent_type: test-step0-b`.)

When the Agent tool returns, **immediately proceed to Step 3 in the SAME response turn**. Do NOT stop.

### Step 3 — Post-boundary flag

```bash
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step3.flag"
echo "step3 flag created."
```

Then output:

```
Trial $RITE_STEP0_TRIAL_ID variant=B complete.
```

## Success criterion

Same as Variant A: both step1 and step3 flags must exist after the turn ends.
