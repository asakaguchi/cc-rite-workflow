#!/bin/bash
# Tests for the "未完了事項" (outstanding items) aggregation contract added by
# Issue #1946 (T-01/T-02/T-03): non-blocking failures that a flow continued
# past (wiki push failure, branch deletion deferral, etc.) must be surfaced
# in the flow's completion report instead of only appearing as scattered
# per-checkbox annotations that are easy to miss.
#
# cleanup.md / batch-run.md / wiki-ingest.md / recover.md are prose-driven
# skills (LLM-executed, not scripts), so this suite follows the same
# static-contract convention as cleanup-message-contract.test.sh: grep-pin
# the literal markers/sections so drift is caught without needing to run an
# LLM turn.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

CLEANUP="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
BATCH_RUN="$SCRIPT_DIR/../../skills/batch-run/SKILL.md"
WIKI_INGEST="$SCRIPT_DIR/../../skills/wiki-ingest/SKILL.md"
RECOVER="$SCRIPT_DIR/../../skills/recover/SKILL.md"

echo "=== cleanup.md ステップ 12: 未完了事項の集約セクション (T-01, T-02) ==="
assert_grep "Step 12 report has a 未完了事項 section" "$CLEANUP" '^未完了事項:$'
assert_grep "Step 12 has the {outstanding_items_block} placeholder" "$CLEANUP" '\{outstanding_items_block\}'
assert_grep "outstanding_items_block rule aggregates the same per-check warnings" "$CLEANUP" 'その付記文をそのまま箇条書きで列挙する'
# T-01/T-02 感度強化: {local_branch_check}/{wiki_ingest_check} が集約 enumeration の member
# であることを、汎用動詞句の plain assert_grep とは別に、集約ブロック定義の範囲に scope した
# assert_grep_in_section で pin する。同語は checklist 本体・判定 prose にも出現するため、
# section-scope なしだと enumeration からの脱落 regression を検知できない
# (cleanup-message-contract.test.sh の section-scope 規約と同型)。
assert_grep_in_section "outstanding_items_block enumeration includes {local_branch_check} (T-02, AC-2)" \
  "$CLEANUP" '`\{outstanding_items_block\}`（Issue #1946' '^親 Issue 処理結果' \
  '\{local_branch_check\}'
assert_grep_in_section "outstanding_items_block enumeration includes {wiki_ingest_check} (T-01, AC-1)" \
  "$CLEANUP" '`\{outstanding_items_block\}`（Issue #1946' '^親 Issue 処理結果' \
  '\{wiki_ingest_check\}'

echo "=== cleanup.md ステップ 12: 失敗ゼロ件時の明示 (T-03, AC-3) ==="
assert_grep "outstanding_items_block emits an explicit 'none' line when clean" "$CLEANUP" 'なし（非ブロッキングで継続した失敗はありませんでした）'

echo "=== cleanup.md ステップ 12: batch-run が読む outstanding count sentinel ==="
assert_grep "Step 12 emits the [cleanup:outstanding:{n}] sentinel" "$CLEANUP" '\[cleanup:outstanding:\{n\}\]'
assert_grep "outstanding sentinel is placed alongside returned-to-caller" "$CLEANUP" '\[cleanup:outstanding:\{n\}\] --> <!-- skill return signal'

echo "=== batch-run.md: run-queue に outstanding[] 配列を追加 ==="
assert_grep "run-queue schema includes outstanding field (init doc)" "$BATCH_RUN" 'cursor, mode, failed, outstanding, active, updated_at'
assert_grep "queue initialization literal includes outstanding:[]" "$BATCH_RUN" 'failed:\[\], outstanding:\[\], active:true'

echo "=== batch-run.md ステップ 6: cleanup の outstanding sentinel を run-queue に記録 ==="
assert_grep "Step 6 reads the [cleanup:outstanding:N] sentinel" "$BATCH_RUN" '\[cleanup:outstanding:N\]'
assert_grep "Step 6 records into outstanding[] via jq" "$BATCH_RUN" '\.outstanding = \(\(\.outstanding // \[\]\) \+ \[\$n\] \| unique\)'
assert_grep "Step 6 emits RUN_OUTSTANDING_RECORDED" "$BATCH_RUN" 'RUN_OUTSTANDING_RECORDED'

echo "=== batch-run.md ステップ 7: 完了通知への未完了事項ロールアップ ==="
assert_grep "Step 7 bash reads outstanding from the queue" "$BATCH_RUN" 'outstanding=\$\(jq -rc'
assert_grep "Step 7 merge-mode message has an 未完了事項 rollup line" "$BATCH_RUN" '未完了事項: （`outstanding=` が空のとき）なし'

echo "=== wiki-ingest.md ステップ 9: 未完了事項 (Issue #1946, In Scope) ==="
assert_grep "Step 9 report template has 未完了事項 line" "$WIKI_INGEST" '\{ingest_outstanding_line\}'
assert_grep "ingest_outstanding_line reuses WIKI_INGEST_PUSH marker (no new record store)" "$WIKI_INGEST" '新しい記録先は持たない'
assert_grep "ingest_outstanding_line emits explicit none line when push ok" "$WIKI_INGEST" 'なし（非ブロッキングで継続した失敗はありませんでした）'
# marker なし (未確認) は「なし」と混同せず {wiki_push_line} と同じ ⚠️ 未確認扱いにする (F-04 fix)
assert_grep "ingest_outstanding_line treats marker-absent as unconfirmed, not none" "$WIKI_INGEST" '\{wiki_push_line\}` の同ケースと同じ扱い'

echo "=== recover.md: 未完了事項の検出 (Issue #1946, cleanup/completed 到達時のみ, informational) ==="
assert_grep "recover has the outstanding-item detection subsection" "$RECOVER" '### 3\.6 未完了事項の検出'
# gate は {resolved_phase} LLM placeholder 形式でなければならない ($resolved_phase シェル変数形式は
# 別 Bash tool 呼び出しで常に空文字になり検出ロジックが dead code 化するバグだった — 3 レビュアーが
# 独立検出、cross-validation で CRITICAL に昇格。修正後の literal を pin する)
assert_grep "detection is gated on {resolved_phase} placeholder, not a shell variable" "$RECOVER" '\[ "\{resolved_phase\}" = "cleanup" \] \|\| \[ "\{resolved_phase\}" = "completed" \]'
assert_not_grep "detection no longer references the dead \$resolved_phase shell variable" "$RECOVER" '\[ "\$resolved_phase" = "cleanup" \]'
assert_grep "detection checks unpushed wiki worktree commits" "$RECOVER" 'RECOVER_OUTSTANDING_WIKI'
assert_grep "detection checks a residual local branch with no OPEN PR" "$RECOVER" 'RECOVER_OUTSTANDING_BRANCH'
# wiki-worktree パスは state-path-resolve.sh で root 解決してから触る (multi_session worktree 実行時に
# 相対パス .rite/wiki-worktree が cwd 基準で解決できないバグの修正)
assert_grep "wiki-worktree path is resolved via state-path-resolve.sh, not a bare relative path" "$RECOVER" 'wiki_wt="\$state_root/\.rite/wiki-worktree"'
# origin に対応 ref が無い (一度も push が成功していない最悪ケース) も検出側に倒す (false negative 修正)
assert_grep "detection distinguishes an unresolved origin ref from zero unpushed commits" "$RECOVER" 'reason=no_remote_ref'

if ! print_summary "$(basename "$0")" "cleanup/batch-run/wiki-ingest/recover の未完了事項集約 contract (Issue #1946 T-01/T-02/T-03)"; then
  exit 1
fi
