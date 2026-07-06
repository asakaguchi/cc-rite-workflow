#!/usr/bin/env bash
# doc-heavy-patterns-drift-check.sh
#
# Detect drift in `doc_file_patterns` across 2 files that MUST agree on the
# same set of glob tokens for tech-writer Activation / Doc-Heavy PR detection:
#
#   1. plugins/rite/skills/review/SKILL.md            (ステップ 1.2.7
#      `doc_file_patterns` pseudo-code block)
#   2. plugins/rite/skills/reviewers/SKILL.md        (Reviewers table,
#      Technical Writer row — source of truth for tech-writer Activation
#      patterns after the per-reviewer skill files were consolidated into the
#      named-subagent definitions)
#
# This covers 系統 1 of the drift invariants catalogued in
# skills/review/references/internal-consistency.md. 系統 2 (canonical category
# name literal match) and 系統 3 (review.md ステップ 5.4 Doc-Heavy section 2-place
# duplication) are out of scope for this checker.
#
# The 2 files encode the same pattern list in 2 different textual forms
# (pseudo-code without backticks / Markdown table cell). This checker does NOT
# compare the raw text — it extracts glob tokens per file and compares the
# resulting sets. Syntactic differences (ordering, spacing, line breaks) are
# tolerated by design; only set-level drift is reported.
#
# --- Token extraction contract -----------------------------------------------
#
# A glob token is any substring matching the POSIX regex
#   [A-Za-z0-9/._-]*\*[A-Za-z0-9/._*-]*
# of length >= 3 characters (to exclude bare `*` / `**` artifacts). Tokens are
# extracted from a constrained section of each file so that unrelated glob-like
# text elsewhere in the file (other skills, other pseudo-code, Note paragraphs
# that repeat pattern examples) does NOT bleed into the comparison:
#
#   review.md      : only lines strictly between `doc_file_patterns = [` and
#                    the subsequent closing `]` at column 0.
#   SKILL.md       : only the single table row that begins with
#                    `| Technical Writer |`.
#
# Drift reporting is based on set difference (`comm -23`) in both directions
# between the 2 files. Every token present in only one file is emitted as a
# finding. Exit code 1 when any finding is emitted, 0 when both sets are
# identical.
#
# Usage:
#   doc-heavy-patterns-drift-check.sh --all [--repo-root DIR] [--quiet]
#
# Exit codes:
#   0  No drift detected across the 2 files (or not applicable — invoked
#      outside the rite plugin source tree, e.g. marketplace/consumer install)
#   1  Drift detected (symmetric set difference non-empty)
#   2  Invocation error (bad args, empty section)

# `-e` is intentionally omitted for consistency with the sibling drift
# checkers (reviewer-registry-drift-check.sh, distributed-fix-drift-check.sh),
# where a `-euo` "correction" would let a no-match grep pipeline kill the
# script before its extraction guard runs and misclassify an invocation
# error as drift. This file's only pipeline (extract_review / extract_skill)
# is already wrapped in `if !` below, which is exempt from `-e` regardless —
# a future refactor that removes that `if !` wrapping would reintroduce the
# same risk here, so `-e` stays omitted as a defensive baseline.
set -uo pipefail

REPO_ROOT=""
QUIET=0
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: doc-heavy-patterns-drift-check.sh --all [options]

Options:
  --all              Scan the 2 canonical doc_file_patterns files
                     (review.md / SKILL.md) under plugins/rite/.
                     This is the only supported mode; the invariant
                     has no meaning for arbitrary targets.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
                     (per-finding output on stdout is preserved)
  -h, --help         Show this help

Exit codes:
  0  No drift detected across the 2 files (or not applicable)
  1  Drift detected (symmetric set difference non-empty)
  2  Invocation error (bad args, empty section)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$USE_ALL" -ne 1 ]; then
  echo "ERROR: --all is required (doc_file_patterns drift is a fixed 2-file check)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

REVIEW_FILE="plugins/rite/skills/review/SKILL.md"
SKILL_FILE="plugins/rite/skills/reviewers/SKILL.md"

if [ ! -f "$REVIEW_FILE" ] && [ ! -f "$SKILL_FILE" ]; then
  # Neither canonical file exists: this is not the rite plugin source tree
  # (e.g. a consumer repo that installs rite as a marketplace plugin only,
  # with no plugins/rite/ markdown to gate). Treat as a clean skip rather
  # than an invocation error, matching bang-backtick-check.sh's
  # --skip-if-no-target precedent — this check has nothing to compare.
  log "[doc-heavy-patterns-drift] not applicable: neither $REVIEW_FILE nor $SKILL_FILE found under $REPO_ROOT — clean skip"
  exit 0
fi

for f in "$REVIEW_FILE" "$SKILL_FILE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    echo "  Likely cause: partial checkout, or the sibling file was moved/renamed without updating this checker" >&2
    echo "  Recovery: verify both $REVIEW_FILE and $SKILL_FILE exist, or pass --repo-root pointing to a complete rite plugin source tree" >&2
    exit 2
  fi
done

# Canonical signal-specific trap pattern (repo convention — see
# references/bash-trap-patterns.md): declare path before mktemp,
# set trap before mktemp, and guard the cleanup with ${var:-} so an early
# signal (between path declaration and mktemp completion) cannot dereference
# an unset variable. Signals return conventional exit codes (INT=130,
# TERM=143, HUP=129) so callers can distinguish the cause.
WORK_DIR=""
_cleanup() {
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

WORK_DIR="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 2; }

# --- Section extractors ------------------------------------------------------

# review.md: the ステップ 1.2.7 pseudo-code block between `doc_file_patterns = [`
# and the next line consisting of `]` at column 0.
extract_review() {
  awk '
    /^doc_file_patterns = \[/ { in_sec = 1; next }
    in_sec && /^\]/ { in_sec = 0; next }
    in_sec { print }
  ' "$REVIEW_FILE"
}

# SKILL.md: the single Technical Writer row of the Reviewers table.
extract_skill() {
  grep -E '^\| Technical Writer \|' "$SKILL_FILE"
}

# --- Token extraction --------------------------------------------------------
#
# awk scans each line and emits every substring matching the glob-token regex
# of length >= 3. The while/match/substr idiom (rather than a one-shot match)
# captures multiple tokens per line (e.g. `- \`docs/**\`, \`documentation/**\`
# ` yields two tokens).
extract_tokens() {
  awk '
    {
      line = $0
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /[A-Za-z0-9/._-]*\*[A-Za-z0-9/._*-]*/)) break
        tok = substr(sub_s, RSTART, RLENGTH)
        if (length(tok) >= 3) print tok
        pos = pos + RSTART + RLENGTH
        if (RLENGTH == 0) pos = pos + 1
      }
    }
  '
}

# --- Normalization -----------------------------------------------------------
normalize_set() {
  sort -u
}

# --- Run extractors ----------------------------------------------------------
#
# Each pipeline is guarded by an explicit exit-code check so an IO error,
# grep/awk failure, or redirect write failure surfaces with the actual cause
# instead of falling through to the `< 10` token guard below. Without the
# check a partial/empty set file would reach the guard, which would then
# misreport the failure as "section markers changed" and misdirect debugging.
#
# `pipefail` is already active globally (line 56 `set -uo pipefail`), so the
# `if !` guard below catches mid-pipeline failures. Do NOT toggle pipefail
# locally — doing so either duplicates the global setting or silently
# disables it for the remainder of the script, breaking future pipe guards.
if ! extract_review | extract_tokens | normalize_set > "$WORK_DIR/review.set"; then
  echo "ERROR: ${REVIEW_FILE} extractor pipeline failed (grep/awk IO error or write failure)" >&2
  echo "  Likely cause: read permission on ${REVIEW_FILE}, or /tmp write failure" >&2
  echo "  Recovery: inspect the file and re-run; do not confuse this with a section-marker change" >&2
  exit 2
fi
if ! extract_skill | extract_tokens | normalize_set > "$WORK_DIR/skill.set"; then
  echo "ERROR: ${SKILL_FILE} extractor pipeline failed (grep/awk IO error or write failure)" >&2
  echo "  Likely cause: read permission on ${SKILL_FILE}, or /tmp write failure" >&2
  echo "  Recovery: inspect the file and re-run; do not confuse this with a section-marker change" >&2
  exit 2
fi

review_count=$(wc -l < "$WORK_DIR/review.set")
skill_count=$(wc -l < "$WORK_DIR/skill.set")

log "review.md        : ${review_count} glob tokens"
log "SKILL.md         : ${skill_count} glob tokens"

# Each section is expected to define at least 10 glob tokens (the canonical
# list has 18 as of this writing). An empty or undersized set almost always
# means the section markers changed and extraction fell off the end, so fail
# fast with an invocation error rather than silently reporting a large drift.
for kv in "review.md:${review_count}" "SKILL.md:${skill_count}"; do
  file="${kv%:*}"
  count="${kv##*:}"
  if [ "$count" -lt 10 ]; then
    echo "ERROR: $file extracted only $count glob tokens (expected >= 10)" >&2
    echo "  Likely cause: section markers changed and extractor fell through" >&2
    echo "  Recovery: inspect the section boundaries in doc-heavy-patterns-drift-check.sh" >&2
    exit 2
  fi
done

# --- Diff report -------------------------------------------------------------

diff_count=0

report_diff() {
  local a="$1" a_label="$2" b="$3" b_label="$4"
  local only_in_a
  only_in_a=$(comm -23 "$a" "$b")
  if [ -n "$only_in_a" ]; then
    echo "[doc-heavy-patterns-drift] only in ${a_label} (missing in ${b_label}):"
    while IFS= read -r tok; do
      echo "  - ${tok}"
      diff_count=$((diff_count + 1))
    done <<< "$only_in_a"
  fi
}

report_diff "$WORK_DIR/review.set" "review.md ステップ 1.2.7 doc_file_patterns" \
            "$WORK_DIR/skill.set"  "SKILL.md Technical Writer row"
report_diff "$WORK_DIR/skill.set"  "SKILL.md Technical Writer row" \
            "$WORK_DIR/review.set" "review.md ステップ 1.2.7 doc_file_patterns"

log "==> Total doc-heavy-patterns-drift findings: ${diff_count}"

if [ "$diff_count" -gt 0 ]; then
  exit 1
fi
exit 0
