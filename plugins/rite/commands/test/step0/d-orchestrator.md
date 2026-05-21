---
description: Step 0 experiment Variant D orchestrator (inline only + completion marker)
---

# Step 0 Variant D Orchestrator

**Experimental fixture for Plan §21.2 Step 0**. Not a production command.
No boundary tool: parent performs all work inline in a single turn. Tests whether
completion-like marker alone (without any tool boundary) can trigger implicit stop.

## Required pre-state

- `RITE_STEP0_TRIAL_ID`
- `RITE_STEP0_RESULTS_DIR` (results/d-inline-completion)

## Steps (all inline in the SAME response turn)

### Step 1 — Pre-boundary flag

```bash
test -n "$RITE_STEP0_TRIAL_ID" || { echo "RITE_STEP0_TRIAL_ID unset" >&2; exit 1; }
test -n "$RITE_STEP0_RESULTS_DIR" || { echo "RITE_STEP0_RESULTS_DIR unset" >&2; exit 1; }
mkdir -p "$RITE_STEP0_RESULTS_DIR"
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step1.flag"
```

### Step 2 — Inline dummy work + emit completion-like marker

Run exactly:

```bash
pwd
git rev-parse HEAD
echo "[trial:completed:$RITE_STEP0_TRIAL_ID]"
```

The completion marker appears in the Bash output. The orchestrator MUST proceed
to Step 3 immediately in the SAME response turn.

### Step 3 — Post-boundary flag

```bash
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step3.flag"
```

Then output:

```
Trial $RITE_STEP0_TRIAL_ID variant=D complete.
```
