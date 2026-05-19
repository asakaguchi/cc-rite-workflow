#!/usr/bin/env bash
# migrate-review-state-to-1.1.sh
#
# Migrate review-result JSON files in `.rite/review-results/` from schema
# 1.0 / 1.0.0 / missing to canonical 1.1.0. Issue #1021 (Epic #1015).
#
# Migration adds the two fields introduced in 1.1.0 (Issue #1016):
#   - findings[].scope        — default mapping from severity
#                                 (CRITICAL/HIGH/MEDIUM → current-pr,
#                                  LOW-MEDIUM/LOW       → nit-noted)
#   - findings[].pre_existing — initialized to false (revert-test result
#                                 unknown for migrated findings; reviewer
#                                 must update manually if applicable)
#
# Additionally initializes per-PR accepted-fingerprints state files
# (`.rite/state/accepted-fingerprints-{pr}.txt`) as empty files when missing.
#
# Idempotency: jq `has(...)` guards ensure repeated runs are no-ops once a
# file is already 1.1.0. Files with schema_version already 1.1.0 are skipped.
#
# Usage:
#   migrate-review-state-to-1.1.sh                     # apply (default REPO_ROOT)
#   migrate-review-state-to-1.1.sh --dry-run           # detect only
#   REPO_ROOT="/path/to/repo" migrate-review-state-to-1.1.sh
#
# Exit codes:
#   0 — migration completed (including no-op / dry-run / empty target set)
#   1 — migration failed (atomic write or jq parse error on a file)

set -uo pipefail

# --- Argument parsing ---
DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  '') ;;
  *) echo "ERROR: unknown argument: $1 (expected: --dry-run)" >&2; exit 1 ;;
esac

# --- REPO_ROOT resolution ---
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: REPO_ROOT could not be resolved (not in a git repo and REPO_ROOT env unset)" >&2
  exit 1
fi

REVIEW_DIR="$REPO_ROOT/.rite/review-results"
STATE_DIR="$REPO_ROOT/.rite/state"

if ! command -v jq >/dev/null 2>&1; then
  echo "[rite] ERROR: jq is required for migrate-review-state-to-1.1.sh but was not found in PATH" >&2
  exit 1
fi

# --- Helper: severity → default scope mapping (1.1.0 schema doc Table) ---
# CRITICAL / HIGH / MEDIUM → current-pr
# LOW-MEDIUM / LOW         → nit-noted
# unknown severity         → current-pr (conservative — surface in fix loop)
DEFAULT_SCOPE_FILTER='
  if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
  elif .severity == "LOW-MEDIUM" or .severity == "LOW" then "nit-noted"
  else "current-pr"
  end
'

# --- Migration filter: only fills missing fields (idempotent) ---
# Outer guard: if schema_version already "1.1.0", emit unchanged.
# Otherwise: bump schema_version to "1.1.0", and per-finding fill scope /
# pre_existing only when absent (has(...) guard preserves explicit values).
MIGRATE_FILTER='
  if (.schema_version // "") == "1.1.0" then .
  else
    .schema_version = "1.1.0"
    | .findings |= map(
        (if has("scope") then . else .scope = ('"$DEFAULT_SCOPE_FILTER"') end)
        | (if has("pre_existing") then . else .pre_existing = false end)
      )
  end
'

MIGRATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
FAILED_FILES=()

migrate_file() {
  local file="$1"
  local tmp parsed_ver

  if ! jq empty "$file" 2>/dev/null; then
    echo "[rite] ERROR: $file is not valid JSON — skipping" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi

  parsed_ver=$(jq -r '.schema_version // "missing"' "$file" 2>/dev/null) || parsed_ver="missing"

  case "$parsed_ver" in
    "1.1.0")
      # Already canonical — no-op (idempotency)
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      return
      ;;
    "1.0.0"|"1.0"|"missing")
      : # proceed
      ;;
    *)
      echo "[rite] WARNING: $file has unknown schema_version='$parsed_ver' — skipping (manual review required)" >&2
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      return
      ;;
  esac

  if [ "$DRY_RUN" = "true" ]; then
    echo "[rite] dry-run: would migrate $file (schema_version='$parsed_ver' → 1.1.0)"
    MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
    return
  fi

  # Atomic write: jq → tempfile → mv
  tmp=$(mktemp "${file}.XXXXXX") || {
    echo "[rite] ERROR: mktemp failed for $file" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  }

  if ! jq "$MIGRATE_FILTER" "$file" > "$tmp" 2>/dev/null; then
    echo "[rite] ERROR: jq migration filter failed for $file" >&2
    rm -f "$tmp"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi

  if [ ! -s "$tmp" ]; then
    echo "[rite] ERROR: migrated output empty for $file (jq produced no output)" >&2
    rm -f "$tmp"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi

  if ! mv "$tmp" "$file"; then
    echo "[rite] ERROR: atomic mv failed for $file (tmp=$tmp left behind for inspection)" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi

  echo "[rite] migrated: $file ($parsed_ver → 1.1.0)" >&2
  MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
}

# --- Step 1: Migrate review-result JSON files ---
if [ -d "$REVIEW_DIR" ]; then
  while IFS= read -r -d '' f; do
    migrate_file "$f"
  done < <(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
else
  echo "[rite] info: review-results directory not present ($REVIEW_DIR) — skipping JSON migration" >&2
fi

# --- Step 2: Initialize per-PR accepted-fingerprints state files ---
# Enumerate PR numbers from `.rite/review-results/{pr}-*.json` and ensure
# `.rite/state/accepted-fingerprints-{pr}.txt` exists (empty if newly created).
INIT_COUNT=0
if [ -d "$REVIEW_DIR" ]; then
  pr_numbers=$(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
    | sed 's|.*/||; s|-.*||' \
    | grep -E '^[0-9]+$' \
    | sort -u)

  if [ -n "$pr_numbers" ]; then
    if [ "$DRY_RUN" != "true" ] && [ ! -d "$STATE_DIR" ]; then
      mkdir -p "$STATE_DIR" 2>/dev/null || {
        echo "[rite] WARNING: failed to create state directory $STATE_DIR — accepted-fingerprints init skipped" >&2
        pr_numbers=""
      }
    fi

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      state_file="$STATE_DIR/accepted-fingerprints-${pr}.txt"
      if [ ! -f "$state_file" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          echo "[rite] dry-run: would initialize empty $state_file"
        else
          : > "$state_file" || {
            echo "[rite] WARNING: failed to initialize $state_file" >&2
            continue
          }
          echo "[rite] initialized: $state_file (empty)" >&2
        fi
        INIT_COUNT=$((INIT_COUNT + 1))
      fi
    done <<< "$pr_numbers"
  fi
fi

# --- Summary ---
if [ "$DRY_RUN" = "true" ]; then
  echo "[rite] dry-run summary: would migrate=$MIGRATED_COUNT, skip=$SKIPPED_COUNT, fail=$FAILED_COUNT, init-fingerprint-files=$INIT_COUNT" >&2
else
  echo "[rite] migration summary: migrated=$MIGRATED_COUNT, skipped=$SKIPPED_COUNT, failed=$FAILED_COUNT, init-fingerprint-files=$INIT_COUNT" >&2
fi

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "[rite] failed files:" >&2
  for f in "${FAILED_FILES[@]}"; do
    echo "  - $f" >&2
  done
  exit 1
fi

exit 0
