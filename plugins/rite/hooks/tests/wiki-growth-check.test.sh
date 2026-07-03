#!/bin/bash
# Tests for hooks/scripts/wiki-growth-check.sh (Issue #1719)
#
# The checker is a non-blocking lint that fires (exit 1) when the wiki branch
# has stalled relative to merged PRs on the base branch. Its many skip paths
# (exit 0) exist so it never blocks a flow on a misconfigured or wiki-disabled
# repo. These tests pin the invocation contract, the config/branch skip gates,
# and one gh-stubbed positive detection.
#
# Convention: mktemp sandbox, gh stubbed via PATH (no network), GNU/BSD
# portable, commit.gpgsign disabled locally so fixtures commit under a global
# signing config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/wiki-growth-check.sh"

echo "=== wiki-growth-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOXES=()
cleanup() { local d; for d in "${SANDBOXES[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT INT TERM HUP

# gh stub: emit a fixed merged-PR JSON array (GH_STUB_PRS, default []). Both the
# growth-stall count query and the pr-raw correspondence query read this.
STUB_DIR="$(mktemp -d)"; SANDBOXES+=("$STUB_DIR")
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${GH_STUB_PRS:-[]}"
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Build a git repo with rite-config.yml committed and (optionally) a wiki branch.
#   $1 = wiki enabled? (true|false)   $2 = create wiki branch? (yes|no)
# Echoes the repo path.
make_wiki_repo() {
  local enabled="$1" with_wiki="$2" repo
  repo="$(mktemp -d)"; SANDBOXES+=("$repo")
  git -C "$repo" init -q
  git -C "$repo" config user.email t@test.local
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
  printf 'wiki:\n  enabled: %s\n  branch_name: wiki\nbranch:\n  base: develop\n' "$enabled" \
    > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml
  git -C "$repo" commit -q -m init
  [ "$with_wiki" = "yes" ] && git -C "$repo" branch wiki
  printf '%s' "$repo"
}

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "unknown argument exits 2" "2" "$(bash "$SCRIPT" --repo-root "$STUB_DIR" --bogus >/dev/null 2>&1; echo $?)"

# --- Skip gates (exit 0) ------------------------------------------------------
empty_dir="$(mktemp -d)"; SANDBOXES+=("$empty_dir")
assert "rite-config.yml absent → skip (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$empty_dir" --quiet >/dev/null 2>&1; echo $?)"

disabled_repo="$(make_wiki_repo false yes)"
assert "wiki.enabled=false → skip (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$disabled_repo" --quiet >/dev/null 2>&1; echo $?)"

no_wiki_repo="$(make_wiki_repo true no)"
assert "wiki branch absent → skip (exit 0)" "0" \
  "$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --repo-root "$no_wiki_repo" --quiet >/dev/null 2>&1; echo $?)"

# --- Healthy: wiki branch present, zero merged PRs → exit 0 -------------------
healthy_repo="$(make_wiki_repo true yes)"
assert "no merged PRs since last wiki commit → healthy (exit 0)" "0" \
  "$(PATH="$STUB_DIR:$PATH" GH_STUB_PRS='[]' bash "$SCRIPT" --repo-root "$healthy_repo" --quiet >/dev/null 2>&1; echo $?)"

# --- Growth stall detected (exit 1) ------------------------------------------
# threshold=1 with 1 merged PR trips the stall; pr-raw-threshold set high so the
# correspondence check stays healthy and only the growth-stall finding counts.
stall_repo="$(make_wiki_repo true yes)"
assert "merged PRs >= threshold with stalled wiki → finding (exit 1)" "1" \
  "$(PATH="$STUB_DIR:$PATH" GH_STUB_PRS='[{"number":1}]' bash "$SCRIPT" \
      --repo-root "$stall_repo" --threshold 1 --pr-raw-threshold 999 --quiet >/dev/null 2>&1; echo $?)"

# --- Findings line always emitted --------------------------------------------
findings_out="$(PATH="$STUB_DIR:$PATH" GH_STUB_PRS='[]' bash "$SCRIPT" --repo-root "$healthy_repo" --quiet 2>/dev/null || true)"
if printf '%s' "$findings_out" | grep -qE '==> Total wiki-growth-check findings: [0-9]+'; then
  pass "always prints the findings summary line"
else
  fail "findings summary line missing: $findings_out"
fi

print_summary "wiki-growth-check.sh"
