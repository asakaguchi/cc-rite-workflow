#!/usr/bin/env bash
# distributed-fix-drift-check.sh
#
# Detect "distributed fix drift" patterns in large rite-workflow procedural
# markdown files (fix.md, review.md, tech-writer-reviewer.md, etc.).
#
# This is the static lint counterpart to LLM agent-based review, which has
# been observed to miss distributed/asymmetric fix patterns (PR #350 / Issue #361).
#
# Patterns:
#   1. retained-flag coverage  — `exit 1` without preceding `[CONTEXT] *_FAILED=1` emit
#   2. reason-table drift       — markdown reason table vs actual `reason=...` emit
#   3. if-wrap drift            — `cat <<'EOF' > "$tmpfile"` not wrapped by `if !`
#   4. anchor drift             — markdown `[text](path#anchor)` resolving to non-existent heading
#   5. eval-table list drift    — evaluation-order table parenthesized list vs emit
#   6. review-result schema_version drift — `.rite/review-results/*.json` whose
#      `.schema_version` is outside the accept list (delegates to
#       `review-schema-version-check.sh`; Issue #1021)
#
# Usage:
#   distributed-fix-drift-check.sh [--all] [--target FILE]... [--pattern N]
#                                  [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = drift detected, 2 = invocation error.

set -uo pipefail
# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"

REPO_ROOT=""
QUIET=0
PATTERN_FILTER=""
SHOW_EXTRACTED_REASONS=0
declare -a TARGETS=()
USE_ALL=0

# Default target set when --all is given.
# review-findings-maps.sh は fix.md ステップ 1.2.0 から委譲された reason を emit するため
# Pattern-5 (helper docstring 内の Eval-order enumeration vs reason= emits) の対象に含める (Issue #1196)。
DEFAULT_ALL_TARGETS=(
  "plugins/rite/commands/pr/fix.md"
  "plugins/rite/commands/pr/review.md"
  "plugins/rite/agents/tech-writer-reviewer.md"
  "plugins/rite/scripts/review-findings-maps.sh"
)

usage() {
  cat <<'EOF'
Usage: distributed-fix-drift-check.sh [options]

Options:
  --all                       Check the default target set (fix.md, review.md, tech-writer-reviewer.md, review-findings-maps.sh)
  --target FILE               Check FILE (repeatable). Path relative to repo root.
  --pattern N                 Only run pattern N (1-6). Default: all patterns.
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  --show-extracted-reasons    Print the extracted table_reasons / emit_reasons lists for Pattern 2.
                              Useful for differentiating real drift from regex artifacts (Issue #1158 AC-4).
  --quiet                     Suppress per-finding output (still exit non-zero on drift)
  -h, --help                  Show this help

Combining --all and --target:
  --all and --target can be used together. When both are specified, the
  default target set is merged with explicitly specified targets.
  Duplicate entries are automatically deduplicated.

Exit codes:
  0  No drift detected
  1  Drift detected
  2  Invocation error (bad args, missing files)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
out() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --pattern) PATTERN_FILTER="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --show-extracted-reasons) SHOW_EXTRACTED_REASONS=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
# SHOW_EXTRACTED_REASONS は check_pattern_2 が同一シェル内 `[ ... ]` builtin で参照するため
# export 不要 (将来 awk 内で `ENVIRON["SHOW_EXTRACTED_REASONS"]` を参照する誤拡張を誘発するリスクがある
# ため export を削除し、parent shell scope のみで運用する)。

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  TARGETS+=("${DEFAULT_ALL_TARGETS[@]}")
fi

# Deduplicate TARGETS (preserving order)
if [ "${#TARGETS[@]}" -gt 0 ]; then
  declare -A _seen=()
  declare -a _unique=()
  for _t in "${TARGETS[@]}"; do
    if [ -z "${_seen[$_t]+x}" ]; then
      _seen[$_t]=1
      _unique+=("$_t")
    fi
  done
  TARGETS=("${_unique[@]}")
  unset _seen _unique _t
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  # Pattern 6 (review-result JSON drift) scans .rite/review-results/ on its own
  # and does not consume the TARGETS list. Allow `--pattern 6` without targets.
  if [ "$PATTERN_FILTER" != "6" ]; then
    echo "ERROR: no targets specified (use --all or --target FILE)" >&2
    usage >&2
    exit 2
  fi
fi

DRIFT_COUNT_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
# Pattern 6 (Issue #1021) で使用する stderr capture tempfile を script-level で宣言し、
# 統合 trap で signal interrupt 時の orphan を防ぐ。
PATTERN6_STDERR=""
# Pattern 2 awk tempfile も script-level で宣言して統合 trap で signal interrupt 時の
# orphan を防ぐ (Pattern 6 stderr capture と同様に script-level 宣言 + 統合 trap で回収する doctrine)。
# check_pattern_2 関数内で AWK_TABLE_OUT 等に mktemp 結果を代入し、正常完了時に明示 rm + ""
# reset することで二重 rm を避ける。signal interrupt 経路では本 trap が rm -f で回収する。
AWK_TABLE_OUT=""
AWK_TABLE_ERR=""
AWK_EMIT_OUT=""
AWK_EMIT_ERR=""
_drift_check_cleanup() {
  rm -f "${DRIFT_COUNT_FILE:-}" "${PATTERN6_STDERR:-}" \
        "${AWK_TABLE_OUT:-}" "${AWK_TABLE_ERR:-}" \
        "${AWK_EMIT_OUT:-}" "${AWK_EMIT_ERR:-}"
}
trap 'rc=$?; _drift_check_cleanup; exit $rc' EXIT
trap '_drift_check_cleanup; exit 130' INT
trap '_drift_check_cleanup; exit 143' TERM
trap '_drift_check_cleanup; exit 129' HUP
echo 0 > "$DRIFT_COUNT_FILE"
report() {
  # report PATTERN FILE LINE MESSAGE
  local pattern="$1" file="$2" line="$3" msg="$4"
  out "[drift][P${pattern}] ${file}:${line}: ${msg}"
  local n
  n=$(<"$DRIFT_COUNT_FILE")
  echo $((n + 1)) > "$DRIFT_COUNT_FILE"
}

run_pattern() {
  local n="$1"
  [ -z "$PATTERN_FILTER" ] || [ "$PATTERN_FILTER" = "$n" ]
}

# ----- Pattern 1: retained-flag coverage -------------------------------------
# For every `exit 1` line, look at the preceding 5 lines (within the same code
# block). If none of them contain `[CONTEXT] *_FAILED=1` and the line itself is
# not inside a `trap` cleanup or a best-effort warning-only handler, flag it.
check_pattern_1() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v F="$file" '
    BEGIN { in_block = 0; line_no = 0 }
    {
      line_no++
      # Maintain a 5-line lookback buffer
      buf6 = buf5; buf5 = buf4; buf4 = buf3; buf3 = buf2; buf2 = buf1; buf1 = $0
      bln6 = bln5; bln5 = bln4; bln4 = bln3; bln3 = bln2; bln2 = bln1; bln1 = line_no
      if ($0 ~ /^[[:space:]]*exit 1[[:space:]]*$/) {
        # Check 5 preceding lines for retained flag emit
        has_flag = 0
        for (i = 2; i <= 6; i++) {
          v = (i==2?buf2:(i==3?buf3:(i==4?buf4:(i==5?buf5:buf6))))
          if (v ~ /\[CONTEXT\][^"]*_FAILED=1/) { has_flag = 1; break }
        }
        # Best-effort exclusions: trap cleanup or best-effort warnings
        is_excluded = 0
        for (i = 2; i <= 6; i++) {
          v = (i==2?buf2:(i==3?buf3:(i==4?buf4:(i==5?buf5:buf6))))
          if (v ~ /trap[[:space:]]/) { is_excluded = 1; break }
          if (v ~ /(best-effort|[[:space:]]+\|\|[[:space:]]+true|2>\/dev\/null)/) { is_excluded = 1; break }
        }
        if (!has_flag && !is_excluded) {
          printf "%d\n", line_no
        }
      }
    }
  ' "$file" | while read -r ln; do
    report 1 "$file" "$ln" "exit 1 without preceding [CONTEXT] *_FAILED=1 emit"
  done
}

# ----- Pattern 2: reason-table drift -----------------------------------------
# Markdown table cells like `| `reason_name` ...` vs `reason=reason_name` emits.
#
# Robustness notes (Issue #1158):
#   - Both extractors accept hyphens in identifiers ([a-z_][a-z0-9_-]*) so that
#     reasons such as `no-pending` are not truncated to `no`.
#   - Both extractors skip matches that are truncation artifacts:
#       (a) emit-side: followed immediately by `$` — shell variable expansion
#           ends the value (e.g. `reason=trigger_exit_$trigger_exit` would
#           otherwise yield the bogus reason `trigger_exit_`)
#       (b) both sides: ending in `_` or `-` — these are stub residues of (a)
#           or hyphenated/underscored values that got chopped at a
#           non-identifier boundary. table-side also applies this filter so that
#           Markdown table cells like `| `python_unexpected_exit_$py_exit` |`
#           do not pollute `table_reasons` with `python_unexpected_exit_` and
#           generate a false "table has X but emit doesn't" drift entry against
#           the emit-side `[_-]$` skip.
#     Static literals like `reason=commit_rc_4` are preserved (they end in a
#     digit, not `_/-`, and have no trailing `$`).
#
# Silent-failure guard (Pattern 2 awk rc check):
#   awk のバイナリ異常 / syntax error / IO 失敗で `table_reasons` / `emit_reasons` が
#   空文字列 silent fallback すると、後段 `[ -z "$table_reasons" ] && return 0` で
#   Pattern 2 全体が暗黙 skip され drift があっても見逃される。awk の exit code を
#   tempfile 経由で明示捕捉し、失敗時は WARNING + skip するように guard する。
check_pattern_2() {
  local file="$1"
  [ -f "$file" ] || return 0
  local table_reasons emit_reasons missing extra
  local awk_table_rc awk_emit_rc

  # tempfile は script-level の AWK_TABLE_OUT / AWK_TABLE_ERR / AWK_EMIT_OUT / AWK_EMIT_ERR
  # 4 変数で管理し、_drift_check_cleanup trap (本 script 冒頭の signal interrupt cleanup ハンドラ)
  # で orphan を回収する。正常完了時は明示 rm + "" reset で trap 二重 rm を避ける。
  # mktemp に 2>/dev/null を付け sibling (pr-cycle-cleanup.sh 等) と統一 (bare stderr leak 防止)。
  # table-side awk: rc capture for silent-failure guard + asymmetric [_-]$ skip
  AWK_TABLE_OUT=$(mktemp /tmp/rite-drift-awk-table-out-XXXXXX 2>/dev/null) || AWK_TABLE_OUT=""
  AWK_TABLE_ERR=$(mktemp /tmp/rite-drift-awk-table-err-XXXXXX 2>/dev/null) || AWK_TABLE_ERR=""
  if [ -z "$AWK_TABLE_OUT" ]; then
    log "  [P2] Pattern 2 skipped on $file: mktemp for table-side awk output failed"
    # skip を distinct prefix で stdout にも emit して CI grep で区別可能にする
    # ([drift][P2] と区別する [drift-check-skip][P2] prefix)
    out "[drift-check-skip][P2] ${file}: mktemp_failed (table_out)"
    rm -f "${AWK_TABLE_ERR:-}"
    AWK_TABLE_ERR=""
    return 0
  fi
  awk_table_rc=0
  awk '
    /^\| `[a-z_][a-z0-9_-]*`/ {
      gsub(/[|`]/, " ")
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[a-z_][a-z0-9_-]*$/) {
          if ($i ~ /[_-]$/) continue
          print $i
          break
        }
      }
    }
  ' "$file" >"$AWK_TABLE_OUT" 2>"${AWK_TABLE_ERR:-/dev/null}" || awk_table_rc=$?
  if [ "$awk_table_rc" -ne 0 ]; then
    log "  [P2] Pattern 2 skipped on $file: table-side awk rc=$awk_table_rc"
    if [ -n "$AWK_TABLE_ERR" ] && [ -s "$AWK_TABLE_ERR" ]; then
      log "    awk stderr: $(head -1 "$AWK_TABLE_ERR" | tr -d '\n' | neutralize_ctrl --c0-only)"
    fi
    out "[drift-check-skip][P2] ${file}: awk_rc=${awk_table_rc} (table)"
    rm -f "$AWK_TABLE_OUT" "${AWK_TABLE_ERR:-}"
    AWK_TABLE_OUT="" AWK_TABLE_ERR=""
    return 0
  fi
  table_reasons=$(sort -u "$AWK_TABLE_OUT")
  rm -f "$AWK_TABLE_OUT" "${AWK_TABLE_ERR:-}"
  AWK_TABLE_OUT="" AWK_TABLE_ERR=""

  # emit-side awk: rc capture for silent-failure guard
  AWK_EMIT_OUT=$(mktemp /tmp/rite-drift-awk-emit-out-XXXXXX 2>/dev/null) || AWK_EMIT_OUT=""
  AWK_EMIT_ERR=$(mktemp /tmp/rite-drift-awk-emit-err-XXXXXX 2>/dev/null) || AWK_EMIT_ERR=""
  if [ -z "$AWK_EMIT_OUT" ]; then
    log "  [P2] Pattern 2 skipped on $file: mktemp for emit-side awk output failed"
    out "[drift-check-skip][P2] ${file}: mktemp_failed (emit_out)"
    rm -f "${AWK_EMIT_ERR:-}"
    AWK_EMIT_ERR=""
    return 0
  fi
  awk_emit_rc=0
  awk '
    {
      rest = $0
      while (match(rest, /reason=[a-z_][a-z0-9_-]*/)) {
        val = substr(rest, RSTART + 7, RLENGTH - 7)
        after = substr(rest, RSTART + RLENGTH, 1)
        rest = substr(rest, RSTART + RLENGTH)
        if (after == "$") continue
        if (val ~ /[_-]$/) continue
        print val
      }
    }
  ' "$file" >"$AWK_EMIT_OUT" 2>"${AWK_EMIT_ERR:-/dev/null}" || awk_emit_rc=$?
  if [ "$awk_emit_rc" -ne 0 ]; then
    log "  [P2] Pattern 2 skipped on $file: emit-side awk rc=$awk_emit_rc"
    if [ -n "$AWK_EMIT_ERR" ] && [ -s "$AWK_EMIT_ERR" ]; then
      log "    awk stderr: $(head -1 "$AWK_EMIT_ERR" | tr -d '\n' | neutralize_ctrl --c0-only)"
    fi
    out "[drift-check-skip][P2] ${file}: awk_rc=${awk_emit_rc} (emit)"
    rm -f "$AWK_EMIT_OUT" "${AWK_EMIT_ERR:-}"
    AWK_EMIT_OUT="" AWK_EMIT_ERR=""
    return 0
  fi
  emit_reasons=$(sort -u "$AWK_EMIT_OUT")
  rm -f "$AWK_EMIT_OUT" "${AWK_EMIT_ERR:-}"
  AWK_EMIT_OUT="" AWK_EMIT_ERR=""

  # AC-4 (Issue #1158): expose extracted reason lists so the user can
  # differentiate true positives from regex artifacts at a glance.
  # `${var//$'\n'/ }` で改行を space に置換し、parameter expansion 形で渡す設計:
  # 引数渡し形 (`printf '%s ' $var`) は word-splitting と glob 展開が同時発生するため、将来
  # reason regex に glob char (`*` / `?` / `[` 等) を許可した際に silent corrupt するリスクがある。
  # parameter expansion 形に統一することでこの経路を構造的に排除する。
  if [ "${SHOW_EXTRACTED_REASONS:-0}" -eq 1 ]; then
    log "  [P2 extracted] ${file}: table_reasons=$(printf '%s' "${table_reasons//$'\n'/ }" | sed 's/[[:space:]]*$//')"
    log "  [P2 extracted] ${file}: emit_reasons=$(printf '%s' "${emit_reasons//$'\n'/ }" | sed 's/[[:space:]]*$//')"
  fi
  # If the file has no reason table at all, Pattern-2 does not apply.
  # Skipping here prevents false "never emitted" flags for emit-only files.
  [ -z "$table_reasons" ] && return 0
  # If the file has a table but no emits, all table entries are unused — still a drift,
  # so we continue through to the comm comparison below.
  # Drift = symmetric difference
  missing=$(comm -23 <(printf '%s\n' "$emit_reasons") <(printf '%s\n' "$table_reasons"))
  extra=$(comm -13 <(printf '%s\n' "$emit_reasons") <(printf '%s\n' "$table_reasons"))
  if [ -n "$missing" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      report 2 "$file" 0 "reason '$r' emitted but not in reason table"
    done <<< "$missing"
  fi
  if [ -n "$extra" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      report 2 "$file" 0 "reason '$r' in reason table but never emitted"
    done <<< "$extra"
  fi
}

# ----- Pattern 3: if-wrap drift ----------------------------------------------
# `cat <<'XXEOF' > "$tmpfile"` should be wrapped by `if ! cat ...; then`.
check_pattern_3() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    BEGIN { line_no = 0; prev1 = ""; curr = "" }
    {
      line_no++
      prev1 = curr; curr = $0
      if (curr ~ /cat[[:space:]]+<<[\x27]?[A-Z_]+[\x27]?[[:space:]]*>[[:space:]]*"\$tmpfile"/) {
        wrapped = 0
        if (curr ~ /^[[:space:]]*if[[:space:]]+!/) wrapped = 1
        if (prev1 ~ /^[[:space:]]*if[[:space:]]+!/ && prev1 ~ /cat/) wrapped = 1
        # Exclusions: testing/example tmpfiles inside fenced explanatory blocks
        if (!wrapped) printf "%d\n", line_no
      }
    }
  ' "$file" | while read -r ln; do
    report 3 "$file" "$ln" "cat <<'EOF' > \"\$tmpfile\" not wrapped by 'if !'"
  done
}

# ----- Pattern 4: anchor drift -----------------------------------------------
# Extract [text](path#anchor) and verify the anchor exists in path's headings,
# using GitHub's anchor conversion (github-slugger compatible):
# lowercase, strip non-word/non-space/non-hyphen, spaces->hyphens, collapse hyphens.
# Implemented as inline perl in check_pattern_4 for batch processing efficiency.

check_pattern_4() {
  local file="$1"
  [ -f "$file" ] || return 0
  local file_dir
  file_dir="$(dirname "$file")"
  # Extract markdown links with #anchor. `|| true` makes no-match explicit
  # (prevents pipefail from propagating grep exit 1 if callers enable it).
  { grep -oE '\[[^]]*\]\([^)]+\)' "$file" 2>/dev/null || true; } \
    | { grep -oE '\([^)]*#[^)]+\)' || true; } \
    | sed -e 's/^(//' -e 's/)$//' \
    | while IFS= read -r ref; do
        local target_path anchor abs_path
        target_path="${ref%%#*}"
        anchor="${ref#*#}"
        # Skip URL-style links and self-only anchors here (handled separately if needed)
        case "$target_path" in
          ""|http*|mailto:*) continue ;;
          /*) abs_path="$REPO_ROOT$target_path" ;;
          *)  abs_path="$file_dir/$target_path" ;;
        esac
        [ -f "$abs_path" ] || continue
        # Build heading anchor list
        local headings
        headings=$(grep -E '^#{1,6}[[:space:]]' "$abs_path" 2>/dev/null \
          | sed -E 's/^#+[[:space:]]+//' \
          | perl -CSD -Mutf8 -pe 'chomp; $_ = lc($_); s/[^\w\s-]//g; s/\s+/-/g; s/-{2,}/-/g; s/^-|-$//g; $_ .= "\n"')
        # Skip files with no markdown headings (e.g. pure code files) to avoid
        # false positives where every anchor would be reported as unresolved.
        [ -z "$headings" ] && continue
        if ! grep -Fxq "$anchor" <<< "$headings"; then
          report 4 "$file" 0 "anchor '#$anchor' not found in $target_path"
        fi
      done
}

# ----- Pattern 5: eval-table parenthesized list drift ------------------------
# `( `a` / `b` / `c` )` style enumerations inside markdown tables vs actual
# `reason=...` emits in the same file.
check_pattern_5() {
  local file="$1"
  [ -f "$file" ] || return 0
  local table_words emit_reasons missing
  # Extract `xxx` words inside `( ... / ... / ... )` groups
  table_words=$(grep -oE '\([^)]*`[a-z_][a-z0-9_]*`[^)]*\)' "$file" 2>/dev/null \
    | grep -oE '`[a-z_][a-z0-9_]*`' \
    | tr -d '`' | sort -u)
  emit_reasons=$(grep -oE 'reason=[a-z_][a-z0-9_]*' "$file" 2>/dev/null \
    | sed 's/reason=//' | sort -u)
  # Short-circuit when either side is empty to avoid comm's environment-dependent
  # behavior with empty/unsorted input. A file without an eval-table or without
  # any emits is out of scope for Pattern-5.
  [ -z "$table_words" ] && return 0
  [ -z "$emit_reasons" ] && return 0
  missing=$(comm -23 <(printf '%s\n' "$emit_reasons") <(printf '%s\n' "$table_words"))
  if [ -n "$missing" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      report 5 "$file" 0 "reason '$r' emitted but not in eval-table parenthesized list"
    done <<< "$missing"
  fi
}

for file in "${TARGETS[@]}"; do
  log "Checking $file ..."
  run_pattern 1 && check_pattern_1 "$file"
  run_pattern 2 && check_pattern_2 "$file"
  run_pattern 3 && check_pattern_3 "$file"
  run_pattern 4 && check_pattern_4 "$file"
  run_pattern 5 && check_pattern_5 "$file"
done

# ----- Pattern 6: review-result schema_version drift (Issue #1021) -----------
# Delegates to review-schema-version-check.sh, which checks .rite/review-results/*.json
# against the accept list ("1.0.0" / "1.0" / "1.1.0"). Runs once per invocation
# (independent of the TARGETS loop above, since the JSON files are scanned by
# the delegate). Captures stderr to surface drift details via report().
#
# delegate を 1 回のみ invoke する設計: --quiet + verbose の 2 回 invoke では stderr を
# 2 回読み出すため I/O コストが倍増する。1 回の invoke で stderr に drift 行を出力させて
# 後段で parse する形に統合することで I/O コストを最小化する。
# rc を `|| true` で握りつぶさず明示 capture する設計: 黙殺すると unexpected exit code
# (binary 異常 / OOM / IO 失敗) が trace から消え、checker の degradation を後から
# 追えなくなるため。`PATTERN6_STDERR` を script-level 変数として宣言する設計: signal
# interrupt 時の orphan tempfile を本 script 冒頭の signal interrupt cleanup ハンドラで
# 確実に回収するため。
check_pattern_6() {
  local checker_script="$REPO_ROOT/plugins/rite/hooks/scripts/review-schema-version-check.sh"
  if [ ! -x "$checker_script" ]; then
    log "Pattern 6 skipped: review-schema-version-check.sh not found / not executable"
    return 0
  fi
  PATTERN6_STDERR=$(mktemp) || { log "Pattern 6 skipped: mktemp failed"; return 0; }
  local rc=0
  # 1 回のみ invoke: --quiet なしで stderr に drift 行を出力させ、後段で parse する。
  bash "$checker_script" --all --repo-root "$REPO_ROOT" 2>"$PATTERN6_STDERR" || rc=$?
  if [ "$rc" -eq 1 ]; then
    # rc=1: drift detected. stderr の `[CONTEXT] REVIEW_SCHEMA_VERSION_DRIFT=1` 行を parse。
    while IFS= read -r drift_line; do
      [ -z "$drift_line" ] && continue
      # Extract file path from `file=...; schema_version=...` for cleaner reporting
      drift_file=$(printf '%s' "$drift_line" | sed -nE 's/.*file=([^;]+); schema_version=.*/\1/p')
      drift_ver=$(printf '%s'  "$drift_line" | sed -nE 's/.*schema_version=(.+)$/\1/p')
      if [ -n "$drift_file" ]; then
        report 6 "$drift_file" 0 "schema_version='$drift_ver' outside accept list (1.0.0 / 1.0 / 1.1.0)"
      fi
    done < <(grep -E '^\[CONTEXT\] REVIEW_SCHEMA_VERSION_DRIFT=1' "$PATTERN6_STDERR")
  elif [ "$rc" -ne 0 ]; then
    # rc != 0/1 (delegate invocation error / jq missing 等): silent に握りつぶさず log + stderr 内容を表示
    log "Pattern 6 delegate exited with unexpected code $rc; check delegate diagnostics:"
    if [ -s "$PATTERN6_STDERR" ]; then
      head -5 "$PATTERN6_STDERR" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2
    fi
  fi
  # trap が cleanup を保証するが、明示 reset で次回 invocation 時の stale 参照を防ぐ
  rm -f "$PATTERN6_STDERR"
  PATTERN6_STDERR=""
}

run_pattern 6 && check_pattern_6

DRIFT_COUNT=$(<"$DRIFT_COUNT_FILE")
if [ "$DRIFT_COUNT" -gt 0 ]; then
  log "==> Total drift findings: $DRIFT_COUNT"
  exit 1
fi
log "==> No drift detected"
exit 0
