#!/usr/bin/env bash
# sh-cross-ref-check.sh
#
# Detect cross-file step/phase references that live inside shell-script prose
# (echo strings and comments) under plugins/rite/**/*.sh and verify them against
# the actual headings of the referenced markdown file. Companion to
# comment-line-ref-check.sh (which targets `<file>:<NN>` line-number references)
# and the markdown-side anchor check in distributed-fix-drift-check.sh Pattern 4.
#
# Why a separate hook:
#   A review found an overshoot in wiki-growth-check.sh where a hint
#   string referenced a step in close.md using the wrong keyword (the file uses
#   the "Phase" convention, but the prose said the in-scope "ステップ"
#   convention). Earlier review cycles only scanned `.md` files, so `.sh` prose
#   was never checked. This hook closes that gap mechanically.
#
# What is detected (two independent checks per reference):
#   (A) dangling number  — the referenced section number does NOT exist as a
#                          heading number in the target file.
#   (B) keyword mismatch — the referenced number DOES exist, but the keyword
#                          used in the prose (ステップ / Phase) does not match
#                          the target file's own convention.
#
# Heading-convention model (verified against the real tree):
#   Only TOP-LEVEL `##` headings carry the keyword:
#       `## ステップ N: title`   (ステップ-style file, e.g. pr/review.md, pr/open.md)
#       `## Phase N: title`      (Phase-style file,    e.g. issue/close.md, lint.md)
#   SUB headings are bare-number, WITHOUT the keyword:
#       `#### 6.5.W.2 Wiki Raw Commit`
#   Therefore a file's convention is DERIVED from its own headings (count of
#   ステップ vs Phase keyword headings) rather than from a hardcoded path map —
#   a hardcoded map is fragile (e.g. open.md is ステップ-style, not Phase, and
#   create.md differs between issue/ and pr/).
#
# Reference grammar matched in prose:
#   <file-token>.(md|sh)  <keyword>  <number>
#     file-token : bare basename (review.md) OR path (commands/pr/review.md)
#     keyword    : ステップ | Phase
#     number     : N(.X)*  where X is [0-9A-Za-z]  (e.g. 6.5.W.2, 4.4.W.2, 3.15)
#
# Scope / non-goals:
#   - Targets that are `.sh` files or `.md` files with no numbered headings are
#     UNVERIFIABLE and silently skipped (no step/phase headings to match).
#   - Unresolvable file references (file not found under plugins/rite) are out of
#     scope here — dangling *file* references are a separate concern.
#   - Pre-existing inconsistencies are reported as warnings; intentional or
#     historical references can be exempted with an inline whitelist marker
#     (`drift-check-ignore`) on the same line (cleanup itself is out of scope).
#
# Exclusions:
#   - This script's own file (self-exclusion under --all).
#   - plugins/rite/hooks/tests/ (test fixtures intentionally contain bad refs).
#   - Any line containing the marker `drift-check-ignore`.
#
# Usage:
#   sh-cross-ref-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = inconsistency detected, 2 = invocation error.

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: sh-cross-ref-check.sh [options]

Options:
  --all              Scan plugins/rite/**/*.sh (excluding hooks/tests/ and self)
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary output on stderr
  -h, --help         Show this help

Detected (cross-file step/phase references in shell prose):
  <file>.(md|sh) (ステップ|Phase) <number>
  (A) dangling number   — number not present as a heading in the target file
  (B) keyword mismatch  — number present but keyword conflicts with the target
                          file's own convention

Exclusions: self / hooks/tests/ / lines containing 'drift-check-ignore'.

Exit codes:
  0  No inconsistency detected
  1  Inconsistency detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
if [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: repo-root not a directory: $REPO_ROOT" >&2
  exit 2
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  base="plugins/rite"
  if [ ! -d "$base" ]; then
    echo "ERROR: --all requested but $base does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  self_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  self_rel=""
  case "$self_abs" in
    "$REPO_ROOT"/*) self_rel="${self_abs#"$REPO_ROOT"/}" ;;
  esac
  while IFS= read -r f; do
    # Test fixtures intentionally embed malformed references — skip the suite.
    case "$f" in plugins/rite/hooks/tests/*) continue ;; esac
    if [ -n "$self_rel" ] && [ "$f" = "$self_rel" ]; then
      continue
    fi
    TARGETS+=("$f")
  done < <(find "$base" -type f -name '*.sh' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE=""
_sh_cross_ref_cleanup() { rm -f "${FINDINGS_FILE:-}"; }
trap 'rc=$?; _sh_cross_ref_cleanup; exit $rc' EXIT
trap '_sh_cross_ref_cleanup; exit 130' INT
trap '_sh_cross_ref_cleanup; exit 143' TERM
trap '_sh_cross_ref_cleanup; exit 129' HUP
FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }

# Reference grammar. The number token (`[0-9]+(\.[0-9A-Za-z]+)*`) stops at the
# first non-[.0-9A-Za-z] byte, so prose ranges like `Phase 3.5-3.9` yield the
# leading number `3.5` (the `-` is not consumed).
FILE_RE='[A-Za-z0-9_][A-Za-z0-9_./-]*\.(md|sh)'
NUM_RE='[0-9]+(\.[0-9A-Za-z]+)*'
REF_RE="${FILE_RE}[[:space:]]+(ステップ|Phase)[[:space:]]+${NUM_RE}"

# Per-target caches (keyed by resolved repo-relative path).
declare -A CONV_CACHE=()   # path -> "ステップ" | "Phase" | "" (unknown)
declare -A NUMS_CACHE=()   # path -> newline-joined heading numbers ("" if none)

# Emit a file's content with fenced code blocks removed. A heading scan that
# reads the raw file would treat shell comments inside ```bash fences (e.g.
# `# 1401-1404 ...`) as markdown headings, polluting the heading-number set and
# masking dangling references. Toggling on any line whose first non-space run is
# a code fence (3+ backticks/tildes) drops fence delimiters and their contents,
# while genuine top-level headings (outside fences) pass through unchanged.
strip_code_fences() {
  awk '/^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next } !in_fence { print }' "$1" 2>/dev/null
}

# Derive a file's keyword convention from the majority of its keyword-bearing
# headings. Empty result = no clear convention (keyword check is skipped).
derive_convention() {
  local path="$1" s p stripped
  stripped=$(strip_code_fences "$path")
  s=$(printf '%s\n' "$stripped" | grep -cE '^#{1,6}[[:space:]]+ステップ[[:space:]]' || true)
  p=$(printf '%s\n' "$stripped" | grep -cE '^#{1,6}[[:space:]]+Phase[[:space:]]' || true)
  if [ "$s" -gt "$p" ]; then printf 'ステップ'
  elif [ "$p" -gt "$s" ]; then printf 'Phase'
  else printf ''
  fi
}

# Extract the set of heading numbers in a file. A heading is `#{1,6} <text>`;
# the number is the leading numeric token of the text, with the optional
# keyword prefix stripped. Headings without a number contribute nothing.
extract_heading_numbers() {
  local path="$1"
  strip_code_fences "$path" \
    | grep -E '^#{1,6}[[:space:]]' \
    | sed -E 's/^#+[[:space:]]+//' \
    | grep -oE "^((ステップ|Phase)[[:space:]]+)?${NUM_RE}" \
    | sed -E 's/^(ステップ|Phase)[[:space:]]+//' \
    | sort -u
}

cache_target() {
  local path="$1"
  [ -n "${NUMS_CACHE[$path]+x}" ] && return 0
  NUMS_CACHE[$path]="$(extract_heading_numbers "$path")"
  CONV_CACHE[$path]="$(derive_convention "$path")"
}

# Resolve a file token to candidate repo-relative paths (echoed one per line).
resolve_candidates() {
  local token="$1"
  case "$token" in
    */*)
      [ -f "$token" ] && printf '%s\n' "$token"
      [ -f "plugins/rite/$token" ] && printf '%s\n' "plugins/rite/$token"
      ;;
    *)
      find plugins/rite -type f -name "$token" 2>/dev/null | sort
      ;;
  esac
}

# Verify one extracted reference against its target file(s).
check_ref() {
  local src="$1" lineno="$2" token="$3" kw="$4" num="$5"
  local -a candidates=()
  while IFS= read -r c; do [ -n "$c" ] && candidates+=("$c"); done < <(resolve_candidates "$token")
  [ "${#candidates[@]}" -eq 0 ] && return 0   # unresolvable file ref — out of scope

  local verifiable=0 num_found=0 kw_ok=0
  local -a convs=()
  local c nums conv
  for c in "${candidates[@]}"; do
    cache_target "$c"
    nums="${NUMS_CACHE[$c]}"
    [ -z "$nums" ] && continue            # .sh target or no numbered headings — unverifiable
    verifiable=1
    if grep -Fxq "$num" <<< "$nums"; then
      num_found=1
      conv="${CONV_CACHE[$c]}"
      convs+=("${conv:-?}")
      if [ -z "$conv" ] || [ "$conv" = "$kw" ]; then
        kw_ok=1
      fi
    fi
  done

  [ "$verifiable" -eq 0 ] && return 0       # no verifiable candidate

  if [ "$num_found" -eq 0 ]; then
    printf '[sh-cross-ref] %s:%s: dangling number: "%s %s %s" — number %s not found as a heading in %s\n' \
      "$src" "$lineno" "$token" "$kw" "$num" "$num" "${candidates[*]}" >> "$FINDINGS_FILE"
  elif [ "$kw_ok" -eq 0 ]; then
    printf '[sh-cross-ref] %s:%s: keyword mismatch: "%s %s %s" — target convention is %s, prose says %s\n' \
      "$src" "$lineno" "$token" "$kw" "$num" "${convs[*]}" "$kw" >> "$FINDINGS_FILE"
  fi
}

# Split a single matched reference substring into token / keyword / number.
parse_and_check() {
  local src="$1" lineno="$2" ref="$3"
  local token kw num rest
  token=$(grep -oE "^${FILE_RE}" <<< "$ref")
  [ -z "$token" ] && return 0
  rest="${ref#"$token"}"
  kw=$(grep -oE '(ステップ|Phase)' <<< "$rest" | head -1)
  num=$(grep -oE "${NUM_RE}" <<< "$rest" | head -1)
  [ -z "$kw" ] || [ -z "$num" ] && return 0
  check_ref "$src" "$lineno" "$token" "$kw" "$num"
}

check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  local numbered lineno content ref
  while IFS= read -r numbered; do
    lineno="${numbered%%:*}"
    content="${numbered#*:}"
    case "$content" in *drift-check-ignore*) continue ;; esac
    while IFS= read -r ref; do
      [ -n "$ref" ] && parse_and_check "$file" "$lineno" "$ref"
    done < <(grep -oE "$REF_RE" <<< "$content")
  done < <(grep -nE "$REF_RE" "$file" 2>/dev/null || true)
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
log "==> Total sh-cross-ref findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
