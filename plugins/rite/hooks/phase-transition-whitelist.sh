#!/bin/bash
# rite workflow - Phase Transition Whitelist
#
# Defines the canonical phase-transition graph for the /rite:issue:start flat
# workflow (9 phases: init / branch / plan / implement / lint / pr / review /
# fix / completed) plus the cleanup and wiki:ingest lifecycle rings. Legacy
# phase names from earlier sub-skill chains are accepted via the forward-compat
# arm so existing state files can still be resumed.
#
# This file is designed to be SOURCED, not executed directly. After sourcing:
#   - `rite_phase_transition_allowed <prev> <next>` — library entry point for
#     orchestrator-level pre-write validation. Currently exercised only by the
#     test suite; production hooks (pre-tool-bash-guard.sh, session-end.sh)
#     consume the predicate helpers below rather than calling this validator
#     directly. Wiring it into a write-time hook is a follow-up.
#   - `rite_phase_is_create_lifecycle_in_progress <phase>` — predicate used by
#     production hooks to detect orphaned create_* lifecycle state from
#     pre-flat-workflow versions (the current flat create.md writes only
#     `phase=completed`, so a non-completed `create_*` value indicates a stale
#     state file that needs cleanup).
#   - `rite_phase_is_cleanup_lifecycle_in_progress <phase>` — same shape for
#     /rite:pr:cleanup intermediate phases.
#   - `rite_phase_expected_next <phase>` — prints space-separated list of valid
#     next phases (for diagnostic messages).
#   - `rite_phase_is_known <phase>` — returns 0 if the phase name exists in the graph.
#
# Overrides may be loaded from rite-config.yml under:
#   hooks:
#     stop_guard:
#       phase_transitions:
#         <phase>: [<next1>, <next2>]
#
# ⚠️ The `stop_guard:` key name is preserved verbatim for backward compatibility
# with existing project rite-config.yml files — renaming it would silently
# break every consumer that already has overrides under the old key.
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
  ["pr"]="review completed ready ready_error"
  ["review"]="fix pr completed"
  ["fix"]="review pr completed"
  ["completed"]=""

  # `ready` is the post-Ready success state written by /rite:pr:ready. Allowed
  # exits: success → completed (normal finalize via start.md ステップ 8.3-8.6),
  # or fallback → ready_error if a downstream failure rolls back the Ready
  # transition mid-flight. Both arms terminate the workflow; ready_error is the
  # recovery-eligible terminal so /rite:resume can pick it up.
  ["ready"]="completed ready_error"

  # `ready_error` is an intermediate failure state written by /rite:pr:ready
  # when the Ready transition fails. It must NOT route /rite:resume back to
  # ステップ 6 (PR creation — the PR already exists); resume.md maps
  # `ready_error` directly to ステップ 8 (Ready & 完結) so the user can retry
  # the Ready transition (→ ready) or terminate (→ completed) without
  # re-creating the PR.
  ["ready_error"]="ready completed"
  # `create_completed` is intentionally absent: /rite:issue:create writes
  # `completed` (same terminal as /rite:issue:start) in the flat workflow.
  # session-end.sh / pre-tool-bash-guard.sh still detect `create_*` lifecycle
  # phases only to handle legacy state files left by older versions.

  # /rite:pr:cleanup lifecycle.
  # cleanup → cleanup_pre_ingest → cleanup_post_ingest → cleanup_completed
  # is the canonical ring; the entries below let pre-ingest jump directly to
  # cleanup_completed when wiki ingest is configured off, and let the
  # caller's "Mandatory After Wiki Ingest" rewrite cleanup_post_ingest after
  # ingest.md temporarily overrides the phase to ingest_pre_lint.
  ["cleanup"]="cleanup_pre_ingest cleanup_completed"
  ["cleanup_pre_ingest"]="cleanup_post_ingest cleanup_completed ingest_pre_lint"
  ["cleanup_post_ingest"]="cleanup_completed"
  ["cleanup_completed"]=""

  # /rite:wiki:ingest lifecycle ring. ingest.md temporarily overrides the
  # caller phase to ingest_pre_lint, patches ingest_post_lint after lint
  # returns, then writes the terminal ingest_completed. The extra edges
  # below let the caller's "Mandatory After Wiki Ingest" restore the
  # caller phase (cleanup_post_ingest) even when the intermediate patches
  # silently degrade — without them a downstream WARNING-and-continue would
  # leave the flow-state in an unrepairable state.
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
        # Strip trailing comment / whitespace before matching the closing `]`
        # so `[a]  # inline comment` is not misclassified as "unclosed inline list".
        local rhs_no_comment="${rhs%%#*}"
        rhs_no_comment="${rhs_no_comment%"${rhs_no_comment##*[![:space:]]}"}"
        if [[ "$rhs_no_comment" =~ ^\[(.*)\]$ ]]; then
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
#
# Synthetic rules:
#   - Empty prev_phase is accepted for any known phase (workflow cold start where
#     no prior state exists yet).
#   - Unknown prev_phase is accepted (forward-compat; future sub-skills that
#     introduce new phases outside this whitelist must not cause spurious blocks).
#   - Terminal phases ("completed" / "cleanup_completed" / "ingest_completed")
#     are accepted ONLY from their canonical predecessor set. Unconditional
#     `prev → terminal` would let a workflow skip (e.g. init → completed) pass
#     silently, defeating the whole point of the whitelist.
rite_phase_transition_allowed() {
  local prev="$1"
  local next="$2"
  [ -z "$prev" ] && return 0
  [ "$prev" = "$next" ] && return 0

  if [ "$next" = "completed" ] || [ "$next" = "cleanup_completed" ] || [ "$next" = "ingest_completed" ]; then
    case "$next:$prev" in
      completed:lint|completed:pr|completed:review|completed:fix|completed:ready|completed:ready_error) return 0 ;;
      cleanup_completed:cleanup_post_ingest|cleanup_completed:cleanup_pre_ingest) return 0 ;;
      ingest_completed:ingest_pre_lint|ingest_completed:ingest_post_lint) return 0 ;;
      # Legacy phase names (create_* / start_* / phase[0-9]*) accepted so that
      # /rite:resume can pick up state files written by older sub-skill chains
      # without tripping the guard. `phase[0-9]*` covers both `phase5` and
      # `phase5_step1` — separate underscored arm would be redundant.
      completed:create_*|completed:start_*|completed:phase[0-9]*) return 0 ;;
      *)
        # Surface the rejection so incident triagers can distinguish
        # "protocol violation" from "guard not running".
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
  # Surface the block so triagers can distinguish "guard rejected" from "guard
  # not running"; a silent return 1 here would let a caller swallow the
  # decision and the protocol violation would only manifest downstream as a
  # mismatched state file.
  if [ "${RITE_DEBUG:-0}" = "1" ]; then
    echo "[rite] ERROR phase-transition: '$prev' → '$next' not in allowed set [$allowed]" >&2
  else
    echo "[rite] ERROR phase-transition: '$prev' → '$next' blocked" >&2
  fi
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

# Return 0 if the given phase is an in-progress create_* lifecycle phase from
# the pre-flat-workflow sub-skill chain (i.e., create_interview / create_post_interview /
# create_delegation / create_post_delegation — NOT create_completed which is terminal).
#
# These phase names are legacy: the flat /rite:issue:create writes only
# `phase=completed` and does not produce intermediate create_* states. This
# predicate is retained so pre-tool-bash-guard.sh and session-end.sh can
# identify orphaned state files left by older sessions and surface them as
# stale-cleanup WARNINGs. Centralizing the legacy phase name list here
# prevents silent drift between the predicate callers.
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
