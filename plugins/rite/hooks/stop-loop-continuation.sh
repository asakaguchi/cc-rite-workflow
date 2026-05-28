#!/bin/bash
# rite workflow - Stop Hook: review↔fix loop continuation (Issue #1168)
#
# Guarantees that /rite:pr:iterate の review↔fix ループが、LLM が継続 sentinel
# ([review:fix-needed:N] / [fix:pushed] / [fix:pushed-wm-stale]) を出した直後に
# turn を終了してしまっても自動継続するよう、構造的な層を提供する。
#
# 仕組み (one-shot consume / stop_hook_active に依存しない設計):
#   - 継続 sentinel を出す sub-skill (review.md Step 8.0 / fix.md Step 5.1) が
#     flow-state に handoff マーカー (例 "/rite:pr:fix 99") をセットする。
#   - 本 hook は turn 終了時に flow-state.sh consume-handoff で handoff を
#     **読み取り + 削除** する (one-shot)。非空なら decision:block で停止を差し戻し、
#     handoff のコマンドを reason として再注入する。
#   - 削除済みのため、進捗なく再度停止すれば handoff は空 → block しない
#     (無限 block ループ防止 / Issue #1168 AC-3)。
#   - 各継続点で handoff が再セットされるため複数サイクル継続する (AC-1)。
#   - 終了 sentinel ([review:mergeable] / [fix:replied-only] / [fix:cancelled-by-user])
#     は handoff をセットしない (cmd_set がデフォルトクリア) → handoff 空 → block しない
#     (誤継続防止 / AC-2)。
#
# Exit behavior:
#   exit 0 (no stdout)        — allow stop (handoff 不在 / loop 外 / 解決失敗 = fail-open)
#   stdout {"decision":"block"} — block stop and re-inject the loop continuation command
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration 由来の二重登録対策)
[ -z "${_RITE_HOOK_RUNNING_STOP:-}" ] || exit 0
export _RITE_HOOK_RUNNING_STOP=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Parse session_id + cwd from the Stop payload (single jq invocation).
# Unit separator (\x1f) avoids IFS collapsing an empty field and left-shifting cwd.
_jq_out=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.cwd // "")] | join("")' 2>/dev/null) || _jq_out=$'\x1f'
IFS=$'\x1f' read -r SESSION_ID CWD <<< "$_jq_out"

# session_id 不在 → loop state を解決できない → 停止許可 (fail-open)。
# Claude Code の Stop payload は常に session_id を含むため、空は非 Claude Code クライアント等の例外。
[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD) — post-tool-wm-sync.sh と同じ解決経路。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Read + clear the one-shot handoff marker. stderr は握る (loop 外セッションでは
# state file 不在が常態のため diagnostic を出さない)。RITE_DEBUG 時のみ後段で観測可能。
HANDOFF=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" consume-handoff --session "$SESSION_ID" 2>/dev/null) || HANDOFF=""

# handoff 不在 → review↔fix ループの継続待ちではない → 停止許可。
[ -n "$HANDOFF" ] || exit 0

# handoff pending: 停止を差し戻し、次のループコマンドを再注入する。
_reason="rite の review↔fix ループ (/rite:pr:iterate) が継続中です。停止せず、次を実行してください: ${HANDOFF}

このループは [review:mergeable] / [fix:replied-only] / [fix:cancelled-by-user] のいずれかに到達するか、ユーザーが Ctrl+C で中断するまで継続します (Issue #1136 / #1168)。handoff は consume 済みのため、進捗なく再度停止した場合は次回は停止が許可されます。"

# decision:block を JSON で emit。jq 失敗時は literal JSON にフォールバックして継続意図を保つ
# (pre-tool-bash-guard.sh の fail-closed フォールバックと同様の堅牢化)。
if ! jq -n --arg r "$_reason" '{decision:"block", reason:$r}'; then
  _r_esc="${_reason//\\/\\\\}"
  _r_esc="${_r_esc//\"/\\\"}"
  _r_esc="${_r_esc//$'\n'/\\n}"
  printf '{"decision":"block","reason":"%s"}\n' "$_r_esc"
fi
exit 0
