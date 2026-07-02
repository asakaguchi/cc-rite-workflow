#!/usr/bin/env bash
# wiki-backfill-skipped-frontmatter.sh
#
# One-time, idempotent back-fill of the `ingest_status: skipped` /
# `skip_reason:` frontmatter onto historically-skipped raw sources
# (Issue #1730).
#
# Background:
#   Issue #1520 (Sub-3, PR #1540) moved the `ingest:skip` Source of Truth from
#   `.rite/wiki/log.md` (a table) to each raw source's frontmatter
#   (`ingest_status: skipped` + `skip_reason`). That PR only wired the
#   *going-forward* mechanism — it did NOT back-fill the raw sources that had
#   already been skipped before the migration. As a result, 231 raws remained in
#   the state "`ingested: true`, not registered in any page's `sources.ref`, and
#   without the skip frontmatter marker". `wiki-lint-skipped-refs.sh` scans
#   frontmatter only, so those raws fell out of the skipped set and risked being
#   miscounted as `missing_concept` (blocking) instead of `unregistered_raw`
#   (informational) in wiki/lint.md ステップ 6.2.
#
#   log.md retains the human-facing `ingest:skip` change-log entries, so it is
#   the authoritative source for each historically-skipped raw's `skip_reason`.
#   This script reconciles that history back onto the entities.
#
# What it does (idempotent — safe to re-run):
#   For each raw source under `.rite/wiki/raw/**/*.md` that is
#     (1) `ingested: true`,
#     (2) NOT already carrying an `ingest_status:` frontmatter key,
#     (3) NOT registered in any page's `sources[].ref` (the "S" set — a
#         page-contributing raw is genuinely NOT skipped, so it must be left
#         untouched), and
#     (4) recorded as `ingest:skip` in log.md (yielding a reason),
#   insert `ingest_status: skipped` + `skip_reason: "<reason>"` immediately after
#   the `ingested: true` line, matching the frontmatter shape ingest.md writes for
#   new skips. A raw satisfying (1)-(3) but NOT (4) is reported (no reason to
#   fabricate) and left untouched.
#
# The `skip_reason` value is emitted via `python3 json.dumps(..., ensure_ascii=
# False)`. A JSON string literal is a valid YAML double-quoted scalar, so this is
# a bullet-proof encoder for arbitrary reason prose (embedded `"`, `\`, `#`, `:`,
# backticks) and matches the double-quoted style ingest.md already writes.
#
# Branch strategy:
#   separate_branch — edits files in the `.rite/wiki-worktree` worktree (checked
#                     out to `wiki.branch_name`); this script ensures the worktree
#                     via wiki-worktree-setup.sh. Commit + push is left to
#                     wiki-worktree-commit.sh (the caller runs it after this).
#   same_branch     — edits `.rite/wiki/raw/**` in the current tree.
#
# This script performs frontmatter edits ONLY; it never commits. Pair with
# `wiki-worktree-commit.sh` (separate_branch) or a normal commit (same_branch).
#
# Usage:
#   bash wiki-backfill-skipped-frontmatter.sh [--dry-run] [--repo-root DIR]
#
# Options:
#   --dry-run          Report what would change; write nothing. Exits 0.
#   --repo-root DIR    Repository root (default: shared state root via
#                      state-path-resolve.sh, falling back to git rev-parse).
#   -h, --help         Show this help.
#
# Output (stdout): one structured summary line
#   [wiki-backfill] backfilled=<N>; skipped_existing=<N>; page_registered=<N>; \
#     no_reason=<N>; total_ingested=<N>; branch_strategy=<s>[; dry_run=1]
#
# Exit codes:
#   0  Normal (including dry-run and "nothing to back-fill")
#   1  Environment / config error (not a git repo, wiki disabled, wiki dir
#      missing, python3 unavailable)
#   2  Invocation error (unknown argument, repo-root cd failure)

set -uo pipefail

_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$_SCRIPT_DIR/../control-char-neutralize.sh"
# shellcheck source=lib/wiki-config.sh
source "$_SCRIPT_DIR/lib/wiki-config.sh"

DRY_RUN=0
REPO_ROOT=""

usage() {
  sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi

# Resolve to the SHARED state root (main checkout) so `.rite/wiki-worktree`
# resolves identically from a linked worktree session (mirrors
# wiki-worktree-setup.sh). state-path-resolve.sh returns `git rev-parse
# --show-toplevel` verbatim outside multi-session use.
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$("$_SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null)" || REPO_ROOT=""
  [ -n "$REPO_ROOT" ] || REPO_ROOT="$(git rev-parse --show-toplevel)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required (used to YAML-safe-encode skip_reason)" >&2
  exit 1
fi

# ---- Wiki config -----------------------------------------------------------
if [ ! -f rite-config.yml ]; then
  echo "ERROR: rite-config.yml not found at repo root '$REPO_ROOT'" >&2
  exit 1
fi
wiki_enabled=$(parse_wiki_scalar enabled)
case "$wiki_enabled" in
  true|yes|1) ;;
  *) echo "[wiki-backfill] skipped: wiki feature disabled (wiki.enabled=$wiki_enabled)" >&2; exit 1 ;;
esac
branch_strategy=$(parse_wiki_scalar branch_strategy)
[ -n "$branch_strategy" ] || branch_strategy="separate_branch"

# ---- Resolve the wiki working directory (holds raw/, pages/, log.md) --------
case "$branch_strategy" in
  same_branch)
    WIKI_DIR="$REPO_ROOT/.rite/wiki"
    ;;
  separate_branch)
    wiki_branch=$(parse_wiki_scalar branch_name)
    [ -n "$wiki_branch" ] || wiki_branch="wiki"
    validate_wiki_branch_name "$wiki_branch" || exit 1
    WIKI_DIR="$REPO_ROOT/.rite/wiki-worktree/.rite/wiki"
    if [ ! -d "$WIKI_DIR" ]; then
      # Ensure the worktree exists (idempotent). Non-fatal warnings tolerated.
      bash "$_SCRIPT_DIR/wiki-worktree-setup.sh" >/dev/null 2>&1 || true
    fi
    ;;
  *)
    echo "ERROR: unknown wiki.branch_strategy '$branch_strategy' (expected separate_branch|same_branch)" >&2
    exit 1
    ;;
esac

if [ ! -d "$WIKI_DIR/raw" ]; then
  echo "ERROR: wiki raw directory not found: $WIKI_DIR/raw" >&2
  [ "$branch_strategy" = "separate_branch" ] && \
    echo "  対処: bash $_SCRIPT_DIR/wiki-worktree-setup.sh で wiki worktree を用意してください" >&2
  exit 1
fi
LOG_MD="$WIKI_DIR/log.md"
if [ ! -f "$LOG_MD" ]; then
  echo "ERROR: wiki log.md not found: $LOG_MD (skip_reason の一次情報源)" >&2
  exit 1
fi

# ---- Build S: the set of raws registered in some page's sources[].ref -------
# Match `ref: "raw/..."` (quoted) and `ref: raw/...` (bare). Keys are the
# `raw/{type}/{filename}` refs; a raw in S is page-contributing => NOT skipped.
declare -A IN_PAGES=()
if [ -d "$WIKI_DIR/pages" ]; then
  while IFS= read -r ref; do
    [ -n "$ref" ] && IN_PAGES["$ref"]=1
  done < <(
    LC_ALL=C grep -rhoE 'ref:[[:space:]]*"?raw/[^"[:space:]]+' "$WIKI_DIR/pages" 2>/dev/null \
      | sed -E 's/^ref:[[:space:]]*"?//'
  )
fi

# ---- extract_skip_reason REF: emit the log.md `ingest:skip` reason for REF ---
# log.md is a markdown table: | 日時 | アクション | 対象 | 詳細 |. The 詳細 (reason)
# cell can itself contain markdown-escaped pipes (`\|`), so reason = fields
# 5..NF-1 rejoined with `|`, then unescape `\|` -> `|`. Emits the first match.
extract_skip_reason() {
  local ref="$1"
  awk -F'|' -v tgt="$ref" '
    /ingest:skip/ {
      a=$3; gsub(/^[ \t]+|[ \t]+$/, "", a)
      t=$4; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (a == "ingest:skip" && t == tgt) {
        r=$5
        for (i=6; i<NF; i++) r = r "|" $i
        gsub(/^[ \t]+|[ \t]+$/, "", r)
        gsub(/\\\|/, "|", r)
        print r
        exit
      }
    }
  ' "$LOG_MD"
}

# ---- yaml_encode: STDIN reason text -> valid YAML double-quoted scalar -------
# A JSON string literal is a valid YAML flow scalar; json.dumps handles all
# escaping (`"`, `\`, control chars) and preserves non-ASCII verbatim.
yaml_encode() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read(), ensure_ascii=False))'
}

backfilled=0
skipped_existing=0
page_registered=0
no_reason=0
total_ingested=0

# Iterate raws deterministically (sort) so dry-run / real runs align.
while IFS= read -r file; do
  [ -n "$file" ] || continue
  rel="raw/${file#"$WIKI_DIR"/raw/}"   # -> raw/{type}/{filename}

  # Frontmatter must lead the file (line 1 == '---'). Read it once.
  fm=$(awk 'NR==1 && /^---[[:space:]]*$/ {infm=1; next}
            infm && /^---[[:space:]]*$/ {exit}
            infm {print}' "$file")
  # (1) ingested: true
  printf '%s\n' "$fm" | grep -qE '^ingested:[[:space:]]*true[[:space:]]*$' || continue
  total_ingested=$((total_ingested+1))
  # (2) idempotency: already carries an ingest_status key -> leave as-is
  if printf '%s\n' "$fm" | grep -qE '^ingest_status:[[:space:]]*'; then
    skipped_existing=$((skipped_existing+1))
    continue
  fi
  # (3) page-registered raws are genuinely not skipped -> leave untouched
  if [ -n "${IN_PAGES[$rel]:-}" ]; then
    page_registered=$((page_registered+1))
    continue
  fi
  # (4) reason from log.md
  reason=$(extract_skip_reason "$rel")
  if [ -z "$reason" ]; then
    no_reason=$((no_reason+1))
    echo "WARNING: no ingest:skip entry in log.md for $rel — left untouched (reason は捏造しない)" >&2
    continue
  fi

  reason_json=$(printf '%s' "$reason" | yaml_encode)
  if [ -z "$reason_json" ]; then
    no_reason=$((no_reason+1))
    echo "WARNING: skip_reason の YAML エンコードに失敗しました: $rel — left untouched" >&2
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    backfilled=$((backfilled+1))
    echo "[dry-run] would back-fill: $rel"
    continue
  fi

  # Insert `ingest_status: skipped` + `skip_reason: <json>` after the
  # `ingested: true` line, inside the frontmatter only (first occurrence).
  # ENVIRON is used for the reason line so awk does NOT re-process its
  # backslashes (awk -v would mangle the JSON escapes).
  RITE_BF_REASON_LINE="skip_reason: $reason_json" \
  awk '
    BEGIN { infm=0; done=0 }
    NR==1 && /^---[[:space:]]*$/ { infm=1; print; next }
    infm && !done && /^---[[:space:]]*$/ { infm=0; print; next }
    infm && !done && /^ingested:[[:space:]]*true[[:space:]]*$/ {
      print
      print "ingest_status: skipped"
      print ENVIRON["RITE_BF_REASON_LINE"]
      done=1
      next
    }
    { print }
  ' "$file" > "$file.bf.tmp" && mv "$file.bf.tmp" "$file" || {
    rm -f "$file.bf.tmp"
    echo "ERROR: frontmatter 書込に失敗しました: $rel" >&2
    continue
  }
  backfilled=$((backfilled+1))
done < <(LC_ALL=C find "$WIKI_DIR/raw" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

summary="[wiki-backfill] backfilled=$backfilled; skipped_existing=$skipped_existing; page_registered=$page_registered; no_reason=$no_reason; total_ingested=$total_ingested; branch_strategy=$branch_strategy"
[ "$DRY_RUN" -eq 1 ] && summary="$summary; dry_run=1"
echo "$summary"
exit 0
