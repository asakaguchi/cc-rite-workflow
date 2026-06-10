#!/bin/bash
# rite workflow - Pre-Tool Bash Guard (PreToolUse hook)
# Blocks known-bad Bash command patterns before execution.
# Uses only Bash built-ins for pattern matching (no external processes).
#
# Denylist patterns:
#   1. gh pr diff --stat  (unsupported flag)
#   2. gh pr diff -- <path>  (unsupported file filter)
#   3. != null in jq/awk  (history expansion breaks !)
#   4. Reviewer subagent running state-mutating git commands
#      Enforced only when transcript_path contains "/subagents/".
#
# Exit behavior:
#   exit 0 — allow (no output)
#   stdout JSON with permissionDecision: "deny" — block
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRETOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# neutralize_ctrl --c0-only (deny フォールバックの JSON エスケープ用 — Issue #1278)。
# guard なし source は意図的な設計判断: 本 hook は Pattern 1-3 の ERR trap
# (_rite_btg_pattern13_fail_open) が exit 0 = allow を選ぶ設計上 fail-open であり、helper
# 欠落 (= plugin 破損) による source 失敗の exit 1 も PreToolUse では non-blocking = allow
# として同じ fail-open に収束する (flow-state.sh / stop-loop-continuation.sh の必須依存
# precedent と同一)。`|| true` を付けてはならない — neutralize_ctrl 未定義のまま deny
# フォールバックに到達すると command not found で reason を失い placeholder へ縮退する
# だけで、guard を付ける利点がない。
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Deny フォールバック JSON 用の reason エスケープ (Issue #1278)。適用順序が契約:
# backslash → double-quote → 改行 \n 化 → neutralize_ctrl --c0-only (残存 C0+DEL を ? 化)。
# backslash エスケープが先頭でないと、後続が生成する \" / \n の backslash を二重に
# エスケープしてしまう。--c0-only なのは byte 単位の C1 置換が UTF-8 マルチバイト本文を
# 破壊するため (RFC 8259 が生バイトを禁じるのは U+0000-001F のみ)。neutralize_ctrl 失敗時は
# 非ゼロ exit し、caller が static placeholder へ縮退する (fail-closed)。
# tests/pre-tool-bash-guard.test.sh の TC-117 が本関数定義を境界行
# (`_bash_guard_escape_deny_reason() {` / `}`) で抽出して改行 / raw C0 実入力の変換を
# 直接 pin する — シグネチャ・境界行を変える際はテスト側の抽出パターンも更新すること。
_bash_guard_escape_deny_reason() {
  local _r="$1"
  _r="${_r//\\/\\\\}"
  _r="${_r//\"/\\\"}"
  _r="${_r//$'\n'/\\n}"
  printf '%s' "$_r" | neutralize_ctrl --c0-only
}
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Only inspect Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Reviewer subagent detection.
# Claude Code routes subagent sessions to jsonl files under a "subagents/"
# directory inside the project transcript root; the main session does not.
# When the PreToolUse hook runs inside a subagent, transcript_path therefore
# contains the "/subagents/" path component. Pattern 4 below uses this as a
# heuristic to scope state-mutating git denylist checks to reviewer contexts.
#
# Three-tier detection (future-proofing against SDK convention drift):
#   Tier 1 (primary):  transcript_path glob `*/subagents/*` — current Claude Code
#                      convention. Most reliable signal today.
#   Tier 2 (fallback): hook input JSON `subagent_type` / `agent_type` field —
#                      reserved for future SDK schemas that surface subagent
#                      identity in the hook envelope rather than the path.
#                      Presence-only check on STRING values; numeric/array/object
#                      values are rejected via `| strings` filter to avoid jq's
#                      `//` operator treating only null/false as falsy.
#   Tier 3 (fallback): environment variables CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE —
#                      catch-all if a future SDK exposes subagent context via
#                      env vars before updating the hook input schema. Presence-only.
#
# Forward-compatibility caveat: presence-only check fires on any non-empty string.
# If a future SDK starts emitting `subagent_type: "main"` / `"none"` / `"null"`
# sentinel values on main-session hooks, every main-session git command in this
# block would be blocked (false positive). When such a convention appears,
# upgrade to an allow-list check (e.g. `*-reviewer` glob) here. Tier 3 env vars
# share the same risk — see BLOCKED_ALTERNATIVE recovery text for `unset` guidance.
#
# All three field extractions share a single jq invocation; the original
# three-jq layout would triple subprocess fork overhead on the PreToolUse hot path.
# jq 失敗時の空 fallback は subagent 判定経路を silent に外す危険があるため、stderr を
# tempfile capture し、RITE_DEBUG 設定時は失敗詳細を debug log へ追記する。security 防御層
# (subagent 限定の Tier 3 ガード等) が silent bypass される経路を観測できるようにする。
_jq_input_err=$(mktemp 2>/dev/null) || _jq_input_err=""
JQ_OUT=$(echo "$INPUT" | jq -r '[(.transcript_path // ""), (.subagent_type | strings // ""), (.agent_type | strings // "")] | @tsv' 2>"${_jq_input_err:-/dev/null}") || JQ_OUT=$'\t\t'
if [ -n "${RITE_DEBUG:-}" ] && [ -n "$_jq_input_err" ] && [ -s "$_jq_input_err" ]; then
  printf '[%s] pre-tool-bash-guard: jq input parse stderr: %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(head -c 200 "$_jq_input_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)" \
    >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
fi
[ -n "$_jq_input_err" ] && rm -f "$_jq_input_err"
TRANSCRIPT_PATH=$(printf '%s' "$JQ_OUT" | cut -f1)
INPUT_SUBAGENT_TYPE=$(printf '%s' "$JQ_OUT" | cut -f2)
INPUT_AGENT_TYPE=$(printf '%s' "$JQ_OUT" | cut -f3)
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac
if [ "$IS_SUBAGENT" = "0" ]; then
  if [ -n "$INPUT_SUBAGENT_TYPE" ] || [ -n "$INPUT_AGENT_TYPE" ]; then
    IS_SUBAGENT=1
  fi
fi
if [ "$IS_SUBAGENT" = "0" ]; then
  if [ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    IS_SUBAGENT=1
  fi
fi

# Fail-open ERR trap for Patterns 1-3: if heredoc extraction or simple pattern
# matching crashes on edge-case input, allow the command rather than blocking it.
_rite_btg_pattern13_fail_open() {
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-bash-guard: Pattern 1-3 ERR trap fired — command allowed via fail-open\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  exit 0
}
trap '_rite_btg_pattern13_fail_open' ERR

# --- Heredoc-safe command extraction ---
# Strip heredoc content to avoid false positives on text inside commit messages,
# PR descriptions, etc. Only check the command prefix before the first heredoc marker.
# Known limitation: Piped heredoc patterns (e.g., `cat <<EOF | gh pr diff`) bypass
# this stripping because the command before `<<` is `cat`, not the target pattern.
# Risk is limited since such patterns are rare in practice.
CMD_CHECK="${COMMAND%%<<*}"

# --- Denylist check (Bash built-ins only) ---

BLOCKED_PATTERN=""
BLOCKED_REASON=""
BLOCKED_ALTERNATIVE=""
# Sub-kind tag for the deny message. Stays empty for git-verb blocks (A)-(G);
# the (Z) shell-wrapper sub-block sets it to "shell-wrapper" so the final deny
# message can explain why a read-only wrapper probe is blocked (Issue #1322).
BLOCKED_SUBKIND=""

# Pattern 1: gh pr diff --stat
case "$CMD_CHECK" in
  *"gh pr diff"*" --stat"*)
    BLOCKED_PATTERN="gh-pr-diff-stat"
    BLOCKED_REASON="gh pr diff does not support the --stat flag."
    BLOCKED_ALTERNATIVE="Use: gh pr view {pr_number} --json files --jq '.files[] | {path, additions, deletions}'"
    ;;
esac

# Pattern 2: gh pr diff -- <path> (file filter)
# `[^|]*` (zero-or-more) covers both forms: `gh pr diff 123 -- file` and
# `gh pr diff -- file` (when invoked from a PR branch with no positional arg).
# An earlier `[^|]+` (one-or-more) silently missed the bare form.
if [ -z "$BLOCKED_PATTERN" ]; then
  if [[ "$CMD_CHECK" =~ gh[[:space:]]+pr[[:space:]]+diff[[:space:]]+[^|]*[[:space:]]?--[[:space:]] ]]; then
    BLOCKED_PATTERN="gh-pr-diff-file-filter"
    BLOCKED_REASON="gh pr diff does not support -- <path> for per-file filtering."
    BLOCKED_ALTERNATIVE="Use: gh pr diff {pr_number} | awk '/^diff --git/ { found=0 } /^diff --git.*target_pattern/ { found=1 } found { print }'"
  fi
fi

# Pattern 3: != null in jq expressions (history expansion breaks !)
if [ -z "$BLOCKED_PATTERN" ]; then
  case "$CMD_CHECK" in
    *'!= null'*|*'!=null'*)
      BLOCKED_PATTERN="jq-not-equal-null"
      BLOCKED_REASON="!= null causes bash history expansion errors. The ! character is interpreted by bash before reaching jq."
      BLOCKED_ALTERNATIVE="Use: select(.field) for truthiness check, or select(.field == null | not) for explicit null exclusion"
      ;;
  esac
fi

# Pattern 4: Reviewer subagent running state-mutating git commands.
# Scope: only when IS_SUBAGENT=1 (transcript_path contains "/subagents/").
# Main-session git operations (branch switch, commit, etc. performed by
# /rite:pr:open → implement.md Phase 5.1) are NOT affected because IS_SUBAGENT=0 there.
#
# Allowed read-only git commands (NOT matched below):
#   - git diff / git log / git show / git blame / git status / git ls-files /
#     git ls-remote / git rev-parse / git cat-file
#   - git worktree add / git worktree list
#   - git fetch (bare — must NOT include --prune or --force)
#   - git branch with display-only flags: --list / --show-current / -a / -r / -v
#   - git tag -l / git tag --list
#   - git stash list / git stash show
#   - git reflog (bare list, no expire/delete)
#
# Denylist design:
#   (1) Shell meta-character boundary recognition: `;`, `&`, `|`, `(`, backtick,
#       `$` are also treated as word boundaries — prevents bypass via
#       `true;git reset` / `$(git commit)` / `(git checkout ...)` forms.
#   (2) Sub-action precision: `git tag -l` / `git stash list` / `git reflog` (bare)
#       / `git worktree list` must stay allowed. The denylist targets only
#       state-mutating sub-actions of these verbs.
#   (3) Bare new-branch creation: `git branch <name>` (without any flag) creates
#       a new ref and is therefore blocked. `git branch` and `git branch -a`
#       (display) remain allowed.
#   (4) Long-form flag coverage: `git branch --delete/--force/--move/--copy`
#       are treated the same as the short forms `-d/-f/-m/-c/-C`.
if [ -z "$BLOCKED_PATTERN" ] && [ "$IS_SUBAGENT" = "1" ]; then
  # Normalize whitespace AND shell meta-characters into a single space so that
  # `;git reset` / `(git checkout ...)` / `$(git commit)` / multi-line commands
  # are recognized as `git <verb>` with proper word boundaries.
  CMD_NORMALIZED="${CMD_CHECK//$'\t'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\n'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\r'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//;/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//&/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//|/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//(/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//)/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\{/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\}/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\`/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\$/ }"
  # Absolute-path / explicit-invocation bypass guard:
  # Pattern 4 全体は `*" git <verb> "*` glob に依存するため、`git` を直接呼び出さない
  # 形式 (絶対パス指定 `/usr/bin/git checkout`、`command git checkout`、`exec git checkout`、
  # backslash-escaped `\git checkout` 等) は match せず bypass 可能になる。これらを ` git ` に
  # 正規化することで既存 (A)〜(G) sub-block の glob を改変せずに防御範囲を拡大する。
  #   - `/usr/bin/git` / `/opt/homebrew/bin/git` 等の絶対パス → ` git`
  #   - `command git` / `exec git` / `builtin git` (builtin は構文 invalid だが safety) → ` git`
  #   - `\git` (backslash-escaped) → ` git`
  # Residual gap: alias / function indirection (`alias gg='git'`, `my_git() { ... }`)
  # は parent shell 解決後の独立トークンとして渡るため、本 hook の静的 glob では検出不能。
  # Layer 2 の責務は「静的 token として `git` を含むコマンド」に限定し、一次防御は agent prompt、
  # 三次防御は Layer 3 post-condition state-verify gate に委ねる三層構造を維持する。
  #
  # `/git` substring 全置換の boundary 設計:
  # 本 line は `/git` を ` git` に置換するため `/home/user/.config/git/config` のような
  # path 構成要素も置換対象になる (例: `grep -r foo /home/user/.config/git/config` →
  # `grep -r foo /home/user/.config git/config`)。実装上、現状 false positive は発生しない。
  # 主要因 (全サブブロック共通): path 由来トークンは置換後 ` git/<X>` 形 (前 boundary に leading
  # space、`/` で verb 境界が崩れる) となり、(A)〜(G) すべての deny glob (trailing space 必須形 /
  # 省略形いずれも) が要求する連続 token `git <verb>` シーケンスに到達しないため別経路で safe。
  # 補強要因 (サブブロック別の trailing space): (A) Always-deny verbs の case-glob は
  # `*" git <verb> "*` 形式で trailing space 必須 (verb 末尾の token boundary も二重に保護)。
  # (B) stash / (C) tag / (D) reflog の case-glob、および (E) worktree の case-glob (remove/move/
  # prune 等) は `*" git <verb>"*` 形式で trailing space 省略。(E) worktree の token-loop
  # precondition (`add` 等) は ` git worktree add ` で trailing space 必須。(G) branch は混在で、
  # 短形式 (`-D` / `-d` / `-f` / `-m` / `-M` / `-c` / `-C` 等) は trailing space あり、long-form
  # (`--delete` / `--force` / `--move` / `--copy` 等) は trailing space 省略。
  # 将来、本正規化を `/git ` (後続スペース必須: `${CMD_NORMALIZED//\/git / git }`) に変更すべき
  # ケース: (A) Always-deny に新規 verb を追加し末尾境界条件を緩める設計変更時。(B)-(G) を変更
  # する場合も path 由来トークンとの衝突を再検証する必要がある。
  CMD_NORMALIZED="${CMD_NORMALIZED//\/git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED//\\git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED// command git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED// exec git/ git}"
  CMD_NORMALIZED="${CMD_NORMALIZED// builtin git/ git}"
  # 注: quote 正規化 (`"` / `'` → space) は false positive 過剰 (TC-061 `echo "git checkout"`
  # のような log 出力経路を阻害) のため採用せず、代わりに quote-shell 経路 (`eval` / `sh -c` /
  # `bash -c` / `zsh -c`) を別 sub-block で明示 block する設計に統一。
  # Collapse multiple spaces into one.
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  # Git global flag normalization:
  # `git -C <dir> checkout -b` / `git --git-dir=<X> checkout -b` 等の global flag が介在する形式は
  # 後続の case glob `*" git checkout "*` / token-loop `[[ " git worktree add " ]]` に match せず
  # Pattern (A)〜(G) を bypass する。global flag 群を ` git ` に圧縮することで、後続の sub-block 全体が
  # flag-presence に関わらず一律に match できる。
  #
  # The substitution `${CMD_NORMALIZED/$_lit/git }` interprets $_lit as a glob pattern (bash
  # parameter-expansion semantics), so a `-C <dir>` value containing `*` / `?` / `[` would be
  # treated as a wildcard and could either overmatch or fail to match. Escape those metacharacters
  # before substituting to keep the normalization literal regardless of input content.
  _escape_glob_meta() {
    local s="$1"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//\[/\\[}"
    printf '%s' "$s"
  }
  while [[ " $CMD_NORMALIZED " =~ \ git\ (-C|--git-dir|--work-tree|--exec-path|--namespace|-c|--config-env)(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)\  ]]; do
    _matched="${BASH_REMATCH[0]}"
    _lit=$(_escape_glob_meta "${_matched# }")
    CMD_NORMALIZED="${CMD_NORMALIZED/$_lit/git }"
  done
  while [[ " $CMD_NORMALIZED " =~ \ git\ (--bare|--no-replace-objects|--paginate|--no-pager|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--info-path|--man-path|--html-path)\  ]]; do
    _matched="${BASH_REMATCH[0]}"
    _lit=$(_escape_glob_meta "${_matched# }")
    CMD_NORMALIZED="${CMD_NORMALIZED/$_lit/git }"
  done
  # Re-collapse spaces after global-flag normalization.
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  PADDED=" $CMD_NORMALIZED "

  # --- (Z) Quote-shell bypass guard ---
  # `eval` / `sh -c` / `bash -c` / `zsh -c` 経由で git command を実行する経路は、
  # quote 内の content が (A)-(G) glob と word-boundary を共有しないため bypass 可能。
  # 例: `eval "git checkout -b evil"` は (A) Always-deny に match しない。
  # reviewer subagent が `eval` / shell `-c` を実行する legitimate な理由はほぼない
  # (read-only な script 実行は `bash <script>` で十分) ため、これらの shell-wrapper を直接 block する。
  # 注: `bash <script.sh>` (引数 1 個目が `-c` でない) は allow し続ける必要があるため、`-c` flag の
  # 直前トークンが shell 名であるパターンのみを block する。
  case "$PADDED" in
    *" eval "*|\
    *" sh -c "*|\
    *" bash -c "*|\
    *" zsh -c "*|\
    *" ksh -c "*|\
    *" dash -c "*|\
    *" fish -c "*)
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      # 中身が read-only でも block するため、deny message 側で理由を明示する (Issue #1322)。
      # pattern 名は既存テスト (assert_subagent_deny が reason に "reviewer-state-mutating-git"
      # を要求) との互換のため変えず、subkind タグで message だけを分岐する。
      BLOCKED_SUBKIND="shell-wrapper"
      ;;
  esac

  # --- (A) Always-deny verbs (no read-only sub-action exists) ---
  case "$PADDED" in
    *" git checkout "*|\
    *" git reset "*|\
    *" git add "*|\
    *" git rm "*|\
    *" git restore "*|\
    *" git commit "*|\
    *" git push "*|\
    *" git pull "*|\
    *" git merge "*|\
    *" git rebase "*|\
    *" git cherry-pick "*|\
    *" git revert "*|\
    *" git clean "*|\
    *" git gc "*|\
    *" git prune "*|\
    *" git update-ref "*|\
    *" git symbolic-ref "*|\
    *" git am "*|\
    *" git apply "*|\
    *" git mv "*|\
    *" git notes "*|\
    *" git config "*|\
    *" git remote "*|\
    *" git bisect "*|\
    *" git filter-branch "*|\
    *" git filter-repo "*|\
    *" git replace "*)
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      ;;
  esac

  # --- (B) Sub-action precision: git stash push/pop/drop/apply/clear only ---
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git stash push"*|\
      *" git stash pop"*|\
      *" git stash drop"*|\
      *" git stash apply"*|\
      *" git stash clear"*|\
      *" git stash save"*|\
      *" git stash create"*|\
      *" git stash store"*|\
      *" git stash branch"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (C) Sub-action precision: git tag (creation/deletion only) ---
  # Allowed: `git tag -l`, `git tag --list`, `git tag` (bare list)
  # Denied:  `git tag <name>`, `git tag -a`, `git tag -d`, `git tag --delete`,
  #          `git tag -f`, `git tag --force`
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git tag -a"*|\
      *" git tag --annotate"*|\
      *" git tag -d"*|\
      *" git tag --delete"*|\
      *" git tag -f"*|\
      *" git tag --force"*|\
      *" git tag -s"*|\
      *" git tag -u"*|\
      *" git tag -m"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (D) Sub-action precision: git reflog (only expire/delete block) ---
  # Allowed: `git reflog`, `git reflog show`
  # Denied:  `git reflog expire`, `git reflog delete`
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git reflog expire"*|\
      *" git reflog delete"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (E) Sub-action precision: git worktree remove/prune/move + add-with-new-branch ---
  # Allowed: `git worktree list`, `git worktree add --detach <path> <ref>`,
  #          `git worktree add <path> <existing-branch>` (2 positional args: path + existing ref)
  # Denied:  `git worktree remove`, `git worktree prune`, `git worktree move`,
  #          `git worktree add -b <newbranch> ...` (any position) / `-B`, attached forms
  #          `-bNAME` / `-b=NAME` / `--new-branch=NAME`, bare `git worktree add <path>` (1 positional
  #          arg only — Git auto-creates a new named branch matching basename(path)).
  #
  # Failure mode: a reviewer subagent creates a new named branch via `git worktree add -b`,
  # then runs `git checkout` to traverse states, replacing the parent session's working tree
  # with a clean reference. `git checkout` is already blocked by (A) Always-deny, but
  # `git worktree add -b` had been permitted by (E), leaving a structural gap that this
  # sub-block closes.
  #
  # Initial `add -b ` glob required a trailing space and silently passed forms like
  # `add -bNAME`, `add -b=NAME`, `add --track -b NAME` (mid-flag), and `add /tmp/d -b newbr HEAD`
  # (positional after path). The token loop below identifies `-b` / `-B` as standalone flag
  # tokens, with the case glob retained as a first-line defense.
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git worktree remove"*|\
      *" git worktree prune"*|\
      *" git worktree move"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi
  # Token-loop based detection for `git worktree add` forms — covers all bypass paths:
  #   - bare `add <path>` (1 positional arg, no --detach) → leak
  #   - any token equal to `-b` / `-B` / `--new-branch` / `--force-new-branch` / `--orphan` → leak
  #     (regardless of where it appears in args)
  #   - attached forms `-bNAME` / `-BNAME` / `-b=NAME` / `--new-branch=NAME` /
  #     `--force-new-branch=NAME` / `--orphan=NAME` → leak
  # Allowed:
  #   - `--detach` flag present (token equal to `--detach` or attached form `--detach=...`
  #     which is not a real git option but harmless to recognize)
  #   - 2+ positional args (path + existing branch/ref) AND no new-branch flag
  if [ -z "$BLOCKED_PATTERN" ]; then
    if [[ "$PADDED" =~ " git worktree add " ]]; then
      WT_ARGS="${PADDED##* git worktree add }"
      WT_ARGS="${WT_ARGS% }"
      WT_POSITIONAL_COUNT=0
      WT_HAS_DETACH=0
      WT_NEW_BRANCH_FLAG=0
      for tok in $WT_ARGS; do
        case "$tok" in
          --detach|--detach=*)
            WT_HAS_DETACH=1
            ;;
          -b|-B|--new-branch|--force-new-branch|--orphan)
            # standalone new-branch flag (next token is the branch name)
            WT_NEW_BRANCH_FLAG=1
            ;;
          -b*|-B*|--new-branch=*|--force-new-branch=*|--orphan=*)
            # attached form: `-bNAME` / `-BNAME` / `-b=NAME` / long-form `=NAME`
            # Note: `-b*` glob also catches `-b` alone (handled above by exact-match first
            # branch in case statement, but bash case falls through in order — first match wins,
            # so the standalone variant is matched before this attached-form branch).
            WT_NEW_BRANCH_FLAG=1
            ;;
          -*)
            : ;;  # other flag (--track / --quiet / --guess-remote etc.), skip
          *)
            WT_POSITIONAL_COUNT=$((WT_POSITIONAL_COUNT + 1)) ;;
        esac
      done
      # Deny logic:
      #   (a) new-branch flag present at any position → leak (regardless of --detach)
      #   (b) positional_count <= 1 AND no --detach → bare `add <path>`, auto-creates branch → leak
      if [ "$WT_NEW_BRANCH_FLAG" -eq 1 ]; then
        BLOCKED_PATTERN="reviewer-state-mutating-git"
      elif [ "$WT_POSITIONAL_COUNT" -le 1 ] && [ "$WT_HAS_DETACH" -eq 0 ]; then
        BLOCKED_PATTERN="reviewer-state-mutating-git"
      fi
    fi
  fi

  # --- (F) Sub-action precision: git fetch (bare allowed, --prune/--force denied) ---
  # CRITICAL: `-p` / `-f` must be matched as **standalone flag tokens**, not as
  # substrings inside branch names like `hot-fix` / `release-patch` /
  # `v1.0-rc-final` / `main-pipeline`.
  #
  # Use a single bash regex with an optional "leading args" group:
  #   ([^[:space:]]+[[:space:]]+)*
  # This matches zero or more "non-space token + trailing spaces" — allowing
  # the flag to appear either directly after `git fetch ` or after any number
  # of positional args. The flag group `(--prune|--force|-p|-f)` requires an
  # exact token match, so branch names containing `-p`/`-f` as substrings are
  # NOT matched.
  if [ -z "$BLOCKED_PATTERN" ]; then
    if [[ "$PADDED" =~ " git fetch "([^[:space:]]+[[:space:]]+)*(--prune|--force|-p|-f)([[:space:]=]|$) ]]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
    fi
  fi

  # --- (G) git branch: display-only flags allowed, everything else denied ---
  # Display-only flags: --list / --show-current / -a / --all / -r / --remotes /
  #                     -v / -vv / --verbose / -q / --quiet
  # Denied: -D / -d / -f / -m / -M / -c / -C / --delete / --force / --move /
  #         --copy, bare `git branch <name>` (new ref creation)
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Short/long-form deletion and move flags
    case "$PADDED" in
      *" git branch -D "*|\
      *" git branch -d "*|\
      *" git branch -f "*|\
      *" git branch -m "*|\
      *" git branch -M "*|\
      *" git branch -c "*|\
      *" git branch -C "*|\
      *" git branch --delete"*|\
      *" git branch --force"*|\
      *" git branch --move"*|\
      *" git branch --copy"*|\
      *" git branch --set-upstream"*|\
      *" git branch --unset-upstream"*|\
      *" git branch --edit-description"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Bare new-branch creation: `git branch <non-flag-token>` after the verb.
    # Use a bash regex to detect `git branch` followed by a token that does NOT
    # start with `-` (which would indicate a flag). Bare `git branch`
    # (no argument) and `git branch -<flag>` stay in the regex's non-match path.
    if [[ "$PADDED" =~ " git branch "[[:space:]]*[^[:space:]-] ]]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
    fi
  fi

  if [ -n "$BLOCKED_PATTERN" ]; then
    BLOCKED_REASON="Reviewer subagents must not mutate the working tree, index, or refs. State-changing git commands (checkout/reset/add/stash push/restore/commit/push/merge/rebase/cherry-pick/revert/tag -a -d -f/clean/gc/branch -D --delete/update-ref/symbolic-ref/am/apply/mv/notes/config/remote/bisect/filter-branch/replace/reflog expire/worktree remove/fetch --prune/--force/etc.) are forbidden inside reviewer contexts."
    BLOCKED_ALTERNATIVE="Use read-only alternatives: 'git show <ref>:<file>' to read a blob, 'git diff <ref> -- <file>' to compare, 'git worktree add <path> <ref>' to inspect a different ref in an isolated directory, 'git tag -l' / 'git stash list' / 'git reflog' / 'git branch --list' for display-only queries, or bare 'git fetch' (without --prune/--force) for ref sync. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the full list. If this block fires on a main session (not a reviewer subagent), check whether CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE env vars are accidentally set; recover with: unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE"
    # (Z) shell-wrapper の場合は、wrapper 専用の理由・代替を前置する (Issue #1322)。
    # 汎用 git message だけだと、git を含まない read-only probe (例: `bash -c 'echo x'`) が
    # "State-changing git commands ... forbidden" と表示され、reviewer には over-broad で
    # 不可解な block に見える。なぜ wrapper を一律 block するか / read-only probe をどう書き
    # 直すかを先頭で説明する (既存 git ガイダンスは wrapper が git を包む場合に有効なので残す)。
    if [ "$BLOCKED_SUBKIND" = "shell-wrapper" ]; then
      BLOCKED_REASON="Shell-command wrappers (eval / bash -c / sh -c / zsh -c / ksh -c / dash -c / fish -c) are blocked in reviewer contexts because their quoted argument is opaque to this guard's word-boundary matching and can hide state-mutating git commands. They are therefore blocked unconditionally — even when the wrapped command is read-only. $BLOCKED_REASON"
      BLOCKED_ALTERNATIVE="For a read-only probe, drop the wrapper: run the command directly, group multiple commands in a subshell '( cmd1; cmd2 )', or put them in a file and run 'bash <script.sh>'. $BLOCKED_ALTERNATIVE"
    fi
  fi
fi

# --- Result ---

if [ -z "$BLOCKED_PATTERN" ]; then
  exit 0
fi

# Log block event (stderr, for effect measurement)
CMD_SUMMARY="${COMMAND:0:80}"
CMD_SUMMARY="${CMD_SUMMARY//\"/\\\"}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] bash-guard: BLOCKED pattern=$BLOCKED_PATTERN cmd=\"$CMD_SUMMARY\"" >&2

# Deny with reason and alternative. jq is required to emit the final permission
# payload; an intermittent jq failure here would silently downgrade the deny to
# allow. Fall back to a literal JSON envelope + exit 2 so the deny is fail-closed.
# reason のエスケープ連鎖 (改行 \n 化 + 残存 C0 の ? 化 — Issue #1278 / #1275、
# stop-loop-continuation.sh の JSON emit フォールバックと対称) は
# _bash_guard_escape_deny_reason に集約。neutralize 失敗時は raw を emit せず
# static placeholder へ縮退し、deny + exit 2 の fail-closed 契約を維持する。
_deny_reason="BLOCKED ($BLOCKED_PATTERN): $BLOCKED_REASON $BLOCKED_ALTERNATIVE"
if ! jq -n --arg reason "$_deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'; then
  _deny_reason_escaped=$(_bash_guard_escape_deny_reason "$_deny_reason") \
    || _deny_reason_escaped="BLOCKED: command denied (reason neutralization failed, fail-closed). Check the bash-guard stderr log for the blocked pattern."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$_deny_reason_escaped"
  exit 2
fi
