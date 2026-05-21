#!/bin/bash
# asymmetric-whitelist.test.sh — PR H (#905)
#
# Purpose:
#   phase-transition-whitelist.sh の `_RITE_PHASE_TRANSITIONS` 連想配列に登録されている
#   phase key のうち、orchestrator (`commands/issue/start*.md`、`commands/issue/implement.md`、
#   `commands/resume.md`、`commands/issue/create*.md`) のどこにも `--phase <name>` として
#   現れない key を検出する。
#
#   そのような orphan key は次のいずれかを示す:
#     (a) sub-skill 分割 / refactor で削除された旧 phase が whitelist に残存している (dead key)
#     (b) 新規 phase が whitelist に追加されたが orchestrator 側で誰も write していない
#         (unreachable transition、bug の可能性)
#
#   いずれも whitelist と実装の drift であり、stop-guard の transition check が無意味な
#   key で chunk されている (= regression detection power の低下) ことを意味する。
#
# Detection algorithm:
#   1. `phase-transition-whitelist.sh` から `["<key>"]=` 形式で全 key を抽出 (whitelist set A)
#   2. orchestrator markdown 群から `--phase <name>` パターンを grep で抽出 (used set B)
#   3. `comm -23 A B` で A にあって B に無い key (orphan) を検出
#   4. orphan ≠ 0 で fail (orphan の一覧を表示し、削除候補として informational に提示)
#
# Excluded keys (whitelist にあって意図的に `--phase` で参照されない key):
#   - `""` (empty string — synthetic "workflow start" predecessor、whitelist 内部の implicit)
#
# When this test fails:
#   orphan key が検出された場合、(a) whitelist から削除するか、(b) orchestrator 側で
#   `--phase <name>` を追加するか、どちらかで対称性を回復する。Do NOT relax this test —
#   whitelist と実装の drift は stop-guard の信頼性を破壊する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
COMMANDS_DIR="$PLUGIN_ROOT/commands"
WHITELIST_SH="$PLUGIN_ROOT/hooks/phase-transition-whitelist.sh"

if [ ! -f "$WHITELIST_SH" ]; then
  echo "  ❌ FILE NOT FOUND: $WHITELIST_SH" >&2
  exit 1
fi

echo "=== whitelist key extraction ==="
# phase-transition-whitelist.sh から ["<key>"]= 形式で全 key を抽出
mapfile -t whitelist_keys < <(grep -oE '^\s*\["[a-z0-9_]+"\]=' "$WHITELIST_SH" | sed 's/^[[:space:]]*\["//;s/"\]=//' | sort -u)
whitelist_count="${#whitelist_keys[@]}"
echo "  whitelist keys: $whitelist_count"
if [ "$whitelist_count" -ge 1 ]; then
  pass "whitelist contains >= 1 key (count=$whitelist_count)"
else
  fail "whitelist is empty (extraction failed?)"
  exit 1
fi

echo
echo "=== --phase usage extraction (orchestrator markdown) ==="
# PR H (#905) F-03 対応: 動的展開 + sub-skill / reference を含む全 .md を scan。
# 旧実装は ORCHESTRATOR_FILES 配列で 18 ファイルを hardcode していたが、`--phase` を使用する
# 旧 7 ファイル (branch-setup.md, child-issue-selection.md, implementation-plan.md, parent-routing.md,
# references/flow-state-scaffolding.md, references/metrics-recording.md, work-memory-init.md) が
# enumeration 漏れで silent drift のリスクがあった (code-quality-reviewer HIGH finding F-03)。
# PR #1079 で 5 ファイル (branch-setup / child-issue-selection / implementation-plan / parent-routing
# / work-memory-init) が flat workflow に統合され削除済。現存対象は references/flow-state-scaffolding.md
# と references/metrics-recording.md。find で commands/ 全 .md を動的展開し、test ファイル自身は除外する。
mapfile -t ORCHESTRATOR_FILES < <(find "$COMMANDS_DIR" -name '*.md' -type f | sort)
echo "  orchestrator files (dynamic): ${#ORCHESTRATOR_FILES[@]}"

# 各 file から `--phase "name"` または `--phase name` を抽出。quoted/unquoted 両対応。
# 注: grep -oE -- で `--phase` を pattern として安全に扱う。
mapfile -t used_keys < <(
  for f in "${ORCHESTRATOR_FILES[@]}"; do
    # F-15 finding 対応: `&& B || C` の precedence pitfall を回避するため 2 行形式に分離。
    # 旧形式 `[ -f "$f" ] && grep ... "$f" || true` は grep が exit 2 (IO error) で
    # 失敗した場合も silent 化するため、`[ -f ] || continue` の早期 skip 形式に変更。
    [ -f "$f" ] || continue
    grep -hoE -- '--phase[[:space:]]+"?[a-z0-9_]+' "$f" || true
  done | sed 's/--phase[[:space:]]*"\?//' | sort -u
)
used_count="${#used_keys[@]}"
echo "  --phase usages (unique): $used_count"
if [ "$used_count" -ge 1 ]; then
  pass "orchestrator has >= 1 --phase usage (count=$used_count)"
else
  fail "no --phase usages found in orchestrator files"
  exit 1
fi

echo
echo "=== orphan detection (whitelist key NOT in --phase usage) ==="

# Documented backwards-compat dead targets — whitelist key として残存しているが、
# 現在のコードパスでは write されないことが意図された marker。removal は別 PR scope
# (whitelist 簡素化 PR 候補) で扱う。本テストでは exception list として通過させる。
DEAD_KEY_EXCEPTIONS=(
  # PR #1079 で whitelist を flat workflow phase 名のみに整理したため、現状は documented
  # exception 不要。将来 backward-compat marker を追加する場合はここに entry + rationale を
  # 記載すること。
)

# comm -23 で A (whitelist) にあって B (used) に無い key を検出
whitelist_tmp=$(mktemp)
used_tmp=$(mktemp)
trap 'rm -f "$whitelist_tmp" "$used_tmp"' EXIT
printf '%s\n' "${whitelist_keys[@]}" | sort -u > "$whitelist_tmp"
printf '%s\n' "${used_keys[@]}" | sort -u > "$used_tmp"

mapfile -t raw_orphans < <(comm -23 "$whitelist_tmp" "$used_tmp")

# Apply exception list を排除
orphans=()
for k in "${raw_orphans[@]}"; do
  [ -z "$k" ] && continue
  is_exception=0
  for ex in "${DEAD_KEY_EXCEPTIONS[@]}"; do
    if [ "$k" = "$ex" ]; then
      is_exception=1
      break
    fi
  done
  [ "$is_exception" -eq 0 ] && orphans+=("$k")
done
orphan_count="${#orphans[@]}"

# documented exception 数も informational に表示
echo "  documented dead key exceptions: ${#DEAD_KEY_EXCEPTIONS[@]} (excluded from orphan check)"

if [ "$orphan_count" -eq 0 ]; then
  pass "no orphan phase keys (whitelist と orchestrator の対称性 OK; ${#DEAD_KEY_EXCEPTIONS[@]} documented exceptions excluded)"
else
  fail "found $orphan_count orphan phase key(s) in whitelist (whitelist key の中で orchestrator の --phase に一切現れないもの、かつ documented exceptions 外):"
  for k in "${orphans[@]}"; do
    [ -z "$k" ] && continue
    echo "    - $k"
  done
  echo "  対処: (a) whitelist から削除するか、(b) orchestrator 側で --phase \"<name>\" を追加するか、(c) 意図的な backward-compat なら DEAD_KEY_EXCEPTIONS に追加 (rationale 付き) で対称性回復"
fi

echo
echo "=== reverse direction: --phase used but NOT whitelisted (II-4 PR #1079 verified-review) ==="
# 反対方向の drift: orchestrator が `--phase foobar` を書いているが whitelist に未登録の場合、
# `rite_phase_transition_allowed` は forward-compat (unknown prev accept) で silent に通過するため、
# protocol violation が hook で検出できない。本 reverse check で「使われているが whitelist 不在」を
# detect する。
#
# Documented exceptions: 一部の sub-skill (pr/ready.md など) が PR #1079 で flat workflow に未統合
# のまま legacy phase5_* / phase1_* / phase2_* / phase3_* 系の phase 名を `--phase` で書き続けている。
# これらは follow-up PR (PR 3: PR 系 slim 化) で flat phase 名に統一される予定の暫定残置。
# phase-transition-whitelist は forward-compat (unknown prev accept) で挙動を維持するが、protocol
# violation 検出力は低下する。本 exception を縮退させる前に follow-up PR で legacy 書き込みを撤去する。
REVERSE_EXCEPTIONS=(
  "phase5_lint"
  "phase5_post_fix"
  "phase5_post_metrics"
  "phase5_post_ready"
  "phase5_post_review"
  "phase5_pr"
  "phase5_ready"
  "phase5_ready_error"
  "phase5_review"
)

# comm -13 で B (used) にあって A (whitelist) に無い key を検出
mapfile -t raw_reverse_orphans < <(comm -13 "$whitelist_tmp" "$used_tmp")
reverse_orphans=()
for k in "${raw_reverse_orphans[@]}"; do
  [ -z "$k" ] && continue
  is_exception=0
  for ex in "${REVERSE_EXCEPTIONS[@]}"; do
    if [ "$k" = "$ex" ]; then
      is_exception=1
      break
    fi
  done
  [ "$is_exception" -eq 0 ] && reverse_orphans+=("$k")
done
reverse_orphan_count="${#reverse_orphans[@]}"

if [ "$reverse_orphan_count" -eq 0 ]; then
  pass "no reverse-orphan phase keys (orchestrator が使う phase はすべて whitelist 登録済)"
else
  fail "found $reverse_orphan_count reverse-orphan phase key(s) in orchestrator (--phase で書かれているが whitelist 未登録):"
  for k in "${reverse_orphans[@]}"; do
    [ -z "$k" ] && continue
    echo "    - $k"
  done
  echo "  対処: (a) whitelist に追加 (forward-compat unknown prev accept で silent 通過するため、明示登録で transition check を有効化)、(b) typo であれば orchestrator 側を修正、(c) 意図的な test/example use なら REVERSE_EXCEPTIONS に追加"
fi

# === Summary ===
if ! print_summary "$(basename "$0")" \
  "orphan key 検出時は whitelist 削除 or orchestrator --phase 追加で対称性回復。reverse orphan は whitelist 追加で transition check を有効化。Do NOT relax this test."; then
  exit 1
fi
exit 0
