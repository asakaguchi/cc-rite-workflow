#!/bin/bash
# AND-logic defense chain (Wiki 経験則 #660: 「前提条件の silent omit が AND 論理の防御層
# チェーンを全体無効化する」) を新形式 (per-session file, schema_version=2) 上で verify。
#
# Issue #683 / parent #672 AC-LOCAL-3:
#   - AND 論理防御層が新形式上で動作 (.rite-stop-guard-diag.log 相当の trace で verify)
#   - Layer 6 (Step 0 Immediate Bash) / Layer 7 (--active true minimal presence) は parent-routing
#     pattern 移行 (ADR docs/designs/parent-routing-unification.md) で撤去済。numbering gap
#     (Layer 5 → Layer 8) は historical cross-references を維持するため意図的に保持する。
#
# 6 種防御層 (Layer 6 / Layer 7 撤去、numbering gap を維持):
#   1. declarative : commands/issue/*.md prose で `--active true` literal を declare
#   2. sentinel : workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 sentinel を emit
#   3. Pre-check : commands で state-read.sh --field phase 経由の pre-condition check
#   4. whitelist : phase-transition-whitelist.sh が source 可能で case arm を持つ
#   5. Pre-flight : preflight-check.sh が --command-id 引数を受け付け、compact_state を gate
#   6. Step 0 (撤去済) : parent-routing pattern 移行で create.md の "Step 0 Immediate Bash" pattern を撤去。
#                         create-interview Pre-flight の存在は parent-routing-pattern-interim.test.sh が代替 pin する。
#   7. minimal presence (撤去済) : --active true site-level pin は parent-routing-pattern-interim.test.sh
#                         TC-2h-2j で代替 pin される。
#   8. case arm : phase-transition-whitelist.sh の declare -gA テーブル + rite_phase_transition_allowed 関数
#
# 各 layer について以下を verify:
#   (a) Evidence Test : layer の存在を grep / file existence で mechanical に検出
#   (b) AND-logic Test : `.active=true` で fire / `.active=false` で silent skip という contract が成立
#
# Note (architecture drift since #660): stop-guard.sh は #674 で removal 済み。
# `.rite-stop-guard-diag.log` は現存しないため、layer 4/5/8 の AND-logic は
# phase-transition-whitelist.sh と pre-tool-bash-guard.sh の挙動で間接観測する。
#
# Out of scope (#684 で扱う):
#   - migration / atomic write integrity / cleanup / crash resume
#
# Usage: bash plugins/rite/hooks/tests/and-logic-defense-chain.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="$SCRIPT_DIR/.."
PLUGIN_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
HOOK="$HOOK_DIR/flow-state-update.sh"
WHITELIST="$HOOK_DIR/phase-transition-whitelist.sh"
PREFLIGHT="$HOOK_DIR/preflight-check.sh"
INCIDENT_EMIT="$HOOK_DIR/workflow-incident-emit.sh"
PRE_TOOL_GUARD="$HOOK_DIR/pre-tool-bash-guard.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

make_test_dir() {
  local d
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; return 1; }
  [ -n "$d" ] && [ -d "$d" ] || { echo "ERROR: test dir invalid" >&2; return 1; }
  (
    set -e
    cd "$d"
    git init -q
    echo a > a && git add a
    git -c user.email=t@test.local -c user.name=test commit -q -m init
  ) || { echo "ERROR: test fixture setup failed in $d" >&2; return 1; }
  echo "$d"
}

write_config() {
  local d="$1" sv="$2"
  cat > "$d/rite-config.yml" << EOF
flow_state:
  schema_version: $sv
EOF
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

echo "=== and-logic-defense-chain tests (Wiki 経験則 #660 / Issue #683 AC-LOCAL-3) ==="
echo ""

# --------------------------------------------------------------------------
# Layer 1: declarative — commands/issue/*.md prose で --active true literal を declare
# --------------------------------------------------------------------------
echo "Layer 1 (declarative): commands で --active true literal が declare されている"
# 旧 `2>/dev/null` は git binary 不在 / repo corrupt / file lock を
# 「count=0 → Layer 失敗」に silent に倒す。stderr-tempfile pattern に統一。
_grep_err=$(mktemp /tmp/rite-andlogic-grep-err-XXXXXX 2>/dev/null) || _grep_err=""
declarative_count=$(git -C "$REPO_ROOT" grep -nE '\-\-active true' plugins/rite/commands/issue/ 2>"${_grep_err:-/dev/null}" | wc -l)
if [ -n "$_grep_err" ] && [ -s "$_grep_err" ]; then
  echo "WARNING: Layer 1 git grep stderr 出力あり (test 環境 IO エラーの可能性): $(head -1 "$_grep_err")" >&2
fi
[ -n "$_grep_err" ] && rm -f "$_grep_err"
if [ "$declarative_count" -gt 0 ]; then
  pass "Layer 1 evidence: --active true literal が commands/issue/ 内に $declarative_count 箇所 (declarative 層成立)"
else
  fail "Layer 1: --active true literal が commands/issue/ 内に存在しない (declarative 層欠落)"
fi

# --------------------------------------------------------------------------
# Layer 2: sentinel — workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 を emit
# --------------------------------------------------------------------------
echo "Layer 2 (sentinel): workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 sentinel を emit"
if [ -x "$INCIDENT_EMIT" ] || [ -f "$INCIDENT_EMIT" ]; then
  pass "Layer 2 evidence: workflow-incident-emit.sh が存在"
else
  fail "Layer 2: workflow-incident-emit.sh が存在しない"
fi

# Runtime: emit が WORKFLOW_INCIDENT=1 sentinel を出力するか
# stderr 退避で emit script の syntax error / 引数 parse 失敗 / permission error を可視化
emit_err=$(mktemp)
if ! sentinel_out=$(bash "$INCIDENT_EMIT" --type skill_load_failure --details "test details" --pr-number 0 2>"$emit_err"); then
  emit_rc=$?
  emit_stderr_preview=$(head -3 "$emit_err")
  echo "  WARN: workflow-incident-emit.sh rc=$emit_rc. stderr: ${emit_stderr_preview:-<empty>}" >&2
  sentinel_out=""
fi
rm -f "$emit_err"
if echo "$sentinel_out" | grep -q "WORKFLOW_INCIDENT=1"; then
  pass "Layer 2 runtime: emit 結果に WORKFLOW_INCIDENT=1 が含まれる"
else
  fail "Layer 2 runtime: WORKFLOW_INCIDENT=1 sentinel が emit されない (out=$sentinel_out)"
fi

# --------------------------------------------------------------------------
# Layer 3: Pre-check — commands で state-read.sh --field phase 経由の pre-condition
# --------------------------------------------------------------------------
echo "Layer 3 (Pre-check): commands で state-read.sh --field phase pre-condition check"
# silent-failure-hunter M-4: stderr-tempfile pattern (Layer 1 と同型)
_grep_err=$(mktemp /tmp/rite-andlogic-grep-err-XXXXXX 2>/dev/null) || _grep_err=""
precheck_count=$(git -C "$REPO_ROOT" grep -nE 'state-read\.sh --field phase' plugins/rite/commands/ 2>"${_grep_err:-/dev/null}" | wc -l)
if [ -n "$_grep_err" ] && [ -s "$_grep_err" ]; then
  echo "WARNING: Layer 3 git grep stderr 出力あり: $(head -1 "$_grep_err")" >&2
fi
[ -n "$_grep_err" ] && rm -f "$_grep_err"
if [ "$precheck_count" -gt 0 ]; then
  pass "Layer 3 evidence: state-read.sh --field phase 呼び出しが commands/ に $precheck_count 箇所"
else
  fail "Layer 3: Pre-check pattern が commands/ に存在しない"
fi

# --------------------------------------------------------------------------
# Layer 4: whitelist — phase-transition-whitelist.sh が source 可能で whitelist を持つ
# --------------------------------------------------------------------------
echo "Layer 4 (whitelist): phase-transition-whitelist.sh が source 可能で whitelist を持つ"
if [ -f "$WHITELIST" ]; then
  pass "Layer 4 evidence: phase-transition-whitelist.sh が存在"
else
  fail "Layer 4: phase-transition-whitelist.sh が存在しない"
fi

# Runtime: source して関数が呼べるか
set +e
(
  set +u
  source "$WHITELIST"
  if declare -f rite_phase_transition_allowed >/dev/null 2>&1; then
    # 既知の遷移 (phase1_5_parent → phase1_5_post_parent) が allow される
    if rite_phase_transition_allowed "phase1_5_parent" "phase1_5_post_parent"; then
      exit 0
    else
      exit 1
    fi
  else
    exit 2
  fi
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "Layer 4 runtime: rite_phase_transition_allowed が known transition を allow"
else
  fail "Layer 4 runtime: whitelist 関数が機能しない (rc=$rc)"
fi

# --------------------------------------------------------------------------
# Layer 5: Pre-flight — preflight-check.sh が --command-id を受け付け compact gate
# --------------------------------------------------------------------------
echo "Layer 5 (Pre-flight): preflight-check.sh が --command-id を受け付け、normal state で exit 0"
if [ -f "$PREFLIGHT" ]; then
  pass "Layer 5 evidence: preflight-check.sh が存在"
else
  fail "Layer 5: preflight-check.sh が存在しない"
fi

TD=$(make_test_dir); cleanup_dirs+=("$TD")
# compact state なし → normal → exit 0
set +e
(cd "$TD" && bash "$PREFLIGHT" --command-id "/rite:issue:start" --cwd "$TD" >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "Layer 5 runtime: compact_state=normal で preflight-check は exit 0 (allow)"
else
  fail "Layer 5 runtime: normal state で preflight-check が block (rc=$rc)"
fi

# Layer 6 (Step 0 Immediate Bash) は parent-routing pattern 移行
# (ADR docs/designs/parent-routing-unification.md) で撤去済。caller-side Step 0 が不要に
# なったため、本 test では Layer 6 を保持しない。create-interview Pre-flight の存在は
# `parent-routing-pattern-interim.test.sh` が代替 pin する。

# --------------------------------------------------------------------------
# Layer 7 (--active true minimal presence) は parent-routing pattern 移行 (ADR §6.1) で
# AND-logic invariant への寄与を失い vestigial 化したため撤去。numbering gap (Layer 5 → Layer 8) は
# Layer 6 / Layer 7 撤去の historical cross-reference を保持するため意図的に維持する。
# create-interview / wiki-ingest / pr-cleanup 系の `--active true` 出現は
# `parent-routing-pattern-interim.test.sh` の TC-2h-2j で site-level に pin される。

# --------------------------------------------------------------------------
# Layer 8: case arm — phase-transition-whitelist.sh の declare -gA テーブル
# --------------------------------------------------------------------------
echo "Layer 8 (case arm): phase-transition-whitelist.sh の declare -gA + 関数 dispatch"
# silent-failure-hunter M-4: stderr-tempfile pattern
_grep_err=$(mktemp /tmp/rite-andlogic-grep-err-XXXXXX 2>/dev/null) || _grep_err=""
case_arm_count=$(grep -E 'declare -gA _RITE_PHASE_TRANSITIONS' "$WHITELIST" 2>"${_grep_err:-/dev/null}" | wc -l)
if [ -n "$_grep_err" ] && [ -s "$_grep_err" ]; then
  echo "WARNING: Layer 8 grep stderr 出力あり: $(head -1 "$_grep_err")" >&2
fi
[ -n "$_grep_err" ] && rm -f "$_grep_err"
if [ "$case_arm_count" -ge 1 ]; then
  pass "Layer 8 evidence: declare -gA _RITE_PHASE_TRANSITIONS が存在 ($case_arm_count 箇所)"
else
  fail "Layer 8: case arm/dispatch table が存在しない"
fi

# Runtime: 不正な遷移は reject される
set +e
(
  set +u
  source "$WHITELIST"
  if declare -f rite_phase_transition_allowed >/dev/null 2>&1; then
    if rite_phase_transition_allowed "phase1_5_parent" "phase5_completion"; then
      exit 1  # 想定外: reject されるべき遷移が allow された
    else
      exit 0  # 期待通り reject
    fi
  else
    exit 2
  fi
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "Layer 8 runtime: 不正な遷移 (phase1_5_parent → phase5_completion) は reject される"
else
  fail "Layer 8 runtime: 不正な遷移が reject されない (rc=$rc)"
fi

# --------------------------------------------------------------------------
# AND-logic invariant: active=false 状態で防御層は silent skip / active=true で fire
# (#660 root cause = active=true 前提を omit すると 8 layer 全体が無効化される)
# --------------------------------------------------------------------------
echo "AND-logic invariant: active=false で defense layer は silent skip / active=true で fire"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_INV="abcdefab-cdef-abcd-efab-cdefabcdefab"
write_session_id "$TD" "$SID_INV"

# active=false setup
(cd "$TD" && bash "$HOOK" create --session "$SID_INV" \
  --phase "create_interview" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
INV_F="$TD/.rite/sessions/$SID_INV.flow-state"

# `gh issue create` は phase=create_interview で AND-logic gate が block 対象とする command。
# active=false → guard は早期 silent skip (stdout 空 / deny JSON なし)
# active=true → defense pathway 評価に進み stdout に permissionDecision: deny JSON を出力
# pre-tool-bash-guard は exit 0 のまま stdout で deny を表現するため、stdout 内容で判定する。
HOOK_INPUT_BLOCKING=$(jq -n --arg cwd "$TD" --arg sid "$SID_INV" \
  '{cwd: $cwd, session_id: $sid, tool_name: "Bash", tool_input: {command: "gh issue create --title test --body test"}}')

# `jq | mv` の `&&` 連鎖は bash の "tested context" 例外で jq 失敗時に silent fall-through する。
# helper で if/else 化し fail-fast パターンに統一 (session-ownership-regression.test.sh と対称)。
patch_active() {
  local file="$1" value="$2"
  if jq ".active = $value" "$file" > "${file}.tmp"; then
    # mv 失敗 (disk full / EXDEV / permission denied) を明示 handle。
    # `if ! cmd; then` の中で `$?` は `!` 演算後の値 (常に 0) のため rc 取得不可。
    # flow-state-update.sh の create mode 内 `mv "$TMP_STATE" "$FLOW_STATE"` block と
    # 同じく rc を表示せず失敗メッセージのみで fail-fast する。
    if ! mv "${file}.tmp" "$file"; then
      echo "ERROR: mv failed for $file (disk full / EXDEV / permission denied?)" >&2
      rm -f "${file}.tmp"
      exit 1
    fi
  else
    echo "ERROR: jq patch failed for $file (.active = $value)" >&2
    rm -f "${file}.tmp"
    exit 1
  fi
}

# M-6 対応: guard 自体の syntax error / set -u 違反等が silent skip
# されないよう、stderr を tempfile に退避して exit code + stderr 空判定で異常終了を検知する。
# 旧 `2>/dev/null` は guard が壊れて出力なしの場合と「正常 silent skip」を区別できなかった。
_guard_stderr=$(mktemp /tmp/rite-and-logic-guard-err-XXXXXX) || _guard_stderr=""

patch_active "$INV_F" false
set +e
if [ -n "$_guard_stderr" ]; then
  out_false=$(echo "$HOOK_INPUT_BLOCKING" | (cd "$TD" && bash "$PRE_TOOL_GUARD" 2>"$_guard_stderr"))
  guard_rc_false=$?
else
  out_false=$(echo "$HOOK_INPUT_BLOCKING" | (cd "$TD" && bash "$PRE_TOOL_GUARD" 2>/dev/null))
  guard_rc_false=$?
fi
set -e
if [ -n "$_guard_stderr" ] && [ -s "$_guard_stderr" ] && [ "$guard_rc_false" -ne 0 ] && [ -z "$out_false" ]; then
  echo "ERROR: pre-tool-bash-guard.sh failed (rc=$guard_rc_false, active=false) — cannot evaluate AND-logic invariant" >&2
  head -5 "$_guard_stderr" >&2
  rm -f "$_guard_stderr"
  exit 1
fi
[ -n "$_guard_stderr" ] && : > "$_guard_stderr"  # truncate for reuse

patch_active "$INV_F" true
set +e
if [ -n "$_guard_stderr" ]; then
  out_true=$(echo "$HOOK_INPUT_BLOCKING" | (cd "$TD" && bash "$PRE_TOOL_GUARD" 2>"$_guard_stderr"))
  guard_rc_true=$?
else
  out_true=$(echo "$HOOK_INPUT_BLOCKING" | (cd "$TD" && bash "$PRE_TOOL_GUARD" 2>/dev/null))
  guard_rc_true=$?
fi
set -e
if [ -n "$_guard_stderr" ] && [ -s "$_guard_stderr" ] && [ "$guard_rc_true" -ne 0 ] && [ -z "$out_true" ]; then
  echo "ERROR: pre-tool-bash-guard.sh failed (rc=$guard_rc_true, active=true) — cannot evaluate AND-logic invariant" >&2
  head -5 "$_guard_stderr" >&2
  rm -f "$_guard_stderr"
  exit 1
fi
[ -n "$_guard_stderr" ] && rm -f "$_guard_stderr"

# active=false: deny JSON が出力されない (silent skip = 防御層 no-op、Wiki #660 root cause 経路)
if ! echo "$out_false" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  pass "AND-logic (active=false): permissionDecision: deny が出力されない (silent skip = 防御層 no-op)"
else
  fail "AND-logic (active=false): active=false でも guard が block JSON を出力 (silent skip 契約違反)"
fi

# active=true: deny JSON が出力される (AND-logic fire = .active=true 前提が機能している)
# 旧 `rc=0 or 2` 検査では active 値に関わらず常に pass するため #660 regression を検出不能だった
if echo "$out_true" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  pass "AND-logic invariant (active=true): permissionDecision: deny が出力 (AND-logic fire verified、#660 regression なし)"
else
  fail "AND-logic invariant (active=true): active=true でも guard が block JSON を出力しない (silent AND-logic skip = #660 regression)"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo ""
echo "Defense layer mapping:"
echo "  Layer 1 declarative      : commands prose で --active true literal を declare"
echo "  Layer 2 sentinel         : workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 emit"
echo "  Layer 3 Pre-check        : state-read.sh --field phase pre-condition"
echo "  Layer 4 whitelist        : phase-transition-whitelist.sh が source 可能"
echo "  Layer 5 Pre-flight       : preflight-check.sh の compact_state gate"
echo "  Layer 6/7 retired        : parent-routing pattern 移行で撤去 (ADR §6.1; --active true site-level pin は parent-routing-pattern-interim.test.sh の TC-2h-2j で代替)"
echo "  Layer 8 case arm         : phase-transition-whitelist.sh の declare -gA dispatch"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
