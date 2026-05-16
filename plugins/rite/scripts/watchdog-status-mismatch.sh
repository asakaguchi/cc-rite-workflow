#!/bin/bash
# rite workflow - Status Mismatch Watchdog (Issue #1003 AC-9)
#
# Scans repository Issues that are linked to OPEN, Ready-for-review PRs (isDraft=false)
# and detects ones whose GitHub Projects Status is still "In Progress" — the symptom
# of the Issue #1003 silent-skip bug. Outputs JSON to stdout and a warning summary to
# stderr. Optionally attempts reconciliation when --reconcile is passed.
#
# Usage:
#   bash watchdog-status-mismatch.sh [options]
#
# Options:
#   --dry-run         Report only; do not reconcile (default)
#   --reconcile      Attempt to update mismatched Issue Status → "In Review" via
#                    projects-status-update.sh. Failures are logged but never block.
#   --limit N        Maximum PRs to scan (default: 50)
#   --quiet          Suppress stderr warnings (JSON output still produced)
#   -h, --help       Show usage
#
# Output (stdout):
#   {
#     "scan_summary": {
#       "prs_scanned": N,
#       "mismatches_found": M,
#       "reconciled": K,
#       "reconcile_failures": F
#     },
#     "mismatches": [
#       { "pr_number": 1001, "issue_number": 998, "current_status": "In Progress", "reconcile_result": "updated|failed|skipped|not_attempted" }
#     ],
#     "warnings": []
#   }
#
# Exit codes:
#   0  success, no mismatches
#   1  fatal error (missing config / gh failure)
#   2  mismatches detected (intended for CI gating)
set -euo pipefail

# --- Arg parse ---
DRY_RUN=true
RECONCILE=false
LIMIT=50
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; RECONCILE=false; shift ;;
    --reconcile) DRY_RUN=false; RECONCILE=true; shift ;;
    --limit)     LIMIT="$2"; shift 2 ;;
    --quiet)     QUIET=true; shift ;;
    -h|--help)
      sed -n '3,/^set -euo/p' "$0" | sed -n 's/^# \?//p' | head -n -1
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1 ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --limit must be a positive integer (got: $LIMIT)" >&2
  exit 1
fi

# --- Locate rite-config.yml ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

# Find repo root (look upward for rite-config.yml or .git)
CWD="$(pwd)"
REPO_ROOT="$CWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/rite-config.yml" ] && [ ! -d "$REPO_ROOT/.git" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

if [ ! -f "$REPO_ROOT/rite-config.yml" ]; then
  echo "ERROR: rite-config.yml not found from $CWD upward" >&2
  exit 1
fi

PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""

if [ "$PROJECTS_ENABLED" != "true" ] || [ -z "$PROJECT_NUMBER" ]; then
  jq -n --arg reason "projects_disabled_or_unconfigured" \
    '{scan_summary: {prs_scanned: 0, mismatches_found: 0, reconciled: 0, reconcile_failures: 0}, mismatches: [], warnings: [$reason]}'
  exit 0
fi

# --- Repo info ---
REPO_INFO=$(gh repo view --json owner,name 2>/dev/null) || {
  echo "ERROR: gh repo view failed" >&2
  exit 1
}
REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login')
REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name')

# --- Scan OPEN, non-draft PRs ---
PR_LIST=$(gh pr list --state open --limit "$LIMIT" --json number,isDraft,body,headRefName 2>/dev/null) || {
  echo "ERROR: gh pr list failed" >&2
  exit 1
}

PRS_SCANNED=0
MISMATCHES=()
RECONCILED=0
RECONCILE_FAILURES=0

while IFS= read -r pr_entry; do
  pr_number=$(printf '%s' "$pr_entry" | jq -r '.number')
  is_draft=$(printf '%s' "$pr_entry" | jq -r '.isDraft')
  pr_body=$(printf '%s' "$pr_entry" | jq -r '.body // empty')
  head_ref=$(printf '%s' "$pr_entry" | jq -r '.headRefName // empty')
  PRS_SCANNED=$((PRS_SCANNED + 1))

  if [ "$is_draft" != "false" ]; then
    continue  # Draft PR — not yet Ready, skip
  fi

  # Extract linked Issue number from PR body (Closes #N / Fixes #N / Resolves #N) or branch name (issue-N)
  issue_number=$(printf '%s' "$pr_body" | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)
  if [ -z "$issue_number" ] && [[ "$head_ref" =~ issue-([0-9]+) ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    continue  # No linked Issue
  fi

  # Query Issue's current Status in the Project
  current_status=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project { number }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$issue_number" 2>/dev/null \
    | jq -r --argjson pn "$PROJECT_NUMBER" \
      '[.data.repository.issue.projectItems.nodes[]? | select(.project.number == $pn) | .fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // empty' 2>/dev/null) || current_status=""

  if [ "$current_status" = "In Progress" ]; then
    reconcile_result="not_attempted"
    if [ "$RECONCILE" = "true" ]; then
      reconcile_json=$(bash "$PLUGIN_ROOT/scripts/projects-status-update.sh" "$(jq -n \
        --argjson issue "$issue_number" --arg owner "$REPO_OWNER" --arg repo "$REPO_NAME" \
        --argjson project_number "$PROJECT_NUMBER" --arg status "In Review" \
        --argjson auto_add false --argjson non_blocking true \
        '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>/dev/null) || reconcile_json=""
      reconcile_result=$(printf '%s' "$reconcile_json" | jq -r '.result // "failed"' 2>/dev/null) || reconcile_result="failed"
      if [ "$reconcile_result" = "updated" ]; then
        RECONCILED=$((RECONCILED + 1))
      else
        RECONCILE_FAILURES=$((RECONCILE_FAILURES + 1))
      fi
    fi
    MISMATCHES+=("$(jq -n --argjson pr "$pr_number" --argjson issue "$issue_number" \
      --arg status "$current_status" --arg recon "$reconcile_result" \
      '{pr_number:$pr, issue_number:$issue, current_status:$status, reconcile_result:$recon}')")
    if [ "$QUIET" != "true" ]; then
      echo "[watchdog] ⚠️ mismatch: PR=#$pr_number isDraft=false → Issue #$issue_number Status=\"$current_status\" (expected In Review)" >&2
    fi
  fi
done < <(printf '%s' "$PR_LIST" | jq -c '.[]')

MISMATCH_COUNT=${#MISMATCHES[@]}

# Build output JSON
if [ "$MISMATCH_COUNT" -eq 0 ]; then
  mismatches_json='[]'
else
  mismatches_json=$(printf '%s\n' "${MISMATCHES[@]}" | jq -s '.')
fi

jq -n \
  --argjson scanned "$PRS_SCANNED" \
  --argjson found "$MISMATCH_COUNT" \
  --argjson reconciled "$RECONCILED" \
  --argjson failures "$RECONCILE_FAILURES" \
  --argjson mismatches "$mismatches_json" \
  '{scan_summary: {prs_scanned: $scanned, mismatches_found: $found, reconciled: $reconciled, reconcile_failures: $failures}, mismatches: $mismatches, warnings: []}'

if [ "$MISMATCH_COUNT" -gt 0 ]; then
  exit 2
fi
exit 0
