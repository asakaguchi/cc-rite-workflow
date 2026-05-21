#!/bin/bash
# rite workflow - Phase Transition Whitelist
#
# Provides the canonical phase-transition graph used by pre-tool-bash-guard.sh
# and other orchestration helpers to detect silent phase-skipping bugs in the
# /rite:issue:start end-to-end flow. The flat workflow uses 9 phases (init /
# branch / plan / implement / lint / pr / review / fix / completed); legacy
# phase names from earlier sub-skill chains are accepted via the fail-open
# path so existing state files can still be resumed.
#
# This file is designed to be SOURCED, not executed directly. After sourcing:
#   - `rite_phase_transition_allowed <prev> <next>` — returns 0 if allowed, 1 otherwise
#   - `rite_phase_expected_next <phase>` — prints space-separated list of valid next phases
#   - `rite_phase_is_known <phase>` — returns 0 if the phase name exists in the graph
#
# Overrides may be loaded from rite-config.yml under:
#   hooks:
#     stop_guard:
#       phase_transitions:
#         <phase>: [<next1>, <next2>]
#
# ⚠️ The `stop_guard:` key name is preserved verbatim for backward compatibility
# with existing project rite-config.yml files — the original stop-guard.sh has
# been retired but renaming the config key would be a breaking change.
#
# Override semantics: MERGE — listed targets are APPENDED to the baked-in
# whitelist for that phase (so projects can add custom transitions without
# losing the defaults).

# Guard against double-loading when multiple scripts source this file.
[ -n "${_RITE_PHASE_TRANSITION_LOADED:-}" ] && return 0
_RITE_PHASE_TRANSITION_LOADED=1

# Bash 4.2+ required for `declare -gA`. Older bash (macOS default 3.2, pinned
# by Apple's GPLv3 constraints) would abort with a syntax error on the
# associative-array literal below. Emit a WARNING and return gracefully so
# callers can detect the missing function and route around the disabled
# whitelist; a silent return would hide the macOS fail-open from developers.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  echo "[rite] WARNING: phase-transition-whitelist disabled (requires bash >= 4.2, found ${BASH_VERSION:-unknown}). macOS users running default bash 3.2 will not get phase transition validation. Upgrade bash via Homebrew or use the bundled hooks with a newer shell." >&2
  return 0
fi

# Baked-in whitelist. Each entry maps a phase to the phases it may transition
# to. Empty string ("") is accepted as a synthetic "workflow start" predecessor
# for any phase, since /rite:issue:start begins with no prior state. Each step
# also accepts "same phase → same phase" so /rite:resume can rewrite the
# current phase without tripping the guard (handled by the
# `[ "$prev" = "$next" ]` short-circuit in rite_phase_transition_allowed).
# The canonical phase→step routing is documented in commands/resume.md Phase 3.2.
declare -gA _RITE_PHASE_TRANSITIONS=(
  ["init"]="branch plan"
  ["branch"]="plan implement"
  ["plan"]="implement lint"
  ["implement"]="lint pr"
  ["lint"]="pr review completed"
  ["pr"]="review completed"
  ["review"]="fix pr completed"
  ["fix"]="review pr completed"
  ["completed"]=""
  # create.md は flat 化後 terminal state を `completed` (start.md と同じ) で書き込むため、
  # 旧 `create_completed` は whitelist から削除済。session-end.sh / pre-tool-bash-guard.sh
  # の `create_*` lifecycle 検出は legacy state file 残置用 (forward-compat)。

  # /rite:pr:cleanup lifecycle (#604).
  # cleanup.md Phase 4 (wiki-auto-ingest) → Phase 5 (Completion Report) 多層防御で導入。
  # cleanup_pre_ingest は Phase 4.W.2 invoke 直前、cleanup_post_ingest は wiki:ingest sub-skill
  # return 直後 (🚨 Mandatory After Wiki Ingest セクション)、cleanup_completed は Phase 5
  # Terminal Completion (sentinel + flow-state deactivate)。
  # cleanup_completed は rite_phase_transition_allowed() の terminal acceptance に追加済み。
  # /rite:pr:cleanup initial phase (#608 follow-up): cleanup.md Phase 1.0 (Activate
  # Flow State) writes phase=cleanup before any sub-skill invoke. Without this entry,
  # the cleanup → cleanup_pre_ingest transition was unknown, leaving Phase 1.0-4.W.1 unprotected.
  # (stop-guard.sh の `case "$PHASE" in cleanup)` ブランチの HINT 文言 "Phase 1.0 (Activate Flow State)" と一致させる)
  # NOTE (#618 reverts the #608 follow-up YAGNI removal): cleanup_pre_ingest can transition to
  # ingest_pre_lint when ingest.md Phase 8.2 Pre-write overrides the caller phase. On lint return,
  # ingest.md 🚨 Mandatory After Auto-Lint Step 1 patches ingest_post_lint, then the caller's
  # Mandatory After Wiki Ingest writes back cleanup_post_ingest. See DRIFT-CHECK ANCHOR in
  # plugins/rite/commands/wiki/ingest.md 🚨 Mandatory After Auto-Lint section.
  ["cleanup"]="cleanup_pre_ingest cleanup_completed"
  ["cleanup_pre_ingest"]="cleanup_post_ingest cleanup_completed ingest_pre_lint"
  ["cleanup_post_ingest"]="cleanup_completed"
  ["cleanup_completed"]=""

  # /rite:wiki:ingest lifecycle ring (#618, reverts the #608 follow-up YAGNI removal).
  # ingest.md Phase 8.2 Pre-write (ingest_pre_lint) → 🚨 Mandatory After Auto-Lint Step 1
  # (ingest_post_lint) → Phase 9.1 Step 3 terminal patch (ingest_completed, active=false).
  # Caller 経由時は caller Mandatory After Wiki Ingest が caller phase
  # (cleanup_post_ingest) に書き戻す ring 構造。単独実行時は --if-exists により flow-state
  # 不在なら no-op。
  #
  # **Historical (PR #675 で stop-guard.sh は削除済)**: 旧 `stop-guard.sh` の ingest_pre_lint /
  # ingest_post_lint case arm が end_turn を block し manual_fallback_adopted sentinel を emit する
  # 設計だった。現在は本 phase-transition-whitelist の許可遷移定義 + ingest.md 🚨 Mandatory After
  # Auto-Lint section の 2 site で symmetry を担う (旧 3 site から 2 site に縮退)。
  # DRIFT-CHECK ANCHOR (semantic): ingest.md 🚨 Mandatory After Auto-Lint section と
  # 本 whitelist 定義の ingest_* phase 遷移とで 2 site 対称。いずれかを変更する際は両 site 同時確認。
  #
  # Edge rationale:
  # - `ingest_pre_lint → ingest_post_lint`: canonical path (Mandatory After Step 1 patch after lint returns)
  # - `ingest_pre_lint → ingest_completed`: defense-in-depth edge for the Step 1 WARNING fallback only.
  #   If Mandatory After Step 1 patch silently fails (WARNING + continue), Phase 9.1 Step 3's terminal
  #   patch can still transition directly to ingest_completed without tripping the guard.
  # - `ingest_pre_lint → cleanup_post_ingest`: defense-in-depth edge for both Mandatory After Step 1
  #   AND Phase 9.1 Step 3 failing — lets the caller's Mandatory After write the caller phase back.
  ["ingest_pre_lint"]="ingest_post_lint ingest_completed cleanup_post_ingest"
  ["ingest_post_lint"]="ingest_completed cleanup_post_ingest"
  ["ingest_completed"]="cleanup_post_ingest"
)

# Load override map from rite-config.yml if present.
# Only called once per process via the guard flag above.
_rite_load_whitelist_overrides() {
  local config_file="${1:-}"
  [ -z "$config_file" ] && return 0
  [ ! -f "$config_file" ] && return 0

  # Extract the hooks.stop_guard.phase_transitions block with awk.
  # Supported format (subset of YAML):
  #   hooks:
  #     stop_guard:
  #       phase_transitions:
  #         phase_x: [phase_y, phase_z]
  #         phase_a:
  #           - phase_b
  #           - phase_c
  #
  # Trailing `# comment` and `#` column-0 comments are both tolerated
  # (regex ends with optional `#.*` to match full-line or inline comments).
  #
  # Error visibility: awk errors (permission denied, disk I/O, malformed invocation)
  # are sent to stderr. Previously suppressed with `2>/dev/null`, which silently
  # hid override misconfiguration from users — the opposite of #490's intent
  # (error-handling-reviewer CRITICAL).
  local block awk_err
  # When mktemp fails, awk stderr routes to /dev/null and the override-parse
  # root cause vanishes. Surface the mktemp failure once so users can debug
  # disk/inode issues instead of silently skipped overrides.
  awk_err=$(mktemp /tmp/rite-phase-transition-awk-err-XXXXXX 2>/dev/null) || {
    awk_err=""
    echo "WARNING: phase-transition-whitelist: mktemp failed for awk stderr capture; override parse errors will not be diagnosable" >&2
  }
  block=$(awk '
    BEGIN { in_hooks=0; in_sg=0; in_pt=0; pt_indent=-1 }
    /^hooks:[[:space:]]*(#.*)?$/ { in_hooks=1; next }
    in_hooks && /^[a-zA-Z]/ { in_hooks=0; in_sg=0; in_pt=0 }
    in_hooks && /^[[:space:]]+stop_guard:[[:space:]]*(#.*)?$/ { in_sg=1; next }
    in_sg && /^[[:space:]]+phase_transitions:[[:space:]]*(#.*)?$/ {
      in_pt=1
      match($0, /^[[:space:]]+/)
      pt_indent=RLENGTH
      next
    }
    in_pt {
      # Leaving the phase_transitions block when indentation shrinks back.
      line_indent=0
      match($0, /^[[:space:]]*/); line_indent=RLENGTH
      if ($0 ~ /^[[:space:]]*$/) { next }
      if (line_indent <= pt_indent) { in_pt=0; next }
      print
    }
  ' "$config_file" 2>"${awk_err:-/dev/null}")
  local awk_rc=$?

  if [ "$awk_rc" -ne 0 ]; then
    echo "WARNING: rite-config.yml override parse (awk) failed (rc=$awk_rc): $config_file" >&2
    if [ -n "$awk_err" ] && [ -s "$awk_err" ]; then
      head -3 "$awk_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: rite-config.yml の権限 / awk バイナリを確認してください" >&2
    [ -n "$awk_err" ] && rm -f "$awk_err"
    # Return non-zero so the caller's `|| log_diag ...` handler records the
    # failure in the diagnostic log (devops cycle-2 LOW #2).
    return 1
  fi
  [ -n "$awk_err" ] && rm -f "$awk_err"

  [ -z "$block" ] && return 0

  # Parse the extracted block. Two sub-formats:
  #   (1) inline list:  phase_x: [a, b, c]
  #   (2) block list:   phase_x:\n  - a\n  - b
  local current_key=""
  local current_targets=""
  # Reset here rather than only via the trailing `unset`: early returns
  # (awk failure, empty block) skip the unset, and a residual count from a
  # prior source-and-call would inflate the next WARNING.
  _rite_pt_skip_count=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Strip leading whitespace
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue

    # Ignore pure comment lines
    [[ "$trimmed" =~ ^# ]] && continue

    # Block list entry: "- value" — use [[:space:]]+ to tolerate tab and multiple spaces
    # (prompt-engineer IMPORTANT R #2).
    if [[ "$trimmed" =~ ^-[[:space:]]+ ]]; then
      local val="${trimmed#-}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%%#*}"
      val="${val//[[:space:]]/}"
      [ -n "$val" ] && current_targets="${current_targets:+$current_targets }$val"
    elif [[ "$trimmed" =~ ^([a-zA-Z0-9_]+):(.*)$ ]]; then
      # Flush previous key
      if [ -n "$current_key" ] && [ -n "$current_targets" ]; then
        _rite_merge_override_entry "$current_key" "$current_targets"
      fi
      current_key="${BASH_REMATCH[1]}"
      local rhs="${BASH_REMATCH[2]}"
      rhs="${rhs#"${rhs%%[![:space:]]*}"}"
      current_targets=""
      # Handle inline list form:  [a, b, c]
      # Require balanced brackets — unclosed `[a, b` silently dropped the entry
      # and leaked into the next key (IMPORTANT R #3).
      if [[ "$rhs" =~ ^\[ ]]; then
        if [[ "$rhs" =~ ^\[(.*)\]$ ]]; then
          local list_body="${BASH_REMATCH[1]}"
          list_body="${list_body//,/ }"
          for val in $list_body; do
            val="${val//\"/}"
            val="${val//\'/}"
            val="${val//[[:space:]]/}"
            [ -n "$val" ] && current_targets="${current_targets:+$current_targets }$val"
          done
          _rite_merge_override_entry "$current_key" "$current_targets"
          current_key=""
          current_targets=""
        else
          echo "WARNING: rite-config.yml override parse: unclosed inline list on '$current_key': $rhs" >&2
          current_key=""
          current_targets=""
        fi
      fi
    else
      # Unrecognized line: count it so we can summarize once after the loop
      # (even without RITE_DEBUG, the user needs a single signal that lines
      # were dropped — silent drops on misconfigured overrides were the
      # original failure mode).
      _rite_pt_skip_count=$((${_rite_pt_skip_count:-0} + 1))
      [ -n "${RITE_DEBUG:-}" ] && echo "[rite debug] override parse skipped line: $trimmed" >&2
    fi
  done <<< "$block"

  if [ "${_rite_pt_skip_count:-0}" -gt 0 ] && [ -z "${RITE_DEBUG:-}" ]; then
    echo "WARNING: phase-transition-whitelist: ${_rite_pt_skip_count} override lines skipped (set RITE_DEBUG=1 for details): $config_file" >&2
  fi
  unset _rite_pt_skip_count

  # Flush any trailing block list
  if [ -n "$current_key" ] && [ -n "$current_targets" ]; then
    _rite_merge_override_entry "$current_key" "$current_targets"
  fi
}

_rite_merge_override_entry() {
  local key="$1"
  local new_targets="$2"
  local existing="${_RITE_PHASE_TRANSITIONS[$key]:-}"
  if [ -z "$existing" ]; then
    _RITE_PHASE_TRANSITIONS[$key]="$new_targets"
  else
    # Append non-duplicate targets
    local merged="$existing"
    local val
    for val in $new_targets; do
      if ! [[ " $merged " == *" $val "* ]]; then
        merged="$merged $val"
      fi
    done
    _RITE_PHASE_TRANSITIONS[$key]="$merged"
  fi
}

# Return 0 if `prev_phase -> next_phase` is allowed, 1 otherwise.
# Synthetic rules:
#   - Empty prev_phase is accepted for any known phase (workflow cold start).
#   - Unknown prev_phase is accepted (forward-compatibility; phases added by
#     sub-skills outside this whitelist should not cause spurious blocks).
#   - The special phase "completed" is always a valid terminal.
rite_phase_transition_allowed() {
  local prev="$1"
  local next="$2"

  # Terminal / cold-start cases.
  # "completed" is the /rite:issue:start terminal state. "create_completed" is written by
  # /rite:issue:create at its end. "cleanup_completed" (#604) is the terminal state for
  # /rite:pr:cleanup. "phase_done" was a speculative reserved name with no producer —
  # removed per code-quality cycle-3 LOW (premature abstraction). "ingest_completed" was
  # removed in #608 follow-up as YAGNI, then **revived in #618 (PR #624)** when ingest.md
  # gained flow-state writes (Phase 8.2 Pre-write / 🚨 Mandatory After Step 1 / Phase 9.1
  # Step 3 terminal patch) — see the revived entries in _RITE_PHASE_TRANSITIONS array
  # above and plugins/rite/commands/wiki/ingest.md Phase 8.2 / 🚨 Mandatory After /
  # Phase 9.1 Step 3 for the ring design.
  #
  # NOTE (#608 follow-up — forward-compat bypass scope): The four terminal accepts below
  # currently allow ANY prev → terminal transition unconditionally. This is intentional
  # forward-compat behaviour today (catches cold-start writes, retry paths, and skill
  # versions that may add new prev phases without updating this file), but it also masks
  # genuine protocol violations such as cleanup → cleanup_completed (skipping pre/post
  # ingest entirely). Tightening this to require specific prev → terminal pairs is a
  # separate scope (devops LOW) — when revisited, build the constraint from the explicit
  # _RITE_PHASE_TRANSITIONS entries (e.g. cleanup_completed must come from cleanup_post_ingest
  # OR cleanup_pre_ingest) and add coverage in stop-guard.test.sh before flipping the
  # default.
  # ingest_completed (#618, reverts the #608 follow-up removal): ingest.md Phase 9.1 Step 3
  # writes this terminal state when flow-state was actived by a caller. Accept any prev →
  # ingest_completed in forward-compat mode; the explicit ingest_pre_lint / ingest_post_lint
  # → ingest_completed transitions are still encoded in _RITE_PHASE_TRANSITIONS above for
  # semantic clarity.
  [ -z "$prev" ] && return 0
  [ "$prev" = "$next" ] && return 0

  # Terminal phase acceptance: only the canonical predecessor set is accepted.
  # An unconditional `prev → terminal` allow would let a workflow skip (e.g.
  # init → completed) pass silently, defeating the whole point of the whitelist.
  if [ "$next" = "completed" ] || [ "$next" = "cleanup_completed" ] || [ "$next" = "ingest_completed" ]; then
    case "$next:$prev" in
      completed:lint|completed:pr|completed:review|completed:fix) return 0 ;;
      cleanup_completed:cleanup_post_ingest|cleanup_completed:cleanup_pre_ingest) return 0 ;;
      ingest_completed:ingest_pre_lint|ingest_completed:ingest_post_lint) return 0 ;;
      # Forward-compat arm: legacy phase names from earlier sub-skill chains
      # (create_* / start_* / phase[0-9]* / phase5_*) are accepted when /rite:resume
      # picks up a state file written before the flat workflow consolidation.
      # Without this, resuming pre-existing in-flight workflows would be blocked.
      completed:create_*|completed:start_*|completed:phase[0-9]*|completed:phase[0-9]_*) return 0 ;;
      *)
        # Block protocol violations (e.g. init → completed) and surface them on
        # stderr — silent rejection would be indistinguishable from "guard not
        # running" during incident triage.
        if [ "${RITE_DEBUG:-0}" = "1" ]; then
          echo "[rite] ERROR terminal-accept rejected: prev='$prev' → next='$next' is outside the canonical predecessor set; protocol violation" >&2
        else
          echo "[rite] ERROR phase-transition: '$prev' → '$next' (terminal) outside canonical set" >&2
        fi
        return 1
        ;;
    esac
  fi

  local allowed="${_RITE_PHASE_TRANSITIONS[$prev]:-}"
  # Unknown prev phase → accept (forward compat) but emit an INFO once per
  # hook process so the forward-compat path remains observable. A global flag
  # suppresses duplicates within the same process; subsequent hook invocations
  # will re-emit so persistent drift is still visible across executions.
  if [ -z "$allowed" ] && ! rite_phase_is_known "$prev"; then
    if [ -z "${_RITE_UNKNOWN_PREV_INFO_EMITTED:-}" ]; then
      echo "[rite] INFO phase-transition: unknown-prev forward-compat allow (prev='$prev' → next='$next'); future drift will be silent within this hook execution" >&2
      _RITE_UNKNOWN_PREV_INFO_EMITTED=1
    fi
    if [ "${RITE_DEBUG:-0}" = "1" ]; then
      echo "[RITE_DEBUG] unknown-prev-accept: prev='$prev' (not in _RITE_PHASE_TRANSITIONS) → next='$next' (forward-compat allow)" >&2
    fi
    return 0
  fi

  local val
  for val in $allowed; do
    [ "$val" = "$next" ] && return 0
  done
  return 1
}

# Print the expected next phases for a given phase.
rite_phase_expected_next() {
  local phase="$1"
  printf '%s\n' "${_RITE_PHASE_TRANSITIONS[$phase]:-}"
}

# Return 0 if the given phase name is defined in the whitelist as either a
# source or a target.
rite_phase_is_known() {
  local phase="$1"
  [ -n "${_RITE_PHASE_TRANSITIONS[$phase]:-}" ] && return 0
  local key val
  for key in "${!_RITE_PHASE_TRANSITIONS[@]}"; do
    for val in ${_RITE_PHASE_TRANSITIONS[$key]}; do
      [ "$val" = "$phase" ] && return 0
    done
  done
  return 1
}

# Return 0 if the given phase is an in-progress phase of /rite:issue:create
# lifecycle (i.e., create_interview / create_post_interview / create_delegation /
# create_post_delegation — NOT create_completed which is terminal).
#
# Single source of truth for "is the create workflow mid-delegation?" queries
# used by pre-tool-bash-guard.sh (Pattern 5) and session-end.sh (lifecycle
# unfinished warning). Centralizing the phase name list here prevents silent
# drift when new create_* phases are added to _RITE_PHASE_TRANSITIONS (#501
# code-quality review HIGH).
rite_phase_is_create_lifecycle_in_progress() {
  local phase="$1"
  case "$phase" in
    create_interview|create_post_interview|create_delegation|create_post_delegation)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns 0 if `phase` represents a cleanup workflow that has not yet reached its
# terminal cleanup_completed state (#608 follow-up — parity with the create
# lifecycle helper above). Used by session-end.sh to surface a WARN_MSG when a
# session ends mid-cleanup (the wiki ingest never ran, or Phase 5 completion
# report was never emitted).
#
# Ring transition observability: during the cleanup → ingest_pre_lint → ingest_post_lint
# loop, the caller phase is temporarily overwritten. If the session ends mid-loop,
# the helper must still report cleanup-in-progress so session-end.sh emits a
# WARN_MSG — otherwise an incomplete cleanup lifecycle goes unnoticed. Standalone
# `/rite:wiki:ingest` invocations avoid false-positive WARN_MSG by reading
# flow-state.active=false separately in session-end.sh.
# Note: `ingest_completed` is intentionally excluded — it's the terminal state
# (active=false) and does not qualify as "in progress".
rite_phase_is_cleanup_lifecycle_in_progress() {
  local phase="$1"
  case "$phase" in
    cleanup|cleanup_pre_ingest|cleanup_post_ingest|ingest_pre_lint|ingest_post_lint)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Optional: auto-load overrides when RITE_CONFIG env var points to a config file.
# Surface partial loader failure (awk parse error on a corrupt config) so the
# user knows their custom transitions aren't taking effect — silently falling
# back to built-in defaults would leave an undiagnosable observability gap.
if [ -n "${RITE_CONFIG:-}" ]; then
  _rite_load_whitelist_overrides "$RITE_CONFIG" || echo "[rite] WARNING: phase-transition-whitelist: rite-config override load partially failed; using built-in defaults" >&2
fi
