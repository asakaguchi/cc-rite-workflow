---
description: Step 0 experiment Variant A orchestrator (Skill boundary + completion marker)
---

# Step 0 Variant A Orchestrator

**Experimental fixture for Plan §21.2 Step 0**. Not a production command.
Skill boundary + completion-like marker pattern. Baseline observation.

## Required pre-state

The user (operator) must export these before invoking this command:

- `RITE_STEP0_TRIAL_ID` — current trial number (e.g., `01`, `02`, ...)
- `RITE_STEP0_RESULTS_DIR` — absolute path to results directory (e.g., `/home/akiyoshi/Projects/personal/cc-rite-workflow/tests/step0-experiment/results/a-skill-completion`)

If either variable is unset, abort with an error message and do not proceed.

## Steps (execute all three in the SAME response turn)

### Step 1 — Pre-boundary flag

Run exactly:

```bash
test -n "$RITE_STEP0_TRIAL_ID" || { echo "RITE_STEP0_TRIAL_ID unset" >&2; exit 1; }
test -n "$RITE_STEP0_RESULTS_DIR" || { echo "RITE_STEP0_RESULTS_DIR unset" >&2; exit 1; }
mkdir -p "$RITE_STEP0_RESULTS_DIR"
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step1.flag"
echo "step1 flag created: trial-$RITE_STEP0_TRIAL_ID-step1.flag"
```

### Step 2 — Skill boundary

Invoke skill: `rite:test:step0:a-subskill`.

The sub-skill performs a small read-only action and emits `[trial:completed:<trial_id>]` as its final marker. When the Skill tool returns control, **immediately proceed to Step 3 in the SAME response turn**. Do NOT stop.

### Step 3 — Post-boundary flag

Run exactly:

```bash
touch "$RITE_STEP0_RESULTS_DIR/trial-$RITE_STEP0_TRIAL_ID-step3.flag"
echo "step3 flag created: trial-$RITE_STEP0_TRIAL_ID-step3.flag"
```

Then output exactly one line:

```
Trial $RITE_STEP0_TRIAL_ID variant=A complete.
```

## Success criterion

Trial succeeds if BOTH `trial-{N}-step1.flag` AND `trial-{N}-step3.flag` exist in `$RITE_STEP0_RESULTS_DIR` after the turn ends. Failure if step3 flag is missing (implicit stop after Skill return).
