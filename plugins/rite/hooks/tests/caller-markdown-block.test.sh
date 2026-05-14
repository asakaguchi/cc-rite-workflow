#!/bin/bash
# Caller markdown source-pin metatest (PR #688 verified-review cycle 39 G-01 / G-02 対応)
#
# Purpose:
#   commands/issue/start.md / commands/issue/implement.md / commands/pr/review.md 内に
#   含まれる state-read.sh 呼出 caller bash block について、以下を grep ベースで pin する:
#
#   G-01 (type validation pin):
#     parent_issue_number / loop_count を読む caller 3 箇所が `case "$X" in ''|*[!0-9]*) ... esac`
#     形式の type validation を持つことを確認する。validation を将来 revert / 削除した場合に
#     test が落ちて気付ける source-pin。
#
#   G-02 (`if !` anti-pattern revert 検出):
#     caller 6 箇所すべてが canonical `if cmd; then :; else rc=$?; fi` pattern を使い、
#     cycle 35 F-04 で empirical に bash spec 違反 ($? が常に rc=0) と判明した
#     `if ! var=$(bash {plugin_root}/hooks/state-read.sh ...)` 形式に revert されないことを pin する。
#     revert された場合 Issue #687 同型の silent regression を再導入するため fail-fast で検出する。
#
# Background:
#   Phase 1.2.0 / Phase 5 の caller markdown 内の inline bash block は run-tests.sh の通常テスト
#   対象ではない (markdown を grep するメタテスト)。手動レビュー依存だった部分を機械化する。
#
# Caller sites covered (8 箇所、verified-review F11-10 で resume.md を追加):
#   - commands/issue/start.md (4 箇所): Phase 3 (phase) / Phase 5.5.1 (phase) /
#     Phase 5.6 (phase) + Phase 5.7 (parent_issue_number)
#   - commands/issue/references/metrics-recording.md (1 箇所): Phase 5.5.2
#     (implementation_round inline metrics capture, cycle 41 II-1 確立 → Issue #901 PR E で
#     start.md から本 reference に SoT 移管)
#   - commands/issue/implement.md (1 箇所): Phase 5.1.2 (parent_issue_number)
#   - commands/pr/review.md (1 箇所): Phase 5.3.8 (loop_count)
#   - commands/resume.md (1 箇所): Phase 2.1 Step 1 (parent_issue_number_raw) — F11-10 で追加
# 注: 数値の真実の源は本ファイル内 TC-1.1〜TC-1.5 の grep count。docstring drift 防止のため
# verified-review cycle 44 F-07 で 6→7 に更新、verified-review F-14 で start.md Phase 5.1.2 表記を
# Phase 5.5.2 (implementation_round inline metrics capture) へ正確化 (cycle 43 F-12 + cycle 41 II-1 の
# semantic 整合)。F11-10 で 7→8 (resume.md F-02 caller 追加に伴う metatest 拡張)。Issue #901 PR E で
# start.md Phase 5.5.2 の implementation_round inline 形式を metrics-recording.md へ SoT 移管 (caller
# 数 5→4 に減少、新たに METRICS_RECORDING_MD constant を追加し TC-1.5 / TC-6 を当該ファイル対象に変更)。
#
# Type validation only applies to numeric fields (parent_issue_number / loop_count).
# `phase` は文字列のため type validation は不要 (3 箇所は本テストの type validation 対象外)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
COMMANDS_DIR="$PLUGIN_ROOT/commands"

START_MD="$COMMANDS_DIR/issue/start.md"
# PR G2 #904: Phase 5.5.1 / 5.6 / 5.7 caller bash block を start-finalize.md sub-skill へ SoT 移管
START_FINALIZE_MD="$COMMANDS_DIR/issue/start-finalize.md"
IMPLEMENT_MD="$COMMANDS_DIR/issue/implement.md"
REVIEW_MD="$COMMANDS_DIR/pr/review.md"
RESUME_MD="$COMMANDS_DIR/resume.md"
# Issue #901 PR E: implementation_round inline form を metrics-recording.md へ SoT 移管
METRICS_RECORDING_MD="$COMMANDS_DIR/issue/references/metrics-recording.md"

# === Test 1: caller bash block の存在確認 (regression 対策の前提) ===
echo "TC-1: state-read.sh 呼出 caller bash block の存在確認"

# start.md は 1 箇所 (Phase 3 のみ残存)
# cycle 43 F-12 LOW 対応: Phase 5.5.2 の plan_deviation_count metric capture を table cell から
# 別 bash code block へ分離した結果、caller 数が 4 → 5 に増えた。
# Issue #901 PR E: Phase 5.5.2 implementation_round inline 形式を metrics-recording.md へ SoT 移管
# した結果、start.md の caller 数が 5 → 4 に減った (TC-1.5 で metrics-recording.md の 1 箇所を別途検証)。
# PR G2 #904: Phase 5.5.1 / 5.6 / 5.7 caller を start-finalize.md へ SoT 移管した結果、
# start.md の caller 数が 4 → 1 に減った (TC-1.6 で start-finalize.md の 3 箇所を別途検証)。
start_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$START_MD" || true)
assert "TC-1.1: start.md の caller bash block は 1 箇所" "1" "$start_count"

# start-finalize.md は 3 箇所 (Phase 5.5.1 / 5.6 / 5.7) — PR G2 #904 で SoT 移管
start_finalize_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$START_FINALIZE_MD" || true)
assert "TC-1.6: start-finalize.md の caller bash block は 3 箇所" "3" "$start_finalize_count"

# implement.md は 1 箇所
implement_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$IMPLEMENT_MD" || true)
assert "TC-1.2: implement.md の caller bash block は 1 箇所" "1" "$implement_count"

# review.md は 1 箇所
review_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$REVIEW_MD" || true)
assert "TC-1.3: review.md の caller bash block は 1 箇所" "1" "$review_count"

# resume.md は 1 箇所 (F11-10 で追加: Phase 2.1 Step 1 parent_issue_number_raw)
resume_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$RESUME_MD" || true)
assert "TC-1.4: resume.md の caller bash block は 1 箇所" "1" "$resume_count"

# metrics-recording.md は 1 箇所 (Issue #901 PR E で start.md Phase 5.5.2 から SoT 移管:
# implementation_round inline form は本 reference の Step 1 セクション内に唯一存在)
metrics_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$METRICS_RECORDING_MD" || true)
assert "TC-1.5: metrics-recording.md の caller bash block は 1 箇所" "1" "$metrics_count"

# === Test 2: G-02 — `if !` anti-pattern revert 検出 ===
# cycle 35 F-04 で empirical に bash spec 違反と判明した形式が caller markdown に revert されないこと。
# 該当行: `if ! var=$(bash {plugin_root}/hooks/state-read.sh ...)`
echo ""
echo "TC-2: G-02 — \`if !\` anti-pattern (cycle 35 F-04 revert) が caller markdown に存在しないこと"

assert_not_grep "TC-2.1: start.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$START_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

assert_not_grep "TC-2.2: implement.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$IMPLEMENT_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

assert_not_grep "TC-2.3: review.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$REVIEW_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

assert_not_grep "TC-2.4: resume.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$RESUME_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

# === Test 3: G-02 — canonical pattern の存在確認 ===
echo ""
echo "TC-3: G-02 — canonical \`if cmd; then :; else rc=\$?; fi\` pattern の存在確認"

# canonical 直後 (else 節) に `rc=$?` を持つこと
# (start.md は phase で 1 箇所、start-finalize.md は 3 箇所、implement.md は 1 箇所、review.md は 1 箇所)
# PR G2 #904: parent_issue_number caller を start-finalize.md へ SoT 移管した結果、start.md は 1 箇所に
start_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$START_MD" || true)
assert "TC-3.1: start.md の canonical pattern (1 箇所) が存続" "1" "$start_canonical"

start_finalize_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$START_FINALIZE_MD" || true)
assert "TC-3.1b: start-finalize.md の canonical pattern (3 箇所) が存続" "3" "$start_finalize_canonical"

implement_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$IMPLEMENT_MD" || true)
assert "TC-3.2: implement.md の canonical pattern (1 箇所) が存続" "1" "$implement_canonical"

review_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$REVIEW_MD" || true)
assert "TC-3.3: review.md の canonical pattern (1 箇所) が存続" "1" "$review_canonical"

resume_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$RESUME_MD" || true)
assert "TC-3.4: resume.md の canonical pattern (1 箇所) が存続" "1" "$resume_canonical"

# === Test 4: G-01 — type validation pin (numeric field のみ対象) ===
# parent_issue_number / loop_count を読む caller 直後に
# `case "$X" in` (line N) + `  ''|*[!0-9]*)` (line N+1) の 2-line pattern が存在することを pin する。
# silent regression: validation 削除や `[!0-9]` パターン破損で shell injection 経路が無防備化する。
# grep -A 1 で `case "$X" in` の次行を取得し、それが `''|*[!0-9]*)` を含むかを別 grep で確認する。
echo ""
echo "TC-4: G-01 — type validation case 文の pin (parent_issue_number / loop_count)"

assert_2line_validation() {
  local label="$1"
  local file="$2"
  local var_name="$3"
  # case "$VAR" in の次行 (within 1 line) に `''|*[!0-9]*)` を持つことを pin
  local next_line
  next_line=$(grep -A 1 "case \"\\\$${var_name}\" in\$" "$file" | grep -E "^\s*''\|\*\[!0-9\]\*\)" || true)
  if [ -n "$next_line" ]; then
    pass "$label"
  else
    fail "$label (case \"\$${var_name}\" in の直後行に \`''|*[!0-9]*)\` が存在しない: $file)"
  fi
}

# start-finalize.md Phase 5.7: parent_issue_number (PR G2 #904 で start.md から SoT 移管)
assert_2line_validation "TC-4.1: start-finalize.md に parent_issue_number の type validation pattern が存在" \
  "$START_FINALIZE_MD" "parent_issue_number"

# implement.md Phase 5.1.2: parent_issue_number
assert_2line_validation "TC-4.2: implement.md に parent_issue_number の type validation pattern が存在" \
  "$IMPLEMENT_MD" "parent_issue_number"

# review.md Phase 5.3.8: loop_count
assert_2line_validation "TC-4.3: review.md に loop_count の type validation pattern が存在" \
  "$REVIEW_MD" "loop_count"

# resume.md Phase 2.1 Step 1: parent_issue_number_raw (F11-10 で追加)
# 注: resume.md は state-read.sh から取得した値を `parent_issue_number_raw` 変数で保持し、
# `case "$parent_issue_number_raw" in ...''|*[!0-9]*) parent_issue_number_raw=0 ;;` で type validation。
assert_2line_validation "TC-4.4: resume.md に parent_issue_number_raw の type validation pattern が存在" \
  "$RESUME_MD" "parent_issue_number_raw"

# === Test 5: type validation の defaulting 動作 pin ===
# validation がマッチした場合に変数を 0 (parent_issue_number / loop_count) または "" (phase) に降格すること。
# silent regression: validation 後に `default=999` 等にすり替わると後続の比較が壊れる。
echo ""
echo "TC-5: type validation の default 値 pin (numeric field は 0 に降格)"

assert_grep "TC-5.1: start-finalize.md の parent_issue_number validation が default 0 に降格する" \
  "$START_FINALIZE_MD" \
  'parent_issue_number=0'

assert_grep "TC-5.2: implement.md の parent_issue_number validation が default 0 に降格する" \
  "$IMPLEMENT_MD" \
  'parent_issue_number=0'

assert_grep "TC-5.3: review.md の loop_count validation が default 0 に降格する" \
  "$REVIEW_MD" \
  'loop_count=0'

# resume.md Phase 2.1 Step 1 (F11-10 で追加)
assert_grep "TC-5.4: resume.md の parent_issue_number_raw validation が default 0 に降格する" \
  "$RESUME_MD" \
  'parent_issue_number_raw=0'

# === Test 6: G-03 — inline form pin (verified-review cycle 41 II-1) ===
# Background: TC-1 / TC-2 / TC-3 は `^if` (行頭) に限定して caller block を pin する。
# 当初は start.md L1805 周辺の metrics 表内に inline 形式の caller が存在し、`^if` 限定 grep では
# 捕捉できない盲点を本 TC で塞いでいた。
# verified-review cycle 38 F-02 prose に「previous '6 / 7 caller sites' prose self-undercount-drifted
# twice」と明記されている通り、`implementation_round` field は過去 2 回 self-undercount drift を起こした
# 履歴があり、再発確率が高い field。
# Issue #901 PR E (refactor): start.md Phase 5.5.2 を metrics-recording.md へ SoT 移管。implementation_round
# inline form は本 reference の Step 1 セクション内に存続するため、TC-6 の対象を METRICS_RECORDING_MD に
# 切り替え (TC-1.5 と対をなす形で SoT 移管後の存続を検証する)。anti-pattern revert 検出 (`if !` 形式) と
# canonical capture pattern (`then :; else rc=$?`) の維持確認は SoT 移管後も同じく機能する。
echo ""
echo "TC-6: G-03 — metrics-recording.md inline form (implementation_round) pin (cycle 41 II-1, Issue #901 PR E で SoT 移管)"

# 6.1: inline form の caller が metrics-recording.md に存在すること
inline_count=$(grep -cE 'if val=\$\(bash \{plugin_root\}/hooks/state-read\.sh --field implementation_round' "$METRICS_RECORDING_MD" || true)
assert "TC-6.1: metrics-recording.md の implementation_round inline form (1 箇所) が存続" "1" "$inline_count"

# 6.2: inline form に `if !` anti-pattern が含まれていないこと (anti-pattern revert 検出)
assert_not_grep "TC-6.2: metrics-recording.md の implementation_round inline form に \`if !\` anti-pattern が無い" \
  "$METRICS_RECORDING_MD" \
  'if !\s+val=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh --field implementation_round'

# 6.3: inline form の canonical capture pattern が `; then :; else rc=$?;` を含むこと
# (else 節の rc capture が削除された場合に検出)
assert_grep "TC-6.3: metrics-recording.md の implementation_round inline form が canonical capture pattern を維持" \
  "$METRICS_RECORDING_MD" \
  'if val=\$\(bash \{plugin_root\}/hooks/state-read\.sh --field implementation_round.*then :; else rc=\$\?'

# 6.4: SoT 移管後の drift guard — start.md に implementation_round inline form が再度 introduce
# されていないこと (Issue #901 PR E で剥がした SoT を将来の編集で誤って再 inline 化する経路を遮断)
assert_not_grep "TC-6.4: start.md に implementation_round inline form が再 inline 化されていない (SoT drift guard)" \
  "$START_MD" \
  'if val=\$\(bash \{plugin_root\}/hooks/state-read\.sh --field implementation_round'

# === Test 7: G-04 — RESUME_HINT bit-identical drift detection (Issue #956) ===
# Background: PR #955 (Issue #954) で start-finalize.md 3 site に 207 文字の `RESUME_HINT:` echo を
# 追加した際、pre-condition-gate.md で 5 site canonical として規定されていたにも関わらず、他 4 site
# (start.md Phase 3 / implement.md Phase 5.1.2 / review.md Phase 5.3.8 / metrics-recording.md
# Phase 5.5.2) への対称化が漏れていた (PR #955 cycle 2 code-quality reviewer H-3/H-4 検出)。
# Issue #956 で pre-condition-gate.md Form A / Form B canonical block に `RESUME_HINT:` echo を SoT
# として SoT 化し、全 8 site (5 site canonical + 3 site 外延 = implement.md / review.md / resume.md)
# が bit-identical な本文を mirror する契約に拡張した。本 TC は引用符内の文字列が SoT と完全一致
# することを grep + 文字列比較で機械検証し、誤字 / synonym 置換 / 文末 punctuation drift / 追加・
# 削除等の片肺修正を即座に CI fail で検出する。
echo ""
echo "TC-7: G-04 — RESUME_HINT bit-identical drift detection (Issue #956)"

PRECONDITION_GATE_MD="$COMMANDS_DIR/issue/references/pre-condition-gate.md"

# 引用符 (double-quote " または backtick `) で囲まれた RESUME_HINT 本文を抽出する helper。
# Form A (`  echo "..."`) / Form B (`; echo "..." >&2;`) / prose backtick (line 114 `RESUME_HINT: ...`) の
# 3 形式すべてに対応する (PR #959 cycle 1 で line 114 backtick が drift detection 対象外だった指摘に対応)。
# Stage 1 (本 helper): 引用符込みで全形式を捕捉。Stage 2 (_strip_outer_quote): 外側引用符を除去して
# bit-identical 比較する。
extract_resume_hint_body() {
  grep -oE '["`]RESUME_HINT: state-read.sh が異常 exit[^"`]*["`]' "$1"
}

# 外側の double-quote または backtick を 1 文字ずつ除去する helper。
# Stage 2 (本 helper) で全形式の本文を統一形式に正規化してから SoT と比較する。
_strip_outer_quote() {
  sed 's/^["`]//; s/["`]$//'
}

# SoT silent abort 対策: `head -1` は SoT 抽出失敗時 (前段の grep が空入力で
# pipefail 等により非 0 exit) に command-substitution が非 0 を返し、set -euo pipefail 環境下では
# 後続の `[ -z "$sot_body" ]` check 到達前に test 全体が abort して TC-7.0 の fail メッセージが
# emit されない (silent abort)。`|| true` で吸収し、空文字列を保持して fail 経路に到達させる。
sot_raw=$(extract_resume_hint_body "$PRECONDITION_GATE_MD" | head -1 || true)
sot_body=$(printf '%s' "$sot_raw" | _strip_outer_quote)
if [ -z "$sot_body" ]; then
  fail "TC-7.0: SoT 文字列が pre-condition-gate.md から抽出できない (Form A canonical block の RESUME_HINT echo が見つからない)"
else
  pass "TC-7.0: SoT 文字列が pre-condition-gate.md から抽出できた"
fi

# pre-condition-gate.md 自身: SoT 内部 (Form A + Form B + line 114 backtick prose の 3 occurrence) が
# drift していないことを assert。Stage 2 で外側引用符を除去してから unique 数をカウントすることで、
# 「外側 quote は異なるが本文は同一」のケースを 1 種類として正しく集計する。
gate_bodies_raw=$(extract_resume_hint_body "$PRECONDITION_GATE_MD")
gate_bodies_stripped=$(printf '%s\n' "$gate_bodies_raw" | _strip_outer_quote)
gate_unique=$(printf '%s\n' "$gate_bodies_stripped" | sort -u | wc -l | tr -d ' ')
assert "TC-7.0b: pre-condition-gate.md 内 RESUME_HINT 本文が 1 種類 (Form A + Form B + line 114 backtick prose を含む 3 occurrence で drift なし)" "1" "$gate_unique"

# pre-condition-gate.md 内 RESUME_HINT 占有数の機械検証。
# Form A (line 55 double-quote) + Form B (line 69 double-quote) + line 114 backtick prose = 3 occurrence。
# 占有数を pin することで、将来 SoT 拡張や撤回時に drift を即座に検出できる。
gate_occurrence_count=$(printf '%s\n' "$gate_bodies_raw" | grep -c . || true)
assert "TC-7.0c: pre-condition-gate.md 内 RESUME_HINT 占有数 (3 occurrence: Form A + Form B + line 114 backtick prose)" "3" "$gate_occurrence_count"

# 各 caller の RESUME_HINT 本文を SoT と bit-identical 比較
# CQ-HIGH-2 対応: grep の 2 段階分離 (count 確認と drift 検出を独立化) で
# prefix drift も「count mismatch」ではなく明示的に「drift detected」として報告する。
# CQ-MEDIUM-1 対応: redundant `grep -c '"RESUME_HINT:'` を `wc -l` に簡素化 (extract_resume_hint_body
# 出力は既に RESUME_HINT 行のみのため再 count 不要)。
# CQ-LOW-1 対応: drift を `break` で最初の 1 件のみ報告する設計を改め、全 drift を蓄積して
# `{N}/{M} sites drifted` 形式で報告する。同一ファイル内 N site 全 drift 時の発見可能性を向上。
assert_caller_match() {
  local label="$1"
  local file="$2"
  local expected_count="$3"
  local bodies_raw count drift_count=0 drift_report=""
  bodies_raw=$(extract_resume_hint_body "$file" || true)
  # count: wc -l で簡素化 (bodies_raw が空なら 0 とする)
  if [ -z "$bodies_raw" ]; then
    count=0
  else
    count=$(printf '%s\n' "$bodies_raw" | wc -l | tr -d ' ')
  fi
  if [ "$count" != "$expected_count" ]; then
    fail "$label (RESUME_HINT 本文数 expected=$expected_count, actual=$count — count mismatch は missing / prefix drift / 想定外の追加箇所のいずれか)"
    return
  fi
  # 全 drift を蓄積して報告 (CQ-LOW-1 対応)
  local idx=0
  while IFS= read -r body_raw; do
    idx=$((idx + 1))
    [ -z "$body_raw" ] && continue
    local body_stripped
    body_stripped=$(printf '%s' "$body_raw" | _strip_outer_quote)
    if [ "$body_stripped" != "$sot_body" ]; then
      drift_count=$((drift_count + 1))
      drift_report="${drift_report}
  [$idx] $body_raw"
    fi
  done <<< "$bodies_raw"
  if [ "$drift_count" -gt 0 ]; then
    fail "$label (${drift_count}/${count} sites drifted from SoT:${drift_report}
  expected (stripped): $sot_body)"
  else
    pass "$label"
  fi
}

# 8 caller site の RESUME_HINT 本文が全て SoT と bit-identical を assert
# 注: 件数の真実の源は本 TC の expected_count 引数。caller 数変更時はここを更新する。
assert_caller_match "TC-7.1: start.md (Phase 3 pre-condition) RESUME_HINT が SoT bit-identical" "$START_MD" 1
assert_caller_match "TC-7.2: start-finalize.md (Phase 5.5.1/5.6/5.7) 3 site が SoT bit-identical" "$START_FINALIZE_MD" 3
assert_caller_match "TC-7.3: implement.md (Phase 5.1.2 parent_issue_number) RESUME_HINT が SoT bit-identical" "$IMPLEMENT_MD" 1
assert_caller_match "TC-7.4: review.md (Phase 5.3.8 loop_count) RESUME_HINT が SoT bit-identical" "$REVIEW_MD" 1
assert_caller_match "TC-7.5: resume.md (Phase 2.1 parent_issue_number_raw) RESUME_HINT が SoT bit-identical" "$RESUME_MD" 1
assert_caller_match "TC-7.6: metrics-recording.md (Phase 5.5.2 Form B implementation_round) RESUME_HINT が SoT bit-identical" "$METRICS_RECORDING_MD" 1

# Resume.md の「対処: helper の存在」legacy 形式が完全に消失していること (Issue #956 AC-3)
assert_not_grep "TC-7.8: resume.md から「対処: helper の存在」legacy 形式が消失している (Issue #956 AC-3)" \
  "$RESUME_MD" \
  '対処: helper の存在'

# === Summary ===
if ! print_summary "$(basename "$0")"; then
  exit 1
fi
exit 0
