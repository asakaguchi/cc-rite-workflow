#!/usr/bin/env bash
# Aggregate all Step 0 trial records and emit a falsification verdict.
#
# Usage:
#   aggregate.sh
#
# Reads:  tests/step0-experiment/results/<variant>/trial-*.json
# Writes: tests/step0-experiment/results/aggregate.json + human summary to stdout

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
RESULTS_ROOT="$REPO_ROOT/tests/step0-experiment/results"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for aggregation" >&2
  exit 1
fi

VARIANTS=(a-skill-completion b-task-completion c-bash-completion d-inline-completion e-task-non-completion)

# Build per-variant stats
tmp_agg=$(mktemp)
trap 'rm -f "$tmp_agg"' EXIT
echo '{}' > "$tmp_agg"

for v in "${VARIANTS[@]}"; do
  dir="$RESULTS_ROOT/$v"
  if [ ! -d "$dir" ]; then
    jq --arg v "$v" '. + {($v): {total: 0, success: 0, failure: 0, excluded: 0, failure_rate: null}}' "$tmp_agg" > "$tmp_agg.next" && mv "$tmp_agg.next" "$tmp_agg"
    continue
  fi
  total=0; success=0; failure=0; excluded=0
  for trial in "$dir"/trial-*.json; do
    [ -f "$trial" ] || continue
    total=$((total + 1))
    outcome=$(jq -r '.outcome // "unknown"' "$trial" 2>/dev/null)
    case "$outcome" in
      success) success=$((success + 1)) ;;
      failure_implicit_stop) failure=$((failure + 1)) ;;
      excluded_no_start) excluded=$((excluded + 1)) ;;
    esac
  done
  countable=$((success + failure))
  failure_rate="null"
  if [ "$countable" -gt 0 ]; then
    failure_rate=$(echo "scale=4; $failure / $countable" | bc 2>/dev/null || echo "null")
  fi
  jq --arg v "$v" \
     --argjson t "$total" \
     --argjson s "$success" \
     --argjson f "$failure" \
     --argjson x "$excluded" \
     --arg fr "$failure_rate" \
     '. + {($v): {total: $t, success: $s, failure: $f, excluded: $x, failure_rate: (if $fr == "null" then null else ($fr | tonumber) end)}}' \
     "$tmp_agg" > "$tmp_agg.next" && mv "$tmp_agg.next" "$tmp_agg"
done

# Falsification verdicts (Plan §20.2)
A_FAIL=$(jq -r '."a-skill-completion".failure' "$tmp_agg")
B_FAIL=$(jq -r '."b-task-completion".failure' "$tmp_agg")
C_FAIL=$(jq -r '."c-bash-completion".failure' "$tmp_agg")
D_FAIL=$(jq -r '."d-inline-completion".failure' "$tmp_agg")
E_FAIL=$(jq -r '."e-task-non-completion".failure' "$tmp_agg")

A_RATE=$(jq -r '."a-skill-completion".failure_rate' "$tmp_agg")
B_RATE=$(jq -r '."b-task-completion".failure_rate' "$tmp_agg")
C_RATE=$(jq -r '."c-bash-completion".failure_rate' "$tmp_agg")
D_RATE=$(jq -r '."d-inline-completion".failure_rate' "$tmp_agg")
E_RATE=$(jq -r '."e-task-non-completion".failure_rate' "$tmp_agg")

verdict_H2="undetermined"; [ "$B_FAIL" != "null" ] && [ "$B_FAIL" -ge 2 ] && verdict_H2="falsified_task_isolation_insufficient"
[ "$B_FAIL" != "null" ] && [ "$B_FAIL" -lt 2 ] && [ "$(jq '."b-task-completion".total' "$tmp_agg")" -ge 20 ] && verdict_H2="supported"

verdict_H3="undetermined"; [ "$C_FAIL" != "null" ] && [ "$C_FAIL" -ge 2 ] && verdict_H3="falsified_bash_worker_insufficient"
[ "$C_FAIL" != "null" ] && [ "$C_FAIL" -lt 2 ] && [ "$(jq '."c-bash-completion".total' "$tmp_agg")" -ge 20 ] && verdict_H3="supported"

# H4: marker dominance — compare A vs D failure rate. If |A_rate - D_rate| < 0.05, marker dominates (boundary doesn't matter)
verdict_H4="undetermined"
if [ "$A_RATE" != "null" ] && [ "$D_RATE" != "null" ]; then
  diff=$(echo "scale=4; if ($A_RATE > $D_RATE) $A_RATE - $D_RATE else $D_RATE - $A_RATE" | bc 2>/dev/null || echo "0")
  small=$(echo "$diff < 0.05" | bc 2>/dev/null || echo 0)
  if [ "$small" = "1" ]; then
    verdict_H4="marker_dominant"
  else
    verdict_H4="boundary_dominant"
  fi
fi

# H5: marker phrasing — compare B vs E. If E_rate - B_rate < -0.3 (E much better), phrasing matters
verdict_H5="undetermined"
if [ "$B_RATE" != "null" ] && [ "$E_RATE" != "null" ]; then
  diff_be=$(echo "scale=4; $B_RATE - $E_RATE" | bc 2>/dev/null || echo "0")
  big=$(echo "$diff_be > 0.3" | bc 2>/dev/null || echo 0)
  if [ "$big" = "1" ]; then
    verdict_H5="non_completion_marker_helps"
  else
    verdict_H5="marker_form_minor"
  fi
fi

jq \
  --arg h2 "$verdict_H2" \
  --arg h3 "$verdict_H3" \
  --arg h4 "$verdict_H4" \
  --arg h5 "$verdict_H5" \
  '. + {verdicts: {H2: $h2, H3: $h3, H4: $h4, H5: $h5}}' \
  "$tmp_agg" > "$RESULTS_ROOT/aggregate.json"

# Human summary
echo "========================================"
echo "Step 0 Aggregate Results"
echo "========================================"
printf "%-30s %5s %5s %5s %5s %s\n" "Variant" "Total" "OK" "Fail" "Excl" "FailRate"
for v in "${VARIANTS[@]}"; do
  t=$(jq -r --arg v "$v" '.[$v].total' "$tmp_agg")
  s=$(jq -r --arg v "$v" '.[$v].success' "$tmp_agg")
  f=$(jq -r --arg v "$v" '.[$v].failure' "$tmp_agg")
  x=$(jq -r --arg v "$v" '.[$v].excluded' "$tmp_agg")
  r=$(jq -r --arg v "$v" '.[$v].failure_rate' "$tmp_agg")
  printf "%-30s %5s %5s %5s %5s %s\n" "$v" "$t" "$s" "$f" "$x" "$r"
done
echo ""
echo "Falsification verdicts:"
echo "  H2 (Task isolation):     $verdict_H2"
echo "  H3 (Bash worker):        $verdict_H3"
echo "  H4 (Marker vs Boundary): $verdict_H4"
echo "  H5 (Marker phrasing):    $verdict_H5"
echo ""
echo "Full JSON: $RESULTS_ROOT/aggregate.json"
