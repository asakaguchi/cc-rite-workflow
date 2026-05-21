#!/usr/bin/env bash
# Step 0 experiment Variant C bash worker.
# Not for production use. Performs read-only dummy work + emits completion-like marker.

set -uo pipefail

TRIAL_ID="${RITE_STEP0_TRIAL_ID:-UNKNOWN}"

echo "worker: trial=$TRIAL_ID"
echo "worker: pwd=$(pwd)"
echo "worker: head=$(git rev-parse HEAD 2>/dev/null || echo NO_GIT)"

# Final line: completion-like marker
echo "[trial:completed:$TRIAL_ID]"
