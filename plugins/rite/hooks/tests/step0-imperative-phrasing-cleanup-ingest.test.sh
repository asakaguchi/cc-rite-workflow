#!/bin/bash
# step0-imperative-phrasing-cleanup-ingest.test.sh
#
# cleanup.md and wiki/ingest.md rely on load-bearing imperative phrasing in
# their Step 0 sections (`VERY FIRST tool call`, `MUST execute`, `BEFORE any
# text output`, `DO NOT end the turn`, `DO NOT output any narrative`). If a
# future prose refactor softens these directives, the implicit-stop regression
# they prevent will return silently — pin the literals here.
#
# Coverage:
#   - cleanup.md "Mandatory After Wiki Ingest" Step 0 imperative phrasing 5 要素
#   - wiki/ingest.md "Mandatory After Auto-Lint" Step 0 imperative phrasing 5 要素
#   - wiki/ingest.md Phase 9.1 caller continuation HTML comment imperative 5 要素
#
# When this test fails:
#   imperative phrasing が weak 化された (例: `VERY FIRST` → `next` に書き換え) 場合、
#   (a) 文章 refactor の意図が implicit stop 防御を緩めるなら本 test と Issue #910/#917 の
#   設計を再評価、(b) 単なる typo / 不要な refactor なら imperative phrasing を復元する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

CLEANUP_MD="$PLUGIN_ROOT/commands/pr/cleanup.md"
INGEST_MD="$PLUGIN_ROOT/commands/wiki/ingest.md"

for f in "$CLEANUP_MD" "$INGEST_MD"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

# Helper: assert a file contains ALL of the imperative phrases listed.
assert_imperative_set() {
  local label="$1" file="$2"; shift 2
  local fname; fname="$(basename "$file")"
  local missing=""
  local phrase
  for phrase in "$@"; do
    if ! grep -qF -- "$phrase" "$file"; then
      missing="${missing} | '$phrase'"
    fi
  done
  if [ -z "$missing" ]; then
    pass "$label ($fname): all imperative phrases present"
  else
    fail "$label ($fname): missing imperative phrases:$missing"
  fi
}

echo "=== cleanup.md Mandatory After Wiki Ingest Step 0 imperative phrasing ==="
assert_imperative_set "cleanup.md Step 0 imperative phrasing" "$CLEANUP_MD" \
  "MUST execute in the SAME response turn" \
  "MUST execute" \
  "VERY FIRST tool call" \
  "BEFORE any text output"

echo ""
echo "=== wiki/ingest.md Mandatory After Auto-Lint Step 0 imperative phrasing ==="
assert_imperative_set "wiki/ingest.md Step 0 imperative phrasing" "$INGEST_MD" \
  "MUST execute in the SAME response turn" \
  "MUST execute" \
  "VERY FIRST tool call" \
  "BEFORE any text output"

echo ""
echo "=== wiki/ingest.md Phase 9.1 caller continuation HTML comment imperative ==="
# caller 継続 HTML コメントの 5 要素 (Issue #910 D-01 design):
#   MUST execute / VERY FIRST tool call / BEFORE any text output / DO NOT end the turn /
#   DO NOT output any narrative
assert_imperative_set "wiki/ingest.md Phase 9.1 continuation HTML imperative" "$INGEST_MD" \
  "MUST execute its 🚨 Mandatory After Wiki Ingest Step 0 bash literal as VERY FIRST tool call" \
  "BEFORE any text output" \
  "DO NOT end the turn" \
  "DO NOT output any narrative"

echo ""
print_summary "$(basename "$0")" "imperative phrasing を弱める refactor を行う場合、Issue #910 / #917 の設計意図 (LLM turn-boundary heuristic の natural stopping point を消去) と本 test の expected set を同時に再評価すること。VERY FIRST / MUST / BEFORE / DO NOT の 4 要素は Layer 1 (prompt contract) の load-bearing imperative。"
