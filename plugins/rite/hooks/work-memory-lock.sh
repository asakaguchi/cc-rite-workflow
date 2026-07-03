#!/bin/bash
# rite workflow - Work Memory Lock (shared)
# Provides mkdir-based lock/unlock functions for issue-level work memory access.
# Used by pre-compact.sh (compact state lock) and implementation commands (issue lock).
#
# Usage (source from another script):
#   source "$(dirname "${BASH_SOURCE[0]}")/work-memory-lock.sh"
#   acquire_wm_lock "/path/to/lockdir" 50    # timeout in iterations (50 * 100ms = 5s)
#   release_wm_lock "/path/to/lockdir"
#
# Exit codes (from acquire_wm_lock):
#   0: Lock acquired
#   1: Lock acquisition failed (timeout or stale removal failed)

# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# Stale lock threshold in seconds (default: 120s for compact, 300s for issue)
WM_LOCK_STALE_THRESHOLD="${WM_LOCK_STALE_THRESHOLD:-120}"

# Process start-token: a value that changes when a PID is recycled by a new
# process, so `kill -0` alone (which cannot tell the original holder from an
# unrelated process that reused its PID) can be disambiguated. Linux uses the
# monotonic starttime (field 22 of /proc/<pid>/stat, never reused within a boot);
# BSD/macOS falls back to `ps -o lstart=` (absolute start time). Empty when
# neither source is available — callers then degrade to the legacy PID-only check.
_proc_start_token() {
  local pid="$1" tok="" rest
  if [ -r "/proc/$pid/stat" ]; then
    # comm (field 2) is parenthesized and may contain spaces / ')', so strip
    # through the LAST ') ' before counting: state becomes field 1, starttime 20.
    rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null) || rest=""
    [ -n "$rest" ] && tok=$(printf '%s\n' "$rest" | awk '{print $20}')
  fi
  if [ -z "$tok" ]; then
    tok=$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' '_')
  fi
  printf '%s' "$tok"
}

# Record the current process's PID + start-token into the lockdir. `pid` stays
# purely numeric (backward compatible with readers / older versions); the token
# lives in a separate `pid_token` file so its absence signals a legacy lock.
_write_pid_record() {
  local lockdir="$1"
  echo $$ > "$lockdir/pid" 2>/dev/null || true
  _proc_start_token "$$" > "$lockdir/pid_token" 2>/dev/null || true
}

acquire_wm_lock() {
  local lockdir="$1"
  local timeout="${2:-50}"  # 50 iterations * 100ms = 5 seconds
  local i=0

  while ! mkdir "$lockdir" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$timeout" ]; then
      # Stale lock detection: check mtime > threshold
      if [ -d "$lockdir" ]; then
        local lock_mtime lock_age stat_err
        stat_err=$(mktemp 2>/dev/null) || stat_err=""
        # GNU and BSD stat have different flags; try GNU first, fall through to BSD.
        # Both failing on the same call means staleness cannot be computed —
        # surface a WARNING because a permanent stat failure (BusyBox / NFS path
        # / chmod 000) would otherwise look indistinguishable from "fresh lock".
        # Note: bash truncates `$file` on each `2>` redirection, so when both
        # stats fail (e.g., BusyBox without either flag), only the second
        # stat's stderr remains in `stat_err`. The first stat's "illegal option"
        # message is overwritten — usually fine because the second stat's
        # error is enough to diagnose "stat broken on this platform".
        lock_mtime=$(stat -c %Y "$lockdir" 2>"${stat_err:-/dev/null}" || stat -f %m "$lockdir" 2>"${stat_err:-/dev/null}")
        if [ -z "$lock_mtime" ] || [ "$lock_mtime" = "0" ]; then
          echo "[rite] WARNING: acquire_wm_lock: stat failed on $lockdir — staleness undetectable, treating as fresh lock" >&2
          [ -n "$stat_err" ] && [ -s "$stat_err" ] && head -3 "$stat_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
          [ -n "$stat_err" ] && rm -f "$stat_err"
          return 1
        fi
        [ -n "$stat_err" ] && rm -f "$stat_err"
        lock_age=$(( $(date +%s) - lock_mtime ))
        if [ "$lock_age" -gt "$WM_LOCK_STALE_THRESHOLD" ]; then
          # Check PID file: if process is still alive, lock is not stale.
          # No PID file means the lock holder did not record its PID
          # (e.g., older version); treat as stale since we cannot verify liveness.
          if [ -f "$lockdir/pid" ]; then
            local lock_pid
            lock_pid=$(head -c 20 "$lockdir/pid" 2>/dev/null) || lock_pid=""
            if [ -n "$lock_pid" ] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
              # PID is alive — but a dead holder's PID may have been RECYCLED by an
              # unrelated process, in which case `kill -0` succeeds for the wrong
              # process and we would wrongly keep an abandoned lock forever. Compare
              # the recorded start-token against the live process's current token:
              # a mismatch means PID reuse → the original holder is gone → stale.
              if [ -f "$lockdir/pid_token" ]; then
                local stored_token cur_token
                stored_token=$(head -c 100 "$lockdir/pid_token" 2>/dev/null) || stored_token=""
                cur_token=$(_proc_start_token "$lock_pid")
                if [ -n "$stored_token" ] && [ -n "$cur_token" ] && [ "$stored_token" != "$cur_token" ]; then
                  : # PID reused by a different process → fall through to reclaim
                else
                  return 1  # same live holder (or token unverifiable) — not stale
                fi
              else
                # Legacy lock without a token file: reuse is undetectable, so stay
                # conservative and treat the live PID as the genuine holder.
                return 1
              fi
            fi
          fi
          # Stale lock — remove pid + token files and directory, then retry once
          rm -f "$lockdir/pid" "$lockdir/pid_token" 2>/dev/null || true
          rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null || true
          if mkdir "$lockdir" 2>/dev/null; then
            _write_pid_record "$lockdir"
            return 0
          fi
        fi
      fi
      return 1
    fi
    sleep 0.1
  done
  _write_pid_record "$lockdir"
  return 0
}

release_wm_lock() {
  local lockdir="$1"
  rm -f "$lockdir/pid" "$lockdir/pid_token" 2>/dev/null || true
  rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null || true
}

is_wm_locked() {
  local lockdir="$1"
  [ -d "$lockdir" ]
}
