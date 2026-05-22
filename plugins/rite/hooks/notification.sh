#!/bin/bash
# rite workflow - Notification Hook
# Sends notifications to configured channels

set -euo pipefail

# Notifications are best-effort; exit gracefully if jq is not available
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read CWD from stdin JSON (consistent with other hooks).
# CWD is provided by the Claude Code runtime and is already an absolute path;
# realpath normalization is unnecessary and would add a portability concern.
# Malformed input is treated as "no CWD" and the hook exits silently — surface
# the parse failure under RITE_DEBUG so a recurrent malformed payload is
# diagnosable instead of being mistaken for "no notifications configured".
INPUT=$(cat) || INPUT=""
_cwd_jq_err=$(mktemp 2>/dev/null) || _cwd_jq_err=""
# Pre-set CWD="" so set-u-safe; if/else preserves the real jq rc (POSIX `!`
# inversion would collapse `$?` to 0 in the then-branch). A malformed hook
# payload is a production-safety signal, not debug noise — surface the
# WARNING unconditionally and reserve RITE_DEBUG for the stderr snippet.
CWD=""
if CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>"${_cwd_jq_err:-/dev/null}"); then
    :
else
    _cwd_rc=$?
    echo "[rite] WARNING: notification: hook stdin jq parse failed (rc=$_cwd_rc) — notification dispatch skipped for this event" >&2
    [ -n "${RITE_DEBUG:-}" ] && [ -n "$_cwd_jq_err" ] && [ -s "$_cwd_jq_err" ] && head -3 "$_cwd_jq_err" | sed 's/^/  /' >&2
    CWD=""
fi
[ -n "$_cwd_jq_err" ] && rm -f "$_cwd_jq_err"
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
    exit 0
fi

# Resolve project root (git root anchored). Matches session-start.sh /
# _resolve-schema-version.sh / post-tool-wm-sync.sh convention; `$CWD` based
# lookup would silently miss rite-config.yml when Claude Code is launched from
# a subdirectory (Issue #976).
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

CONFIG_FILE="$STATE_ROOT/rite-config.yml"
if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
fi

# Arguments
EVENT_TYPE="${1:-}"    # pr_created, pr_ready, issue_closed, etc.
EVENT_DATA="${2:-}"    # Reserved for future use (JSON data about the event).
                       # Validation will be added when consumers are introduced.

# Check if notifications are enabled
# This is a placeholder - actual implementation would parse YAML

# Webhook URL validation: only ^https:// prefix is checked. A host whitelist is
# intentionally not implemented because webhook URLs come from rite-config.yml,
# which is committed by the project owner. Delivery itself is best-effort, but
# curl failures surface a single-line WARNING so an expired webhook / network
# outage doesn't cause notifications to silently stop arriving.
_send_webhook() {
    local channel="$1" webhook_url="$2" payload="$3"
    # 設定ミス (空文字 / typo / http:// で指定 / 末尾空白) を silent skip すると、配線時に
    # 通知が届かない原因が特定できない。RITE_DEBUG 時は理由を log に残し、操作者が
    # config を見直せるようにする。
    if [ -z "$webhook_url" ]; then
      [ -n "${RITE_DEBUG:-}" ] && echo "[rite] DEBUG: notification webhook=$channel skipped (URL empty)" >&2
      return 0
    fi
    if ! [[ "$webhook_url" =~ ^https:// ]]; then
      [ -n "${RITE_DEBUG:-}" ] && echo "[rite] DEBUG: notification webhook=$channel skipped (URL must start with https://)" >&2
      return 0
    fi
    local _curl_err
    _curl_err=$(mktemp 2>/dev/null) || _curl_err=""
    # `if ! curl` would invert the exit status, leaving `$?` as 0 inside the
    # then-branch and producing the misleading "curl failed (rc=0)" message.
    # The if/else split preserves the real curl rc (timeout=28, host unreachable=7,
    # ssl=60, etc.) so an expired webhook URL or network outage is diagnosable.
    if curl -sf --connect-timeout 5 --max-time 10 -X POST "$webhook_url" \
        -H 'Content-type: application/json' -d "$payload" \
        > /dev/null 2>"${_curl_err:-/dev/null}"; then
        :
    else
        local _rc=$?
        echo "[rite] WARNING: notification($channel): curl failed (rc=$_rc) — webhook may be expired or unreachable" >&2
        [ -n "$_curl_err" ] && [ -s "$_curl_err" ] && head -3 "$_curl_err" | sed 's/^/  /' >&2
    fi
    [ -n "$_curl_err" ] && rm -f "$_curl_err"
}

send_slack() {
    _send_webhook "slack" "$1" "$(jq -n --arg text "$2" '{text: $text}')"
}

send_discord() {
    _send_webhook "discord" "$1" "$(jq -n --arg content "$2" '{content: $content}')"
}

send_teams() {
    _send_webhook "teams" "$1" "$(jq -n --arg text "$2" '{text: $text}')"
}

# Main notification logic — echo-only stubs. The _send_webhook / send_slack /
# send_discord / send_teams helpers above are SCAFFOLDING, NOT LIVE CODE: the
# case arms below intentionally only echo because rite-config.yml webhook URL
# parsing has not been wired through yet. The helpers (and their tests) are
# kept here so the wiring step has a tested target to plug into; treat any
# silent "no notifications arrived" complaint as expected behaviour, not a
# bug in this hook.
case "$EVENT_TYPE" in
    pr_created)
        echo "rite: Notification for PR created"
        ;;
    pr_ready)
        echo "rite: Notification for PR ready for review"
        ;;
    issue_closed)
        echo "rite: Notification for Issue closed"
        ;;
    *)
        # Unknown event type, skip
        ;;
esac
