---
description: Step 0 experiment Variant C orchestrator (Bash worker + completion marker)
---

# Step 0 Variant C Orchestrator

**Experimental fixture for Plan §21.2 Step 0**. Not a production command.
Bash worker boundary + completion-like marker. Tests H3 (Bash worker reliability).

## Required pre-state

- `RITE_STEP0_TRIAL_ID`
- `RITE_STEP0_RESULTS_DIR` (results/c-bash-completion)

## Steps (execute all three in the SAME response turn)

### Step 1 — Pre-boundary flag

```bash
test -n "$RITE_STEP0_TRIAL_ID" || { echo "RITE_STEP0_TRIAL_ID unset" >&2; exit 1; }
test -n "$RITE_STEP0_RESULTS_DIR" || { echo "RITE_STEP0_RESULTS_DIR unset" >&2; exit 1; }
mkdir -p "$RITE_STEP0_RESULTS_DIR"
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step1.flag"
```

### Step 2 — Bash worker boundary

Run exactly:

```bash
bash plugins/rite/scripts/test/step0-worker.sh
```

The worker prints status lines followed by `[trial:completed:$RITE_STEP0_TRIAL_ID]` on the final line. When the Bash tool returns, **immediately proceed to Step 3 in the SAME response turn**.

### Step 3 — Post-boundary flag

```bash
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step3.flag"
```

Then output:

```
Trial $RITE_STEP0_TRIAL_ID variant=C complete.
```
