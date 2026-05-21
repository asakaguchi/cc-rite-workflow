#!/bin/bash
# rite workflow - Status Mismatch Watchdog (Issue #1003 AC-9)
#
# Scans repository Issues that are linked to OPEN, Ready-for-review PRs (isDraft=false)
# and detects ones whose GitHub Projects Status is still "In Progress" — the symptom
# of the Issue #1003 silent-skip bug. Outputs JSON to stdout and a warning summary to
# stderr. Optionally attempts reconciliation when --reconcile is passed.
#
# Usage:
#   bash watchdog-status-mismatch.sh [options]
#
# Options:
#   --dry-run         Report only; do not reconcile (default)
#   --reconcile      Attempt to update mismatched Issue Status → "In Review" via
#                    projects-status-update.sh. Failures are logged but never block.
#   --limit N        Maximum PRs to scan (default: 50)
#   --quiet          Suppress stderr warnings (JSON output still produced)
#   -h, --help       Show usage
#
# Output (stdout):
#   {
#     "scan_summary": {
#       "prs_scanned": N,
#       "mismatches_found": M,
#       "reconciled": K,
#       "reconcile_failures": F
#     },
#     "mismatches": [
#       { "pr_number": 1001, "issue_number": 998, "current_status": "In Progress", "reconcile_result": "updated|failed|skipped|not_attempted" }
#     ],
#     "warnings": []
#   }
#
# Exit codes:
#   0  success, no mismatches
#   1  fatal error (missing config / gh failure)
#   2  mismatches detected (intended for CI gating)
set -euo pipefail

# --- Arg parse ---
DRY_RUN=true
RECONCILE=false
LIMIT=50
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; RECONCILE=false; shift ;;
    --reconcile) DRY_RUN=false; RECONCILE=true; shift ;;
    --limit)     LIMIT="$2"; shift 2 ;;
    --quiet)     QUIET=true; shift ;;
    -h|--help)
      # here-doc usage で BSD head 互換性問題 (head -n -1) を回避
      cat <<'USAGE_EOF'
watchdog-status-mismatch.sh - Status Mismatch Watchdog (Issue #1003 AC-9)

Scans repository Issues that are linked to OPEN, Ready-for-review PRs (isDraft=false)
and detects ones whose GitHub Projects Status is still "In Progress" — the symptom
of the Issue #1003 silent-skip bug. Outputs JSON to stdout and a warning summary to
stderr. Optionally attempts reconciliation when --reconcile is passed.

Usage:
  bash watchdog-status-mismatch.sh [options]

Options:
  --dry-run         Report only; do not reconcile (default)
  --reconcile      Attempt to update mismatched Issue Status → "In Review" via
                   projects-status-update.sh. Failures are logged but never block.
  --limit N        Maximum PRs to scan (default: 50)
  --quiet          Suppress stderr warnings (JSON output still produced)
  -h, --help       Show usage
USAGE_EOF
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1 ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --limit must be a positive integer (got: $LIMIT)" >&2
  exit 1
fi

# --- Locate rite-config.yml ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

# Find repo root (look upward for rite-config.yml or .git)
CWD="$(pwd)"
REPO_ROOT="$CWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/rite-config.yml" ] && [ ! -d "$REPO_ROOT/.git" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

if [ ! -f "$REPO_ROOT/rite-config.yml" ]; then
  echo "ERROR: rite-config.yml not found from $CWD upward" >&2
  exit 1
fi

PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""

if [ "$PROJECTS_ENABLED" != "true" ] || [ -z "$PROJECT_NUMBER" ]; then
  jq -n --arg reason "projects_disabled_or_unconfigured" \
    '{scan_summary: {prs_scanned: 0, mismatches_found: 0, reconciled: 0, reconcile_failures: 0}, mismatches: [], warnings: [$reason]}'
  exit 0
fi

# --- Trap setup: tempfile orphan 防止 (EXIT/INT/TERM/HUP) ---
# canonical pattern: hooks/post-compact.sh と対称化 (PR #1079 で start.md Step 1.5 / start-finalize.md Step 0 は削除/統合済 — 旧 4 site を 2 site に縮退)。
# path 先行宣言 → trap 先行設定 → mktemp の順序で race window を排除する。
# loop 内 gql_err は毎 iteration mktemp + 末尾 rm の現行構造を維持しつつ、signal 経路では
# 本 trap が一括 cleanup する (defense-in-depth)。
# cycle 8 C7-F13 対応: gh repo view と gh pr list で別 tempfile (repo_view_err / pr_list_err) を
# 用意し、前者の non-fatal warning を後者の redirect で truncate して消失させない。
repo_view_err=""
pr_list_err=""
gql_err=""
jq_err=""
reconcile_err=""
_rite_watchdog_cleanup() {
  rm -f "${repo_view_err:-}" "${pr_list_err:-}" "${gql_err:-}" "${jq_err:-}" "${reconcile_err:-}"
}
trap 'rc=$?; _rite_watchdog_cleanup; exit $rc' EXIT
trap '_rite_watchdog_cleanup; exit 130' INT
trap '_rite_watchdog_cleanup; exit 143' TERM
trap '_rite_watchdog_cleanup; exit 129' HUP

# --- Repo info ---
# cycle 8 C7-F01/C7-F13 対応: gh repo view stderr を専用 tempfile (repo_view_err) に capture し、
# 2-site (post-compact / watchdog) で対称化 (PR #1079 で start.md / start-finalize.md 経路は削除/統合済)する。
repo_view_err=$(mktemp /tmp/rite-watchdog-repo-err-XXXXXX) || repo_view_err=""
if ! REPO_INFO=$(gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then
  echo "ERROR: gh repo view failed" >&2
  if [ -n "$repo_view_err" ] && [ -s "$repo_view_err" ]; then
    head -5 "$repo_view_err" | sed 's/^/  /' >&2
  fi
  echo "  対処: gh auth status / network 接続を確認してください" >&2
  exit 1
fi
# cycle 8 C7-F02 対応: jq の `// empty` fallback + 明示 fail で `set -euo pipefail` 下の silent abort を防ぐ。
# 旧実装は `jq -r '.owner.login'` で auth-scope 縮退時に `null` 文字列代入されるか jq exit 5 で
# 診断情報破棄。新実装は空文字列で fail-fast し、stderr に root cause を出力する。
REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>/dev/null) || REPO_OWNER=""
REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>/dev/null) || REPO_NAME=""
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  echo "ERROR: failed to parse owner/name from gh repo view (owner='$REPO_OWNER' name='$REPO_NAME')" >&2
  echo "  対処: gh auth refresh で scope を更新するか、PAT の repo permission を確認してください" >&2
  exit 1
fi

# --- Scan OPEN, non-draft PRs ---
pr_list_err=$(mktemp /tmp/rite-watchdog-pr-list-err-XXXXXX) || pr_list_err=""
if ! PR_LIST=$(gh pr list --state open --limit "$LIMIT" --json number,isDraft,body,headRefName 2>"${pr_list_err:-/dev/null}"); then
  echo "ERROR: gh pr list failed" >&2
  if [ -n "$pr_list_err" ] && [ -s "$pr_list_err" ]; then
    head -5 "$pr_list_err" | sed 's/^/  /' >&2
  fi
  echo "  対処: gh auth status / network 接続 / repository 権限を確認してください" >&2
  exit 1
fi

PRS_SCANNED=0
MISMATCHES=()
RECONCILED=0
RECONCILE_FAILURES=0

# cycle 10 F-10 対応: process substitution の exit code は親に伝播しないため、
# jq 失敗時 (PR_LIST malformed) に loop body が 0 回実行され silent success (`exit 0`) する経路を防ぐ。
# pre-check として jq 'length' で PR_LIST の有効性を検証する。
pr_count_check=$(printf '%s' "$PR_LIST" | jq 'length' 2>/dev/null) || pr_count_check=""
if [ -z "$pr_count_check" ]; then
  echo "ERROR: PR_LIST が valid JSON ではないか jq バイナリ異常です (silent loop skip 防止)" >&2
  echo "  対処: gh pr list の出力と jq バージョンを確認してください" >&2
  exit 1
fi

while IFS= read -r pr_entry; do
  # cycle 10 F-09 対応: jq 失敗時の error handling を追加 (set -euo pipefail 下で script 全体が
  # abort し PR scan が完全停止する fragility を排除)。失敗 entry は continue で skip し warnings に記録。
  pr_number=$(printf '%s' "$pr_entry" | jq -r '.number' 2>/dev/null) || pr_number=""
  is_draft=$(printf '%s' "$pr_entry" | jq -r '.isDraft' 2>/dev/null) || is_draft=""
  pr_body=$(printf '%s' "$pr_entry" | jq -r '.body // empty' 2>/dev/null) || pr_body=""
  head_ref=$(printf '%s' "$pr_entry" | jq -r '.headRefName // empty' 2>/dev/null) || head_ref=""
  if [ -z "$pr_number" ] || [ -z "$is_draft" ]; then
    if [ "$QUIET" != "true" ]; then
      echo "[watchdog] ⚠️ jq parse failed for PR entry, skipping (pr_entry preview: $(printf '%s' "$pr_entry" | head -c 80))" >&2
    fi
    continue
  fi
  PRS_SCANNED=$((PRS_SCANNED + 1))

  if [ "$is_draft" != "false" ]; then
    continue  # Draft PR — not yet Ready, skip
  fi

  # Extract linked Issue number from PR body (Closes #N / Fixes #N / Resolves #N) or branch name (issue-N)
  issue_number=$(printf '%s' "$pr_body" | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)
  if [ -z "$issue_number" ] && [[ "$head_ref" =~ issue-([0-9]+) ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    continue  # No linked Issue
  fi

  # Query Issue's current Status in the Project (gh failure を stderr capture して silent skip 防止)
  # cycle 6 C6-F02 対応: jq の stderr も独立 capture し、4-site symmetry contract を完遂する。
  # post-compact.sh と対称に (PR #1079 で start.md Step 1.5 / start-finalize.md Step 0 は削除/統合済) gh / jq の stderr を区別。
  gql_err=$(mktemp /tmp/rite-watchdog-gql-err-XXXXXX) || gql_err=""
  jq_err=$(mktemp /tmp/rite-watchdog-jq-err-XXXXXX) || jq_err=""
  # cycle 8 C7-F15 対応: inner `set -o pipefail` は line 38 の outer 設定で既に有効だが、defense-in-depth
  # として明示し、将来 sub-shell 単独テスト時の挙動 (sub-shell が options を継承) を保証する。
  if ! current_status=$(set -o pipefail; gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project { number }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$issue_number" 2>"${gql_err:-/dev/null}" \
      | jq -r --argjson pn "$PROJECT_NUMBER" \
        '[.data.repository.issue.projectItems.nodes[]? | select(.project.number == $pn) | .fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // empty' 2>"${jq_err:-/dev/null}"); then
    # gh / jq pipeline 失敗 — silent skip せず warnings に記録 (debug 可能性向上)
    # 4-site stderr root cause attribution: gh_stderr と jq_stderr を独立表示
    if [ "$QUIET" != "true" ]; then
      gql_err_oneline=$(head -c 200 "${gql_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
      jq_err_oneline=$(head -c 200 "${jq_err:-/dev/null}" 2>/dev/null | tr '\n' ' ')
      echo "[watchdog] ⚠️ gh api graphql or jq failed for Issue #$issue_number (gh_stderr=$gql_err_oneline, jq_stderr=$jq_err_oneline)" >&2
    fi
    current_status=""
  fi
  [ -n "$gql_err" ] && rm -f "$gql_err"
  [ -n "$jq_err" ] && rm -f "$jq_err"
  # cycle 8 C7-F12 対応: loop iteration 末尾で変数を reset し、trap で stale path への再 rm を回避する。
  # reconcile_err (line 244) と対称化。idempotent な rm でも symmetry 維持で意図的に reset する。
  gql_err=""
  jq_err=""

  if [ "$current_status" = "In Progress" ]; then
    reconcile_result="not_attempted"
    reconcile_stderr_oneline=""
    if [ "$RECONCILE" = "true" ]; then
      # stderr を tempfile に退避して失敗時の原因 (auth / rate limit / partial failure) を可視化する。
      # 他 1-site (post-compact.sh) と対称化された (PR #1079 で start.md / start-finalize.md 経路は削除/統合済) stderr capture 契約。
      # silent suppress (2>/dev/null) では RECONCILE_FAILURES non-zero 時に user は失敗原因を knowing できない。
      reconcile_err=$(mktemp /tmp/rite-watchdog-reconcile-err-XXXXXX) || reconcile_err=""
      reconcile_json=$(bash "$PLUGIN_ROOT/scripts/projects-status-update.sh" "$(jq -n \
        --argjson issue "$issue_number" --arg owner "$REPO_OWNER" --arg repo "$REPO_NAME" \
        --argjson project_number "$PROJECT_NUMBER" --arg status "In Review" \
        --argjson auto_add false --argjson non_blocking true \
        '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>"${reconcile_err:-/dev/null}") || reconcile_json=""
      reconcile_result=$(printf '%s' "$reconcile_json" | jq -r '.result // "failed"' 2>/dev/null) || reconcile_result="failed"
      if [ "$reconcile_result" = "updated" ]; then
        RECONCILED=$((RECONCILED + 1))
      else
        RECONCILE_FAILURES=$((RECONCILE_FAILURES + 1))
        if [ -n "$reconcile_err" ] && [ -s "$reconcile_err" ]; then
          reconcile_stderr_oneline=$(head -c 200 "$reconcile_err" | tr '\n' ' ')
          if [ "$QUIET" != "true" ]; then
            echo "[watchdog] ⚠️ reconcile failed for Issue #$issue_number: $reconcile_stderr_oneline" >&2
          fi
        fi
      fi
      [ -n "$reconcile_err" ] && rm -f "$reconcile_err"
      reconcile_err=""
    fi
    MISMATCHES+=("$(jq -n --argjson pr "$pr_number" --argjson issue "$issue_number" \
      --arg status "$current_status" --arg recon "$reconcile_result" \
      --arg recon_stderr "$reconcile_stderr_oneline" \
      '{pr_number:$pr, issue_number:$issue, current_status:$status, reconcile_result:$recon, reconcile_stderr:$recon_stderr}')")
    if [ "$QUIET" != "true" ]; then
      echo "[watchdog] ⚠️ mismatch: PR=#$pr_number isDraft=false → Issue #$issue_number Status=\"$current_status\" (expected In Review)" >&2
    fi
  fi
done < <(printf '%s' "$PR_LIST" | jq -c '.[]')

MISMATCH_COUNT=${#MISMATCHES[@]}

# Build output JSON
if [ "$MISMATCH_COUNT" -eq 0 ]; then
  mismatches_json='[]'
else
  mismatches_json=$(printf '%s\n' "${MISMATCHES[@]}" | jq -s '.')
fi

jq -n \
  --argjson scanned "$PRS_SCANNED" \
  --argjson found "$MISMATCH_COUNT" \
  --argjson reconciled "$RECONCILED" \
  --argjson failures "$RECONCILE_FAILURES" \
  --argjson mismatches "$mismatches_json" \
  '{scan_summary: {prs_scanned: $scanned, mismatches_found: $found, reconciled: $reconciled, reconcile_failures: $failures}, mismatches: $mismatches, warnings: []}'

if [ "$MISMATCH_COUNT" -gt 0 ]; then
  exit 2
fi
exit 0
