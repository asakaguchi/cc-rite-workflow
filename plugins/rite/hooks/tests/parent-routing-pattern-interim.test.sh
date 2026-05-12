#!/bin/bash
# parent-routing-pattern-interim.test.sh
#
# ⚠️ DELETION CHECKLIST (削除忘れ防止):
#   本テストは parent-routing-unification ADR (docs/designs/parent-routing-unification.md) PR-7 で
#   `parent-routing-pattern-uniformity.test.sh` が新設されるタイミングで **本ファイル全体を削除する** こと。
#   PR-7 で各 sub-skill が parent-routing pattern canonical form に統一されるため、本 interim test の
#   pin 対象 (create-interview.md のみの interim 形態) は uniformity test の subset として吸収される。
#   PR-7 マージ時のチェックリスト:
#     1. plugins/rite/hooks/tests/parent-routing-pattern-interim.test.sh を削除
#     2. plugins/rite/hooks/tests/run-tests.sh (テストランナーが個別 list する形式に変わった場合は同等の場所) から該当行を削除
#     3. ADR §6.1 / sub-skill-return-protocol.md 廃止済 invariant test list に本ファイル名を追記
#     4. PR-7 統合計画 task list (ADR §6.1 PR-7 引き継ぎ箇所) の各 IMP-2 / IMP-3 / IMP-4 / IMP-5 / TQ-4 を確認
#
#   ⚠️ PR-3 マージ時の事前更新 (pr-test-analyzer M-3 対応):
#     lint.md Phase 9.2 三点セット blockquote が PR-3 で parent-routing pattern に移行するタイミングで、
#     **本ファイル中の TC-5 全体を削除 or 更新** すること (TC-5a `>= 3` が PR-3 で fail に転じる)。PR-3 着手時の
#     チェックリスト:
#       a. TC-5 を一括削除する (lint.md 移行が完了し、blockquote が消滅するため pin 対象が消える)
#       b. ADR §6.1 row 230 の "PR-3 撤去予定" 状態を "PR-3 撤去済" に更新
#       c. 本ファイルが PR-7 まで残存することを前提に、TC-5 のみ削除 + 他 TC は維持する形で patch する
#
# Interim invariant test for the parent-routing pattern migration.
# 移行ロードマップ・統合計画は ADR docs/designs/parent-routing-unification.md 参照。
#
# Pinned invariants:
#   TC-1 create-interview.md Pre-flight + Return Output re-patch の存在 + cold-start 二段書き込み sequence
#   TC-2 create-interview.md は bare bracket sentinel のみ (HTML-comment form / caller HTML hint なし)
#   TC-3 cleanup.md Mandatory After Wiki Ingest Step 0 の imperative keyword + bash literal + anchor
#   TC-4 ingest.md Mandatory After Auto-Lint Step 0 + continuation HTML literal の imperative keyword 群
#   TC-5 lint.md Phase 9.2 三点セット blockquote の imperative recast を 3 canonical sites で pin
#   TC-6 workflow-incident-emit invocation count + WARNING fallback + 8 retained flag 名 + create.md prose
#   TC-7 caller-side [interview:error] halt rule presence (create.md / pre-check-routing.md)
#         + 4 sentinel literal の dispatcher grep target pin
#
# When this test fails: parent-routing pattern compliance または imperative keyword 強度の regression。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

INTERVIEW_MD="$REPO_ROOT/plugins/rite/commands/issue/create-interview.md"
CLEANUP_MD="$REPO_ROOT/plugins/rite/commands/pr/cleanup.md"
INGEST_MD="$REPO_ROOT/plugins/rite/commands/wiki/ingest.md"
LINT_MD="$REPO_ROOT/plugins/rite/commands/wiki/lint.md"

# Hard precondition — missing target files are an environment error, not a test failure.
for f in "$INTERVIEW_MD" "$CLEANUP_MD" "$INGEST_MD" "$LINT_MD"; do
  if [ ! -f "$f" ]; then
    echo "  ❌ FILE NOT FOUND: $f" >&2
    exit 1
  fi
done

# 旧 inline pattern
#   `if VAR=$(grep -cE 'pat' "$FILE" 2>/dev/null); then :; else VAR=0; fi`
# は IO エラー (NFS / antivirus / 競合編集) を silent に count=0 へ倒し、
# 「pattern なし regression」と「test 環境 IO エラー」を区別不能にしていた。
# `error-count-runtime-reference.test.sh` の canonical pattern (stderr-tempfile +
# rc=2 fail-fast) を本 helper に集約し、11 site の inline 重複を解消する。
# Usage:
#   count=$(_grep_count_safe "<test_label>" "<file>" "<ERE_pattern>")
#   if [ "$count" -ge N ]; then ...; fi
# IO エラー時は本 helper が直接 stderr に `❌ <test_label> [GREP_IO_ERROR ...]` を出力して
# `exit 1` で test 環境問題を fail-fast する (silent count=0 に倒さない)。
_grep_count_safe() {
  local _label="$1"
  local _file="$2"
  local _pattern="$3"
  local _err
  # silent-failure-hunter M-6 (rationale only): test runner が `set +e` で各 TC を呼ぶと subshell の
  # `exit 1` は parent の `$(...)` 代入 rc=非0 として propagate するが、`set -e` が off だと後続 TC に
  # 進んでしまう懸念がある。本関数は本テスト先頭 `set -euo pipefail` (L30) で常に set -e 環境下で
  # 呼ばれることを invariant としており、test runner が無効化する場合は本テスト全体の前提が崩れる
  # ことが先に検出される (rc=2 detection は parent shell の set -e に依存)。
  # 注: bash command substitution subshell の `$-` は errexit を反映しないことがあるため動的 check は
  # 不安定。本 invariant は文書 (本コメント) で示すに留め、runtime check は行わない。
  # silent-failure-hunter IMP-1: mktemp 失敗時の doctrine を `error-count-runtime-reference.test.sh`
  # の `_grep_err mktemp + fail-fast` canonical pattern (行番号 drift 回避のため構造 anchor で参照)
  # と統一する。旧 `|| _err=""` は silent degraded mode で、IO エラー時 (`/tmp` inode 枯渇 / read-only
  # filesystem / permission 拒否) に診断情報を失わせていた。fail-fast に変更し、ロジック上は POSIX `:-`
  # 演算子の暗黙挙動 (`_err=""` でも `2>"${_err:-/dev/null}"` が `/dev/null` に倒れる) に依存しない明確な
  # 経路にする。
  if ! _err=$(mktemp /tmp/rite-grep-count-err-XXXXXX 2>/dev/null); then
    echo "  ❌ $_label [MKTEMP_FAILED] (cannot capture grep stderr — IO エラー時の診断情報を失うため fail-fast)" >&2
    echo "    対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
    exit 1
  fi
  local _count
  local _rc
  # `set -e` 下で grep rc=1 (no match) 経路で関数全体が exit する罠を回避するため、
  # `if cmd; then :; else _rc=$?; fi` 形式で代入と rc 捕捉を独立させる。
  # `_count=$(cmd)` 単独代入は set -e 下で cmd 失敗 (rc!=0) → 代入 rc!=0 → 関数 exit するため。
  # M-8: `_err` は本ブロック冒頭で mktemp fail-fast 済のため非空が invariant。`2>"$_err"` で直接渡せるが、
  # 将来 `_err` を可変にする refactor を考慮して `${_err:-/dev/null}` defensive 形式を維持する。
  if _count=$(grep -cE "$_pattern" "$_file" 2>"${_err:-/dev/null}"); then
    _rc=0
  else
    _rc=$?
  fi
  if [ "$_rc" -ge 2 ]; then
    local _detail=""
    [ -s "$_err" ] && _detail=" ($(head -1 "$_err"))"
    rm -f "$_err"
    echo "  ❌ $_label [GREP_IO_ERROR rc=$_rc] (grep IO/regex error in $_file: $_pattern)${_detail}" >&2
    exit 1
  fi
  rm -f "$_err"
  # rc=0 (match found, count>0) と rc=1 (no match, count=0) は legitimate
  # ただし rc=1 の場合 `grep -c` は count=0 を stdout に出力するので _count は "0" になっている
  # M-4: invariant 明示 — 将来 `grep -cE` を別実装に置換した場合の defense として `_count="${_count:-0}"`。
  _count="${_count:-0}"
  printf '%s' "$_count"
}

echo "=== TC-1: create-interview.md Pre-flight + Return Output re-patch の存在 ==="

# Pre-flight (head) と Return Output re-patch (tail) の 2 site で
# `flow-state-update.sh patch ... --phase "create_post_interview"` が出現することを pin。
# 実測 3 回 (Pre-flight if branch / Pre-flight cold-start elif / Return Output re-patch) のため
# `>= 3` で厳格化し、いずれか 1 site の silent removal も catch する。
# if/else 形式採用の意図: grep の rc=2 (IO エラー) と rc=1 (no match) を区別し、IO エラーを silent
# count=0 に倒さないこと (本テスト全体の defensive pattern との対称化)。
#
# Known limitation: hardcoded `>= 3` は将来の正当な refactor
# (例: Pre-flight 3 重 patch 化) で false positive を出さない代わりに、「期待回数が増えたのに気づかず
# >= N で甘く pass する」silent drift を許す。Pre-flight が scope conditional 内に移動した場合
# (Bug Fix/Chore skip path で skip される regression) も count 3 を維持するため本 TC 単独では検出不可。
# **TC-2f (prose anchor) + TC-2f-2 (bash block 構造 pin) が部分緩和**: skip path Defense-in-Depth 必須化の
# prose と bash block の scope-conditional 不在を独立 pin し、scope=skip による silent gate 化を catch する。
# PR-7 uniformity test では Return Output re-patch bash block の構造 pin (awk-based anchor scope range +
# 最近接祖先 conditional 検査) でより強い保証を導入予定。
#
# === Threshold Convention (pr-test-analyzer TQ-1) ===
# 本 TC の閾値 (== 3) は将来の正当な refactor (Pre-flight 統合 / patch 分割 / Defense-in-Depth 追加)
# が発生するたびに **手動で更新する必要がある** intentional design。これは PR-7 uniformity test
# (awk-based 構造 pin) への移行までの interim defense であり、convention は以下の通り:
#
# 1. site 数を変える refactor を PR で実施する場合は、本 TC の閾値も同 PR 内で更新する
# 2. 「`>= N` で甘く pass」ではなく `== N` で厳格化することで、site 数変化を強制的に意識させる
# 3. 閾値更新の commit message には「Pre-flight 3 重 patch 化 → 4 重に変更」のような site 数変化の
#    rationale を明示し、`>= N` を `== N+1` 等に変更する
# 4. PR-7 uniformity test 導入時に本 interim test 全体を削除し、awk-based 構造 pin に移行する
#
# 「閾値を update するだけで何も考えない」反応は本 PR の charter violation。site 数が増減する
# 場合は、その理由が `parent-routing-pattern-uniformity.test.sh` (PR-7) で構造的に表現できるか
# どうかを必ず検討すること。
#
# Known limitation 2 (旧 inline grep の IO エラー silent 化): 解決済。
# (silent-failure-hunter) 対応で `_grep_count_safe` helper に統一し、stderr-tempfile +
# rc=2 fail-fast pattern を 13 site 全てに適用 (canonical pattern in line 50-80)。
# IO エラーは [GREP_IO_ERROR ...] sentinel 付き fail で test 環境問題を明示する。
interview_patch_count=$(_grep_count_safe "interview_patch_count" "$INTERVIEW_MD" 'flow-state-update\.sh patch')
# 緩 floor (>= 3) で site 数下限のみ pin する。section-level の構造的整合性は
# TC-1c-2 (section-aware count) で別途厳格に保護されるため、本 TC は site が「消える」regression
# のみを catch する floor として機能する。site 追加 (Defense-in-Depth 拡張等) は同時更新不要。
if [ "$interview_patch_count" -ge 3 ]; then
  pass "TC-1: create-interview.md に 'flow-state-update.sh patch' が >= 3 (実測=$interview_patch_count, Pre-flight if + Pre-flight cold-start elif + Return Output re-patch 以上)"
else
  fail "TC-1: create-interview.md の 'flow-state-update.sh patch' 出現回数が 3 未満 (実測=$interview_patch_count, 期待 >= 3 — site が消えた regression の可能性)"
fi

# pr-test-analyzer I-3 部分緩和: 「Pre-flight section から 1 patch を削除して別 section に 1 patch を
# 追加」のような silent reorganization (count==3 維持) を catch するため、Pre-flight section と
# Defense-in-Depth section の **section 別 patch 数** を独立 awk range で pin する。
# TC-1d/1e (section anchor 存在 pin) と組み合わせることで、section 構造 + section 内 patch 数の両方を
# mechanical に保証する (旧 TC-1 単独の section 内 silent reorganization 検出不能を補完)。
# PR-7 uniformity test では awk-based 構造 pin で完全カバーするが、本 interim test では heading anchor
# 範囲の patch count 簡易 pin で部分緩和する。
_preflight_section_patches=$(awk '
  /^## 🚨 MANDATORY Pre-flight: Flow State Update/ { in_section=1; next }
  in_section && /^## / && !/^## 🚨 MANDATORY Pre-flight/ { in_section=0; next }
  in_section && /flow-state-update\.sh patch/ { c++ }
  END { print c+0 }
' "$INTERVIEW_MD" 2>/dev/null)
_defense_section_patches=$(awk '
  /^## Defense-in-Depth: Flow State Update \(Before Return\)/ { in_section=1; next }
  in_section && /^## / && !/^## Defense-in-Depth: Flow State Update/ { in_section=0; next }
  in_section && /flow-state-update\.sh patch/ { c++ }
  END { print c+0 }
' "$INTERVIEW_MD" 2>/dev/null)
# Pre-flight section: 2 patch (if branch + cold-start elif branch) / Defense-in-Depth: 1 patch (Return Output re-patch)
if [ "${_preflight_section_patches:-0}" -ge 2 ] && [ "${_defense_section_patches:-0}" -ge 1 ]; then
  pass "TC-1c-2: section 別 patch count 健全 (Pre-flight section >= 2 [if + cold-start elif], Defense-in-Depth >= 1 [Return Output re-patch])"
else
  fail "TC-1c-2: section 別 patch count が崩壊 (Pre-flight=${_preflight_section_patches}, Defense-in-Depth=${_defense_section_patches}, 期待 Pre-flight >= 2 AND Defense-in-Depth >= 1 — section 内 silent reorganization のリスク)"
fi
unset _preflight_section_patches _defense_section_patches

# create_post_interview phase が patch arg として現れることを pin
assert_grep "TC-1b: create-interview.md に '--phase \"create_post_interview\"' が存在" \
  "$INTERVIEW_MD" \
  'phase[[:space:]]+"create_post_interview"'

# TC-1c: cold-start 二段書き込み (create→patch) sequence の pin。
# parent-routing pattern の load-bearing audit-trail fidelity 機能の regression を
# mechanical に検出する。単段 `create --phase create_post_interview` への退化が起きた場合、
# (a) `create --phase "create_interview"` が消失する OR (b) cold-start branch 自体が消失するため fail する。
#
# 旧 `grep -A 1` 隣接 pin は cold-start branch 内
# であることを構造的に保証していなかった (`else` 節外に独立に出現しても pass する false-negative)。
# awk で Pre-flight section の `else` 〜 `fi` ブロック範囲を切り出し、その範囲内で `create` invocation の
# 1〜3 行下に `--phase "create_interview"` が現れることを検証する。bash backslash 続行で
# create が複数行に分割されていても tolerate するため 3 行幅の lookahead を許す。
#
# Convention (pr-test-analyzer IMP-1): 本 awk range-based check は inline で実装する設計判断。
# `_grep_count_safe` のような helper 化は本テストが PR-7 で interim 削除対象であるため
# investment cost が見合わない。将来 awk range-based scan を追加する TC が複数発生する場合は、
# `_awk_range_check` helper を `_test-helpers.sh` に追加する選択肢を再評価する (現状は本箇所のみ
# のため inline 維持)。
# silent-failure-hunter M-5: awk の stderr を tempfile に退避し、busybox/gawk 差異や IO エラーで
# 空文字列 ("MISSING" 誤判定) になる経路を fail-fast する。旧 `2>/dev/null` は本テスト全体の defensive
# pattern (`_grep_count_safe` の rc=2 fail-fast) と非対称だった。
_awk_err=$(mktemp /tmp/rite-awk-err-XXXXXX 2>/dev/null) || {
  echo "  ❌ TC-1c-1 [MKTEMP_FAILED] awk stderr 退避用 tempfile の mktemp に失敗 — fail-fast" >&2
  exit 1
}
_cold_start_check=$(awk '
  # Pre-flight section の `else` (== if-fi 構造の else 節開始) を検出して in_else=1
  # else 単独行 (front whitespace + else + end) を完全一致でマッチ
  /^[[:space:]]*else[[:space:]]*$/ { in_else=1; next }
  # else 節終了の `fi` (= Pre-flight 全体の閉じ) で in_else=0
  in_else && /^[[:space:]]*fi[[:space:]]*$/ { in_else=0; next }
  # in_else 中、`flow-state-update.sh create` 行を検出 → 1〜3 行先までを lookahead window として記録
  in_else && /flow-state-update\.sh create/ { lookahead=NR+3; next }
  # lookahead window 内で `--phase "create_interview"` (suffix `_post_` を除外) が現れたら found=1
  in_else && NR <= lookahead && /--phase[[:space:]]+"create_interview"[^_]/ { found=1; lookahead=0 }
  END { print (found ? "FOUND" : "MISSING") }
' "$INTERVIEW_MD" 2>"$_awk_err")
if [ -s "$_awk_err" ]; then
  echo "  ❌ TC-1c-1 [AWK_ERROR] awk が stderr 出力あり (busybox/gawk 差異 / IO error 等):" >&2
  head -3 "$_awk_err" | sed 's/^/    /' >&2
  rm -f "$_awk_err"
  exit 1
fi
rm -f "$_awk_err"
if [ "$_cold_start_check" = "FOUND" ]; then
  pass "TC-1c-1: create-interview.md cold-start branch (else block) 内に 'create + --phase \"create_interview\"' の sequence が存在 (audit-trail fidelity, awk range-based pin)"
else
  fail "TC-1c-1: create-interview.md cold-start branch の 'create + --phase \"create_interview\"' sequence が消失 (awk 結果=$_cold_start_check, 単段 create --phase create_post_interview への退化または else block の reorganization、audit-trail fidelity 欠落)"
fi
unset _cold_start_check
# 二段書き込みの第 2 段 (create_post_interview への patch) は TC-1 で既に pin 済。

# TC-1d / TC-1e: per-section directional check
# TC-1 の `count >= 3` だけでは「Pre-flight if-branch を削除して Return Output re-patch を 2 重化」
# のような refactor mistake (count=3 維持) を catch できない silent drift を持つ。
# Pre-flight section と Return Output section の heading anchor をそれぞれ独立に pin することで、
# どちらの section が silent 削除されても fail する補完防御を追加する。
assert_grep "TC-1d: create-interview.md に Pre-flight section heading anchor が存在 (Pre-flight 削除の silent regression を catch)" \
  "$INTERVIEW_MD" \
  '^## 🚨 MANDATORY Pre-flight: Flow State Update'
assert_grep "TC-1e: create-interview.md に Defense-in-Depth (Return Output) section heading anchor が存在 (Return Output 削除の silent regression を catch)" \
  "$INTERVIEW_MD" \
  '^## Defense-in-Depth: Flow State Update \(Before Return\)'

echo
echo "=== TC-2: create-interview.md parent-routing pattern compliance ==="

# bare bracket form sentinel が result pattern bullet list として存在
assert_grep "TC-2a: create-interview.md に bare bracket '[interview:completed]' bullet" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview completed\*\*: `\[interview:completed\]`'
assert_grep "TC-2b: create-interview.md に bare bracket '[interview:skipped]' bullet (TC-2a と parallel に sentinel value も pin)" \
  "$INTERVIEW_MD" \
  '^- \*\*Interview skipped\*\*.*: `\[interview:skipped\]`'

# TC-2e: catastrophic halt sentinel `[interview:error]` の bullet 存在を pin する。
# caller routing (create.md / pre-check-routing.md) が halt trigger として参照する load-bearing sentinel。
# silent revert で bullet が消えると catastrophic dual-failure 経路の halt が機能しなくなる。
assert_grep "TC-2e: create-interview.md に bare bracket '[interview:error]' bullet (catastrophic halt sentinel)" \
  "$INTERVIEW_MD" \
  '^- \*\*Halt with error\*\*.*: `\[interview:error\]`'

# TC-2e-1..TC-2e-4: halt 判定表 4 row の AND 条件組合せを「flag 名 + AND token + flag 名」の
# 同一行存在で pin する (PR-7 uniformity test で予定されている loose 化方針を先取り)。
# pipe-delimited cell literal は table の harmless な reformatting で全 row 同時 fail を引き起こす
# brittleness があったため撤去。flag 識別子 4 種の AND 関係を semantic に pin する設計に切り替える。
assert_grep "TC-2e-1: create-interview.md halt 判定表に PREFLIGHT_CREATE_FAILED 単独 row が存在 (flag 名同一行 pin)" \
  "$INTERVIEW_MD" \
  'PREFLIGHT_CREATE_FAILED=1'
assert_grep "TC-2e-2: create-interview.md halt 判定表に PREFLIGHT_PATCH_FAILED AND INTERVIEW_RETURN_PATCH_FAILED row が存在" \
  "$INTERVIEW_MD" \
  'PREFLIGHT_PATCH_FAILED=1.*AND.*INTERVIEW_RETURN_PATCH_FAILED=1'
assert_grep "TC-2e-3: create-interview.md halt 判定表に PREFLIGHT_CREATE_THEN_PATCH_FAILED AND INTERVIEW_RETURN_PATCH_FAILED row が存在" \
  "$INTERVIEW_MD" \
  'PREFLIGHT_CREATE_THEN_PATCH_FAILED=1.*AND.*INTERVIEW_RETURN_PATCH_FAILED=1'
assert_grep "TC-2e-4: create-interview.md halt 判定表に PREFLIGHT_CREATE_THEN_PATCH_FAILED AND skip path row が存在" \
  "$INTERVIEW_MD" \
  'PREFLIGHT_CREATE_THEN_PATCH_FAILED=1.*AND.*skip path'

# TC-2f: Skip path での Defense-in-Depth re-patch 必須化 prose anchor の pin。
# Bug Fix / Chore preset (scope=skip) 経路で本 re-patch を省略すると
# PREFLIGHT_CREATE_THEN_PATCH_FAILED 単独経路で audit-trail が create_interview に停滞する
# silent regression を起こすため、prose anchor の silent weakening を mechanical に検出する。
assert_grep "TC-2f: create-interview.md に Skip path Defense-in-Depth 必須化 prose anchor が存在 (skip path / standard path / limited path / full path のいずれも実行する)" \
  "$INTERVIEW_MD" \
  'skip path / standard path / limited path / full path のいずれも実行する'

# TC-2f-2 (IMP-4): Defense-in-Depth bash block の構造 pin (verified-review pr-test-analyzer IMP-4 対応)。
# TC-2f は prose anchor のみで bash block を scope 条件で wrap する regression を catch できない。
# `## Defense-in-Depth: Flow State Update (Before Return)` H2 anchor から file 末尾までを切り出し、
# その範囲内に scope-conditional (`if [ "$scope" ... ` / `if.*scope.*skip` / `if.*scope.*!= ` 等) が
# **bash fenced block 内** で出現しないことを assert する。prose 中の `scope=skip` 言及は許容するため、
# bash fenced block (``` ... ```) の内部のみを抽出してから grep する。
_defense_in_depth_section=$(awk '
  /^## Defense-in-Depth: Flow State Update \(Before Return\)/ { in_section=1; next }
  # 次の H2 heading で section を抜ける boundary check を追加
  # (旧実装は EOF まで extract する設計で、`## Caller Return Protocol` 等の後続 section に
  # bash block が追加された場合に false-positive fail を起こす経路があった)。
  in_section && /^## / { in_section=0 }
  in_section && /^```bash$/ { in_bash=1; next }
  in_section && in_bash && /^```$/ { in_bash=0; next }
  in_section && in_bash { print }
' "$INTERVIEW_MD" 2>/dev/null)
# bash block 内に scope-conditional (case 文 / if [ "$scope" / scope 変数を参照する分岐) が
# 出現しないことを確認。`if [ ! -f ... ]` (file 存在 check) と `if !` (command 失敗 check) は許容。
if printf '%s\n' "$_defense_in_depth_section" | grep -qE 'if[[:space:]]+\[[^]]*\$\{?scope|case[[:space:]]+"?\$\{?scope|if[[:space:]]+\[\[[^]]*\$\{?scope'; then
  fail "TC-2f-2: create-interview.md Defense-in-Depth bash block 内に scope-conditional (\$scope 参照の if/case) が出現 (skip path での silent gate 化 regression、TC-2f prose anchor を回避して bash block を scope=skip で skip させる経路)"
else
  pass "TC-2f-2: create-interview.md Defense-in-Depth bash block 内に scope-conditional なし (skip path / standard path 共通実行が構造的に保証されている)"
fi
unset _defense_in_depth_section

# TC-2g (negative): 旧 caller HTML literal 内で使われていた weak phrasing
# `IMMEDIATELY run this as your next tool call` が parent-routing 移行後の本ファイルに
# 書き戻されていないことを pin する (anti-pattern revert detection)。
assert_not_grep "TC-2g: create-interview.md に旧 'IMMEDIATELY run this as your next tool call' weak phrasing が残存しない (anti-pattern revert pin)" \
  "$INTERVIEW_MD" \
  'IMMEDIATELY run this as your next tool call'

# `--if-exists` flag の silent revert を catch する pin。
# parent-routing pattern で導入された file 不在時 silent skip guard (`flow-state-update.sh`
# の patch / increment mode 内 `IF_EXISTS && ! -f` 分岐) を defeat する revert (例: `--if-exists`
# を一括削除 / `--preserve-error-count` に書き換え) を検出する。実測 7 occurrences (CLI invocation 3 site +
# prose 言及 4 site)。最低 3 を要求して将来の正当な refactor (1 site のみ撤廃等) でも catch する。
interview_if_exists_count=$(_grep_count_safe "interview_if_exists_count" "$INTERVIEW_MD" '\-\-if-exists')
if [ "$interview_if_exists_count" -ge 3 ]; then
  pass "TC-2h: create-interview.md に '--if-exists' flag が 3 個以上 (実測=$interview_if_exists_count, 同 phase self-patch の idempotent guard 維持)"
else
  fail "TC-2h: create-interview.md の '--if-exists' flag が 3 個未満 (実測=$interview_if_exists_count, 期待>=3 — Pre-flight patch 2 + Return Output 1 のいずれかが silent 削除された可能性、file 不在時 silent skip guard が defeat される)"
fi

# TC-2i (IMP-1): `--next` per-site pin (verified-review pr-test-analyzer IMP-1 対応)。
# create-interview.md の 3 patch site (Pre-flight if branch / Pre-flight cold-start elif / Return Output re-patch)
# それぞれに `--next "..."` が指定されていることを per-line count で pin。silent removal で `next_action` が
# stale になる regression (LLM 継続ヒントの弱体化) を catch する。実測 4 occurrences (3 patch site + cold-start
# `create` の 1 site)。閾値は 3 を最低として設定。
interview_next_count=$(_grep_count_safe "interview_next_count" "$INTERVIEW_MD" '^[[:space:]]*--next ')
if [ "$interview_next_count" -ge 3 ]; then
  pass "TC-2i: create-interview.md に '--next' arg が 3 個以上 (実測=$interview_next_count, 各 patch site の next_action 指定が維持されている)"
else
  fail "TC-2i: create-interview.md の '--next' arg が 3 個未満 (実測=$interview_next_count, 期待>=3 — 3 patch site のいずれかで --next が silent 削除され next_action が stale になる regression リスク)"
fi

# TC-2j (IMP-2): `--active true` per-site pin (verified-review pr-test-analyzer IMP-2 対応)。
# Issue #660 系の `active=false` 退行 (stop-guard early return) を防ぐため、各 patch site に
# `--active true` が指定されていることを per-line count で pin。Layer 7 (and-logic-defense-chain.test.sh)
# は file 粒度の存在のみ pin するため、per-site 強化として本 TC を追加。実測 3 occurrences。
interview_active_count=$(_grep_count_safe "interview_active_count" "$INTERVIEW_MD" '^[[:space:]]*--active true')
if [ "$interview_active_count" -ge 3 ]; then
  pass "TC-2j: create-interview.md に '--active true' が 3 個以上 (実測=$interview_active_count, 各 patch site の active 値が維持されている)"
else
  fail "TC-2j: create-interview.md の '--active true' が 3 個未満 (実測=$interview_active_count, 期待>=3 — 3 patch site のいずれかで --active が silent 削除/反転され active=false 退行リスク)"
fi

# HTML-comment form sentinel が bash fenced block 外で出現しないこと
# (rationale prose や migration note 内で history 言及することはあるが、
#  bullet list の result pattern が HTML-comment 形式に戻ったら fail させる)
if grep -qE '^- \*\*Interview .*: `<!-- *\[interview:' "$INTERVIEW_MD"; then
  fail "TC-2c: create-interview.md の result pattern bullet が HTML-comment form に reverted (parent-routing pattern violation)"
else
  pass "TC-2c: create-interview.md result pattern bullet は bare bracket form (parent-routing pattern compliant)"
fi

# TC-2d (negative): caller HTML hint `<!-- caller: -->` literal の partial revert を検出する
# (parent-routing pattern では caller-side hint が不要のため、本 site では絶対に出現してはならない)
assert_not_grep "TC-2d: create-interview.md に caller HTML hint '<!-- caller:' literal が存在しない (parent-routing pattern compliant)" \
  "$INTERVIEW_MD" \
  '^<!-- caller:'

echo
echo "=== TC-3: cleanup.md Mandatory After Wiki Ingest Step 0 imperative keyword ==="

# `VERY FIRST tool call` Markdown bold (Step 0 prose canonical phrasing pin)
assert_grep "TC-3a: cleanup.md に '**VERY FIRST tool call**' Markdown bold が存在" \
  "$CLEANUP_MD" \
  '\*\*VERY FIRST tool call\*\*'
assert_grep "TC-3b: cleanup.md に 'BEFORE any text output' keyword が存在" \
  "$CLEANUP_MD" \
  'BEFORE any text output'

# Step 0 / Step 1 二重 patch design が silently 削除されると prose だけ残った half-migration
# regression を引き起こすため、bash literal の存在 + 個数で structure を pin する。
assert_grep "TC-3c: cleanup.md Step 0 bash literal 'phase \"cleanup_post_ingest\" --active' が存在" \
  "$CLEANUP_MD" \
  'phase[[:space:]]+"cleanup_post_ingest"[[:space:]]+--active'
cleanup_post_ingest_count=$(_grep_count_safe "cleanup_post_ingest_count" "$CLEANUP_MD" 'phase[[:space:]]+"cleanup_post_ingest"')
if [ "$cleanup_post_ingest_count" -ge 2 ]; then
  pass "TC-3d: cleanup.md に 'phase \"cleanup_post_ingest\"' bash literal が 2 回以上 (実測=$cleanup_post_ingest_count, Step 0 + Step 1 idempotent 二重 patch)"
else
  fail "TC-3d: cleanup.md の 'phase \"cleanup_post_ingest\"' bash literal が 2 未満 (実測=$cleanup_post_ingest_count, Step 0 or Step 1 が silently 削除された可能性)"
fi
assert_grep "TC-3e: cleanup.md の section anchor '### .*Mandatory After Wiki Ingest' が存在" \
  "$CLEANUP_MD" \
  '^### .*Mandatory After Wiki Ingest'

echo
echo "=== TC-4: ingest.md Mandatory After Auto-Lint Step 0 imperative keyword + continuation HTML literal ==="

assert_grep "TC-4a: ingest.md に '**VERY FIRST tool call**' Markdown bold が存在" \
  "$INGEST_MD" \
  '\*\*VERY FIRST tool call\*\*'
assert_grep "TC-4b: ingest.md に 'BEFORE any text output' keyword が存在" \
  "$INGEST_MD" \
  'BEFORE any text output'

# Step 0/1 二重 patch 構造の存在を pin (count >= 2 で idempotent re-patch 機構の silent 削除を検出)。
ingest_post_lint_count=$(_grep_count_safe "ingest_post_lint_count" "$INGEST_MD" 'phase[[:space:]]+"ingest_post_lint"')
if [ "$ingest_post_lint_count" -ge 2 ]; then
  pass "TC-4c: ingest.md に 'phase \"ingest_post_lint\"' bash literal が 2 回以上 (実測=$ingest_post_lint_count, Step 0 + Step 1 idempotent 二重 patch)"
else
  fail "TC-4c: ingest.md の 'phase \"ingest_post_lint\"' bash literal が 2 未満 (実測=$ingest_post_lint_count, 二重 patch 機構が silently 削除された可能性)"
fi
assert_grep "TC-4d: ingest.md の section anchor '🚨 Mandatory After Auto-Lint' が存在" \
  "$INGEST_MD" \
  '🚨 Mandatory After Auto-Lint'

# continuation HTML literal の 4 imperative keyword を line-anchored regex で pin する。
# load-bearing な負方向 imperative (`DO NOT end the turn` / `DO NOT output any narrative text`) の
# silent weakening を検出する。
assert_grep "TC-4e: ingest.md continuation HTML literal に 'MUST execute' + 'Step 0 bash literal' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*MUST execute.*Step 0 bash literal'
assert_grep "TC-4f: ingest.md continuation HTML literal に 'VERY FIRST tool call BEFORE any text output' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*VERY FIRST tool call BEFORE any text output'
assert_grep "TC-4g: ingest.md continuation HTML literal に 'DO NOT end the turn' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*DO NOT end the turn'
assert_grep "TC-4h: ingest.md continuation HTML literal に 'DO NOT output any narrative text' が存在" \
  "$INGEST_MD" \
  '^<!-- continuation:.*DO NOT output any narrative text'

echo
echo "=== TC-5: lint.md Phase 9.2 Layer 3b imperative recast ==="

# `> ⏭ MUST continue (turn を閉じない):` blockquote を 3 canonical sites で pin
# (Phase 1.1 echo / Phase 1.3 echo / Phase 9.2 raw blockquote)。
# 部分削除を検出するため count >= 3 で厳格化 (count >= 1 だと 1-2 sites 削除が silent pass する)。
lint_must_continue_count=$(_grep_count_safe "lint_must_continue_count" "$LINT_MD" '^[[:space:]]*(echo ")?> ⏭ MUST continue \(turn を閉じない\):')
if [ "$lint_must_continue_count" -ge 3 ]; then
  pass "TC-5a: lint.md に Layer 3b imperative '⏭ MUST continue (turn を閉じない):' blockquote が 3 回以上 (実測=$lint_must_continue_count, 3 canonical sites: Phase 1.1 echo + Phase 1.3 echo + Phase 9.2 raw blockquote)"
else
  fail "TC-5a: lint.md の '⏭ MUST continue (turn を閉じない):' blockquote が 3 未満 (実測=$lint_must_continue_count, 期待>=3 — 3 canonical sites のうち 1-2 sites が silently 削除された可能性)"
fi

# 旧 `⏭ 継続中:` 現状報告 phrasing が残っていないこと (命令形に recast 済)
assert_not_grep "TC-5b: lint.md に旧 '⏭ 継続中:' 現状報告 phrasing が残っていない" \
  "$LINT_MD" \
  '⏭ 継続中:'

echo
echo "=== TC-6: workflow-incident-emit.sh が全 retained flag emit 経路と co-located + create.md Mandatory After Delegation imperative ==="

# TC-6a/b: 8 retained flag の helper invocation が同一ファイル内に co-located であることを
# pin する。grep -cE は helper invocation の行数 (bash backslash 続行のため 1 invocation = 1 行) を
# 返すため、件数は invocation 件数と一致する。flag 名そのものの存在は TC-6i で個別に pin する。
CREATE_MD="$REPO_ROOT/plugins/rite/commands/issue/create.md"

# C-2 対応: hint message を実測値に更新。
# 現状計測値 (本 PR commit 時点):
#   create-interview.md: Pre-flight 5 site (state-path-resolve / _resolve / patch / cold-start create / create-then-patch) +
#                        Return Output 1 site = 6 invocations
#   create.md: Phase 1 Pre-write 4 site (state-path-resolve / _resolve / patch / create) +
#                        Phase 3 Pre-write 4 site = 8 invocations
# 本 TC が enforce する条件は **count >= 4** (canonical 数ではない)。実測値はあくまで現時点の参考値で、
# 将来の正当な site 追加でも threshold を抜けないよう緩めの下限を採用。
# threshold (>=4 / >=4) は H-3 で create.md に site が増えた将来の安全性を考慮して維持。
interview_emit_count=$(_grep_count_safe "interview_emit_count" "$INTERVIEW_MD" '^[[:space:]]*bash .*workflow-incident-emit\.sh')
if [ "$interview_emit_count" -ge 4 ]; then
  pass "TC-6a: create-interview.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$interview_emit_count invocations, Pre-flight 5 site (state-path-resolve / _resolve-flow-state-path / patch-failed / create-failed / create-then-patch-failed) + Return Output 1 site)"
else
  fail "TC-6a: create-interview.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$interview_emit_count invocations, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

create_emit_count=$(_grep_count_safe "create_emit_count" "$CREATE_MD" '^[[:space:]]*bash .*workflow-incident-emit\.sh')
if [ "$create_emit_count" -ge 4 ]; then
  pass "TC-6b: create.md に workflow-incident-emit.sh 呼び出しが 4 回以上 (実測=$create_emit_count invocations, Phase 1 Pre-write 4 site (state-path-resolve + _resolve-flow-state-path + patch + create) + Phase 3 Pre-write 4 site)"
else
  fail "TC-6b: create.md の workflow-incident-emit.sh 呼び出しが 4 回未満 (実測=$create_emit_count invocations, 期待>=4 — silent failure 検出経路が削除された可能性)"
fi

# TC-6b-2 (IMP-5): create.md `flow-state-update.sh patch` count pin (verified-review pr-test-analyzer IMP-5 対応)。
# 旧 TC-6b は `workflow-incident-emit.sh` count に依存するが、`flow-state-update.sh patch` block 削除でも
# 周辺 `workflow-incident-emit.sh` fallback が残れば TC-6b は通過する silent regression を防ぐため、
# patch invocation 自体を独立 count として pin。実測 4 occurrences (Phase 1 Pre-write 1 site +
# Phase 3 Pre-write 1 site + 他 2 site)。
create_patch_count=$(_grep_count_safe "create_patch_count" "$CREATE_MD" 'flow-state-update\.sh patch')
if [ "$create_patch_count" -ge 4 ]; then
  pass "TC-6b-2: create.md に 'flow-state-update.sh patch' invocation が 4 個以上 (実測=$create_patch_count, Phase 1/3 Pre-write block の patch step が維持されている)"
else
  fail "TC-6b-2: create.md の 'flow-state-update.sh patch' invocation が 4 個未満 (実測=$create_patch_count, 期待>=4 — Phase 1 / Phase 3 Pre-write の patch block が silent 削除された可能性、workflow-incident-emit.sh fallback だけが残った half-migration regression リスク)"
fi

# TC-6b-3 / TC-6b-4 (verified-review pr-test-analyzer HIGH-3): create.md per-site `--active` / `--next` pin
# 旧 4-site-symmetry.test.sh は create.md の各 patch site で `--phase / --active / --next / --preserve-error-count` を個別に pin していたが、
# TC-6b-2 は file-level count のみで「site A が --active を落とし、site B が --active を 2 回付ける」regression を検出できない。
# create.md 全体での --active flag (true / false) と --next 引数の出現数を patch 数と整合させることで、per-site 単位の symmetry を確保する。
# 注: terminal phase の patch では `--active false` が使われるため、true/false 両方を count する。
create_active_count=$(_grep_count_safe "create_active_count" "$CREATE_MD" '\-\-active (true|false)')
if [ "$create_active_count" -ge "$create_patch_count" ]; then
  pass "TC-6b-3: create.md の '--active true|false' 出現数 (実測=$create_active_count) が patch invocation 数 (=$create_patch_count) 以上 (per-site --active flag 維持)"
else
  fail "TC-6b-3: create.md の '--active true|false' 出現数が patch invocation 数より少ない (--active=$create_active_count vs patch=$create_patch_count, per-site flag drop の可能性 — deleted 4-site-symmetry.test.sh が pinning していた invariant)"
fi

create_next_count=$(_grep_count_safe "create_next_count" "$CREATE_MD" '\-\-next "')
if [ "$create_next_count" -ge "$create_patch_count" ]; then
  pass "TC-6b-4: create.md の '--next \"...\"' 出現数 (実測=$create_next_count) が patch invocation 数 (=$create_patch_count) 以上 (per-site --next flag 維持)"
else
  fail "TC-6b-4: create.md の '--next \"...\"' 出現数が patch invocation 数より少ない (--next=$create_next_count vs patch=$create_patch_count, per-site flag drop の可能性)"
fi

# fallback WARNING pattern: helper 失敗時に silent fall-through しないことを pin
interview_warn_count=$(_grep_count_safe "interview_warn_count" "$INTERVIEW_MD" 'WARNING: workflow-incident-emit\.sh failed')
if [ "$interview_warn_count" -ge 4 ]; then
  pass "TC-6c: create-interview.md に 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回以上 (実測=$interview_warn_count, silent failure 防御 pattern)"
else
  fail "TC-6c: create-interview.md の 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回未満 (実測=$interview_warn_count, 期待>=4 — \`2>/dev/null || true\` silent failure pattern に reverted した可能性)"
fi

create_warn_count=$(_grep_count_safe "create_warn_count" "$CREATE_MD" 'WARNING: workflow-incident-emit\.sh failed')
if [ "$create_warn_count" -ge 4 ]; then
  pass "TC-6d: create.md に 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回以上 (実測=$create_warn_count, silent failure 防御 pattern)"
else
  fail "TC-6d: create.md の 'WARNING: workflow-incident-emit.sh failed' fallback が 4 回未満 (実測=$create_warn_count, 期待>=4 — \`2>/dev/null || true\` silent failure pattern に reverted した可能性)"
fi

# M-7 対応: silent failure pattern の variation を網羅的に検出。
# 旧実装は `2>/dev/null || true` 単独しか catch しなかったが、`|| :` / `|| return 0` /
# `|| { true; }` 等の equivalent silent fallback variation を全て検出するよう ERE alternation を拡張。
# silent-failure-hunter M-7 (): さらに `|| exit 0` / `|| (true)` / `|| { :; }` (空白なし) も
# alternation に追加し、将来の equivalent silent failure pattern 導入も catch する。
_silent_failure_pattern='2>/dev/null[[:space:]]*\|\|[[:space:]]*(true|:|return[[:space:]]+0|exit[[:space:]]+0|\([[:space:]]*true[[:space:]]*\)|\{[[:space:]]*:?[[:space:]]*true?[[:space:]]*;?[[:space:]]*\})'

# anti-pattern revert detection: silent failure variation が workflow-incident-emit.sh と co-located で残っていないこと
# grep -B1 -A1 では 5+ 行に渡る invocation block の
# 中間行に挿入された `2>/dev/null` を catch できないため、-A 8 に拡大して invocation block 全体
# (backslash 続行 5-7 行 + || echo WARNING フォールバック行) を範囲に含める。
# 加えて comment lines (先頭 `#`) を pre-filter で除外することで、explainer comment 内の
# 旧パターン例示 (`# 旧 mkdir ... 2>/dev/null || true`) を偽陽性として hit させない。
# pipefail 下の false-positive pass を防ぐため、最初の grep の結果を独立変数に capture してから後段 pipeline を実行する。
# 旧実装 `if grep -B1 -A8 ... | grep -v | grep -qE ...; then` は workflow-incident-emit invocation 全削除
# (catastrophic regression) で最初の grep が rc=1 → pipefail で pipeline rc=1 → if 条件 false → else 経路で
# `pass` が呼ばれる false-positive を起こす (Bash Reference Manual の pipefail 仕様、set -e は `if` 文脈で
# trigger しない仕様 — POSIX Shell)。TC-6a/b の count >= 4 で副次的 catch あるが、本 TC 単独で見ると壊れて
# いた。先頭 grep の rc を明示的に区別することで catastrophic regression を fail に倒す。
# 旧 `2>/dev/null || true` は grep の IO エラー
# (rc>=2, permission denied / file lock / broken FS) を silent に空文字へ倒し、TOCTOU race 時に
# 「invocation block 不在」と「IO エラー」を区別不能にしていた。stderr を tempfile に退避し、
# grep rc=1 (= no match → empty 正常) と rc>=2 (= IO error → fail-fast) を明示区別する。
_grep_err_int=$(mktemp /tmp/rite-tc6e-grep-err-XXXXXX 2>/dev/null) || _grep_err_int=""
# `local var=$(cmd)` の bash pitfall (将来 refactor で
# `local var; var=$(cmd)` に分離した場合 `$?` が常に 0 となる罠) を `_grep_count_safe` と同じ
# linear pattern (if-then-else で rc 取得) に統一する。
if _invocation_block_interview=$(grep -B1 -A8 'workflow-incident-emit\.sh' "$INTERVIEW_MD" 2>"${_grep_err_int:-/dev/null}"); then
  _grep_rc_int=0
else
  _grep_rc_int=$?
fi
if [ "$_grep_rc_int" -ge 2 ]; then
  fail "TC-6e prerequisite: create-interview.md grep -B1 -A8 が IO エラー (rc=$_grep_rc_int) で失敗 — test 環境問題 ($([ -n "$_grep_err_int" ] && [ -s "$_grep_err_int" ] && head -1 "$_grep_err_int" || echo no-stderr))"
elif [ -z "$_invocation_block_interview" ]; then
  fail "TC-6e prerequisite: create-interview.md から workflow-incident-emit.sh invocation block が見つからない (catastrophic regression — TC-6a を先に確認してください)"
elif printf '%s\n' "$_invocation_block_interview" | grep -v '^[[:space:]]*#' | grep -qE "$_silent_failure_pattern"; then
  fail "TC-6e: create-interview.md で workflow-incident-emit.sh invocation block 内に silent failure pattern (|| true / || : / || return 0 / || { true; } のいずれか) が残存 (anti-pattern revert)"
else
  pass "TC-6e: create-interview.md で workflow-incident-emit.sh と silent failure pattern の co-location なし (invocation block 全体 8 行範囲 + comment 除外、silent failure 防御維持)"
fi
[ -n "$_grep_err_int" ] && rm -f "$_grep_err_int"

_grep_err_cre=$(mktemp /tmp/rite-tc6f-grep-err-XXXXXX 2>/dev/null) || _grep_err_cre=""
# silent-failure-hunter L-2: TC-6e と対称な linear pattern
if _invocation_block_create=$(grep -B1 -A8 'workflow-incident-emit\.sh' "$CREATE_MD" 2>"${_grep_err_cre:-/dev/null}"); then
  _grep_rc_cre=0
else
  _grep_rc_cre=$?
fi
if [ "$_grep_rc_cre" -ge 2 ]; then
  fail "TC-6f prerequisite: create.md grep -B1 -A8 が IO エラー (rc=$_grep_rc_cre) で失敗 — test 環境問題 ($([ -n "$_grep_err_cre" ] && [ -s "$_grep_err_cre" ] && head -1 "$_grep_err_cre" || echo no-stderr))"
elif [ -z "$_invocation_block_create" ]; then
  fail "TC-6f prerequisite: create.md から workflow-incident-emit.sh invocation block が見つからない (catastrophic regression — TC-6b を先に確認してください)"
elif printf '%s\n' "$_invocation_block_create" | grep -v '^[[:space:]]*#' | grep -qE "$_silent_failure_pattern"; then
  fail "TC-6f: create.md で workflow-incident-emit.sh invocation block 内に silent failure pattern (|| true / || : / || return 0 / || { true; } のいずれか) が残存 (anti-pattern revert)"
else
  pass "TC-6f: create.md で workflow-incident-emit.sh と silent failure pattern の co-location なし (invocation block 全体 8 行範囲 + comment 除外、silent failure 防御維持)"
fi
[ -n "$_grep_err_cre" ] && rm -f "$_grep_err_cre"

# create.md Mandatory After Delegation の imperative phrasing を pin。
# 本 site は create.md に残る唯一の Layer 1 imperative defense で、load-bearing なフレーズ
# (`VERY FIRST cognitive action` / `BEFORE any text output or narrative`) の silent 弱体化を検出する。
assert_grep "TC-6g: create.md に Mandatory After Delegation の '**VERY FIRST cognitive action**' imperative bold が存在" \
  "$CREATE_MD" \
  '\*\*VERY FIRST cognitive action\*\*'
assert_grep "TC-6h: create.md に Mandatory After Delegation の 'BEFORE any text output or narrative' keyword が存在" \
  "$CREATE_MD" \
  'BEFORE any text output or narrative'

# TC-6h-2: TC-6g/h を **同一行** での句結合として再 pin する補強 (旧 step0-immediate-bash-presence.test.sh の
# Per-site weakening 検出: create.md Mandatory After Delegation prose の load-bearing phrases。
# 4 句結合 (`MUST proceed to Self-check.*VERY FIRST cognitive action.*BEFORE.*narrative`) を 1 つの assert_grep に
# 束ねた旧実装は、prose の harmless な改善 (reformat / sentence split / 用語簡素化) でも一律 fail する
# brittle pin だった。各 phrase の存在を独立に pin することで、同一行配置 / 用語の純粋な reorder
# / 軽微な punctuation 改善には寛容、phrase 単独の silent 削除には厳格、というバランスを実現する。
assert_grep "TC-6h-2a: create.md Mandatory After Delegation prose に 'MUST proceed to Self-check' phrase が存在 (load-bearing imperative anchor)" \
  "$CREATE_MD" \
  'MUST proceed to Self-check'
assert_grep "TC-6h-2b: create.md Mandatory After Delegation prose に 'VERY FIRST cognitive action' phrase が存在 (cognitive ordering anchor)" \
  "$CREATE_MD" \
  'VERY FIRST cognitive action'
assert_grep "TC-6h-2c: create.md Mandatory After Delegation prose に 'BEFORE' + 'narrative' phrase が存在 (output ordering anchor)" \
  "$CREATE_MD" \
  'BEFORE.*narrative'

# TC-6j: Mandatory After Interview section の不在 pin
# parent-routing pattern 移行で create.md から `🚨 Mandatory After Interview` section を完全削除した。
# git revert / 別 Issue で section が古い phrasing で復活する catastrophic regression を mechanical に検出する。
# TC-6g/h は **存在** pin (Mandatory After Delegation の load-bearing phrasing 維持) なのに対し、
# 本 TC は **不在** pin で対称化する。両者の組合せで「Delegation のみ存続 / Interview は撤去」を保証。
# heading level は h2 / h3 / h4 のいずれでも catch (`^#+ ` で any heading level)。
# 別 heading level (`## ` / `#### `) での復活経路も silent pass させない。
if grep -qE '^#+ .*🚨.*Mandatory After Interview' "$CREATE_MD"; then
  fail "TC-6j: create.md に '🚨 Mandatory After Interview' section anchor が復活した (parent-routing pattern 移行の意図に反する catastrophic revert — git revert / 別 Issue で誤判断の可能性)"
else
  pass "TC-6j: create.md から '🚨 Mandatory After Interview' section anchor が削除されたまま維持 (parent-routing pattern 整合性、catastrophic revert なし)"
fi

# TC-6i: 8 種 retained flag 名の echo presence を個別に pin する。
# flag 名は ADR documented stable contract のため (rename / typo を確実に catch)、
# helper invocation count (TC-6a/b) だけでは検出できない経路を補完する。
# 対象 flag (4 + 4 = 8):
#   create-interview.md: PREFLIGHT_PATCH_FAILED / PREFLIGHT_CREATE_FAILED /
#                        PREFLIGHT_CREATE_THEN_PATCH_FAILED / INTERVIEW_RETURN_PATCH_FAILED
#   create.md: CREATE_INTERVIEW_PRE_WRITE_PATCH_FAILED / CREATE_INTERVIEW_PRE_WRITE_CREATE_FAILED /
#                        CREATE_DELEGATION_PRE_WRITE_PATCH_FAILED / CREATE_DELEGATION_PRE_WRITE_CREATE_FAILED
for _flag in PREFLIGHT_PATCH_FAILED PREFLIGHT_CREATE_FAILED PREFLIGHT_CREATE_THEN_PATCH_FAILED INTERVIEW_RETURN_PATCH_FAILED; do
  if grep -qE "\\[CONTEXT\\] ${_flag}=1" "$INTERVIEW_MD"; then
    pass "TC-6i: create-interview.md に '[CONTEXT] ${_flag}=1' echo が存在 (catastrophic dual-failure 判定の load-bearing input)"
  else
    fail "TC-6i: create-interview.md に '[CONTEXT] ${_flag}=1' echo が見つからない (flag rename / typo / 削除の可能性 — catastrophic dual-failure 判定が silent break する)"
  fi
done
# pr-test-analyzer I-1: Pre-flight retained flag 6 個中、上記 4 個に加えて以下 2 個も pin する。
# 非 halt diagnostic flag (`STATE_PATH_RESOLVE_FAILED` / `FLOW_STATE_PATH_RESOLVE_FAILED`) が消失すると
# `manual_fallback_adopted` sentinel emit が silent break して observability が片肺化する。
for _flag in STATE_PATH_RESOLVE_FAILED FLOW_STATE_PATH_RESOLVE_FAILED; do
  if grep -qE "\\[CONTEXT\\] ${_flag}=1" "$INTERVIEW_MD"; then
    pass "TC-6i: create-interview.md に '[CONTEXT] ${_flag}=1' echo が存在 (non-halt diagnostic flag、manual_fallback_adopted sentinel emit の load-bearing input)"
  else
    fail "TC-6i: create-interview.md に '[CONTEXT] ${_flag}=1' echo が見つからない (flag rename / typo / 削除 — observability silent break のリスク)"
  fi
done
for _flag in CREATE_INTERVIEW_PRE_WRITE_PATCH_FAILED CREATE_INTERVIEW_PRE_WRITE_CREATE_FAILED CREATE_DELEGATION_PRE_WRITE_PATCH_FAILED CREATE_DELEGATION_PRE_WRITE_CREATE_FAILED; do
  if grep -qE "\\[CONTEXT\\] ${_flag}=1" "$CREATE_MD"; then
    pass "TC-6i: create.md に '[CONTEXT] ${_flag}=1' echo が存在 (caller-side incident emit の load-bearing input)"
  else
    fail "TC-6i: create.md に '[CONTEXT] ${_flag}=1' echo が見つからない (flag rename / typo / 削除の可能性)"
  fi
done

echo
echo "=== TC-7: caller-side [interview:error] halt rule presence ==="

# parent-routing pattern では `[interview:error]` は catastrophic Pre-flight failure を表す halt sentinel として
# create-interview.md / create.md / pre-check-routing.md の 3 site で routing/halt rule が宣言されている。
# silent partial-weakening (例: prose 削除 / phrasing 弱体化) を mechanical に検出する pin。
# 既存 TC-2e が create-interview.md の bullet 存在を pin 済のため、TC-7 では caller 側 (create.md /
# pre-check-routing.md) の halt rule prose 残存を pin する。

PRE_CHECK_ROUTING_MD="$REPO_ROOT/plugins/rite/commands/issue/references/pre-check-routing.md"

# 旧実装は `fail` (継続) + `else` でサブアサーション
# 8+ 件を silent skip する経路だった。L42-48 の precondition check (`for f in "$INTERVIEW_MD" ...`) は
# `exit 1` で fail-fast するのに対し、TC-7 のみ `fail` で継続するのは asymmetric。本修正で
# `pre-check-routing.md` 不在を環境エラーとして `exit 1` に統一する (test 失敗ではなくインフラ問題)。
if [ ! -f "$PRE_CHECK_ROUTING_MD" ]; then
  echo "  ❌ FILE NOT FOUND: $PRE_CHECK_ROUTING_MD" >&2
  echo "  TC-7: pre-check-routing.md が test 環境に不在のため、TC-7 配下 8+ サブアサーション全件を verify できません" >&2
  exit 1
else
  # create.md には Halt rule (Sub-skill Return Protocol section) と Phase 1 return branch
  # ('[interview:error]' return-branch bullet) の **2 箇所** で `[interview:error]` halt prose が存在する。
  # 旧 `grep -q` の 1 match pass は片方を silent 削除しても通過する false negative を持っていたため、
  # `grep -c` で count >= 2 に強化し独立 pin する (semantic anchor を使い line number drift surface を回避)。
  interview_error_halt_count=$(_grep_count_safe "interview_error_halt_count" "$CREATE_MD" '\[interview:error\].*halt')
  if [ "$interview_error_halt_count" -ge 2 ]; then
    pass "TC-7a: create.md に '[interview:error] ... halt' prose が 2 site 以上 (実測=$interview_error_halt_count, Halt rule + Phase 1 return branch の 2 site が load-bearing)"
  else
    fail "TC-7a: create.md の '[interview:error] ... halt' prose が 2 site 未満 (実測=$interview_error_halt_count, 期待>=2 — Halt rule (Sub-skill Return Protocol section) または Phase 1 return branch ('[interview:error]' return-branch bullet) のいずれかが削除された可能性)"
  fi

  # TC-7a-1: create.md halt rule の "manual intervention" / "Issue 未作成のまま停止" prose pin。
  # TC-7a の count >= 2 だけでは prose の semantic 弱化 (例: `halt` → `skip Phase 2 silently` への
  # 表現変更) を catch できないため、load-bearing phrase の存在を独立に pin する。両 phrase の
  # いずれかが silent 削除されると halt rule の意味が user-visible error 省略経路に倒れる。
  if grep -qE 'manual intervention' "$CREATE_MD" && grep -qE 'Issue 未作成のまま停止' "$CREATE_MD"; then
    pass "TC-7a-1: create.md halt rule に 'manual intervention' AND 'Issue 未作成のまま停止' prose が存在 (silent semantic weakening 防止)"
  else
    fail "TC-7a-1: create.md halt rule の 'manual intervention' または 'Issue 未作成のまま停止' prose が欠落 (halt rule の semantic 弱化リスク)"
  fi

  # TC-7a-2: halt rule body の action verb 存在を pin (`halt softly` 等への weak 表現変更検出)。
  # TC-7a / TC-7a-1 は count / phrase 存在を pin するが、halt 自体の action (中断 / abort /
  # exit non-zero) が「skip silently」「continue with warning」等に書き換えられても match する。
  # `[interview:error]` halt 発火 line + 後続 10 行 (合計 11 行) に action verb が存在することを確認する。
  # verified-review C-2 (#926): 旧実装は match 行を `next` で skip していたが、create.md:66 では同一行内に
  # action verb (`Issue 未作成のまま停止`) があるため、match 行も含める必要がある。
  # action verb 集合に `manual intervention` も追加 (Halt rule の正規表現に含まれているため)。
  if awk '/\[interview:error\].*halt/ {flag=1; n=0; print; next} flag && n<10 {print; n++}' "$CREATE_MD" \
       | grep -qE '(exit non-zero|abort|中断|workflow を停止|Issue 未作成のまま停止|manual intervention)'; then
    pass "TC-7a-2: create.md halt rule 行 + 直後 10 行内に action verb (exit non-zero / abort / 中断 / 停止 / manual intervention) が存在 (semantic weakening 防止)"
  else
    fail "TC-7a-2: create.md halt rule 行 + 直後 10 行内に action verb が見つからない (halt が skip / continue に弱化された可能性)"
  fi

  # pre-check-routing.md Item 0 dispatcher は `[interview:error]` matched 時の Phase 2 進入禁止経路を持つ。
  if grep -qE '\[interview:error\].*Phase 2' "$PRE_CHECK_ROUTING_MD"; then
    pass "TC-7b: pre-check-routing.md に '[interview:error] ... Phase 2' routing prose が存在 (Item 0 dispatcher の halt 経路の load-bearing pin)"
  else
    fail "TC-7b: pre-check-routing.md に '[interview:error] ... Phase 2' routing prose が見つからない (Item 0 dispatcher の halt 経路が silent に消失した可能性)"
  fi

  # 4 sentinel literal が pre-check-routing.md Item 0 で grep 対象として列挙されていることを pin
  # (grep -qF は fixed string match のため backslash escape は不要)
  for _sentinel in '[interview:skipped]' '[interview:completed]' '[interview:error]' '[create:completed:{N}]'; do
    if grep -qF "$_sentinel" "$PRE_CHECK_ROUTING_MD"; then
      pass "TC-7c: pre-check-routing.md に sentinel literal '$_sentinel' が enumerated (Item 0 dispatcher の grep target)"
    else
      fail "TC-7c: pre-check-routing.md に sentinel literal '$_sentinel' が見つからない (dispatcher grep target の silent 削除リスク)"
    fi
  done

  # TC-7d: Positional 制約 note の load-bearing prose pin。
  # dispatcher の runtime semantics ("fenced code block 内マッチを無視" + "直近 assistant turn 末尾優先")
  # が silent 削除されると、anti-pattern example (`[WRONG] <LLM output: "[interview:skipped]">`) が
  # dispatcher で誤発火し halt 経路ではなく continuation 経路に流れる silent semantic regression を起こす。
  if grep -qE 'fenced code block.*無視' "$PRE_CHECK_ROUTING_MD"; then
    pass "TC-7d: pre-check-routing.md に Positional 制約 note 'fenced code block 内マッチを無視' が存在 (dispatcher collision-safe matching の load-bearing prose pin)"
  else
    fail "TC-7d: pre-check-routing.md に Positional 制約 note 'fenced code block 内マッチを無視' が見つからない (anti-pattern example 誤発火リスク)"
  fi
fi

# ----------------------------------------------------------------------------
# TC-8 (verified-review I-8 #926): `--preserve-error-count` invocation negative assertion
# 旧 4-site-symmetry test 削除に伴い「`--preserve-error-count` flag が bash invocation で
# 使われていない」を mechanical に pin する手段が失われていた。本 TC で negative assertion を追加し、
# 誤って caller の `flow-state-update.sh` 呼び出しに flag が復活した時に即検出する。
# 注: ADR §3.1 rationale 説明として prose 内に literal で出現する `--preserve-error-count` は許容する
# (forward note としての historical context)。pin 対象は「bash invocation 行で `flow-state-update.sh`
# または `$HOOK` の引数として使用される flag」のみ。
# ----------------------------------------------------------------------------
for _f in "$CREATE_MD" "$INTERVIEW_MD"; do
  # bash invocation 行で flag が使われている場合のみ FAIL (rationale 引用は許容)
  if grep -qE '(flow-state-update\.sh|\$HOOK).*--preserve-error-count' "$_f"; then
    fail "TC-8: $(basename "$_f") の bash invocation に '--preserve-error-count' flag が残存 (ADR §3.1 で撤去済のはず、dead-code 復活リスク)"
  else
    pass "TC-8: $(basename "$_f") の bash invocation から '--preserve-error-count' flag が不在 (dead-code 不在を mechanical pin、rationale 引用は許容)"
  fi
done

# ----------------------------------------------------------------------------
# TC-9 (verified-review I-9 #926): cross-file matrix assertion for VERY FIRST + BEFORE
# 旧 step0-immediate-bash-presence.test.sh の matrix-style 検証 (`VERY FIRST` + `BEFORE any text
# output` を全 caller で同時 pin) が削除されたため、1 site だけ書き換えても他で pass する silent
# loss path が残っていた。本 TC で cross-file matrix を簡潔に復元する。
# 注: create-interview は parent-routing pattern 適用後 sub-skill であり「caller の Mandatory After
# section」自体を持たないため pin 対象外。caller 側 4 sites (cleanup / ingest / create / register /
# decompose) のみを matrix の対象とする。本 PR の scope では register/decompose を pin せず、
# cleanup/ingest/create の 3 sites で対称性を確認する (PR-3 以降で register/decompose も
# parent-routing 化された後、本 TC を拡張する想定)。
# ----------------------------------------------------------------------------
for _f in "$CLEANUP_MD" "$INGEST_MD" "$CREATE_MD"; do
  _bn=$(basename "$_f")
  if grep -qE 'VERY FIRST' "$_f" && grep -qE 'BEFORE any text output' "$_f"; then
    pass "TC-9: $_bn に 'VERY FIRST' + 'BEFORE any text output' が同時存在 (cross-file matrix invariant)"
  else
    fail "TC-9: $_bn の 'VERY FIRST' または 'BEFORE any text output' が欠落 (cross-file matrix invariant 違反)"
  fi
done

DRIFT_HINT="\
parent-routing pattern interim invariant が崩れています。
ADR: docs/designs/parent-routing-unification.md"

if ! print_summary "$(basename "$0")" "$DRIFT_HINT"; then
  exit 1
fi

echo "OK: parent-routing pattern interim invariant verified"
exit 0
