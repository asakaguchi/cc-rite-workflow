#!/bin/bash
# rite workflow - Post-Review State Verification
#
# Reviewer subagent が READ-ONLY 契約を破って parent repo の working tree / branch /
# stash list を変更した場合に検出し、可能な範囲で recovery する defense-in-depth layer。
#
# 一次防御: `plugins/rite/hooks/pre-tool-bash-guard.sh` Pattern 4 (subagent context で
# state-mutating git command を block する PreToolUse hook)。
# 本スクリプトは hook が edge case (subagent detection が transcript_path で失敗する場合等)
# で機能しなかった事故の検出と recovery を担う post-condition gate。
#
# Issue #995: PR #994 cycle 3 で reviewer subagent が `pr-994-test` ブランチを作成して
# `git checkout` した結果、parent session の working tree が develop に切り替わって
# `/rite:pr:fix` が PR ブランチを見失う事故が発生。これを再発させない gate。
#
# Usage:
#   bash post-review-state-verify.sh \
#       --original-branch <name> \
#       [--original-stash-count <N>] \
#       [--original-branch-list-hash <hash>] \
#       [--auto-recover true|false]
#
# Arguments:
#   --original-branch <name>           Review 開始時の current branch 名 (required)
#   --original-stash-count <N>         Review 開始時の `git stash list` 行数 (optional)
#   --original-branch-list-hash <hash> Review 開始時の `git branch --list | sort | md5sum` (optional)
#   --auto-recover                     drift 検出時に automatic recovery を行う (default: true)
#
# Exit codes:
#   0 — no drift, or drift detected and successfully recovered
#   1 — drift detected and recovery failed (manual intervention required)
#   2 — invalid arguments
#
# Output:
#   stderr: WARNING/ERROR messages
#   stdout: machine-readable JSON summary
#     {"drift": false}
#     {"drift": true, "type": "branch", "from": "...", "to": "...", "recovered": true}

set -uo pipefail  # 意図的に -e なし: drift detection 自体を fail とせず、結果を JSON で返す

ORIGINAL_BRANCH=""
ORIGINAL_STASH_COUNT=""
ORIGINAL_BRANCH_LIST_HASH=""
AUTO_RECOVER="true"

while [ $# -gt 0 ]; do
  case "$1" in
    --original-branch)
      ORIGINAL_BRANCH="${2:-}"
      shift 2
      ;;
    --original-stash-count)
      ORIGINAL_STASH_COUNT="${2:-}"
      shift 2
      ;;
    --original-branch-list-hash)
      ORIGINAL_BRANCH_LIST_HASH="${2:-}"
      shift 2
      ;;
    --auto-recover)
      AUTO_RECOVER="${2:-true}"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$ORIGINAL_BRANCH" ]; then
  echo "ERROR: --original-branch is required" >&2
  exit 2
fi

# --- 現在の state を取得 ---
current_branch=$(git branch --show-current 2>/dev/null || echo "")
current_stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
current_branch_list_hash=$(git branch --list 2>/dev/null | sort | md5sum 2>/dev/null | awk '{print $1}')

# --- Drift detection ---
drift_detected="false"
drift_type=""
drift_detail=""

if [ "$current_branch" != "$ORIGINAL_BRANCH" ]; then
  drift_detected="true"
  drift_type="branch"
  drift_detail="from=$ORIGINAL_BRANCH; to=$current_branch"
fi

if [ "$drift_detected" = "false" ] && [ -n "$ORIGINAL_STASH_COUNT" ] && [ "$current_stash_count" != "$ORIGINAL_STASH_COUNT" ]; then
  drift_detected="true"
  drift_type="stash"
  drift_detail="from_count=$ORIGINAL_STASH_COUNT; to_count=$current_stash_count"
fi

if [ "$drift_detected" = "false" ] && [ -n "$ORIGINAL_BRANCH_LIST_HASH" ] && [ "$current_branch_list_hash" != "$ORIGINAL_BRANCH_LIST_HASH" ]; then
  drift_detected="true"
  drift_type="branch_list"
  drift_detail="reviewer leaked named branch(es); compare 'git branch --list' before/after"
fi

if [ "$drift_detected" = "false" ]; then
  printf '{"drift":false}\n'
  exit 0
fi

# --- Drift 検出 — WARNING + recovery attempt ---
echo "WARNING: Reviewer subagent caused parent session state drift" >&2
echo "  type: $drift_type" >&2
echo "  detail: $drift_detail" >&2
echo "  context: pre-tool-bash-guard hook (Pattern 4) did not block this mutation — investigate transcript_path detection or hook registration" >&2

recovered="false"
recovery_error=""

if [ "$AUTO_RECOVER" = "true" ] && [ "$drift_type" = "branch" ]; then
  echo "  recovery: attempting 'git checkout $ORIGINAL_BRANCH'..." >&2
  if checkout_output=$(git checkout "$ORIGINAL_BRANCH" 2>&1); then
    recovered="true"
    echo "  recovery: succeeded" >&2
  else
    recovery_error="git checkout failed: $checkout_output"
    echo "  recovery: FAILED — $recovery_error" >&2
    echo "  manual action: run 'git checkout $ORIGINAL_BRANCH' to restore the working tree" >&2
  fi
fi

# stash drift / branch_list drift は自動 recovery しない (stash の中身を失うリスク)
if [ "$drift_type" = "stash" ]; then
  echo "  recovery: SKIPPED (stash recovery not auto-applied — stash entries may contain reviewer work)" >&2
  echo "  manual action: inspect 'git stash list' and decide whether to drop or apply each entry" >&2
fi

if [ "$drift_type" = "branch_list" ]; then
  echo "  recovery: SKIPPED (named branch leak — orchestrator side pr-cycle-cleanup.sh will sweep)" >&2
  echo "  manual action: review 'git branch --list' for unexpected names matching reviewer experiment patterns" >&2
fi

# --- Workflow incident emit (best-effort, non-blocking) ---
# state-changing emit は scope を absorb する設計のため failure は warning のみ
incident_script=""
for candidate in \
  "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/workflow-incident-emit.sh" \
  "$(dirname "${BASH_SOURCE[0]}")/workflow-incident-emit.sh"; do
  if [ -f "$candidate" ]; then
    incident_script="$candidate"
    break
  fi
done

if [ -n "$incident_script" ]; then
  bash "$incident_script" \
    --type manual_fallback_adopted \
    --details "Reviewer subagent caused $drift_type drift ($drift_detail); recovered=$recovered" \
    --root-cause-hint "pre-tool-bash-guard Pattern 4 did not block — check transcript_path subagent detection or hook registration" \
    2>/dev/null || echo "WARNING: workflow-incident-emit.sh failed (non-blocking)" >&2
fi

# --- JSON summary ---
printf '{"drift":true,"type":"%s","detail":"%s","recovered":%s}\n' \
  "$drift_type" "$drift_detail" "$recovered"

# Exit code: recovered=true → 0、recovered=false → 1 (manual intervention required)
if [ "$recovered" = "true" ] || [ "$drift_type" = "stash" ] || [ "$drift_type" = "branch_list" ]; then
  # stash/branch_list は自動 recover しないが advisory として exit 0 (review flow を block しない)
  exit 0
fi
exit 1
