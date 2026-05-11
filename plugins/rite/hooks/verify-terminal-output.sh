#!/bin/bash
# rite workflow - Terminal Output Regression Guard (Issue #561)
#
# Verifies that Terminal Completion sections in /rite:issue:create sub-skills
# wrap sentinel markers in HTML comments so the user-visible final line is
# always the human-readable completion message, not a bare sentinel token.
#
# Enforced contract (per Issue #561 D-01 / #561 AC-2, AC-3, AC-6):
#   - plugins/rite/commands/issue/create-register.md   Phase 3.4 sentinel is
#     documented as `<!-- [create:completed:{...}] -->` (HTML comment form)
#   - plugins/rite/commands/issue/create-decompose.md  Phase 3.4 sentinel is
#     documented as `<!-- [create:completed:{...}] -->` (HTML comment form)
#   - plugins/rite/commands/issue/create-interview.md  AC-3 non-regression only
#     (ADR docs/designs/parent-routing-unification.md に従い
#     `[interview:completed|skipped|error]` の bare bracket form に移行済、
#     AC-2/AC-6 HTML-wrap 必須化は撤去。raw string `[interview:`
#     presence のみ AC-3 で検証する)
#
# Non-regression (AC-3): the raw string `[create:completed:` / `[interview:`
# must still appear in each file so hook/grep contracts remain matchable.
# create-interview.md の `[interview:` prefix は `[interview:completed]` /
# `[interview:skipped]` / `[interview:error]` の 3 値を取る (Pre-flight failure 経路は
# `[interview:error]` halt sentinel として load-bearing)。Check 3 の正規表現
# `\[interview:(completed|skipped|error)\]` には全 3 値が含まれる。
#
# Exit codes:
#   0  all checks passed
#   1  a check failed (details on stderr)
#   2  usage error (unknown argument)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color helpers (best-effort; disable when stdout is not a tty)
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'
  C_YEL=$'\033[0;33m'
  C_GRN=$'\033[0;32m'
  C_RST=$'\033[0m'
else
  C_RED=""
  C_YEL=""
  C_GRN=""
  C_RST=""
fi

usage() {
  cat <<'USAGE_EOF'
Usage: verify-terminal-output.sh [--quiet] [--repo-root <path>]

Options:
  --quiet                Suppress success output (failures still go to stderr)
  --repo-root <path>     Override repository root (default: auto-detect via
                         git rev-parse --show-toplevel, fallback to plugin
                         parent directory for marketplace installs)
  -h, --help             Show this help (exits 0)

Verifies that Terminal Completion sections in create-register.md /
create-decompose.md wrap sentinel markers in HTML comments (Issue #561
AC-2 / AC-3 / AC-6). create-interview.md は parent-routing pattern
(bare bracket form) に移行済のため AC-3 non-regression のみ検証。
詳細は ADR docs/designs/parent-routing-unification.md を参照。

Exit codes:
  0  all checks passed (or --help)
  1  a check failed (see stderr)
  2  usage error
USAGE_EOF
}

QUIET=0
REPO_ROOT_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --repo-root)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: --repo-root requires a path argument" >&2
        usage >&2
        exit 2
      fi
      REPO_ROOT_OVERRIDE="$1"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# REPO_ROOT resolution (marketplace install 対応、Issue #582 F-05):
# 1. --repo-root <path> が指定されたらそれを優先 (CI / override 用)
# 2. git rev-parse --show-toplevel で検出 (developer local checkout)
# 3. 上記失敗時、SCRIPT_DIR/.. (= plugin root) を使って plugin 内の相対パスで検証対象を参照
#    (marketplace install: ~/.claude/plugins/cache/rite-marketplace/rite/{ver}/hooks/ から見て
#     plugin root は {ver}/ なので、そこに commands/issue/*.md, skills/rite-workflow/* が存在)
# trap install (両経路共通):
# 旧実装は `--repo-root` 経路で trap install されず、`else` 経路でのみ install されていた。
# 将来 `--repo-root` 経路後段で tempfile を追加した時に SIGINT/TERM/HUP 中断で orphan leak する
# 構造的非対称があったため、両経路共通の lifecycle に統一する。`--repo-root` 経路では
# `_git_err=""` のまま cleanup は no-op で安全 (rm -f "" は idempotent)。
_git_err=""
_rite_verify_terminal_cleanup() {
  rm -f "${_git_err:-}"
}
trap 'rc=$?; _rite_verify_terminal_cleanup; exit $rc' EXIT
trap '_rite_verify_terminal_cleanup; exit 130' INT
trap '_rite_verify_terminal_cleanup; exit 143' TERM
trap '_rite_verify_terminal_cleanup; exit 129' HUP

if [ -n "$REPO_ROOT_OVERRIDE" ]; then
  if [ ! -d "$REPO_ROOT_OVERRIDE" ]; then
    echo "ERROR: --repo-root '$REPO_ROOT_OVERRIDE' is not a directory" >&2
    exit 2
  fi
  REPO_ROOT="$(cd "$REPO_ROOT_OVERRIDE" && pwd)"
  CHECK_PATHS_PREFIX="plugins/rite"
else
  # git rev-parse の error class を区別する:
  # stderr を一時ファイルに退避し、`not a git repository` / `dubious ownership` (= legitimate
  # marketplace fallback 経路) のみ silent fallback を許容し、それ以外 (permission denied / git
  # binary 不在 / その他予期しないエラー) は明示的に exit 1 で fail させる。
  if ! _git_err=$(mktemp /tmp/rite-verify-terminal-git-err-XXXXXX 2>/dev/null); then
    echo "WARNING: mktemp failed; cannot capture git stderr — fallback decision will be heuristic" >&2
    echo "  hint: /tmp の inode 枯渇 / read-only filesystem / permission 拒否を確認してください" >&2
    _git_err=""
  fi
  if _git_root=$(git rev-parse --show-toplevel 2>"${_git_err:-/dev/null}"); then
    REPO_ROOT="$_git_root"
    CHECK_PATHS_PREFIX="plugins/rite"
  elif _git_err_classify_rc=0; [ -n "$_git_err" ] && { grep -qE 'not a git repository|dubious ownership' "$_git_err"; _git_err_classify_rc=$?; [ "$_git_err_classify_rc" = "0" ]; }; then
    # legitimate marketplace fallback (not in a git repo, or safe.directory violation).
    # grep rc=0 のみ (match found) を fallback として採用。rc=2 (file I/O error / binary 異常) は
    # 直後の `_git_err_classify_rc` 検査で fail-fast に倒す。
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    CHECK_PATHS_PREFIX=""
  elif [ -n "$_git_err" ] && [ "${_git_err_classify_rc:-0}" -ge 2 ]; then
    # grep classification 自身が失敗 (permission denied / binary corruption / IO エラー)。
    # 「分類不能 → fail-fast」に倒し、silent fallback を排除する (M-2 対応)。
    echo "ERROR: failed to classify git stderr (grep rc=$_git_err_classify_rc) — refusing to silently choose between git-root and marketplace fallback" >&2
    echo "  hint: grep binary / $_git_err の権限を確認してください" >&2
    exit 1
  elif [ -z "$_git_err" ]; then
    # H-1 対応: mktemp 失敗 + git rev-parse 失敗の組合せ。
    # 旧実装は「stderr empty → legitimate fallback」と誤分類して check を続行していたが、
    # 実体は「stderr の中身を観測する手段を失ったため、エラー種別を区別できない」状態。
    # marketplace fallback と permission denied / binary 不在 / corrupt index を silent に
    # 融合させると observability を失い、load-bearing test の信頼性を傷つける。
    # 「分類不能 → fail-fast」に倒して silent fallback を排除する。
    echo "ERROR: cannot classify git error (mktemp failed earlier) — refusing to silently choose between git-root and marketplace fallback" >&2
    echo "  hint: /tmp の inode 枯渇 / read-only filesystem / permission 拒否を解消してから再実行してください" >&2
    exit 1
  elif [ ! -s "$_git_err" ]; then
    # stderr tempfile は作成できたが git stderr が空 (= git binary が silent に exit non-zero)。
    # これも分類不能だが、mktemp 失敗とは区別して別エラーで fail-fast する。
    echo "ERROR: git rev-parse --show-toplevel failed with empty stderr — unable to classify" >&2
    echo "  hint: git binary version の互換性、または PATH 設定を確認してください" >&2
    exit 1
  else
    echo "ERROR: git rev-parse --show-toplevel failed unexpectedly:" >&2
    head -3 "$_git_err" | sed 's/^/  /' >&2
    echo "  hint: PATH に git binary があるか / .git directory の permission を確認してください" >&2
    exit 1
  fi
fi

FAILED=0

fail() {
  echo "${C_RED}FAIL${C_RST}: $1" >&2
  FAILED=$((FAILED + 1))
}

pass() {
  [ "$QUIET" = "1" ] && return 0
  echo "${C_GRN}PASS${C_RST}: $1"
}

info() {
  [ "$QUIET" = "1" ] && return 0
  echo "${C_YEL}INFO${C_RST}: $1"
}

# -----------------------------------------------------------------------------
# Check 1: create-register.md Phase 3.4 HTML-comment sentinel
# -----------------------------------------------------------------------------
CREATE_REGISTER="${REPO_ROOT}${CHECK_PATHS_PREFIX:+/${CHECK_PATHS_PREFIX}}/commands/issue/create-register.md"

if [ ! -f "$CREATE_REGISTER" ]; then
  fail "create-register.md not found at $CREATE_REGISTER"
else
  # AC-3 non-regression: the raw sentinel string must still be present somewhere
  # in the file so downstream hook/grep contracts continue to match
  # (I-9: stop-guard.sh は #675 で撤去済、現役の grep contract は
  # workflow-incident-emit.sh の sentinel grep / pre-tool-bash-guard.sh / phase-transition-whitelist.sh 等)。
  if grep -qE '\[create:completed:' "$CREATE_REGISTER"; then
    pass "create-register.md: contains [create:completed:...] string (AC-3 non-regression)"
  else
    fail "create-register.md: missing [create:completed:...] string (AC-3 regression — hook contract broken)"
  fi

  # AC-2 / AC-6: the HTML-comment wrapped form must be present. This is the
  # mechanical enforcement introduced by Issue #561 — without this form, the
  # bare sentinel regresses to being the user-visible final line.
  if grep -qE '<!--[[:space:]]*\[create:completed:' "$CREATE_REGISTER"; then
    pass "create-register.md: sentinel wrapped in HTML comment form (AC-2 / AC-6)"
  else
    fail "create-register.md: sentinel NOT wrapped in HTML comment form; expected <!-- [create:completed:{N}] -->"
  fi

  # Drift guard: check that the prose no longer instructs "absolute last line"
  # with a bare sentinel. The phrase is now expected only when bound to the
  # HTML-comment form. Emits WARNING on stderr regardless of --quiet so CI does
  # not lose visibility. Not a fail because historical-note prose may legitimately
  # match.
  if grep -nE '\[create:completed:\{[^}]+\}\][[:space:]]*MUST be the (absolute )?last line' "$CREATE_REGISTER" >/dev/null 2>&1; then
    # CI grep-friendly sentinel prefix `[VERIFY:WARNING]` を併記して、--strict 等の
    # downstream catch メカニズムが将来追加された際に機械検出可能にする。
    echo "[VERIFY:WARNING] ${C_YEL}WARNING${C_RST}: create-register.md: legacy prose about bare-sentinel 'absolute last line' may still be present; review manually" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Check 2: create-decompose.md Phase 3.4 HTML-comment sentinel
# -----------------------------------------------------------------------------
CREATE_DECOMPOSE="${REPO_ROOT}${CHECK_PATHS_PREFIX:+/${CHECK_PATHS_PREFIX}}/commands/issue/create-decompose.md"

if [ ! -f "$CREATE_DECOMPOSE" ]; then
  fail "create-decompose.md not found at $CREATE_DECOMPOSE"
else
  if grep -qE '\[create:completed:' "$CREATE_DECOMPOSE"; then
    pass "create-decompose.md: contains [create:completed:...] string (AC-3 non-regression)"
  else
    fail "create-decompose.md: missing [create:completed:...] string (AC-3 regression)"
  fi

  if grep -qE '<!--[[:space:]]*\[create:completed:' "$CREATE_DECOMPOSE"; then
    pass "create-decompose.md: sentinel wrapped in HTML comment form (AC-2 / AC-6)"
  else
    fail "create-decompose.md: sentinel NOT wrapped in HTML comment form"
  fi
fi

# -----------------------------------------------------------------------------
# Check 3: create-interview.md [interview:*] AC-3 non-regression
# (bare bracket form; rationale: ADR docs/designs/parent-routing-unification.md)
# -----------------------------------------------------------------------------
CREATE_INTERVIEW="${REPO_ROOT}${CHECK_PATHS_PREFIX:+/${CHECK_PATHS_PREFIX}}/commands/issue/create-interview.md"

if [ ! -f "$CREATE_INTERVIEW" ]; then
  fail "create-interview.md not found at $CREATE_INTERVIEW"
else
  # IMP-4 対応: AC-3 non-regression を bullet sentinel と halt sentinel に分割。
  # 旧実装 `grep -qE '\[interview:(completed|skipped|error)\]'` は OR 判定で 1 match で pass
  # するため、halt-rule prose で `[interview:error]` が 6 回出現する状況では bullet
  # `[interview:completed]` / `[interview:skipped]` を両方 silent 削除しても通過する false-positive
  # risk を持っていた。本修正で `completed` / `skipped` 2 sentinel を独立 grep として必須化し、
  # bullet section の silent 削除を防御する。`[interview:error]` は OR 経路 (どれか 1 つの sentinel
  # 存在を要求する legacy regex) のまま残し、historical fixture 互換性を維持する
  # (parent-routing pattern 移行前の minimal fixture では `error` sentinel を含まないため)。
  for _sentinel in 'completed' 'skipped'; do
    if grep -qE "\[interview:${_sentinel}\]" "$CREATE_INTERVIEW"; then
      pass "create-interview.md: contains [interview:${_sentinel}] string (AC-3 non-regression, independent grep)"
    else
      fail "create-interview.md: missing [interview:${_sentinel}] string (AC-3 regression — bullet section was silently deleted)"
    fi
  done
  # legacy OR-form: いずれか 1 つの sentinel 存在を pin (3 alternation の elements は historical fixture も含まれる)
  if grep -qE '\[interview:(completed|skipped|error)\]' "$CREATE_INTERVIEW"; then
    pass "create-interview.md: contains at least one [interview:*] sentinel (AC-3 legacy OR-form, fixture compatibility)"
  else
    fail "create-interview.md: missing all [interview:*] sentinels (AC-3 regression)"
  fi

  # Negative assertion — parent-routing pattern compliance check
  # HTML-comment 形式 (`<!-- [interview:*] -->`) の partial revert を検出する interim coverage
  # (uniformity test 統合計画は ADR `docs/designs/parent-routing-unification.md` 参照)。
  #
  # regex scope: rationale prose 内 inline backtick literal (例: `<!-- [interview:*] -->` historical note) や
  # migration note 内で sentinel を quote する自然な編集パターンで誤発火する経路を遮断するため、
  # 行頭 anchor + 行末 anchor で **独立行として現れる HTML-comment sentinel** のみを検出する。
  if grep -qE '^[[:space:]]*<!--[[:space:]]*\[interview:(completed|skipped)\][[:space:]]*-->[[:space:]]*$' "$CREATE_INTERVIEW"; then
    fail "create-interview.md: HTML-commented [interview:*] sentinel detected as standalone line — parent-routing pattern (bare bracket form) violation. ADR docs/designs/parent-routing-unification.md に従い bare bracket form を維持してください"
  else
    pass "create-interview.md: no standalone HTML-commented sentinel line (parent-routing pattern compliant)"
  fi
fi

# -----------------------------------------------------------------------------
# Check 4: SKILL.md / workflow-identity.md identity entries
# -----------------------------------------------------------------------------
SKILL_MD="${REPO_ROOT}${CHECK_PATHS_PREFIX:+/${CHECK_PATHS_PREFIX}}/skills/rite-workflow/SKILL.md"
IDENTITY_MD="${REPO_ROOT}${CHECK_PATHS_PREFIX:+/${CHECK_PATHS_PREFIX}}/skills/rite-workflow/references/workflow-identity.md"

if [ ! -f "$SKILL_MD" ]; then
  fail "SKILL.md not found at $SKILL_MD"
else
  if grep -qE '止まらない|turn を閉じない|meaningful_terminal_output' "$SKILL_MD"; then
    pass "SKILL.md: identity entry for 'workflow stops' / 'meaningful terminal output' present (AC-7)"
  else
    fail "SKILL.md: identity entry missing (AC-7)"
  fi
fi

if [ ! -f "$IDENTITY_MD" ]; then
  fail "workflow-identity.md not found at $IDENTITY_MD"
else
  if grep -qE 'no_mid_workflow_stop' "$IDENTITY_MD" && grep -qE 'meaningful_terminal_output' "$IDENTITY_MD"; then
    pass "workflow-identity.md: both principles (no_mid_workflow_stop / meaningful_terminal_output) registered"
  else
    fail "workflow-identity.md: required principles missing"
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
  echo "" >&2
  echo "${C_RED}verify-terminal-output.sh: $FAILED check(s) failed${C_RST}" >&2
  echo "See Issue #561 for rationale and required output structure." >&2
  exit 1
fi

[ "$QUIET" = "1" ] || echo "${C_GRN}verify-terminal-output.sh: all checks passed${C_RST}"
exit 0
