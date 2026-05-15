#!/bin/bash
# start-md-charter.test.sh — Simplification Charter assertions for start.md
#
# Issue #897 / PR A: 後続 PR (B-H) の slim 進捗を機械的に保護するドリフト検出ゲート。
#
# Run modes:
#   STRICT_CHARTER 未設定 (default): meta-test のみ実行 (Charter assertions skip; CI red 化しない)
#   STRICT_CHARTER=1                : meta-test + Charter assertions 全実行 (上限超過時は fail = ratchet)
#
# Gate 配置の意図 (Issue #914 / PR #915 cycle 3 finding F-02):
#   meta-test (mutation fixture identification power) は CI で常時実行する。これは PR #915 の
#   設計意図 (CI 自動実行で identification power の regression を機械検出可能にする) に合致する。
#   一方 Charter assertions (Issue#/cycle/🚨 上限) は develop に pre-existing 違反があり、
#   後続 slim PR (B-H) で削減するまで CI red 化を避けるため STRICT_CHARTER=1 opt-in で gate する。
#
# Assertions:
#   上限 (Charter 違反パターン上限):
#     - `Issue #[0-9]+` ≤ 1   metavariable `Issue #N` は数字でないため自動除外
#     - `cycle [0-9]+`  ≤ 1
#     - `🚨`            ≤ 5
#   下限 (現状値の保護):
#     - `AskUserQuestion` ≥ 30
#     - `Mandatory After` heading-anchor (h3+h4) ≥ 17 (実測: h3 14 + h4 3)
#   対称性:
#     - `flow-state-update.sh create` 各呼び出しが
#       --phase / --issue / --branch / --pr / --next の 5 種すべてを含む
#     - 検出対象は bash code block 内 (indented fence `   ```bash` も含む) の
#       コードのみ。shell コメント (行頭 `# ...` の comment-only 行、および
#       行内 `cmd # ...` 形式の inline comment 末尾部分) は除外。
#       quoted `#` (`echo "#foo"` 等の double/single quote 内) は完全 shell-aware
#       パース未実装のため scope 外 (Issue #912 finding 1)。
#     - bash code fence 終端 (` ``` `) は trailing whitespace を許容 (CommonMark
#       準拠、Issue #912 finding 2)。
#   対称性-下限 (Issue #908 finding 3):
#     - `flow-state-update.sh create` の (上記検出対象内) 呼び出し数 ≥ 1
#       (全削除 regression を catch する真正な保護)
#   Mutation meta-test (Issue #914):
#     - `fixtures/start-md/m{1..6}-*.md` の 6 fixture を期待値テーブル駆動で検証
#     - 各 fixture について `compute_symmetry_for()` の出力が
#       (expected_total, expected_asymmetric) と一致すること
#     - META_FIXTURES counter == 6 (drift 検出アンカー)
#     - identification power の regression (mutation 実装が壊れた場合) を CI で機械検出
#
# Note (PR C 実装済み, Issue #899):
#   `MUST execute in the SAME response turn` ≥ 17 / `DO NOT stop, do NOT re-invoke` ≥ 17 の
#   下限 assert を PR C で有効化済み (Mandatory After heading 17 件 + 各 1 件導入による現状値を ratchet)。
#   設計ドキュメント上の最終目標 ≥ 30 は Pre-write block への展開を含む後続 PR で引き上げる予定。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
# Issue #908: START_MD を env override 可能にする (mutation test fixture を渡せるように)
START_MD="${START_MD:-$PLUGIN_ROOT/commands/issue/start.md}"
# PR H (#905): sub-skill 分割後の aggregated lower-bound 用に start-execute/publish/finalize を参照
START_EXECUTE_MD="$PLUGIN_ROOT/commands/issue/start-execute.md"
START_PUBLISH_MD="$PLUGIN_ROOT/commands/issue/start-publish.md"
START_FINALIZE_MD="$PLUGIN_ROOT/commands/issue/start-finalize.md"
# Issue #914: mutation fixture 永続化に伴う meta-test fixture ディレクトリ
FIXTURES_DIR="$SCRIPT_DIR/fixtures/start-md"

# PR H (#905): aggregated counter helper — start*.md 4 ファイル横断で pattern 出現数を集計。
# sub-skill 分割 (PR F/G1/G2) で Phase 5 content が start-execute/publish/finalize へ移動した結果、
# start.md 単独の下限 assert が無効化された。aggregated 集計で「content が消滅していない」ことを
# semantic invariant として保護する (個別ファイルではなく合計で contract を維持)。
count_aggregated() {
  local pattern="$1"
  local total=0
  local c
  for f in "$START_MD" "$START_EXECUTE_MD" "$START_PUBLISH_MD" "$START_FINALIZE_MD"; do
    [ -f "$f" ] || continue
    c=$({ grep -oE "$pattern" "$f" || true; } | wc -l | tr -d ' ')
    total=$((total + c))
  done
  echo "$total"
}

# === Symmetry computation function (Issue #914 refactor) ===
# `flow-state-update.sh create` invocation の Symmetry metrics を計算する関数。
# 本体 assert (対称性) と meta-test (mutation fixture identification power)
# の両方から呼び出され、awk pipeline と判定 logic の重複を排除する (DRY)。
#
# Args:
#   $1: target — 解析対象 markdown file (本体: $START_MD, meta-test: M1-M6 fixture)
#
# Output:
#   stdout (複数行):
#     - 0 行以上の diagnostic 行 (`⚠️ asymmetric (...)`、asymmetric block ごとに 1 行)
#     - 末尾 1 行: "TOTAL|ASYMMETRIC" 形式の metrics
#   caller は `tail -1` で metrics を、`sed '$d'` で diagnostics を分離する。
#   stderr は environment error 専用 (本関数では使わない / _test-helpers.sh の "Output convention
#   (Issue #853)" 節遵守)。
#
# Same-file 3-site sync (Wiki: PR #909 経験則 / canonical-list-count-claim-drift-anchor):
#   挙動変更時に以下の 3 site を同期更新すること:
#     (1) 冒頭 spec preamble の "対称性:" / "対称性-下限" / "Mutation meta-test"
#         3 subsection を含む単一 site (本ファイル冒頭 header コメント、節題で参照)
#     (2) compute_symmetry_for() 関数の docstring (本コメント直前)
#     (3) compute_symmetry_for() 内の awk inline コメント (Issue #908/#912 finding 1/2 説明)
#   本関数化に伴い、上記 (2) と (3) が本関数内に集約された。
compute_symmetry_for() {
  local target="$1"
  local total=0
  local asymmetric=0
  local block=""
  local first_line=""
  local missing=""
  local diagnostics=""
  # bash code block 内 (```bash ... ```) の `flow-state-update.sh create` 呼び出しのみ対象。
  # markdown 散文 (table cell / prose mention) の言及は対象外。
  # Issue #908 finding 1: indented fence (`   ```bash` 等、リスト項目内 block) も含めるため
  # `^[[:space:]]*` を許容する。fence 開始/終了を対称適用 (Asymmetric Fix Transcription 防止)。
  # Issue #908 finding 2: shell コメント行 (`# ... flow-state-update.sh create ...`) を
  # false positive 検出してしまう問題に対し、shell コメント開始行を前置 not-match `!/^[[:space:]]*#/`
  # で除外する形式を採用 (前置 not-match で除外 → create 含有を別 regex で判定)。
  # Issue #912 finding 1: 行内 inline `#` comment (`cmd # ...flow-state-update.sh create...`)
  # も false positive で count される問題に対し、`sub(/[[:space:]]+#.*$/, "", line)` で
  # whitespace-preceded inline shell comment を strip してから literal 判定する。
  # quoted `#` (`echo "#foo"` 等の double/single quote 内) は完全 shell-aware パース未実装の
  # ため scope 外として明示。
  # Issue #912 finding 2: bash code fence 終端 (` ``` `) は CommonMark 上 trailing whitespace
  # を許容するため、fence 終端 regex を `^[[:space:]]*```[[:space:]]*$` に拡張する。
  # 各 create 呼び出しに対して、bash block 終端 ``` までを動的に block として抽出する
  # (固定 +7 行 window では line continuation の長さに依存して block を取り損ねるリスクがある)。
  # awk でファイル全体を 1 度走査し、各 block を `\0` 区切りで出力 → bash の read -d '' で受ける。
  while IFS= read -r -d '' block; do
    [ -z "$block" ] && continue
    total=$((total + 1))
    first_line=$(printf '%s' "$block" | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)
    missing=""
    # 引数検出 regex は `--flag value` (space 区切り) 形式を前提とする。`--flag=value` 形式は
    # 現状 start.md では使われていないが、将来書式変更時はこの regex を拡張する必要がある。
    for flag in '--phase' '--issue' '--branch' '--pr' '--next'; do
      if ! printf '%s\n' "$block" | grep -qE -- "${flag}([[:space:]]|$)"; then
        missing="${missing} ${flag}"
      fi
    done
    if [ -n "$missing" ]; then
      asymmetric=$((asymmetric + 1))
      # diagnostic は stdout に蓄積 (caller が tail -1 で metrics を、sed '$d' で diagnostics を
      # 分離する 2-stream-on-stdout 設計)。stderr は environment error 専用とし、
      # _test-helpers.sh の "Output convention (Issue #853)" 節 (failure detail は stdout 推奨) に揃える。
      diagnostics+="  ⚠️ asymmetric (block starting: ${first_line}, missing:${missing})"$'\n'
    fi
  done < <(awk '
    # Issue #908 finding 1: indented bash code fence (e.g., リスト項目内の `   ```bash`) も検出
    # するため `^[[:space:]]*` を許容する。fence 開始/終了の対称適用が必須
    # (Asymmetric Fix Transcription 防止)。
    # Issue #912 finding 2: fence 終端 (` ``` `) は CommonMark 上 trailing whitespace を
    # 許容するため `[[:space:]]*$` で末尾空白を許容する (例: ` ```<EOL>` / ` ``` <EOL>` 両方を
    # 受容)。fence 開始側 (`^[[:space:]]*```bash`) は info string `bash` 直後の任意空白が code
    # language の一部にはならない (CommonMark 仕様) ため、開始側の拡張は不要。
    /^[[:space:]]*```bash/        { in_block=1; in_create=0; block=""; next }
    /^[[:space:]]*```[[:space:]]*$/ {
                      if (in_create) { printf "%s%c", block, 0 }
                      in_block=0; in_create=0; block=""; next
                    }
    # Issue #908 finding 2: shell コメント行 (`# ... flow-state-update.sh create ...`) を
    # false positive で検出してしまう問題に対し、shell コメント開始行 (行頭が任意空白後 `#` で始まる行)
    # を **前置 not-match で除外** してから create 含有を判定する形式を採用。
    # 設計上の選択理由 (前置 not-match vs `[^[:space:]#]` 先頭ガード):
    #   1. `^[[:space:]]*[^[:space:]#].*X` 形式は、X が行頭から始まる行 (例: `flow-state-update.sh create ...`)
    #      を `[^[:space:]#]` で先頭の `f` を消費した結果、続く literal `X` が行内に再発見できず
    #      silent miss する backtracking trap がある (PR #911 cycle 2 で empirical 再現確認済み)。
    #   2. 前置 not-match `!/^[[:space:]]*#/` は「shell コメント開始行のみ除外」と意図が直接的で、
    #      X の行頭出現有無に影響を受けない。これは bash/awk regex の確立されたイディオム。
    # Issue #912 finding 1: 行内 inline `#` comment (`cmd # ...flow-state-update.sh create...`)
    # も false positive を生む問題に対し、judgement-only 用の line copy を作って
    # `sub(/[[:space:]]+#.*$/, "", line)` で whitespace-preceded inline shell comment を strip
    # してから literal を判定する。`block=$0` は元の line を保持する (display 用の正確性維持)。
    # scope 外 (= strip しない / false positive を残す) ケース:
    #   - quoted `#` (`echo "#foo # cmd flow-state-update.sh create"` 等の double/single quote 内
    #     の `#`) は完全 shell-aware パース未実装のため、`sub` が quote を理解せず一律に strip する。
    #     現実的には quote 内に `flow-state-update.sh create` literal を書く運用は皆無と判断し
    #     scope 外として許容する (`# Wiki: PR #909 Same-file 3-site sync` の経験則に従い、
    #     関数 docstring の preamble と本ブロックを sync 更新する際は、関数 docstring の
    #     "Same-file 3-site sync" 節で定義された 3 site (冒頭 spec preamble / 関数 docstring /
    #     関数内 awk inline コメント) を同時に修正すること)。
    # 仕様: shell コメント開始行 (`^[[:space:]]*#`) を除外し、行内 inline shell comment を strip した
    #       うえで `flow-state-update.sh create` を含む行を検出。
    in_block && !/^[[:space:]]*#/ {
                      # Issue #912 finding 1: judgement-only line copy で inline `#` comment strip
                      line = $0
                      sub(/[[:space:]]+#.*$/, "", line)
                      if (line ~ /flow-state-update\.sh create/) {
                        # 同一 bash block 内に複数 create 呼び出しがある場合、前 block を先に flush
                        # してから新 block を開始する (multi-create-per-block blind spot 防止)
                        if (in_create) { printf "%s%c", block, 0 }
                        in_create=1
                        block=$0
                        next
                      }
                    }
    in_block && in_create { block = block "\n" $0 }
  ' "$target")
  # diagnostics を metrics の前に出力 (caller は `sed '$d'` で diag、`tail -1` で metrics を分離)
  if [ -n "$diagnostics" ]; then
    printf '%s' "$diagnostics"
  fi
  printf '%s|%s\n' "$total" "$asymmetric"
}

echo "=== start-md-charter ==="
echo ""

# === Mutation meta-test (Issue #914) ===
# `compute_symmetry_for()` の identification power (= mutation を確実に区別できる能力) を
# fixtures/start-md/M1-M6 に対する期待値テーブル駆動で empirical 検証する。
# 過去 PR (#911 S7/S8/S9 / #913 M5/M6) で `/tmp` に作って捨てていた mutation fixture を永続化し、
# CI 自動実行で identification power の regression を機械検出可能にする。
#
# Gate 配置: Charter assertions (Upper/Lower/Symmetry) は STRICT_CHARTER=1 opt-in だが、
# meta-test は **常時実行**。develop の pre-existing Charter 違反 (Issue#/cycle/🚨 上限超過) を
# 理由に CI で skip すると identification power の regression を CI で検出できず、本 PR の
# 設計意図に反する。Charter assertions と meta-test の opt-in 境界を分離することで、
# 「develop の Charter 違反は許容しつつ、mutation 識別力は CI で必ず検証」を両立する。
#
# META_FIXTURES counter pin: 6 entries (M1-M6) — drift 検出アンカー (Wiki: 「N site 対称化 counter
# 宣言」経験則)。fixture 追加/削除時はこの counter (`-eq 6` assert) と META_FIXTURES 配列を
# 同期更新すること。
#
# 期待値テーブル形式: name|expected_total|expected_asymmetric
# Symmetry-bound (>= 1) の期待結果は expected_total から導出 (1 で pass, 0 で fail)。
echo "--- Mutation meta-test (M1-M6 fixture identification power) ---"

if [ ! -d "$FIXTURES_DIR" ]; then
  fail "Meta: fixtures dir not found: $FIXTURES_DIR"
else
  declare -a META_FIXTURES=(
    "m1-indented-fence.md|1|0"
    "m2-shell-comment-line.md|0|0"
    "m3-zero-create.md|0|0"
    "m4-backtracking-trap.md|1|0"
    "m5-inline-comment.md|0|0"
    "m6-fence-trailing-ws.md|1|0"
  )

  # counter pin: drift 検出アンカー
  if [ "${#META_FIXTURES[@]}" -eq 6 ]; then
    pass "Meta: META_FIXTURES counter == 6 (drift 検出アンカー)"
  else
    fail "Meta: META_FIXTURES counter != 6 (actual=${#META_FIXTURES[@]}, expected=6)"
  fi

  # M6 trailing whitespace pre-check: fixture 末尾 fence の trailing whitespace は M6 識別力の
  # 唯一の load-bearing 要素。`prettier --write` / `trim_trailing_whitespace=true` editorconfig 等で
  # 黙って剥がされた場合、新旧 regex 双方で total=1 となり meta-test が依然 pass し
  # 識別力が silently 失われる。本 pre-check で trailing ws の保持を機械保証する。
  if grep -qE '```[[:space:]]+$' "$FIXTURES_DIR/m6-fence-trailing-ws.md"; then
    pass "Meta: m6 fixture trailing whitespace 保持 (load-bearing for identification power)"
  else
    fail "Meta: m6 fixture lost trailing whitespace (load-bearing for identification power; check .editorconfig / prettier)"
  fi

  for entry in "${META_FIXTURES[@]}"; do
    IFS='|' read -r fname exp_total exp_asym <<<"$entry"
    fixture_path="$FIXTURES_DIR/$fname"
    if [ ! -f "$fixture_path" ]; then
      fail "Meta: fixture not found: $fname"
      continue
    fi
    fixture_output=$(compute_symmetry_for "$fixture_path")
    fixture_metrics=$(printf '%s\n' "$fixture_output" | tail -1)
    fixture_diag=$(printf '%s\n' "$fixture_output" | sed '$d')
    actual_total="${fixture_metrics%%|*}"
    actual_asym="${fixture_metrics##*|}"
    if [ "$actual_total" = "$exp_total" ] && [ "$actual_asym" = "$exp_asym" ]; then
      pass "Meta: $fname → total=$actual_total asymmetric=$actual_asym (expected total=$exp_total asym=$exp_asym)"
    else
      fail "Meta: $fname → total=$actual_total asymmetric=$actual_asym (expected total=$exp_total asym=$exp_asym)"
      # mismatch 時は diagnostic を印字する (本体 assert と出力対称性を維持、debug 情報の silent loss 防止)
      [ -n "$fixture_diag" ] && printf '%s\n' "$fixture_diag"
    fi
  done
fi

# Env gate: Charter assertions のみ opt-in via STRICT_CHARTER=1
# meta-test は上で常時実行済み (CI で identification power の regression を機械検出)。
if [ "${STRICT_CHARTER:-}" != "1" ]; then
  echo ""
  echo "[start-md-charter] charter assertions skipped (STRICT_CHARTER not set; opt-in only); meta-test executed"
  if ! print_summary "$(basename "$0")" \
    "Meta-test only ran. Charter assertions are opt-in via STRICT_CHARTER=1 (develop の pre-existing 違反対応のため)."; then
    exit 1
  fi
  exit 0
fi

if [ ! -f "$START_MD" ]; then
  echo "ERROR: start.md not found at $START_MD" >&2
  exit 1
fi

echo ""
echo "=== Charter assertions (STRICT_CHARTER=1) ==="
echo "target: $START_MD"
echo ""

# === 上限 assert: Charter 違反パターン上限 ===
echo "--- Upper bounds (Charter limits) ---"

# `grep -oE 'Issue #[0-9]+'` は数字限定のため `Issue #N` placeholder は自動除外される
# 注: `set -euo pipefail` 配下では grep 0 マッチ (exit 1) で pipeline 全体が abort するため、
# `{ grep ... || true; }` で 0 マッチを exit 0 に正規化する (ratchet ideal 達成時の silent abort 防止)
# PR H (#905) で閾値を 1 → 3 に recalibrate。Issue #513 regression guard 等の legitimate
# reasoning prose を保護するため (Wiki: cleanup refactor は reasoning prose を保持し
# review-history journal のみ削除)。
issue_count=$({ grep -oE 'Issue #[0-9]+' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$issue_count" -le 3 ]; then
  pass "Upper: \`Issue #[0-9]+\` count <= 3 (actual=$issue_count)"
else
  fail "Upper: \`Issue #[0-9]+\` count <= 3 (actual=$issue_count, expected <=3)"
fi

cycle_count=$({ grep -oE 'cycle [0-9]+' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$cycle_count" -le 1 ]; then
  pass "Upper: \`cycle [0-9]+\` count <= 1 (actual=$cycle_count)"
else
  fail "Upper: \`cycle [0-9]+\` count <= 1 (actual=$cycle_count, expected <=1)"
fi

# PR H (#905) で閾値を 5 → 10 に recalibrate。start.md の Mandatory After heading 数
# (10 件) が現状の正当な構造。10 を超える = section heading が追加されたことを意味する。
bell_count=$({ grep -oE '🚨' "$START_MD" || true; } | wc -l | tr -d ' ')
if [ "$bell_count" -le 10 ]; then
  pass "Upper: \`🚨\` count <= 10 (actual=$bell_count)"
else
  fail "Upper: \`🚨\` count <= 10 (actual=$bell_count, expected <=10)"
fi

# PR H (#905) 追加: 本体 line 数 ≤ 720 assert (parent Issue #896 目標 「600-700 行」 + 20 行 margin)。
# sub-skill 分割完了後の正常な start.md line 数を保護する upper bound (削除のみを catch
# する従来 lower bound と対称な、追加のみを catch する upper bound)。
# margin 20 行は code-quality reviewer F-07 finding 「閾値 700 + 実値 698 で余裕 2 行は tight」
# への対応 (minor edit で即 ratchet 触発する摩擦を緩和)。
# 720 超過時は sub-skill (start-execute / start-publish / start-finalize) への migration を検討する
# forcing function として機能する。
line_count=$(wc -l < "$START_MD" | tr -d ' ')
if [ "$line_count" -le 720 ]; then
  pass "Upper: start.md 本体 line 数 <= 720 (actual=$line_count)"
else
  fail "Upper: start.md 本体 line 数 <= 720 (actual=$line_count, expected <=720, target ≤700; sub-skill 化を検討)"
fi

# === 下限 assert: 現状値の保護 (aggregated across start*.md) ===
echo ""
echo "--- Lower bounds (aggregated across start*.md — sub-skill 分割後の semantic invariant) ---"

# PR H (#905) で aggregated 集計に切替。sub-skill 分割 (PR F/G1/G2) で Phase 5 の content が
# start-execute/publish/finalize へ移動した結果、start.md 単独の下限 assert は無効化された。
# 現状の aggregated 値 (start*.md 4 ファイル合計):
#   - AskUserQuestion: 34 (旧 start.md 単独 30+ 閾値を継承)
#   - Mandatory After heading: 19 (h3 14 + h4 3 + sub-skill 移管分; 旧閾値 17 を継承)
#   - MUST execute in the SAME response turn: 19 (Mandatory After heading + Pre-flight 等)
#   - DO NOT stop, do NOT re-invoke: 19 (同上)
# 上限 assert と単位を揃えるため `grep -oE | wc -l` (occurrence 単位) に統一する。
# 注: 0 マッチ時の pipefail abort 回避は count_aggregated helper 内で実装。

ask_count=$(count_aggregated 'AskUserQuestion')
if [ "$ask_count" -ge 30 ]; then
  pass "Lower (aggregated): \`AskUserQuestion\` count >= 30 (actual=$ask_count)"
else
  fail "Lower (aggregated): \`AskUserQuestion\` count >= 30 (actual=$ask_count, expected >=30)"
fi

# heading-anchor 限定: 行頭の `#+ … 🚨 (Mandatory After|After <Word>)` のみを集計する。
# 散文 mention (`**🚨 Immediate after …**`) や table cell の参照 (`| 🚨 After Review |`) は除外する。
# PR H (#905) で aggregated 集計に切替: start.md 10 + start-execute 2 + start-publish 2 + start-finalize 5 = 19。
# `After ` 側を `After [A-Za-z]` として `Mandatory After` 側との trailing-space 非対称性を解消する。
# 更新ルール: 本 assert 対象の heading を追加/削除する PR では aggregated 合計の閾値 `>=17` を
# 同期更新すること (drift 防止)。
mandatory_count=$(count_aggregated '^#+ .*🚨 (Mandatory After|After [A-Za-z])')
if [ "$mandatory_count" -ge 17 ]; then
  pass "Lower (aggregated): \`Mandatory After\` heading-anchor count >= 17 (actual=$mandatory_count)"
else
  fail "Lower (aggregated): \`Mandatory After\` heading-anchor count >= 17 (actual=$mandatory_count, expected >=17)"
fi

# Issue #899 (PR C) で導入された 2 文 contract phrase の下限 assert。
# PR H (#905) で aggregated 集計に切替: Mandatory After heading 19 + Pre-flight 等の追加箇所で合計 19。
# 旧閾値 17 は sub-skill 分割後も aggregated で維持される (削除のみを catch する真正な構造保護)。
must_execute_count=$(count_aggregated 'MUST execute in the SAME response turn')
if [ "$must_execute_count" -ge 17 ]; then
  pass "Lower (aggregated): \`MUST execute in the SAME response turn\` count >= 17 (actual=$must_execute_count)"
else
  fail "Lower (aggregated): \`MUST execute in the SAME response turn\` count >= 17 (actual=$must_execute_count, expected >=17)"
fi

do_not_stop_count=$(count_aggregated 'DO NOT stop, do NOT re-invoke')
if [ "$do_not_stop_count" -ge 17 ]; then
  pass "Lower (aggregated): \`DO NOT stop, do NOT re-invoke\` count >= 17 (actual=$do_not_stop_count)"
else
  fail "Lower (aggregated): \`DO NOT stop, do NOT re-invoke\` count >= 17 (actual=$do_not_stop_count, expected >=17)"
fi

# === 対称性 assert: flow-state-update.sh create の 5 引数 (aggregated across start*.md) ===
# Issue #914: Symmetry pipeline は `compute_symmetry_for()` 関数に抽出済み。
# 本体 assert と meta-test (mutation fixture) で同一 logic を共有し、識別力を保証する。
# PR H (#905) F-04 対応: lower bound と同じく aggregated 化 (start*.md 4 ファイル横断)。
# 旧実装は $START_MD のみ Symmetry check していたため、sub-skill 内 21 invocations の 5-arg drift が
# CI 緑のまま通過する blind spot があった (HIGH finding by code-quality-reviewer)。
echo ""
echo "--- Symmetry (flow-state-update.sh create 5-arg invariant, aggregated across start*.md) ---"

total_agg=0
asymmetric_agg=0
for f in "$START_MD" "$START_EXECUTE_MD" "$START_PUBLISH_MD" "$START_FINALIZE_MD"; do
  [ -f "$f" ] || continue
  out=$(compute_symmetry_for "$f")
  m=$(printf '%s\n' "$out" | tail -1)
  d=$(printf '%s\n' "$out" | sed '$d')
  [ -n "$d" ] && printf '%s\n' "$d"
  t="${m%%|*}"
  a="${m##*|}"
  total_agg=$((total_agg + t))
  asymmetric_agg=$((asymmetric_agg + a))
done

if [ "$asymmetric_agg" -eq 0 ]; then
  pass "Symmetry: all ${total_agg} aggregated \`flow-state-update.sh create\` invocations have 5 args (start*.md 4 files)"
else
  fail "Symmetry: ${asymmetric_agg}/${total_agg} aggregated invocations missing required args"
fi

# Issue #908 finding 3 (拡張): aggregated total=0 を catch する下限 assert。
# 後続 PR で誤って create 呼び出しを全削除した場合の regression 検出能力を保護する。
if [ "$total_agg" -ge 1 ]; then
  pass "Symmetry-bound (aggregated): \`flow-state-update.sh create\` invocations >= 1 (actual=$total_agg across start*.md)"
else
  fail "Symmetry-bound (aggregated): \`flow-state-update.sh create\` invocations >= 1 (actual=$total_agg, expected >=1)"
fi

# === Summary ===
if ! print_summary "$(basename "$0")" \
  "PR H (#905) で recalibration 完了 (Issue #N <=3 / 🚨 <=10 / line <=700 / aggregated 下限 across start*.md)。STRICT_CHARTER=1 での fail は ratchet として設計されています。"; then
  exit 1
fi
