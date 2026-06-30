#!/usr/bin/env bash
# bash-heaviness-check.sh
#
# Detect "heavy" operational bash blocks in command markdown under
# plugins/rite/skills/**/*.md and flag them as non-blocking warnings.
# Mechanically enforces the "operational bash block heaviness convention"
# documented in skills/rite-workflow/references/coding-principles.md, which
# prose-only enforcement cannot prevent from drifting.
#
# Why a separate hook:
#   Experience showed that large operational bash blocks in command bodies
#   (python inline / nested $() / multiple heredocs / long line counts) caused
#   Claude's tool-call parsing to malform and silently end the turn with no
#   error. The writing convention was added to coding-principles.md, but prose
#   alone does not stop new drift. This hook surfaces the drift on every
#   /rite:lint run as a non-blocking warning (it never changes [lint:success]).
#
# Heaviness model (4 independent signals per fenced ```bash / ```sh block):
#   (1) python-inline  — a line invokes python with inline code (`python3 -c ...`
#                        or `python3 - <<PY` / `python3 <<PY`). Calling a `.py`
#                        helper script (no `-c`, no heredoc) is NOT a signal.
#   (2) nested-cmdsub  — a line nests command substitution, e.g.
#                        `$(cmd "$(inner)")` or `$(a $(b))`.
#   (3) multi-heredoc  — the block opens 2 or more heredocs.
#   (4) long-block     — the block body is >= 25 lines (the convention 目安).
#
# A block is flagged only when it exhibits >= 2 distinct signals. A single
# signal is intentionally NOT flagged: a lone helper invocation that passes one
# JSON heredoc, or a single block that writes a long template, is legitimate and
# matches the precedents (projects-status-update.sh callers etc.). Requiring two
# signals keeps the false-positive rate low while still catching the heavy-bash
# incident blocks, which combined all four signals at once. Heredoc *bodies* are
# treated as data: signals (1)/(2) are evaluated only on real shell lines, not on
# the literal content inside a heredoc, so a template heredoc that happens to
# contain `$(...)` or `python3 -c` example text does not produce a finding.
#
# Standalone detection (separate from the >= 2 score model):
#   inline-gh-create-title — a real shell line that runs `gh {pr,issue} create`
#     with a LITERAL `--title "..."` / `--title '...'` (the first char inside the
#     quote is neither `$` nor the closing quote). `--title "$var"` is sanctioned
#     and an empty `--title ""` / `--title ''` is ignored — both are NOT flagged.
#     The command may span multiple physical lines via backslash continuation (the
#     canonical multi-line `gh pr create --draft \` <newline> `  --title "..."` form
#     in references/gh-cli-commands.md), so the literal-title check stays armed across
#     continuation lines until the logical line ends. Unlike the four heaviness
#     signals, a single inline special-char/long title is itself a dominant
#     malformed-tool-call trigger, so it is flagged on its own — it does not
#     need a second signal. The canonical fix is to write the title via the Write
#     tool to a file and read it into a variable
#     (`pr_title=$(cat title.txt)` → `--title "$pr_title"`), or pass it through a
#     helper's `--arg title`. As with the heaviness signals, the detection runs
#     only on real shell lines (heredoc bodies are data), so example titles in a
#     heredoc body or a non-```bash fence do not produce a finding.
#
# Exclusions:
#   - plugins/rite/skills/**/tests/ (any test fixtures, if present).
#   - Any block containing the marker `drift-check-ignore` on one of its lines
#     (exempts intentional / already-reviewed heavy blocks, mirroring
#     sh-cross-ref-check.sh).
#
# Usage:
#   bash-heaviness-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = heaviness detected, 2 = invocation error.

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

# Tunables (kept in sync with the coding-principles.md convention).
LINE_THRESHOLD=25   # block body lines that count as the "long-block" signal
MIN_SIGNALS=2       # number of distinct signals required to flag a block

usage() {
  cat <<'EOF'
Usage: bash-heaviness-check.sh [options]

Options:
  --all              Scan plugins/rite/skills/**/*.md (excluding tests/)
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress output on stderr
  -h, --help         Show this help

Detected (heavy operational bash blocks; flagged at >= 2 signals):
  python-inline  — python invoked with inline code (`-c` or heredoc)
  nested-cmdsub  — nested command substitution `$( ... $( ... )`
  multi-heredoc  — 2 or more heredocs opened in one block
  long-block     — block body >= 25 lines

Detected standalone (flagged on its own, separate from the >= 2 score model):
  inline-gh-create-title — `gh {pr,issue} create` with a literal `--title "..."`
                           (`--title "$var"` and empty `--title ""` are allowed;
                            backslash line-continuation forms are also detected)

Exclusions: tests/ fixtures / blocks containing 'drift-check-ignore'.

Exit codes:
  0  No heavy block detected
  1  Heavy block detected
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
  base="plugins/rite/skills"
  if [ ! -d "$base" ]; then
    echo "ERROR: --all requested but $base does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  while IFS= read -r f; do
    # Test fixtures may intentionally embed heavy blocks — skip any tests/ dir.
    case "$f" in */tests/*) continue ;; esac
    TARGETS+=("$f")
  done < <(find "$base" -type f -name '*.md' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

WORKDIR=""
_bash_heaviness_cleanup() { rm -rf "${WORKDIR:-}"; }
trap 'rc=$?; _bash_heaviness_cleanup; exit $rc' EXIT
trap '_bash_heaviness_cleanup; exit 130' INT
trap '_bash_heaviness_cleanup; exit 143' TERM
trap '_bash_heaviness_cleanup; exit 129' HUP
WORKDIR="$(mktemp -d)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
AWK_PROG="$WORKDIR/heaviness.awk"
FINDINGS_FILE="$WORKDIR/findings"
: > "$FINDINGS_FILE"

# Block scanner. Tracks fenced bash/sh/shell blocks, evaluates the 4 heaviness
# signals on real shell lines (heredoc bodies are skipped as data), and prints
# one finding line per flagged block. `fname` labels the source file;
# `line_threshold` / `min_signals` are passed in from the shell tunables.
cat > "$AWK_PROG" <<'AWK'
BEGIN { in_block = 0 }
{
  line = $0
  if (in_block == 0) {
    if (line ~ /^[[:space:]]*(```|~~~)[[:space:]]*(bash|sh|shell)[[:space:]]*$/) {
      in_block = 1; block_start = NR
      nlines = 0; has_python = 0; heredoc_count = 0; nested = 0; exempt = 0
      gh_title_inline = 0; gh_title_line = 0
      gh_create_active = 0; gh_create_line = 0
      in_heredoc = 0; heredoc_delim = ""
    }
    next
  }
  # Inside a block. A bare fence closes it, but only when not inside a heredoc
  # body (a fence-looking line inside a heredoc body is literal data).
  if (in_heredoc == 0 && line ~ /^[[:space:]]*(```|~~~)[[:space:]]*$/) {
    evaluate(); in_block = 0; next
  }
  nlines++
  if (in_heredoc == 1) {
    tl = line; sub(/^[[:space:]]+/, "", tl)   # <<- terminators may be tab-indented
    if (tl == heredoc_delim) in_heredoc = 0
    next
  }
  if (line ~ /drift-check-ignore/) exempt = 1
  if (line ~ /python3?[[:space:]]+.*(-c([[:space:]]|=|$)|<<)/) has_python = 1
  if (line ~ /\$\([^)]*\$\(/) nested = 1
  # Standalone trigger: inline `gh {pr,issue} create` with a LITERAL
  # --title. `--title "$var"` (first char after the quote is `$`) and an empty
  # `--title ""` / `--title ''` (first char after the quote is the closing quote)
  # are both allowed — the bracket expression `[^$"']` excludes `$` and both quote
  # chars. A `gh ... create` command may span multiple physical lines via backslash
  # continuation (the canonical multi-line form in references/gh-cli-commands.md), so
  # the literal-title check stays armed across continuation lines until the command's
  # logical line ends (a line not ending in `\`). This keeps the detection from
  # missing `gh pr create --draft \` <newline> `  --title "{title}"`.
  if (line ~ /gh[[:space:]]+(pr|issue)[[:space:]]+create/) {
    gh_create_active = 1; gh_create_line = NR
  }
  if (gh_create_active == 1 && line ~ /--title[[:space:]=]+["'][^$"']/) {
    gh_title_inline = 1
    if (gh_title_line == 0) gh_title_line = gh_create_line
  }
  if (gh_create_active == 1 && line !~ /\\[[:space:]]*$/) {
    gh_create_active = 0
  }
  if (line ~ /<</ && line !~ /<<</ && line ~ /<<-?[^A-Za-z0-9_]*[A-Za-z_]/) {
    heredoc_count++
    if (match(line, /<<-?[^A-Za-z0-9_]*[A-Za-z_][A-Za-z0-9_]*/)) {
      d = substr(line, RSTART, RLENGTH); sub(/^<<-?[^A-Za-z0-9_]*/, "", d)
      heredoc_delim = d; in_heredoc = 1
    }
  }
  next
}
END { if (in_block == 1) evaluate() }
function evaluate(   score, parts) {
  if (exempt == 1) return
  # Standalone finding: independent of the >= 2 heaviness score.
  if (gh_title_inline == 1) {
    printf "[bash-heaviness] %s:%d: inline-gh-create-title — literal --title in gh {pr,issue} create; delegate the title to a file (Write tool) or a variable to avoid malformed tool-call\n", fname, gh_title_line
  }
  score = 0; parts = ""
  if (has_python == 1)            { score++; parts = parts (parts == "" ? "" : ", ") "python-inline" }
  if (nested == 1)                { score++; parts = parts (parts == "" ? "" : ", ") "nested-cmdsub" }
  if (heredoc_count >= 2)         { score++; parts = parts (parts == "" ? "" : ", ") "multi-heredoc(" heredoc_count ")" }
  if (nlines >= line_threshold)   { score++; parts = parts (parts == "" ? "" : ", ") "long-block(" nlines ")" }
  if (score >= min_signals) {
    printf "[bash-heaviness] %s:%d: heavy operational bash block — %d signals: %s\n", fname, block_start, score, parts
  }
}
AWK

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  if [ ! -f "$t" ]; then
    echo "WARNING: target not found: $t" >&2
    continue
  fi
  awk -v fname="$t" -v line_threshold="$LINE_THRESHOLD" -v min_signals="$MIN_SIGNALS" \
    -f "$AWK_PROG" "$t" >> "$FINDINGS_FILE" 2>/dev/null || true
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
total=$(printf '%s' "$total" | tr -d '[:space:]')
log "==> Total bash-heaviness findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
