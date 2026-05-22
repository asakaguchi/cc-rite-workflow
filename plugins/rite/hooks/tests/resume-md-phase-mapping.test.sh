#!/bin/bash
# resume-md-phase-mapping.test.sh
#
# `commands/resume.md` Phase 3.2 is the routing SoT for /rite:resume. A typo,
# a stale row, or a forgotten new-phase entry would silently route the user to
# the wrong step. Pin three invariants statically:
#
#   (a) every flat-workflow phase row resolves via `rite_phase_is_known`
#   (b) every phase in `_RITE_PHASE_TRANSITIONS` has a corresponding row
#   (c) legacy compat rows point to step numbers in the 1-8 range
#
# When this fails: fix the Phase 3.2 / legacy compat tables. When adding a
# phase, update resume.md and the whitelist together so (a) and (b) stay aligned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
RESUME_MD="$PLUGIN_ROOT/commands/resume.md"
WHITELIST_SH="$PLUGIN_ROOT/hooks/phase-transition-whitelist.sh"

if [ ! -f "$RESUME_MD" ]; then
  echo "ERROR: $RESUME_MD not found" >&2
  exit 1
fi
if [ ! -f "$WHITELIST_SH" ]; then
  echo "ERROR: $WHITELIST_SH not found" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$WHITELIST_SH"

# Flat workflow phases. `ready` (post-Ready success) and `ready_error` (Ready
# failure) are first-class flat phases so resume.md routes their state files
# without falling back to the legacy compat table. `completed` is terminal but
# must still be known to rite_phase_is_known so callers can detect "no further
# transition" without misclassifying it as unknown.
FLAT_PHASES=(init branch plan implement lint pr review fix ready ready_error completed)

# ──────────────────────────────────────────────────────────────────────
# (a) Phase 1.3 (Extract Phase Information) と Phase 3.2 (Command-Specific
#     Resume Processing) の双方が 11 phase 全ての row を持つ。
#
# ファイル全体 grep だと片方の表に row があれば PASS してしまい、もう一方の
# 表で行欠落 (例えば Phase 1.3 から ready/ready_error が落ちている) を検出
# できない。各 section 範囲を heading 起点で抽出して独立に検証する。
# ──────────────────────────────────────────────────────────────────────

# 指定 section 内の行を抽出。同 level (`### `) 以上のヘッダで止め、`#### ` 等のサブセクションは
# 同 section 内として扱う (resume.md の Phase 3.2 は `#### For rite:issue:start` を含むため)。
extract_section() {
  local file="$1" start_re="$2"
  awk -v start_re="$start_re" '
    $0 ~ start_re { in_section = 1; next }
    in_section && /^### [^#]/ { in_section = 0 }
    in_section && /^## [^#]/ { in_section = 0 }
    in_section && /^# [^#]/ { in_section = 0 }
    in_section { print }
  ' "$file"
}

PHASE_1_3="$(extract_section "$RESUME_MD" "^### 1\\.3 ")"
PHASE_3_2="$(extract_section "$RESUME_MD" "^### 3\\.2 ")"

if [ -z "$PHASE_1_3" ]; then
  fail "TC-A0 Phase 1.3 section not found in resume.md (heading drift?)"
fi
if [ -z "$PHASE_3_2" ]; then
  fail "TC-A0 Phase 3.2 section not found in resume.md (heading drift?)"
fi

for phase in "${FLAT_PHASES[@]}"; do
  if printf '%s\n' "$PHASE_1_3" | grep -qE "^\|[[:space:]]*\`${phase}\`[[:space:]]*\|"; then
    pass "TC-A1 Phase 1.3 has row for phase=${phase}"
  else
    fail "TC-A1 Phase 1.3 missing row for phase=${phase}"
  fi
  if printf '%s\n' "$PHASE_3_2" | grep -qE "^\|[[:space:]]*\`${phase}\`[[:space:]]*\|"; then
    pass "TC-A2 Phase 3.2 has row for phase=${phase}"
  else
    fail "TC-A2 Phase 3.2 missing row for phase=${phase}"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# (b) 11 phase 全てが rite_phase_is_known を通る
# ──────────────────────────────────────────────────────────────────────
for phase in "${FLAT_PHASES[@]}"; do
  if rite_phase_is_known "$phase"; then
    pass "TC-B1 rite_phase_is_known('$phase') accepts"
  else
    fail "TC-B1 rite_phase_is_known('$phase') rejected (whitelist drift)"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# (c) legacy compat 行の target step 番号は 1-8 の範囲に収まる
# ──────────────────────────────────────────────────────────────────────
# 「Legacy phase 名 (pre-#1079) compatibility」セクション内の行から
# `Resume from ステップ N` を抽出して 1-8 の範囲を検証する。
in_legacy=0
invalid_steps=""
while IFS= read -r line; do
  if [[ "$line" == *"Legacy phase 名 (pre-#1079) compatibility"* ]]; then
    in_legacy=1
    continue
  fi
  if [ "$in_legacy" = "1" ]; then
    # 次の `####` heading で legacy セクション終了
    if [[ "$line" =~ ^#### ]]; then
      break
    fi
    # `Resume from ステップ X` 抽出
    if [[ "$line" =~ Resume\ from\ ステップ\ ([0-9]+) ]]; then
      step="${BASH_REMATCH[1]}"
      if [ "$step" -lt 1 ] || [ "$step" -gt 8 ]; then
        invalid_steps="${invalid_steps} ${step}(line:'$line')"
      fi
    fi
  fi
done < "$RESUME_MD"

if [ -z "$invalid_steps" ]; then
  pass "TC-C1 legacy compat rows target step 1-8"
else
  fail "TC-C1 legacy compat rows have out-of-range step refs:${invalid_steps}"
fi

# ──────────────────────────────────────────────────────────────────────
# (d) `_RITE_PHASE_TRANSITIONS` の primary key が resume.md でも参照されている
#     (`completed` / `init` / `branch` ...)。逆向きの drift guard。
# ──────────────────────────────────────────────────────────────────────
# 配列 keys を取得
declare -a TRANSITION_KEYS=("${!_RITE_PHASE_TRANSITIONS[@]}")
for key in "${TRANSITION_KEYS[@]}"; do
  # cleanup_* / ingest_* / create_* lifecycle は resume.md スコープ外なのでスキップ
  case "$key" in
    cleanup*|ingest*|create*) continue ;;
  esac
  if grep -qE "^\|[[:space:]]*\`${key}\`[[:space:]]*\|" "$RESUME_MD"; then
    pass "TC-D1 whitelist phase=${key} has row in resume.md"
  else
    fail "TC-D1 whitelist phase=${key} missing in resume.md (add row to Phase 3.2 table)"
  fi
done

print_summary "resume-md-phase-mapping.test.sh"
