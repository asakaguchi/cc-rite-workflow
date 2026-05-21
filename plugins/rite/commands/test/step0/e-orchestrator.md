---
description: Step 0 experiment Variant E orchestrator (Task subagent + non-completion marker)
---

# Step 0 Variant E Orchestrator

**Experimental fixture for Plan §21.2 Step 0**. Not a production command.
Task tool boundary + **non-completion-like** marker (`[next: step_3]`).
Tests H5: does changing marker phrasing reduce implicit stop on Task boundary?

## Required pre-state

- `RITE_STEP0_TRIAL_ID`
- `RITE_STEP0_RESULTS_DIR` (results/e-task-non-completion)

## Steps (execute all three in the SAME response turn)

### Step 1 — Pre-boundary flag

```bash
test -n "$RITE_STEP0_TRIAL_ID" || { echo "RITE_STEP0_TRIAL_ID unset" >&2; exit 1; }
test -n "$RITE_STEP0_RESULTS_DIR" || { echo "RITE_STEP0_RESULTS_DIR unset" >&2; exit 1; }
mkdir -p "$RITE_STEP0_RESULTS_DIR"
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step1.flag"
```

### Step 2 — Task subagent boundary (non-completion marker)

Use the Agent tool to launch the `test-step0-e` subagent. The subagent emits its
final line as `[next: step_3]` instead of `[trial:completed:N]`.

When the Agent tool returns, **immediately proceed to Step 3 in the SAME response turn**.

### Step 3 — Post-boundary flag

```bash
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step3.flag"
```

Then output:

```
Trial $RITE_STEP0_TRIAL_ID variant=E complete.
```
