#!/bin/bash
# Tests for state-path-resolve.sh linked-worktree awareness (Issue #1361 / S1).
#
# Covers the multi-session design §1 contract:
#   - Non-worktree sessions: resolver output is BYTE-IDENTICAL to the legacy
#     `git rev-parse --show-toplevel` (backward-compat pin — AC-1).
#   - Linked-worktree sessions: resolver returns the MAIN checkout root so that
#     rite state / locks / wiki-worktree unify on a single inode (AC-2).
#   - git < 2.31 (no `--path-format=absolute`): the cd+pwd fallback still
#     resolves a worktree to the main root (V-6).
#   - Non-git cwd: falls back to the cwd unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

RESOLVER="$SCRIPT_DIR/../state-path-resolve.sh"

cleanup_dirs=()
cleanup() { for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# --- Build a main checkout + a linked worktree -------------------------------
MAIN=$(make_sandbox --branch develop)
cleanup_dirs+=("$MAIN")
# git worktree add needs the worktree dir to NOT pre-exist; place it as a sibling.
WT="${MAIN}-wt-issue-99"
if ! git -C "$MAIN" worktree add -q -b feat/issue-99 "$WT" >/dev/null 2>&1; then
  echo "ERROR: git worktree add failed; cannot run S1 worktree tests" >&2
  exit 1
fi
cleanup_dirs+=("$WT")

echo "=== T-1: non-worktree resolver output is byte-identical (AC-1 pin) ==="
LEGACY=$(cd "$MAIN" && git rev-parse --show-toplevel)
RESOLVED=$(bash "$RESOLVER" "$MAIN")
assert "T-1 non-worktree byte-identical to show-toplevel" "$LEGACY" "$RESOLVED"

echo "=== T-2: linked worktree resolves to main checkout root (AC-2) ==="
RESOLVED_WT=$(bash "$RESOLVER" "$WT")
assert "T-2 worktree -> main root" "$MAIN" "$RESOLVED_WT"

echo "=== T-3: subdir inside worktree also resolves to main root ==="
mkdir -p "$WT/sub/deep"
RESOLVED_SUB=$(bash "$RESOLVER" "$WT/sub/deep")
assert "T-3 worktree subdir -> main root" "$MAIN" "$RESOLVED_SUB"

echo "=== T-4: non-git cwd falls back to cwd ==="
PLAIN=$(make_plain_sandbox)
cleanup_dirs+=("$PLAIN")
RESOLVED_PLAIN=$(bash "$RESOLVER" "$PLAIN")
assert "T-4 non-git -> cwd" "$PLAIN" "$RESOLVED_PLAIN"

echo "=== T-5: git < 2.31 fallback (no --path-format=absolute) still unifies (V-6) ==="
# Shim a `git` that rejects `--path-format` (simulating pre-2.31) but proxies
# every other invocation to the real git. This forces resolve_state_root onto
# its cd+pwd normalization path.
SHIM=$(make_plain_sandbox)
cleanup_dirs+=("$SHIM")
REAL_GIT=$(command -v git)
cat > "$SHIM/git" <<SHIM_EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    --path-format*) echo "error: unknown option \$a (shim: simulated git<2.31)" >&2; exit 129 ;;
  esac
done
exec "$REAL_GIT" "\$@"
SHIM_EOF
chmod +x "$SHIM/git"
RESOLVED_OLDGIT=$(PATH="$SHIM:$PATH" bash "$RESOLVER" "$WT")
assert "T-5 worktree -> main root under git<2.31 fallback" "$MAIN" "$RESOLVED_OLDGIT"
# And the shim must NOT change the non-worktree byte-identical result.
RESOLVED_OLDGIT_MAIN=$(PATH="$SHIM:$PATH" bash "$RESOLVER" "$MAIN")
assert "T-5 non-worktree byte-identical under git<2.31 fallback" "$MAIN" "$RESOLVED_OLDGIT_MAIN"

print_summary "$(basename "$0")" \
  "Drift hint: state-path-resolve.sh §1 contract — non-worktree output must stay byte-identical to git rev-parse --show-toplevel."
