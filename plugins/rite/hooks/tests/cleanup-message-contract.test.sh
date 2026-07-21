#!/bin/bash
# Tests for cleanup.md ステップ 4-W / 5 / 12 の message・配線 contract (Issue #1670, T-06).
#
# cleanup.md は prose-driven command なので、behavioral 検証は worktree-foreign-cwd.test.sh
# (self-exclusion 判定) と pr-cycle-cleanup-session-reap.test.sh (branch recovery) が担う。
# 本テストは、それらに配線する cleanup.md 側の記述が drift しないことを grep で固定する:
#   1. ステップ 4-W が self-exclusion 付き worktree-foreign-cwd.sh に --self-root を渡している
#   2. ステップ 5 が squash-merge 確認済みブランチを強制削除し、遅延ブランチを manifest 記録する
#   3. ユーザー向け遅延メッセージが平易・正確（内部実装語が無く、branch の自動回収を明記）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

CLEANUP="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"

echo "=== ステップ 4-W: self-exclusion 付き live-cwd guard の配線 ==="
assert_grep "4-W uses worktree-foreign-cwd.sh (not the bare live-cwd probe)" "$CLEANUP" "worktree-foreign-cwd\.sh"
assert_grep "4-W passes --self-root \$PPID (excludes the cleanup session's harness)" "$CLEANUP" 'worktree-foreign-cwd\.sh.*--self-root'

echo "=== ステップ 5: squash-merge 確認済みブランチの強制削除 + 遅延ブランチの manifest 記録 ==="
assert_grep "Step 5 reads the {pr_merged} signal" "$CLEANUP" "pr_merged"
assert_grep "Step 5 emits via=squash-merged on confirmed-merged force delete" "$CLEANUP" "via=squash-merged"
assert_grep "Step 5 records the deferred branch to the reap manifest" "$CLEANUP" "rite-tmp-artifact\.sh record --type branch"
# Deferred branch only auto-recovers when the manifest record actually succeeds; the
# marker carries recovery=auto/manual so Step 12 never promises auto-recovery on a
# path that did not record (unmerged force-cleanup / record failure) — AC-6.
assert_grep "Step 5 emits recovery=auto when manifest record succeeds" "$CLEANUP" "recovery=auto"
assert_grep "Step 5 emits recovery=manual when not recorded" "$CLEANUP" "recovery=manual"

echo "=== ステップ 12: ユーザー向けメッセージの平易化・正確化 (AC-6) ==="
# branch の遅延メッセージは「自動で削除される（手動不要）」を明記する（実装の自動回収と整合）。
assert_grep "deferred-branch message states automatic recovery (no manual step)" "$CLEANUP" "自動で削除されます（手動操作は不要）"
# worktree skip メッセージは次セッションでの自動回収を平易に伝える。
assert_grep "worktree-skip message states next-session automatic recovery" "$CLEANUP" "次回のセッション開始時に"

echo "=== ステップ 4-W: busy (EBUSY) 失敗時の sandbox 干渉 WARNING (Issue #1923 AC-5) ==="
assert_grep "4-W detects busy git-worktree-remove stderr" "$CLEANUP" 'grep -qi "busy"'
assert_grep "4-W busy WARNING names sandbox ro-mount interference" "$CLEANUP" "config\.worktree・commondir に read-only bind mount"
assert_grep "4-W busy WARNING gives the sandbox-outside manual recovery command" "$CLEANUP" "sandbox 外のシェルで次を実行してください"
# busy WARNING は sandbox 起因を明示するため、harness の「sandbox 起因の失敗は
# dangerouslyDisableSandbox で即再試行」ルールの発火条件を自ら満たしてしまう。
# この WARNING を読む実行エージェント自身への「この場での再試行はしない」明示が必要
# (non-blocking で遅延 reap へ委譲する設計を守るため)。
assert_grep "4-W busy WARNING tells the executing agent not to auto-retry" "$CLEANUP" "実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと"

echo "=== ステップ 12: 旧・内部実装語/不正確な記述が除去されている ==="
# 旧 worktree-skip メッセージの内部用語「遅延 reap が後で回収します」は撤去済み。
assert_not_grep "old jargon '遅延 reap が後で回収します' removed" "$CLEANUP" "遅延 reap が後で回収します"
# 旧 branch-deferred メッセージ「worktree で checkout 中のため残置しました」は撤去済み。
assert_not_grep "old branch-deferred residue wording removed" "$CLEANUP" "worktree で checkout 中のため残置しました"

if ! print_summary "$(basename "$0")" "cleanup.md ステップ 4-W/5/12 の self-exclusion 配線・branch 回収・平易メッセージ contract (Issue #1670 T-06)"; then
  exit 1
fi
