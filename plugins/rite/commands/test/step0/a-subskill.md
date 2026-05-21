---
description: Step 0 experiment Variant A sub-skill (returns completion-like marker)
---

# Step 0 Variant A Sub-skill

**Experimental fixture for Plan §21.2 Step 0**. Not a production command.
This sub-skill is invoked from `a-orchestrator.md` via the Skill tool to create a
real Skill boundary with a completion-like marker.

## Required pre-state

`RITE_STEP0_TRIAL_ID` must be set in the environment (the orchestrator establishes it before invocation).

## Steps

### Step 1 — Read-only dummy work

Run exactly:

```bash
pwd
git rev-parse HEAD
```

The output of these commands is informational only.

### Step 2 — Emit completion-like marker as the final line

Output the following two-line block as the absolute final text of your response (no narrative after it):

```
Sub-skill done.
[trial:completed:$RITE_STEP0_TRIAL_ID]
```

Replace `$RITE_STEP0_TRIAL_ID` literally with the value of the environment variable.

After emitting the marker, control returns to the orchestrator (`a-orchestrator.md`). The orchestrator MUST proceed to its Step 3 in the SAME response turn. This sub-skill MUST NOT instruct the caller to stop.
