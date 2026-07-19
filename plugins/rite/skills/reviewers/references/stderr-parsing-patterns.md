# stderr/stdout Mixing — Fix Patterns and Rationale

`agents/error-handling-reviewer.md` Step 6 の「stderr/stdout mixing that corrupts downstream parsing」検出項目の詳細教材。検出ヒューリスティック自体は agent 本体にあり、本ファイルは修正パターンの提示と設計解説を担う(rationale 退避規約: CLAUDE.md スキル行数原則)。

## corrupting-example

**Example: `gh api ... 2>&1 | jq` corrupts JSON parsing**

```bash
# ❌ ANTI-PATTERN: stderr (auth warnings, rate-limit notices) merges into stdout.
# Note: the variable is named `default_branch` because that's what the broken call site
# actually intends to capture after the `| jq` pipeline. The parse error or silent empty
# result means this name may or may not match the actual contents — which is part of the bug.
default_branch=$(gh api repos/owner/repo 2>&1 | jq -r '.default_branch')

# When gh emits a warning like "gh: authentication required" to stderr,
# the merged output becomes:
#   gh: authentication required
#   {"default_branch": "main", ...}
# jq then fails with: parse error: Invalid numeric literal at line 1, column 4
# OR silently returns empty if jq tolerates the prefix and the field is absent.
```

## fix-patterns

**Fix patterns** (all three capture the parsed value in `default_branch` matching the anti-pattern's intent, while separating stderr handling. Patterns A and B additionally keep the full JSON response in `repo_info` for callers that need it.):

> **Strict mode for all three patterns**: The example below enables `set -euo pipefail` explicitly at the top of the block for self-contained demonstration (matching this repository's standard convention for bash code). The rationale notes below this code block depend on strict mode being active. When adapting these patterns into a larger script that already enables strict mode at its entry point, the redundant `set -euo pipefail` line inside the example can be omitted — either arrangement produces the same behavior.

```bash
# Enable strict mode for this self-contained example. Safe to omit if the caller's
# script already enables strict mode at its entry point.
set -euo pipefail

# ✅ Pattern A: Full repo-convention mktemp + trap + if/else — surfaces stderr on both success and failure
# Use this pattern when you need the full JSON response AND want stderr warnings visible
# in BOTH the success path (deprecation / rate-limit notices) AND the failure path
# (auth errors, network failures, gh internal errors).
#
# This example follows the repository's standard bash safety convention used in
# plugins/rite/skills/pr-review/SKILL.md ステップ 2.2.1 and plugins/rite/skills/fix/SKILL.md ステップ 4.5.2:
# (1) path declared before trap, (2) trap installed before mktemp, (3) signal-specific
# exit codes (EXIT/INT/TERM/HUP), (4) explicit mktemp failure handling, (5) gh api wrapped
# in if/else to surface stderr in both success and failure branches, (6) `mktemp` uses a
# named template for debug traceability and collision safety.
#
# Note on mktemp template naming: The repository's phase-scoped callers (skills/*/SKILL.md)
# use a 3-segment form `/tmp/rite-<phase(review|fix)>-<purpose>-XXXXXX` to preserve origin
# traceability when many phases share /tmp. This reviewer example is a generic pattern not
# tied to a specific phase, so we use the simpler 2-segment form `/tmp/rite-<purpose>-XXXXXX`.
# When adapting this example into a phase-scoped script, extend the template to match
# (for example, `/tmp/rite-review-gh-api-err-XXXXXX` inside skills/pr-review/SKILL.md).
gh_err=""
_pa_cleanup() { rm -f "${gh_err:-}"; }
trap 'rc=$?; _pa_cleanup; exit $rc' EXIT
trap '_pa_cleanup; exit 130' INT
trap '_pa_cleanup; exit 143' TERM
trap '_pa_cleanup; exit 129' HUP
gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-gh-api-err-XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }

if repo_info=$(gh api repos/owner/repo 2>"$gh_err"); then
  # Success path: surface any stderr warnings (deprecation, rate-limit notices)
  if [ -s "$gh_err" ]; then
    echo "WARNING: gh stderr output: $(cat "$gh_err")" >&2
  fi
  default_branch=$(jq -r '.default_branch' <<< "$repo_info")
else
  # Failure path: show full stderr for debugging, then exit
  echo "ERROR: gh api failed: $(cat "$gh_err")" >&2
  exit 1
fi

# ✅ Pattern B: Capture stdout first, then parse
# Use this pattern when you want the most explicit failure handling on gh error.
# Simpler than Pattern A because it does not inspect stderr on success, only on failure.
repo_info=$(gh api repos/owner/repo) || { echo "ERROR: gh api failed" >&2; exit 1; }
default_branch=$(jq -r '.default_branch' <<< "$repo_info")

# ✅ Pattern C: Use gh's --jq flag to parse inside gh (stderr stays separate)
# Use this pattern when you only need the parsed value and stderr can be discarded.
default_branch=$(gh api repos/owner/repo --jq '.default_branch')
```

## pattern-selection-guide

**Pattern selection guide**:

- **Pattern A** — When you need the full JSON response in `repo_info` AND want stderr warnings visible in **both** the success path (deprecation / rate-limit notices) and the failure path (auth errors, network errors, rate limits). The `if repo_info=$(...); then ...; else ...; fi` wrapper ensures the stderr capture is surfaced in both branches, avoiding the silent-drop trap where `set -euo pipefail` kills the script before the success-path `[ -s ... ]` check can run. This is the right choice when the script must debug `gh api` failures in the field.
- **Pattern B** — When you want the full JSON response and explicit failure handling, but don't care about stderr warnings on the success path (deprecation notices). Simpler than Pattern A. Best for scripts where `gh api` failures must fail fast with a clear message and success-path warnings are low-value.
- **Pattern C** — When you only need a single parsed field and don't care about stderr warnings at all. Most concise but loses access to the full JSON response (cannot parse additional fields later).

## design-notes

> **Why not hardcoded `/tmp/gh.err`?** The previous revision of this example used a hardcoded path, which is vulnerable to hardcoded-path race conditions (filename collisions when the script runs concurrently, symlink attacks on multi-user systems). The rest of this repository uniformly uses `mktemp` for temp files (see `plugins/rite/skills/pr-review/SKILL.md` ステップ 2.2.1, `plugins/rite/skills/fix/SKILL.md` ステップ 4.5.2). Example code in a reviewer file must not teach patterns that the reviewer itself would flag.
>
> **Why the full path-declare → trap → mktemp pattern?** Two kinds of race conditions exist: (a) **hardcoded-path race** (filename collisions, symlink attacks — solved by `mktemp`), and (b) **signal-delivery race window** (a SIGTERM/SIGINT/SIGHUP arriving between `mktemp` success and `trap` installation leaves the tmp file orphaned — solved by declaring the path variable first, installing the trap, then running `mktemp`). The repository's standard convention (`plugins/rite/skills/pr-review/SKILL.md` ステップ 2.2.1, `plugins/rite/skills/fix/SKILL.md` ステップ 4.5.2) addresses both. Pattern A mirrors that convention.
>
> **Why signal-specific trap entries (INT/TERM/HUP)?** Relying on a bare `trap '...' EXIT` alone to handle signals is risky for two independent reasons. First, when you install an explicit signal-specific trap (e.g., `trap 'cleanup' INT`), bash's default behavior after the handler is to **continue executing** the script rather than exit — unless the handler explicitly calls `exit`. If you forget the `exit`, your script silently keeps running after an interrupt. Second, bash's signal dispatch for a bare EXIT trap (with no signal-specific entry) is **context-sensitive**: it varies with interactive vs non-interactive mode, whether a foreground child is running, and which signal was received. Rather than depending on those details, install signal-specific entries for INT/TERM/HUP that (a) run `_pa_cleanup`, and (b) explicitly `exit` with POSIX-conventional codes (SIGINT=130, SIGTERM=143, SIGHUP=129). This guarantees three things regardless of the execution context: cleanup runs with the correct per-signal exit code, the script exits deterministically rather than continuing, and callers see standard exit codes. The EXIT trap still fires as a belt-and-braces catch-all for the normal-exit and non-signal-failure cases. For the full details of bash's signal handling, see `man bash` section "SIGNALS".
>
> **Why wrap `gh api` in `if ... then ... else ... fi` in Pattern A?** Without the wrapper, under `set -euo pipefail` a `gh api` failure exits the script before the success-path `[ -s "$gh_err" ]` stderr check can run. The stderr capture would be silently dropped in exactly the failure case the user most needs to debug (auth error, rate limit, network error). The `if/else` form guarantees that both the success path (with deprecation notices) and the failure path (with error details) surface the captured stderr.
>
> **Why `if [ -s "$gh_err" ]; then ... fi` and not `[ -s ... ] && echo ...`?** Under `set -euo pipefail`, the `&&` form returns a non-zero exit code on the happy path (when `[ -s ]` is false because stderr is empty). If this appears as the final statement in a function or script, the script exits with that non-zero code. The `if ... then ... fi` form always returns exit 0, matching the "this is a non-fatal notification" semantics the code expresses.
