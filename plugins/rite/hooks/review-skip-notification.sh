#!/bin/bash
# rite workflow - Review Result Skip Notification
# Deterministic helper for commands/pr/review.md ステップ 6.1.c (Skip Notification)。
#
# review.md ステップ 6.1.c の skip notification 処理 (post_comment_mode gate + pr_number /
# file_timestamp / local_save_failed の fail-fast gate + LOCAL_SAVE_FAILED に基づく 2 ケース分岐)
# を担う。本文側の巨大 inline bash (機械強制 case 分割 + 2 つの cat heredoc) を helper に切り出す
# ことで、単一 Bash invocation での malform 無言停止を回避する (Issue #1221、6.1.b の
# review-comment-post.sh 切り出しと対称)。
#
# Usage:
#   bash review-skip-notification.sh \
#     --post-comment-mode <true|false> \
#     --pr <number> \
#     --file-timestamp <YYYYMMDDHHMMSS|unknown> \
#     --local-save-failed <0|1|"">
#
#   caller (review.md ステップ 6.1.c) は以下を会話コンテキストから読み取り literal substitute する:
#     - --post-comment-mode: ステップ 1.0 の [CONTEXT] POST_COMMENT_MODE= の値
#     - --pr: 正規化済 pr_number
#     - --file-timestamp: ステップ 6.1.a の [CONTEXT] FILE_TIMESTAMP= の値 (成功時 YYYYMMDDHHMMSS、失敗時 "unknown")
#     - --local-save-failed: ステップ 6.1.a の [CONTEXT] LOCAL_SAVE_FAILED= の値 ("1" または未 emit=空文字)。
#       空文字を確実に渡すため caller は必ずクォートして渡すこと (例: --local-save-failed "")。
#
# 契約 (review.md ステップ 6.1.c と verbatim 一致):
#   - 実行条件: post_comment_mode=false の経路専用 (true 経路は 6.1.b の成功/失敗ログで完結する)。
#   - post_comment_mode machine-enforced gate: false→続行 /
#     true→ERROR + [review:error] + exit 1 / その他→ERROR + [review:error] + exit 1。
#   - 「1 変数 1 gate」原則で fail-fast の局所性を最大化 (post_comment_mode gate 通過後に
#     pr_number / file_timestamp / local_save_failed を順に検証)。reason 語彙:
#       p61c_post_comment_mode_invalid / p61c_pr_number_invalid /
#       p61c_file_timestamp_unset / p61c_file_timestamp_unknown_without_failure /
#       p61c_local_save_failed_invalid / p61c_persistence_unrecoverable
#   - ケース 1 (LOCAL_SAVE_FAILED 未 emit、通常経路): ℹ️ INFO + ローカルファイル path 表示、exit 0。
#   - ケース 2 (LOCAL_SAVE_FAILED=1 ∧ post_comment_mode=false、findings が会話コンテキストにのみ
#     存在する異常経路): ⚠️ ERROR + 復旧方法 4 種を表示し、
#     [CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable を emit、
#     exit 2 で ステップ 6 全体を fail させる (silent data loss 防止のため hard fail)。
#   - [CONTEXT] / WARNING / [review:error] 以外の人間向けログは stderr。
#
# Exit codes:
#   0: 通常の skip notification (ケース 1) 完了。
#   1: gate 違反 (REVIEW_OUTPUT_FAILED emit 済) / 引数エラー。
#   2: ケース 2 (persistence_unrecoverable) の hard fail。ステップ 6 全体を fail させる documented 経路。
set -uo pipefail

# --- Argument parsing ---
POST_COMMENT_MODE=""
PR_NUMBER=""
FILE_TIMESTAMP=""
LOCAL_SAVE_FAILED=""

# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定 + `${2:-}` (nounset 非発火) の下で無限ループに
# 陥る。1 回目の shift で $# を確実に 0 にし、
# 2 回目は no-op で安全に抜ける。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-comment-mode) POST_COMMENT_MODE="${2:-}"; shift; shift ;;
    --pr)                PR_NUMBER="${2:-}"; shift; shift ;;
    --file-timestamp)    FILE_TIMESTAMP="${2:-}"; shift; shift ;;
    --local-save-failed) LOCAL_SAVE_FAILED="${2:-}"; shift; shift ;;
    *) echo "ERROR: review-skip-notification: unknown option: $1" >&2; exit 1 ;;
  esac
done

# post_comment_mode machine-enforced gate。
# 6.1.c は post_comment_mode=false 経路専用。true 経路で誤呼出された場合、本来 6.1.b で
# 成功/失敗ログが完結すべきところ skip notification を出すと観測値が混線する。caller の
# branch selection ミスを fail-fast 遮断する。
case "$POST_COMMENT_MODE" in
  false) ;;
  true)
    echo "ERROR: review-skip-notification: ステップ 6.1.c が post_comment_mode=true の経路で呼び出されました (本来 6.1.b の成功/失敗ログで完結すべき経路)" >&2
    echo "  真因: caller (LLM) が ステップ 6.1 の branch selection を誤りました。post_comment_mode=true の場合は 6.1.b のみを実行し 6.1.c は skip すべきです。" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_post_comment_mode_invalid; value=true" >&2
    echo "[review:error]"
    exit 1
    ;;
  *)
    echo "ERROR: review-skip-notification: post_comment_mode が literal substitute されていません (値: '$POST_COMMENT_MODE', 期待: true/false)" >&2
    echo "  caller は ステップ 1.0 の [CONTEXT] POST_COMMENT_MODE=true|false emit 値を --post-comment-mode に渡す必要があります" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_post_comment_mode_invalid; value=$POST_COMMENT_MODE" >&2
    echo "[review:error]"
    exit 1
    ;;
esac

# pr_number の数値 fail-fast gate (ステップ 6.1.a の pr_number guard と対称化)。
# substitute 漏れ時、ケース 1 のローカルファイル path に placeholder がそのまま出力される
# silent UX regression を防ぐ。
#
# reason drift 対策: ステップ 6.1.a が pr_number 不正を検出した場合は exit 0 (non-blocking) するが、
# ステップ 6.1.c は別 bash invocation のため retained flag を参照できない。pr_number が不正なまま
# 本 helper に到達した場合、真因は ステップ 6.1.a の substitution 忘れなので、その再実行を促す。
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-skip-notification: pr_number が literal substitute されていません (値: '$PR_NUMBER', 期待: 数値のみ非空)" >&2
    echo "  真因: ステップ 6.1.a で Claude が pr_number を literal substitute せず、同じ placeholder が本 helper まで連鎖している可能性が高いです。" >&2
    echo "  対処: ステップ 1.0 で正規化された pr_number を ステップ 6.1.a の bash block 冒頭で literal substitute してから再実行してください" >&2
    echo "  (ステップ 6.1.a が exit 0 non-blocking で完了すると ステップ 6.1.c に substitution 忘れが連鎖します)" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid; upstream_hint=phase_6_1_a_substitution_missing" >&2
    exit 1
    ;;
esac

# file_timestamp gate: placeholder 残留は silent fallthrough せず fail-fast。
case "$FILE_TIMESTAMP" in
  "{"*|*"}")
    echo "ERROR: review-skip-notification: file_timestamp が literal substitute されていません (値: '$FILE_TIMESTAMP')" >&2
    echo "  caller は ステップ 6.1.a の [CONTEXT] FILE_TIMESTAMP=... を読み取って --file-timestamp に渡す必要があります" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unset" >&2
    exit 1
    ;;
  "unknown")
    # ステップ 6.1.a の trap handler は date 失敗時に FILE_TIMESTAMP=unknown と LOCAL_SAVE_FAILED=1 を
    # 同時に emit する設計。片方だけが set された不整合状態 (観測値混線 / race) でケース 1 に流れると、
    # `.rite/review-results/${pr_number}-unknown.json` という実在しないファイルパスを誤提示する UX
    # regression が起きる。整合性違反として明示的に ERROR 化する。
    if [ "$LOCAL_SAVE_FAILED" != "1" ]; then
      echo "ERROR: review-skip-notification: file_timestamp='unknown' だが local_save_failed が '1' ではありません (整合性違反)" >&2
      echo "  ステップ 6.1.a の trap handler は date 失敗時に FILE_TIMESTAMP=unknown と LOCAL_SAVE_FAILED=1 を同時に emit するはずです" >&2
      echo "  単独 emit 経路は観測値混線 / race の兆候であり、ユーザーに誤ったファイルパスを提示する経路を遮断します" >&2
      echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unknown_without_failure" >&2
      exit 1
    fi
    # local_save_failed=1 が併設されている場合は legitimate な失敗経路のため、下記ケース 2 分岐に流す。
    ;;
esac

# local_save_failed の値検証 (許容: 空文字 / 0 / 1)。
case "$LOCAL_SAVE_FAILED" in
  ""|0|1) ;;
  *)
    echo "ERROR: review-skip-notification: local_save_failed が不正 (許容: 空文字 / 0 / 1、値: '$LOCAL_SAVE_FAILED')" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_local_save_failed_invalid" >&2
    exit 1
    ;;
esac

# ケース分岐: LOCAL_SAVE_FAILED=1 が set されていればケース 2 (WARNING 昇格 + hard fail)、
# それ以外はケース 1 (INFO)。
if [ "$LOCAL_SAVE_FAILED" = "1" ]; then
  # ケース 2: local save 失敗 (findings が会話コンテキストにのみ存在する異常経路)。
  #
  # silent data loss 防止のため WARNING のみの exit 0 ではなく、以下 2 段階で hard fail させる:
  # 1. WARNING + 復旧方法 4 種を表示 (ユーザー可視性の維持)
  # 2. `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable` を retained flag
  #    として emit し、ステップ 6 全体を `exit 2` で fail させる (CI / caller が silent pass しない)
  #
  # 「review 成功 = findings が観測可能な場所に届いた」という invariant を維持する。
  cat >&2 <<EOF
⚠️ ERROR: レビュー結果が永続化されませんでした (silent data loss 防止のため ステップ 6 を fail させます)
  PR コメント: スキップ (pr_review.post_comment=false)
  ローカルファイル: 保存失敗 ([CONTEXT] LOCAL_SAVE_FAILED の reason を確認してください)

  影響: 本レビュー結果は現在の会話コンテキストのみに存在します。
  次のセッション開始時 (会話 compaction / terminal close / session restart) に完全に失われます。
  この経路を silent pass にしないため、ステップ 6 全体を exit 2 で fail させます。

  復旧方法 (いずれかを選択):
  1. このセッション内で即座に /rite:pr:fix を実行する (Priority 1: 会話コンテキストから直接読取)
  2. /rite:pr:review --post-comment で PR コメントに投稿して永続化する
  3. rite-config.yml で pr_review.post_comment: true を設定して全 review を永続化する
  4. LOCAL_SAVE_FAILED の reason を解決してから /rite:pr:review を再実行する
EOF
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable; local_save_failed=1; post_comment_mode=false" >&2
  echo "[review:error]"
  exit 2
else
  # ケース 1: local save 成功 (通常経路)。
  cat >&2 <<EOF
ℹ️ PR コメント記録はスキップされました (pr_review.post_comment=false)
  ローカルファイル: .rite/review-results/${PR_NUMBER}-${FILE_TIMESTAMP}.json
  コメント記録を有効化するには --post-comment フラグまたは rite-config.yml で pr_review.post_comment: true を設定してください
EOF
fi

exit 0
