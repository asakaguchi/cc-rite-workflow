#!/bin/bash
# rite workflow - Flow State Atomic Update
# Deterministic script for atomic .rite-flow-state writes.
# Replaces inline jq + atomic write patterns scattered across command files.
#
# Usage:
#   Create mode (full object with jq -n):
#     bash plugins/rite/hooks/flow-state-update.sh create \
#       --phase phase5_lint --issue 42 --branch "feat/issue-42-test" \
#       --pr 0 --next "Proceed to Phase 5.2.1." [--active true]
#
#   Patch mode (update fields in existing file):
#     bash plugins/rite/hooks/flow-state-update.sh patch \
#       --phase phase5_post_lint --next "Proceed to next phase." [--active true] [--if-exists] [--preserve-error-count]
#
#   Increment mode (increment a numeric field):
#     bash plugins/rite/hooks/flow-state-update.sh increment \
#       --field implementation_round [--if-exists]
#
# Options:
#   --phase
#       Phase value (required for create/patch)
#   --issue
#       Issue number (create mode, default: 0)
#   --branch
#       Branch name (create mode, default: "")
#   --pr
#       PR number (create mode, default: 0)
#   --parent-issue
#       Parent Issue number (create mode, default: 0; patch mode: update only if specified)
#   --next
#       next_action text (required for create/patch)
#   --active
#       Active flag (create mode: default true; patch mode: update only if specified)
#   --field
#       Field name to increment (increment mode)
#   --if-exists
#       Only execute if .rite-flow-state exists (patch/increment mode)
#   --session
#       Session UUID override (create mode; defaults to .rite-session-id)
#   --preserve-error-count
#       Patch mode 限定: 既存 .error_count を保持。default は 0 にリセット。
#       (現状 no-op: stop-guard.sh 撤去後は branching reader が存在しないが、forward-compat
#        装備として保持。詳細は ADR `docs/designs/parent-routing-unification.md` Rollback Log)
#   --legacy-mode
#       Force legacy single-file path (`.rite-flow-state`) regardless of
#       rite-config.yml `flow_state.schema_version`. Used by migration script (#2) and
#       tooling that must read/write the pre-migration source. Without this flag,
#       schema_version=2 (default) writes to `.rite/sessions/{session_id}.flow-state`.
#
# Exit codes:
#   0: Success
#   0: Skipped (--if-exists and file does not exist)
#   1: Argument error or jq failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source session ownership helper for stale detection in create mode
# 旧 `2>/dev/null || true` は syntax error / permission denied / missing file を完全 silent suppress
# していた。get_state_session_id / parse_iso8601_to_epoch が未定義になると、後続の
# session-ownership block 内 jq invocation で `command not found` rc が間接 catch される一方、source
# 失敗自体の原因 (deploy 不整合 / 構文エラー / permission denied) は完全に消える。
# silent fallback を排除し、source 失敗時は WARNING + 詳細を stderr に emit する
# (`_validate-helpers.sh` の DEFAULT_HELPERS 配列対象外なため、ここで explicit guard する)。
_session_ownership_source_err=$(mktemp /tmp/rite-fs-source-err-XXXXXX 2>/dev/null) || _session_ownership_source_err=""
if ! source "$SCRIPT_DIR/session-ownership.sh" 2>"${_session_ownership_source_err:-/dev/null}"; then
  echo "WARNING: source session-ownership.sh が失敗しました — get_state_session_id / parse_iso8601_to_epoch が未定義になる可能性があります" >&2
  if [ -n "$_session_ownership_source_err" ] && [ -s "$_session_ownership_source_err" ]; then
    head -3 "$_session_ownership_source_err" | sed 's/^/  /' >&2
  fi
  echo "  対処: $SCRIPT_DIR/session-ownership.sh の存在 / 構文 / permission を確認してください" >&2
  echo "  影響: session ownership check が無効化されますが、後続の jq invocation で間接 catch される" >&2
fi
[ -n "$_session_ownership_source_err" ] && rm -f "$_session_ownership_source_err"

# Helper script existence check (/ HIGH + F-09 MEDIUM):
# 旧実装は state-path-resolve.sh のみ fail-fast 検査していたが、本 helper は以下の helper を `bash <missing>`
# invocation 経路で direct + transitive に依存する。検査対象 list の Single Source of Truth は
# `_validate-helpers.sh` 内の **DEFAULT_HELPERS 配列** (で集約):
#   - `state-path-resolve.sh` (STATE_ROOT 解決経路で direct invoke)
#   - `_resolve-session-id.sh` (`_resolve_session_id` 関数内の direct invoke)
#   - `_resolve-session-id-from-file.sh` (transitive 経由で `_resolve_session_state_path` 解決経路)
#   - `_resolve-schema-version.sh` (`_resolve_schema_version` 関数の helper 委譲)
#   - `_resolve-cross-session-guard.sh` (`_resolve_session_state_path` 内 cross-session classification)
#   - `_emit-cross-session-incident.sh` (foreign:* / corrupt:* / invalid_uuid:* 各 arm)
#   - `_mktemp-stderr-guard.sh` (jq stderr 退避 / mkdir stderr 退避等で direct invoke)
# 上記 bullet list は人間向けの説明であり、実際の検査対象は DEFAULT_HELPERS 配列が決定する。
# helper を追加する際は `_validate-helpers.sh` 内 DEFAULT_HELPERS への 1 行追加のみで両 caller
# (state-read.sh / flow-state-update.sh) に反映される (writer/reader 対称化 doctrine の構造的実装)。
# それらが install 不整合 / deploy regression で missing の場合、`set -euo pipefail` の中でも
# `if`/`else`/`||` 文脈では非ブロッキング扱いとなり、silent fall-through 経路が散在する。Issue #687
# (writer/reader 片肺更新型 silent regression) と同型の deploy regression を構造的に塞ぐため、依存する
# 全 helper を upfront で fail-fast 検査する。state-read.sh の同型ブロックと writer/reader 対称化。
# / helper existence check の
# **validation logic** を `_validate-helpers.sh` に集約。
# helper 名 list 自体も `_validate-helpers.sh` 内の DEFAULT_HELPERS
# 配列に集約し、本 caller は引数 0 個 (script_dir のみ) で呼ぶ形に統一。state-read.sh と本ファイルの
# helper-list 重複が構造的に解消され、helper 追加時は 1 ファイル更新のみで済む。
if [ ! -x "$SCRIPT_DIR/_validate-helpers.sh" ]; then
  echo "ERROR: _validate-helpers.sh not found or not executable: $SCRIPT_DIR/_validate-helpers.sh" >&2
  echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
  exit 1
fi
# DEFAULT_HELPERS を使用 (引数 0 個 = script_dir のみ)
bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR" || exit $?

# Resolve repository root
# stderr 退避 + WARNING emit (writer/reader 対称化 doctrine、silent fallback を排除)。
# script が deploy regression / syntax error で失敗した場合、silent `pwd` fallback だと root cause が
# 完全に失われる。`head -3` で kernel diagnostic を pass-through する。
_state_root_err=$(mktemp /tmp/rite-fs-state-root-err-XXXXXX 2>/dev/null) || _state_root_err=""
if ! STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>"${_state_root_err:-/dev/null}"); then
  echo "WARNING: flow-state-update: state-path-resolve.sh 失敗 — pwd fallback します" >&2
  [ -n "$_state_root_err" ] && [ -s "$_state_root_err" ] && head -3 "$_state_root_err" | sed 's/^/  /' >&2
  STATE_ROOT="$(pwd)"
fi
[ -n "$_state_root_err" ] && rm -f "$_state_root_err"
LEGACY_FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Multi-state helpers (#672 / #678) ---
# Issue #672 design (Option A: per-session file) routes flow-state writes to
# .rite/sessions/{session_id}.flow-state when schema_version=2. Migration to
# call sites is staged across #3-#5; this script is the single API surface.

# Resolve session_id from --session arg, or fall back to .rite-session-id file.
# Validates UUID format (rejects tampered or corrupt content) on **both** paths:
# the file-read path AND the --session arg path. Validation parity prevents
# path traversal via `--session "../foo"` (review #686 F-01).
_resolve_session_id() {
  # UUID validation を `_resolve-session-id.sh` 共通 helper
  # に抽出。state-read.sh / flow-state-update.sh / resume-active-flag-restore.sh の 5 site で重複していた
  # RFC 4122 strict pattern を 1 箇所に集約し、将来の pattern tightening (variant bit check 等) を
  # 片肺更新 drift から守る。
  # 引数指定なし経路 (sid_file 読込 + tr + validation + fallback) を
  # `_resolve-session-id-from-file.sh` 共通 helper に置換。state-read.sh / resume-active-flag-restore.sh と
  # writer/reader/resume 3 layer 対称化。--session arg 指定経路は writer 固有の fail-fast policy
  # (silent fallback で spec drift を隠さない) を維持する必要があるため、本関数内で明示処理を残す。
  local provided_sid="${1:-}"
  if [[ -n "$provided_sid" ]]; then
    local validated
    local _resolve_sid_err
    # mktemp 失敗時の silent fallback を排除 (writer/reader 対称化 doctrine、`verify-terminal-output.sh` の
    # `_git_err mktemp 失敗時 WARNING + fail-fast` pattern と同型、構造 anchor で参照)。stderr 退避が失われると helper internal error (jq missing / fork failure / PATH error)
    # と UUID format 違反 (`ERROR: invalid session_id format`) を区別できず、開発者が誤った原因究明をする。
    # /tmp inode 枯渇 / read-only fs は通常運用では発火しないが、発火時は fail-fast に倒して環境問題を
    # 明示する。chmod 失敗 (`_chmod_err` (dir-creation block 内 mktemp) / `_chmod600_err` (TMP_STATE
    # chmod block 内 mktemp)) は best-effort 経路で silent fallback を許容するのとは性質が異なる
    # (本 site は load-bearing な分類 fail-fast)。
    if ! _resolve_sid_err=$(mktemp /tmp/rite-resolve-sid-err-XXXXXX 2>/dev/null); then
      echo "ERROR: mktemp failed for _resolve_sid_err — cannot capture _resolve-session-id.sh stderr" >&2
      echo "  hint: /tmp の inode 枯渇 / read-only filesystem / permission 拒否を確認してください" >&2
      echo "  影響: UUID format 違反と helper internal error を区別できないため fail-fast します" >&2
      exit 1
    fi
    # 関数内 signal-specific trap: parent atomic cleanup trap install 前の段階で実行されるため、
    # SIGINT/SIGTERM/SIGHUP 受信時に `_resolve_sid_err` tempfile が orphan として `/tmp` に残る経路を
    # 防ぐ。関数末尾で `trap - EXIT INT TERM HUP` で解除し、後続の atomic cleanup trap install を妨げない。
    # canonical pattern: references/bash-trap-patterns.md#signal-specific-trap-template
    _rite_resolve_sid_cleanup() {
      rm -f "${_resolve_sid_err:-}"
    }
    trap 'rc=$?; _rite_resolve_sid_cleanup; exit $rc' EXIT
    trap '_rite_resolve_sid_cleanup; exit 130' INT
    trap '_rite_resolve_sid_cleanup; exit 143' TERM
    trap '_rite_resolve_sid_cleanup; exit 129' HUP
    if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$provided_sid" 2>"${_resolve_sid_err:-/dev/null}"); then
      [ -n "$_resolve_sid_err" ] && rm -f "$_resolve_sid_err"
      trap - EXIT INT TERM HUP
      echo "$validated"
      return 0
    fi
    # Reject malformed --session arg (non-UUID input could escape .rite/sessions/).
    # Fail-fast rather than legacy fallback: silent fallback would hide the spec
    # drift and let the caller think a per-session file was created.
    # helper の stderr を退避し、UUID format 違反と helper internal error (jq missing /
    # fork failure / PATH error 等) を区別できるよう詳細を表示する。
    if [ -n "$_resolve_sid_err" ] && [ -s "$_resolve_sid_err" ]; then
      head -3 "$_resolve_sid_err" | sed 's/^/  /' >&2
    fi
    [ -n "$_resolve_sid_err" ] && rm -f "$_resolve_sid_err"
    trap - EXIT INT TERM HUP
    echo "ERROR: invalid session_id format: '$provided_sid' (expected UUID, RFC 4122 §4: 8-4-4-4-12 hex with hyphens, case-insensitive — \`_resolve-session-id.sh\` accepts [0-9a-fA-F])" >&2
    return 1
  fi
  bash "$SCRIPT_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT"
}

# Resolve flow_state.schema_version from rite-config.yml.
# Returns "1" (legacy single-file) or "2" (per-session file).
# Defaults to "1" on parse failure / absent / unrecognized value (safe fallback).
#
# review (code-quality + error-handling 推奨): writer/reader で同一の
# inline schema_version 解決 logic (cfg → section → grep → case) を持っていた drift リスクを
# 排除するため、共通 helper `_resolve-schema-version.sh` に抽出済。Issue #687 AC-4 / 
# 確立した pipefail silent failure 対策 (`|| v=""`) も helper 内で吸収される。
# 旧 inline 実装 (cfg / section / v 変数 + case 分岐) は helper 内に移動済み。
_resolve_schema_version() {
  bash "$(dirname "${BASH_SOURCE[0]}")/_resolve-schema-version.sh" "$STATE_ROOT"
}

# Resolve flow-state file path based on (effective_schema_version, legacy_mode, session_id).
# - When legacy_mode is "true", schema_version != "2", or session_id is empty -> legacy path
# - Otherwise -> per-session new path
# - Reader-symmetric legacy fallback with cross-session guard (fix):
#   When schema_v=2 + valid sid + per-session ABSENT + legacy EXISTS (size > 0), fall back to legacy
#   ONLY IF legacy.session_id matches the current sid OR legacy.session_id is empty/null.
#   When legacy.session_id != current sid (cross-session residue), refuse to fall back to legacy
#   (CRITICAL: simple fallback caused silent metadata corruption — issue_number
#   / branch / pr_number from another session would silently leak into current session via jq per-field
#   merge). Emit WORKFLOW_INCIDENT sentinel so caller can surface and let create-mode handle init.
#   Size check : writer must mirror reader-side state-read.sh's per-session resolver
#   `[ ! -s ]` guard so size-0 legacy (e.g., from `touch .rite-flow-state`) doesn't silently consume
#   patch updates. (fix F-04 HIGH: hardcoded line-number 参照を semantic anchor に置換)
_resolve_session_state_path() {
  local sv="$1"
  local lm="$2"
  local sid="$3"
  if [[ "$lm" == "true" ]] || [[ "$sv" != "2" ]] || [[ -z "$sid" ]]; then
    echo "$LEGACY_FLOW_STATE"
    return 0
  fi
  local per_session_path="$STATE_ROOT/.rite/sessions/${sid}.flow-state"
  # Reader-symmetric fallback with cross-session guard + size check.
  # `[ -s ]` ensures legacy is non-empty . Cross-session check below
  # ensures we only adopt legacy if it belongs to current session or is sessionless legacy.
  if [ ! -f "$per_session_path" ] && [ -f "$LEGACY_FLOW_STATE" ] && [ -s "$LEGACY_FLOW_STATE" ]; then
    # cross-session guard を `_resolve-cross-session-guard.sh`
    # 共通 helper に抽出。reader 側 (state-read.sh) と重複していた legacy.session_id 抽出 + 比較 +
    # corrupt 判定ロジックを 1 箇所に集約し、片肺更新 drift を構造的に防ぐ。
    local classification
    # use 2>/dev/null instead of 2>&1.
    # The 2>&1 was merging helper's stderr (jq parse error text) into the classification
    # string, breaking `case "$classification" in corrupt:*) ...` matching and silently
    # routing to the defensive `*)` arm — suppressing the `legacy_state_corrupt` sentinel
    # emit on the writer side. Helper now keeps stderr clean ( in
    # _resolve-cross-session-guard.sh), so 2>/dev/null is safe. Symmetric with state-read.sh's
    # per-session resolver `case "$classification"` block (fix; # scan replaced hardcoded `state-read.sh:119` line reference with semantic anchor).
    # F-01 HIGH — helper の正当な WARNING (mktemp 失敗 WARNING) が
    # `2>/dev/null` で silent suppress される問題を修正 (state-read.sh と writer/reader 対称化)。
    #
    # state-read.sh の cross-session guard mktemp block と writer/reader 対称化。canonical pattern
    # (`if ! ... then` + WARNING 3 行 + chmod 600) に統一 (drift 防止のため両層で同一の修正を適用)。
    # MEDIUM: _classify_err に signal-specific trap を追加 (state-read.sh と
    # writer/reader 対称化)。`_resolve_session_state_path` 関数内に閉じた scope で trap を install し、
    # mktemp 成功 〜 rm 完了の race window で SIGINT/SIGTERM/SIGHUP 中断時の orphan を防ぐ。
    #
    # ── trap reset の正当性 ──
    # 本関数は command substitution (`FLOW_STATE=$(_resolve_session_state_path ...)`) で呼ばれる。
    # bash の subshell isolation により、関数内の trap 変更 (install と reset の両方) は subshell 内に
    # 閉じ、parent shell の `_rite_flow_state_atomic_cleanup` trap には一切影響しない。よって関数末尾の
    # `trap - EXIT INT TERM HUP` は parent との衝突回避のためでは**なく**、subshell exit 前に signal-specific
    # trap を default に戻して再 install 時の古い trap 残存を防ぐ canonical pattern として残している
    # (state-read.sh 側の script-wide trap と writer/reader 対称: trap install は両側で行われるが、
    # reset は本関数 subshell scope に固有。両者とも signal-specific trap で SIGINT/SIGTERM/SIGHUP の
    # orphan を防ぐ機能要件は対称に満たす)。
    #
    # ── caller 直接呼び出し化 (subshell isolation 破れ) への姿勢 ──
    # subshell isolation 不変条件は `tests/flow-state-update-trap-isolation.test.sh` で経験的に固定されている。
    # caller が direct call (`_resolve_session_state_path ...; FLOW_STATE=...`) に変更されると、本関数の
    # trap reset は parent shell の cleanup trap を silent 消去する bug 経路に変質する。ただし TC-3 は
    # 静的 grep による semantic check であり「`$()` 等の subshell 形式が使われていること」を確認するに留まる
    # (回帰検出時の修正方向は実装者判断)。本 reset を「direct call 化時の defense-in-depth」と誤解しては
    # ならない — direct call では reset 有り版が reset なし版より悪い結果になる (parent + inner cleanup
    # 双方を消去) ことを経験的に確認済み。
    local _classify_err=""
    # cleanup 本体は Form A (`rm -f` 単一行) のため、
    # bash-trap-patterns.md「cleanup 関数の契約」節 Form A 規範では `return 0` 不要 (rm -f の rc=0 で十分)。
    # `_resolve-cross-session-guard.sh` の Form A cleanup と統一し、Form A 最小性 doctrine を維持する。
    _rite_flow_state_classify_cleanup() {
      rm -f "${_classify_err:-}"
    }
    trap 'rc=$?; _rite_flow_state_classify_cleanup; exit $rc' EXIT
    trap '_rite_flow_state_classify_cleanup; exit 130' INT
    trap '_rite_flow_state_classify_cleanup; exit 143' TERM
    trap '_rite_flow_state_classify_cleanup; exit 129' HUP
    # verified-review () F-05 (MEDIUM) 対応: writer/reader 対称化 doctrine 構造的破綻の解消。
    # 旧実装は `mktemp + WARNING 3 行 + chmod 600` を 6 行 inline で書き、`_mktemp-stderr-guard.sh` の
    # F-02 consolidation スコープから漏れていた。state-read.sh と byte-for-byte に重複していたため、
    # 将来 WARNING 文言や chmod 仕様を変更する際の片肺更新 drift リスクが残存していた。
    # state-read.sh の本 helper invocation と writer/reader 対称化を維持するため、同じ helper 経由に統一する。
    _classify_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
      "flow-state-update" "classify-err-writer" \
      "cross-session guard helper の WARNING (mktemp 失敗 / jq stderr) が pass-through されません")
    # F-01 (HIGH) — writer/reader 対称化 doctrine 違反を解消。state-read.sh の同 doctrine
    # コメント (writer 側との対称化を維持する原則 — Cross-Reference: state-read.sh の本 helper
    # invocation 直前の F-11 / 対称化 note と同じ趣旨で記述) に従い、`|| true` で helper の
    # 想定外 exit を silent swallow せず、`if ... then : else _guard_rc=$?; fi` で rc を捕捉する。
    # helper の design contract (`exit 0 — always`) が将来 regression した場合、writer 側でも
    # 確実に WARNING emit + classification="" にして create-mode 経路への routing が壊れない
    # ようにする (Issue #687 同型の片肺更新 silent regression を新たに導入しない)。
    local _guard_rc=0
    if classification=$(bash "$SCRIPT_DIR/_resolve-cross-session-guard.sh" "$LEGACY_FLOW_STATE" "$sid" 2>"${_classify_err:-/dev/null}"); then
      :
    else
      _guard_rc=$?
      echo "WARNING: _resolve-cross-session-guard.sh exited non-zero (rc=$_guard_rc) — design contract violation (helper should always exit 0) [writer]" >&2
      classification=""
    fi
    if [ -n "$_classify_err" ] && [ -s "$_classify_err" ]; then
      # state-read.sh の同 pass-through ブロック (reader 側) と writer/reader 対称化。
      # `_resolve-cross-session-guard.sh` の `head -3 "$_jq_err"` ブロックが出力する生 `jq:`
      # parse error 行 (line/column 診断) を pass-through し、dead-observability を回避する。
      # grep 自身の失敗 (binary 異常 / OOM 等) も classify err pass-through path で
      # silent suppression しないよう、`|| true` を撤去し WARNING に昇格する。
      if ! grep -E '^WARNING:|^  |^jq: ' "$_classify_err" >&2; then
        local _grep_classify_rc=$?
        if [ "$_grep_classify_rc" -ne 1 ]; then
          # rc=1 は legitimate no-match。rc>=2 は grep binary error / file I/O error の兆候。
          echo "WARNING: _classify_err pass-through grep failed (rc=$_grep_classify_rc) — diagnostic output may be incomplete" >&2
        fi
      fi
    fi
    [ -n "$_classify_err" ] && rm -f "$_classify_err"
    _classify_err=""
    # restore default trap (subshell exit 前のクリーンアップ — subshell isolation 前提で leak は発生しないが、
    # canonical pattern として future-proof な再 install ガードを維持する。詳細は本関数
    # `_resolve_session_state_path` の `── trap reset の正当性 ──` コメントブロックを参照)
    trap - EXIT INT TERM HUP
    # PR #688 followup F-01 MEDIUM: foreign:* / corrupt:* / invalid_uuid:* arm の workflow-incident-emit.sh
    # 呼び出しブロックを `_emit-cross-session-incident.sh` helper に集約 (state-read.sh と writer/reader 対称)。
    case "$classification" in
      same|empty)
        # Same session or sessionless legacy: safe to take over
        echo "$LEGACY_FLOW_STATE"
        return 0
        ;;
      foreign:*)
        # Cross-session residue: refuse takeover, emit canonical incident sentinel via helper
        # (caller will see --if-exists silent skip on per-session path or non-existence error,
        #  prompting create-mode init which is the correct behavior for fresh sessions)
        local legacy_sid="${classification#foreign:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" foreign writer "$sid" "$legacy_sid"
        echo "WARNING: refusing to write to legacy flow-state (session_id=${legacy_sid}) from current session (sid=${sid}). Routing to per-session path (--if-exists will silent skip, create-mode will init)." >&2
        ;;
      corrupt:*)
        # jq 失敗 (corrupt JSON / IO error) → take over は不安全 (cross-session の可能性を否定できない)
        local jq_rc="${classification#corrupt:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" corrupt writer "$sid" "$LEGACY_FLOW_STATE" "$jq_rc"
        echo "WARNING: legacy flow-state ${LEGACY_FLOW_STATE} jq parse failed; routing to per-session path (create-mode will init)." >&2
        ;;
      invalid_uuid:*)
        # legacy.session_id が JSON-parseable だが UUID validation 失敗 (tampered / legacy schema)。
        local invalid_uuid_rc="${classification#invalid_uuid:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" invalid_uuid writer "$sid" "$LEGACY_FLOW_STATE" "$invalid_uuid_rc"
        echo "WARNING: legacy flow-state ${LEGACY_FLOW_STATE} session_id failed UUID validation (tampered / legacy schema); routing to per-session path." >&2
        ;;
      *)
        # 想定外の classification (defensive)
        echo "WARNING: unexpected classification from _resolve-cross-session-guard.sh: $classification" >&2
        ;;
    esac
  fi
  echo "$per_session_path"
}

# --- Argument parsing ---
MODE="${1:-}"
# 旧 `(( $# > 0 )) && shift` は `$#=0` で `(( 0 > 0 ))` が rc=1 を返し、行末 rc=1 のまま続行する経路があった。
# bash `&&` chain の中間失敗は `set -e` の発火対象外 (POSIX/bash manual: "the shell does not exit if the command
# that fails is part of ... a && or || list" — `set -e` 自体が直接 kill する経路はない) だが、行末 rc=1 が
# `pipefail` 下や caller の `if !` 判定で誤シグナルになる経路を完全には塞げない。`if-then-fi` 形式 (rc=0 保証) に
# 書き換えて bash `(( ))` の rc 仕様への暗黙依存を解消する。
if [ $# -gt 0 ]; then
  shift
fi

PHASE=""
ISSUE=0
BRANCH=""
PR=0
PARENT_ISSUE=0
NEXT=""
ACTIVE=""
IF_EXISTS=false
FIELD=""
SESSION=""
PRESERVE_ERROR_COUNT=false
LEGACY_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)    PHASE="$2"; shift 2 ;;
    --issue)    ISSUE="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --pr)       PR="$2"; shift 2 ;;
    --parent-issue) PARENT_ISSUE="$2"; shift 2 ;;
    --next)     NEXT="$2"; shift 2 ;;
    --active)   ACTIVE="$2"; shift 2 ;;
    --if-exists) IF_EXISTS=true; shift ;;
    --preserve-error-count) PRESERVE_ERROR_COUNT=true; shift ;;
    --legacy-mode) LEGACY_MODE=true; shift ;;
    --field)    FIELD="$2"; shift 2 ;;
    --session)  SESSION="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validate numeric/boolean argument values (defense-in-depth, Issue #688 F-10) ---
# create mode の `--argjson` は値を JSON literal として parse するため、object literal
# (`{"x":1}`) や string (`"foo"`) も受理されてしまう。increment mode の FIELD allowlist
#  と対称な writer side validation として、数値/boolean 引数を allowlist で
# 検証する。work-memory-update.sh の `_validate_numeric_yaml_value` と同型の defense-in-depth。
# Issue title 等の dynamic 文字列が `--issue` に流入する経路があれば flow-state JSON 破壊で
# stop-guard / phase-transition-whitelist hook の判定が壊れ workflow が hard abort する経路を防ぐ。
case "${ISSUE:-0}" in
  ''|*[!0-9]*) echo "ERROR: --issue must be non-negative integer (got: '$ISSUE')" >&2; exit 1 ;;
esac
case "${PR:-0}" in
  ''|*[!0-9]*) echo "ERROR: --pr must be non-negative integer (got: '$PR')" >&2; exit 1 ;;
esac
case "${PARENT_ISSUE:-0}" in
  ''|*[!0-9]*) echo "ERROR: --parent-issue must be non-negative integer (got: '$PARENT_ISSUE')" >&2; exit 1 ;;
esac
case "${ACTIVE:-true}" in
  true|false) ;;
  *) echo "ERROR: --active must be true or false (got: '$ACTIVE')" >&2; exit 1 ;;
esac

# --- Resolve effective schema version and target flow-state path ---
# session_id is needed for both create/patch/increment to route writes to the
# session-owned file when schema_version=2. patch/increment auto-read from
# .rite-session-id when --session is not provided (caller-side simplification).
if ! SESSION=$(_resolve_session_id "$SESSION"); then
  exit 1
fi
SCHEMA_VERSION=$(_resolve_schema_version)
if [[ "$LEGACY_MODE" == "true" ]]; then
  EFFECTIVE_SCHEMA_VERSION="1"
else
  EFFECTIVE_SCHEMA_VERSION="$SCHEMA_VERSION"
fi
FLOW_STATE=$(_resolve_session_state_path "$EFFECTIVE_SCHEMA_VERSION" "$LEGACY_MODE" "$SESSION")

# Ensure parent directory exists for the new format. The path-based check below
# is the single source of truth — `_resolve_session_state_path` already encodes
# the (schema_version, legacy_mode, session_id) decision, so we just compare the
# resolved path to the legacy fallback (review #686 F-04). Failures surface via
# `_log_flow_diag` (symmetric with mv-failure path) rather than being silently
# suppressed (review #686 F-05).

# writer/reader 対称化 doctrine (state-read.sh の `_rite_state_read_cleanup`
# 関数 — `rm -f "${_classify_err:-}" "${_jq_err:-}"` ブロックと同型) に従い、atomic-cleanup 関数を
# 3 変数 (TMP_STATE / _mkdir_err / _jq_err) に拡張し、`_mkdir_err` (本ファイル前段の dir-creation
# block 内 mktemp) と `_jq_err` (create mode の PREV_PHASE 抽出 jq stderr 用 mktemp) を含む全
# tempfile の lifecycle を cover する位置に trap を前倒し配置する。旧実装の trap (atomic write
# block 直前の TMP_STATE 専用 cleanup) は TMP_STATE のみ cleanup で、`_mkdir_err` / `_jq_err` の
# mktemp 〜 rm 区間で SIGINT/SIGTERM/SIGHUP 到達時に orphan tempfile が leak する非対称があった
# (HIGH)。canonical pattern「パス先行宣言 → trap 先行設定 → mktemp」を踏襲する。
TMP_STATE=""
_mkdir_err=""
_jq_err=""
# _chmod_err / _chmod600_err / _ownership_jq_err も
# atomic cleanup の対象に含める。これらは mktemp 〜 inline rm の短い lifetime だが、SIGINT/SIGTERM/SIGHUP
# が mktemp 成功直後〜rm 到達前に届くと orphan として残る。`/tmp` inode 枯渇を防ぐため、本トラップで
# 全 tempfile lifecycle を cover する。`${var:-}` で未代入時も safe (rm -f "" は idempotent no-op)。
_chmod_err=""
_chmod600_err=""
_ownership_jq_err=""
_existing_parent_err=""
# # create/patch/increment mode 各々の jq stderr tempfile も atomic cleanup の対象に追加。
# 旧実装は で 7 変数までしか cover せず、本 3 変数は mktemp 直後〜inline rm の race
# window で SIGINT/SIGTERM/SIGHUP が届いた場合に orphan として `/tmp` に残留する設計欠陥があった
# (doctrine 約束「全 tempfile lifecycle cover」との factual mismatch)。
_create_write_jq_err=""
_patch_jq_err=""
_inc_jq_err=""
_rite_flow_state_atomic_cleanup() {
  rm -f "${TMP_STATE:-}" "${_mkdir_err:-}" "${_jq_err:-}" \
        "${_chmod_err:-}" "${_chmod600_err:-}" "${_ownership_jq_err:-}" \
        "${_existing_parent_err:-}" "${_create_write_jq_err:-}" \
        "${_patch_jq_err:-}" "${_inc_jq_err:-}"
}
trap 'rc=$?; _rite_flow_state_atomic_cleanup; exit $rc' EXIT
trap '_rite_flow_state_atomic_cleanup; exit 130' INT
trap '_rite_flow_state_atomic_cleanup; exit 143' TERM
trap '_rite_flow_state_atomic_cleanup; exit 129' HUP

if [[ "$FLOW_STATE" != "$LEGACY_FLOW_STATE" ]]; then
  _flow_state_dir=$(dirname "$FLOW_STATE")
  # Capture mkdir stderr so the kernel's specific failure reason
  # (`mkdir: cannot create directory '...': Not a directory` / `Permission denied` /
  # `No space left on device` 等) reaches the user instead of being suppressed
  # to /dev/null (review #686 LOW). Symmetric with the create-mode
  # `_jq_err` capture pattern.
  # mktemp 失敗時に WARNING emit。旧実装 `2>/dev/null || _mkdir_err=""` は silent fallback で
  # writer/reader 対称化 doctrine と矛盾していた (reader 側 state-read.sh の _mktemp-stderr-guard.sh
  # invocation block は対応済み)。/tmp full / SELinux deny 環境で mkdir 失敗 line/column が失われる
  # 二重 silent failure を防ぐ。共通 helper `_mktemp-stderr-guard.sh` 経由で Stderr emit + chmod 600
  # + path return を集約。
  _mkdir_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
    "flow-state-update" "flow-state-mkdir-err" \
    "mkdir 失敗時の error 詳細が表示されません")
  if ! mkdir -p "$_flow_state_dir" 2>"${_mkdir_err:-/dev/null}"; then
    # _log_flow_diag is defined later in the file; inline the diag write here
    # because we exit before reaching that definition's call sites.
    _diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
    # M-4 対応: diag log 書込み失敗を完全 silent にせず WARNING を 1 行 emit。
    # 旧 `|| true` は disk full / permission denied で post-hoc audit-trail 検出経路が完全に途絶える。
    if ! echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] flow_state_mkdir_failed path=$_flow_state_dir" >> "$_diag_file" 2>/dev/null; then
      echo "WARNING: diag log append failed: $_diag_file (post-hoc audit-trail unavailable)" >&2
    fi
    echo "ERROR: failed to create $_flow_state_dir (permission denied / disk full / parent is a regular file?)" >&2
    if [ -n "$_mkdir_err" ] && [ -s "$_mkdir_err" ]; then
      head -3 "$_mkdir_err" | sed 's/^/  /' >&2
    fi
    [ -n "$_mkdir_err" ] && rm -f "$_mkdir_err"
    _mkdir_err=""  # trap による double-rm 防止
    exit 1
  fi
  [ -n "$_mkdir_err" ] && rm -f "$_mkdir_err"
  _mkdir_err=""  # trap による double-rm 防止
  # F-09 (MEDIUM, security Hypothetical exception): .rite/sessions/ ディレクトリにも chmod 700 を
  # 適用 (.rite-work-memory dir と同型)。multi-user CI runner / shared dev host で session metadata が
  # group-readable になる経路を防ぐ。chmod 失敗は best-effort skip (filesystem が ACL 非対応 / SELinux
  # 制約等で chmod 不能な環境でも flow-state 機能は維持する)。
  # chmod 失敗時は WARNING + stderr 先頭行を pass-through し、busybox 環境 (ACL 非対応で
  # 設計通り skip) か permission denied (defense-in-depth が外れる異常状態) を区別可能にする。
  _chmod_err=$(mktemp /tmp/rite-fs-chmod-err-XXXXXX 2>/dev/null) || _chmod_err=""
  if ! chmod 700 "$_flow_state_dir" 2>"${_chmod_err:-/dev/null}"; then
    echo "WARNING: chmod 700 failed: $_flow_state_dir (best-effort skip — defense-in-depth depth lost on non-POSIX/busybox env)" >&2
    # head -1 → head -3 統一
    # (ACL/SELinux 環境で kernel diagnostic が複数行になるケースを cover、他 site の head -3 doctrine に整合)
    if [ -n "$_chmod_err" ] && [ -s "$_chmod_err" ]; then
      head -3 "$_chmod_err" | sed 's/^/  /' >&2
    fi
  fi
  [ -n "$_chmod_err" ] && rm -f "$_chmod_err"
  _chmod_err=""
  # 旧実装の `unset _mkdir_err` は trap cleanup の `${_mkdir_err:-}` で問題ないが、
  # writer/reader 対称化 doctrine に従い再代入で "" に戻す (state-read.sh の `_classify_err=""`
  # 再代入ブロック — _classify_err inline rm 直後の writer 対称化コメント箇所と同型)。
  unset _flow_state_dir
fi

# --- Validation ---
# verified-review I-1 対応: --if-exists skip path で lock file を残さないため、
# 先に validation を実行する。--if-exists で file 不在を検出した場合、lock 取得前に exit 0 する
# (旧実装は flock 取得後に validation していたため、--if-exists skip で `.flow-state.lock` が
# disk に残留し、`.rite/sessions/` に session 数分の lock file が累積していた)。
case "$MODE" in
  create)
    if [[ -z "$PHASE" || -z "$NEXT" ]]; then
      echo "ERROR: create mode requires --phase and --next" >&2
      exit 1
    fi
    ;;
  patch)
    if [[ -z "$PHASE" || -z "$NEXT" ]]; then
      echo "ERROR: patch mode requires --phase and --next" >&2
      exit 1
    fi
    if [[ "$IF_EXISTS" == true && ! -f "$FLOW_STATE" ]]; then
      # silent skip 時に INFO を stderr に emit して post-hoc event reconstruction を可能にする
      # (旧 silent exit 0 は audit-trail を残さなかった)。
      echo "INFO: --if-exists patch skipped (file not present): $FLOW_STATE" >&2
      exit 0
    fi
    ;;
  increment)
    if [[ -z "$FIELD" ]]; then
      echo "ERROR: increment mode requires --field" >&2
      exit 1
    fi
    # FIELD allowlist validation — state-read.sh の FIELD allowlist block と writer/reader 対称化。
    # 現 caller は commands/issue/start.md の implementation_round 増分箇所で同名フィールドを
    # ハードコードしているのみだが、FIELD は `_log_flow_diag "flow_state_jq_failed mode=increment field=$FIELD"`
    # で .rite-stop-guard-diag.log に書き込まれるため、改行を含む FIELD で log 形式破壊が可能。
    # helper API 単体としての defense-in-depth gap を埋めるため、識別子 (英数字 + _) のみ受理する。
    if ! [[ "$FIELD" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      echo "ERROR: invalid field name: $FIELD" >&2
      echo "  field name must match ^[a-zA-Z_][a-zA-Z0-9_]*\$ (state-read.sh と対称化)" >&2
      exit 1
    fi
    if [[ "$IF_EXISTS" == true && ! -f "$FLOW_STATE" ]]; then
      # increment mode の --if-exists silent skip も INFO emit する (patch mode と対称)。
      echo "INFO: --if-exists increment skipped (file not present): $FLOW_STATE" >&2
      exit 0
    fi
    ;;
  *)
    echo "ERROR: Unknown mode: $MODE (expected: create, patch, increment)" >&2
    exit 1
    ;;
esac

# >>> DRIFT-CHECK ANCHOR: flow_state_advisory_lock <<<
# HIGH-1 race condition defense: 個人開発で並列 session 運用は実質ないが、resume /
# cleanup / wiki ingest / sprint team-execute / dogfooding で同一 session_id を持つ
# 複数プロセスが衝突する経路があるため、advisory lock (fd 9) を取得する。lock は
# script exit 時に kernel が自動解放する (`exec 9>` で開いた fd の lifecycle = process)。
# flock 不在環境 (busybox 等) では non-locking mode で best-effort 継続 (WARNING を emit
# して silent skip を回避)。
#
# Position (verified-review I-1 対応で変更): validation block の後に置く。--if-exists skip path で
# lock file を作成しないようにするため、create / patch / increment の必須引数検証と --if-exists の
# file 不在チェックが通った後 (= 実際に atomic write を実行する経路に限定) で lock を取得する。
# 旧実装は mkdir block 直後で lock を取っていたため、--if-exists patch/increment の skip exit で
# `.flow-state.lock` が disk に残留し、`.rite/sessions/` に session 数分の lock file が
# 累積する disk-pollution の原因になっていた (code-reviewer I-1)。
if command -v flock >/dev/null 2>&1; then
  FLOW_STATE_LOCK_FILE="${FLOW_STATE}.lock"
  # (#926):
  # 旧実装は `exec 9>"$LOCK" 2>"${_lock_open_err:-/dev/null}"` で fd 9 と fd 2 の両方を redirect していた。
  # `exec` (コマンドなし) は POSIX/Bash 仕様で current shell に redirection を適用するため、`2>...` が
  # **親 shell の fd 2 を恒久 redirect** する副作用があり、後段の `rm -f "$_lock_open_err"` で error
  # message が消失する silent failure を引き起こしていた (flow-state-update.test.sh で 2 件 FAIL の根本原因)。
  # 修正: 親 shell の fd 9 を確実に開きたい以上、`exec 9>` の stderr 退避はそのままでは不可能。
  # diagnostic 詳細を諦めて redirect を削除する (lock file open 失敗は permission denied / ENOSPC /
  # ENOENT 等が主因で、kernel の error メッセージは fd 2 経由で stderr に直接出力される)。
  # Source: bash(1) man page "REDIRECTION" / [Linux Journal: Bash Redirections Using Exec]
  if exec 9>"$FLOW_STATE_LOCK_FILE"; then
    if ! flock -w 30 9; then
      echo "ERROR: flow-state advisory lock 取得に失敗しました (30s timeout): $FLOW_STATE_LOCK_FILE" >&2
      echo "  対処: 別 session が同じ flow-state を更新中です。fuser/lsof で lock holder の PID を" >&2
      echo "  特定し、停止後に lock file を削除してください (lock file 単独削除は fd lifecycle 内では無効)" >&2
      exit 1
    fi
  else
    # lock file open 失敗時のデフォルトは fail-fast。race protection は load-bearing で、silent disable は
    # sprint team-execute / wiki ingest / dogfooding 経路で flow-state 破壊を再発させるリスクが大きい。
    # 環境変数 RITE_ALLOW_UNLOCKED_FLOW_STATE=true で明示的に opt-out できる (best-effort 続行)。
    if [ "${RITE_ALLOW_UNLOCKED_FLOW_STATE:-false}" = "true" ]; then
      echo "WARNING: lock file open に失敗 ($FLOW_STATE_LOCK_FILE)。RITE_ALLOW_UNLOCKED_FLOW_STATE=true により non-locking mode で続行 (HIGH-1 race protection なし)" >&2
      echo "  原因候補: permission denied / parent dir 不在 / disk full (kernel error は上記行直前に出力)" >&2
    else
      echo "ERROR: lock file open に失敗 ($FLOW_STATE_LOCK_FILE)。race protection なしでは続行できません" >&2
      echo "  対処: $(dirname "$FLOW_STATE_LOCK_FILE") の permission / 容量を確認、または RITE_ALLOW_UNLOCKED_FLOW_STATE=true で opt-out" >&2
      exit 1
    fi
  fi
else
  if [ "${RITE_ALLOW_UNLOCKED_FLOW_STATE:-false}" = "true" ]; then
    echo "WARNING: flock command 不在 (busybox 等)。RITE_ALLOW_UNLOCKED_FLOW_STATE=true により non-locking mode で続行" >&2
  else
    echo "ERROR: flock command 不在 (busybox 等)。race protection なしでは続行できません" >&2
    echo "  対処: util-linux (flock) をインストール、または RITE_ALLOW_UNLOCKED_FLOW_STATE=true で opt-out" >&2
    exit 1
  fi
fi

# --- Atomic write ---
# 旧実装は (a) PID-suffix
# silent fallback で symlink race 攻撃面が増加し、(b) compound 単一行 trap が
# canonical bash-trap-patterns.md 4-line signal-specific pattern と乖離していた。
# 本 PR の writer/reader 対称化 doctrine と整合させるため、(1) mktemp 失敗時は
# fail-fast (atomic write 不能 = exit 1)、(2) 4-line signal-specific trap で
# SIGINT/SIGTERM/SIGHUP の POSIX exit code 130/143/129 を返す pattern に統一する。
# canonical trap pattern: references/bash-trap-patterns.md#signal-specific-trap-template
#
# trap setup を本ファイルの dir-creation block 直前に前倒し済み。
# `_rite_flow_state_atomic_cleanup` は TMP_STATE / _mkdir_err / _jq_err の 3 変数を cover する。
# 旧 で確立した「パス先行宣言 → trap 先行設定 → mktemp」順序の延長で、
# `_mkdir_err` (dir-creation block 内 mktemp) と create-mode の `_jq_err` (PREV_PHASE 抽出 jq
# stderr 用 mktemp) の race window も同 trap で構造的に保護する。本箇所では既に
# declared/installed 済みの TMP_STATE への mktemp のみ実行する。

if ! TMP_STATE=$(mktemp "${FLOW_STATE}.XXXXXX" 2>/dev/null); then
  echo "ERROR: flow-state-update.sh: TMP_STATE の mktemp に失敗しました (atomic write 不能)" >&2
  echo "  対処: $(dirname "$FLOW_STATE") の容量 / permission / read-only filesystem を確認してください" >&2
  # _log_flow_diag 関数は本ブロックの後段 (この case 文の直後) で定義されるため、ここでは inline で
  # diag log を書き込む。関数名 anchor で定義位置を semantic に参照する (で hardcoded
  # 行番号 L332 から関数名 anchor に置換)。
  _diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
  # M-4 対応: diag log 書込み失敗を完全 silent にせず WARNING を 1 行 emit。
  if ! echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] tmp_state_mktemp_failed path=${FLOW_STATE}" >> "$_diag_file" 2>/dev/null; then
    echo "WARNING: diag log append failed: $_diag_file (post-hoc audit-trail unavailable for tmp_state_mktemp_failed)" >&2
  fi
  unset _diag_file
  exit 1
fi

# F-09 (MEDIUM, security Hypothetical exception) / 訂正:
# atomic-write tempfile に chmod 600 を **defense-in-depth として明示適用**。
# **重要 — factual correction **: 旧コメント「mktemp `${FLOW_STATE}.XXXXXX` で multi-user
# umask 022 環境では 644 で作成され」は GNU coreutils mktemp の実装と矛盾する factual error だった
# (man mktemp coreutils:「The file is created with mode 0600」)。実機検証済み: `umask 022; mktemp
# /tmp/test-XXXXXX` → mode 0600。したがって本 chmod 600 は **mktemp の OS デフォルト (600)** を冗長
# に強制するもので、現行 GNU coreutils 環境では機能上の差はない。
# それでも保持する理由 — defense-in-depth:
#   (1) 将来 mktemp 実装が変更された場合の保険
#   (2) 非 GNU 環境 (一部の BSD / busybox 等) への移植性
#   (3) 同 PR で他 helper (state-read.sh _jq_err / _resolve-cross-session-guard.sh /
#       _resolve-session-id-from-file.sh) と対称化を維持し、コードレビュー時の認知負荷を均一化
# Source: man mktemp (coreutils): "The file is created with mode 0600"
# multi-user CI runner / shared dev host で session_id・issue_number・branch・phase 等の metadata と
# (将来) 機密値を含む可能性がある file が他ユーザーに読まれる経路を構造的に塞ぐ。chmod 失敗は
# best-effort skip (と対称)。
# chmod 失敗時は WARNING + stderr 先頭行を pass-through し、busybox 環境 (ACL 非対応で
# 設計通り skip) か permission denied (defense-in-depth が外れる異常状態) を区別可能にする。
_chmod600_err=$(mktemp /tmp/rite-fs-chmod600-err-XXXXXX 2>/dev/null) || _chmod600_err=""
if ! chmod 600 "$TMP_STATE" 2>"${_chmod600_err:-/dev/null}"; then
  echo "WARNING: chmod 600 failed: $TMP_STATE (best-effort skip — defense-in-depth depth lost on non-POSIX/busybox env)" >&2
  # head -1 → head -3 統一 (M-7 と対称)
  if [ -n "$_chmod600_err" ] && [ -s "$_chmod600_err" ]; then
    head -3 "$_chmod600_err" | sed 's/^/  /' >&2
  fi
fi
[ -n "$_chmod600_err" ] && rm -f "$_chmod600_err"
_chmod600_err=""

# 永続 diag log: stderr 経由の WARNING に加えて audit-trail としてファイルに append する。
# stderr だけだと caller が stderr を suppress した場合に痕跡が完全に消えるため、disk full /
# permission denied を tolerate しつつ可視化する。
# 注: log ファイル名 `.rite-stop-guard-diag.log` は撤去済 stop-guard.sh 時代の慣行を歴史的に踏襲
# (rename は migration コスト > 命名整合性 のため見送り)。ring buffer truncation はかつて
# stop-guard.sh 側で発火していたが #675 撤去後は append-only となり無限増殖する設計欠陥が残る
# — 別 Issue で truncation ロジックを本関数 inline 化する必要あり。
_log_flow_diag() {
  local diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
  # 他 2 site の WARNING emit pattern と対称化: diag log append 失敗 (disk full /
  # permission denied) を完全 silent にせず WARNING を 1 行 emit する。旧 `|| true` は
  # post-hoc audit-trail 検出経路が disk full 状況で site ごとに非対称に silent suppress されていた。
  if ! echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1" >> "$diag_file" 2>/dev/null; then
    echo "WARNING: diag log append failed: $diag_file (post-hoc audit-trail unavailable for: $1)" >&2
  fi
}

case "$MODE" in
  create)
    # Default active to true if not explicitly specified
    if [[ -z "$ACTIVE" ]]; then
      ACTIVE="true"
    fi
    # session_id is now resolved upfront via _resolve_session_id() (see top-level
    # block after arg parsing). The previous in-mode auto-read (#216) is folded
    # into the helper so patch/increment also benefit.
    # Session ownership: overwrite protection for active state owned by another session
    # 各 jq/helper 失敗を stderr 退避して WARNING に昇格する。silent fallback (`|| _existing_active="false"`)
    # は session ownership check を「無所有」扱いに silent 倒し、別 session の workflow を上書きする
    # 経路を生む load-bearing logic のため、jq 失敗 (corrupt JSON / IO error) を可視化する。
    if [[ -n "$SESSION" && -f "$FLOW_STATE" ]]; then
      _ownership_jq_err=$(mktemp /tmp/rite-fs-own-jq-err-XXXXXX 2>/dev/null) || _ownership_jq_err=""
      # silent-failure-hunter IMP-3: 4 jq site で同一 tempfile を reuse するため、各 site の
      # 直前で truncate して前 site の stale stderr が `head -1` 経由で誤誘導しないようにする
      # (`error-count-runtime-reference.test.sh` の `: > "$_err" # truncate before reuse` canonical pattern と同型、構造 anchor で参照)。後段 site の判定経路は前 site
      # の進行 gate (`if [[ $_existing_active == "true" ]]`) で限定的だが、defense-in-depth で全 site truncate。
      [ -n "$_ownership_jq_err" ] && : > "$_ownership_jq_err"
      if ! _existing_active=$(jq -r '.active // false' "$FLOW_STATE" 2>"${_ownership_jq_err:-/dev/null}"); then
        echo "WARNING: session-ownership .active 抽出 jq 失敗 ($FLOW_STATE) — fail-safe で active=true として扱い ownership check を強制" >&2
        [ -n "$_ownership_jq_err" ] && [ -s "$_ownership_jq_err" ] && head -3 "$_ownership_jq_err" | sed 's/^/  /' >&2
        # fail-safe `true` に倒す: jq 失敗で `false` 扱いにすると ownership check が skip され
        # 別 session の state を silent 上書きする (state-read.sh / session-end.sh:127 の fail-safe `other`
        # と writer/reader 対称化)。"true と倒し → ownership check 強制" の方が
        # "false と倒し → 別 session 上書き" より安全。
        _existing_active="true"
      fi
      if [[ "$_existing_active" == "true" ]]; then
        [ -n "$_ownership_jq_err" ] && : > "$_ownership_jq_err"  # IMP-3: truncate before reuse
        if ! _existing_sid=$(get_state_session_id "$FLOW_STATE" 2>"${_ownership_jq_err:-/dev/null}"); then
          echo "WARNING: session-ownership session_id 抽出失敗 ($FLOW_STATE) — defaulting to empty" >&2
          [ -n "$_ownership_jq_err" ] && [ -s "$_ownership_jq_err" ] && head -3 "$_ownership_jq_err" | sed 's/^/  /' >&2
          _existing_sid=""
        fi
        if [[ -n "$_existing_sid" && "$_existing_sid" != "$SESSION" ]]; then
          # Different session owns the state — check staleness
          [ -n "$_ownership_jq_err" ] && : > "$_ownership_jq_err"  # IMP-3: truncate before reuse
          if ! _updated_at=$(jq -r '.updated_at // empty' "$FLOW_STATE" 2>"${_ownership_jq_err:-/dev/null}"); then
            echo "WARNING: session-ownership .updated_at 抽出 jq 失敗 ($FLOW_STATE) — defaulting to empty (staleness check 不能)" >&2
            [ -n "$_ownership_jq_err" ] && [ -s "$_ownership_jq_err" ] && head -3 "$_ownership_jq_err" | sed 's/^/  /' >&2
            _updated_at=""
          fi
          if [[ -n "$_updated_at" ]]; then
            [ -n "$_ownership_jq_err" ] && : > "$_ownership_jq_err"  # IMP-3: truncate before reuse
            if ! _state_epoch=$(parse_iso8601_to_epoch "$_updated_at" 2>"${_ownership_jq_err:-/dev/null}"); then
              echo "WARNING: session-ownership ISO8601 parse 失敗 ($_updated_at) — defaulting epoch=0 (stale 扱い)" >&2
              [ -n "$_ownership_jq_err" ] && [ -s "$_ownership_jq_err" ] && head -3 "$_ownership_jq_err" | sed 's/^/  /' >&2
              _state_epoch=0
            fi
            _now_epoch=$(date +%s)
            _diff=$((_now_epoch - _state_epoch))
            if [[ "$_diff" -le 7200 ]]; then
              echo "ERROR: 別のワークフローが進行中です（2時間以内に更新）。" >&2
              echo "INFO: 上書きするには先に /rite:resume で所有権を移転するか、2時間待ってください。" >&2
              exit 1
            fi
          fi
        fi
      fi
      [ -n "$_ownership_jq_err" ] && rm -f "$_ownership_jq_err"
      _ownership_jq_err=""
    fi
    # Capture previous phase for whitelist-based transition verification (#490).
    # When the state file is absent, previous_phase is "" (legitimate cold start).
    # When the file exists but is corrupt, fail-fast — silently treating corruption
    # as a cold start would erase the prior phase and effectively bypass the
    # whitelist for the next transition (error-handling CRITICAL #2).
    # Error messages reference $FLOW_STATE (the resolved path) rather than the
    # legacy literal `.rite-flow-state` so users running on schema_version=2
    # see the actual per-session path (review #686 F-06).
    PREV_PHASE=""
    if [[ -f "$FLOW_STATE" ]]; then
      if [[ ! -s "$FLOW_STATE" ]]; then
        echo "ERROR: flow-state file exists but is empty: $FLOW_STATE" >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: $FLOW_STATE を /rite:resume で復旧するか、既存ファイルを削除してから再度 /rite:issue:start を実行" >&2
        exit 1
      fi
      # Validate JSON parse; distinguish "missing .phase" (acceptable → "") from
      # "jq parse error" (corrupt state, must not silently fall back).
      # mktemp 失敗時に WARNING emit (writer/reader 対称化、reader 側 state-read.sh の
      # _mktemp-stderr-guard.sh invocation block と統一)。
      # 共通 helper `_mktemp-stderr-guard.sh` 経由で Stderr emit + chmod 600 + path return を集約。
      _jq_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
        "flow-state-update" "flow-state-jq-err" \
        "jq 失敗時の parse error 詳細が表示されません (caller は corrupt JSON を検知できますが原因 line/column が失われます)")
      if PREV_PHASE=$(jq -r '.phase // ""' "$FLOW_STATE" 2>"${_jq_err:-/dev/null}"); then
        : # jq ok
      else
        echo "ERROR: flow-state file parse failed: $FLOW_STATE" >&2
        [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  /' >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: $FLOW_STATE を確認し、必要なら /rite:resume で復旧してください" >&2
        [ -n "$_jq_err" ] && rm -f "$_jq_err"
        _jq_err=""  # trap による double-rm 防止
        exit 1
      fi
      [ -n "$_jq_err" ] && rm -f "$_jq_err"
      _jq_err=""  # trap による double-rm 防止 (state-read.sh の `_classify_err=""` 再代入と同型)
      # Preserve parent_issue_number from existing state when --parent-issue is not
      # explicitly specified (#497). Without this, every create call that omits
      # --parent-issue would reset parent_issue_number to 0, erasing the value
      # persisted by Phase 2.4 Mandatory After.
      #
      # 旧 `2>/dev/null || _existing_parent=0` は
      # session-ownership block の jq sites と非対称な silent fallback だった。本 jq は parent
      # tracking の load-bearing read で、jq 失敗時に silent に 0 倒すと別 session の parent linkage を
      # silent に切る経路を持つ。WARNING + stderr-tempfile pattern (session-ownership block と対称)
      # に統一する。`_existing_parent_err` も atomic cleanup の対象として再利用する _ownership_jq_err と同じ
      # tempfile pool を流用 (trap は既に登録済み)。
      if [[ "$PARENT_ISSUE" -eq 0 ]]; then
        _existing_parent_err=$(mktemp /tmp/rite-fs-parent-jq-err-XXXXXX 2>/dev/null) || _existing_parent_err=""
        if ! _existing_parent=$(jq -r '.parent_issue_number // 0' "$FLOW_STATE" 2>"${_existing_parent_err:-/dev/null}"); then
          echo "WARNING: parent_issue_number 抽出 jq 失敗 ($FLOW_STATE) — defaulting to 0 (parent linkage may silently drop)" >&2
          [ -n "$_existing_parent_err" ] && [ -s "$_existing_parent_err" ] && head -3 "$_existing_parent_err" | sed 's/^/  /' >&2
          _existing_parent=0
        fi
        [ -n "$_existing_parent_err" ] && rm -f "$_existing_parent_err"
        _existing_parent_err=""
        if [[ "$_existing_parent" =~ ^[0-9]+$ ]] && [[ "$_existing_parent" -ne 0 ]]; then
          PARENT_ISSUE="$_existing_parent"
        fi
      fi
    fi
    # mv 失敗 path も診断メッセージを出す (歴史的対称化: stop-guard.sh の error_count atomic write
    # block と同型 pattern だったが、stop-guard.sh 自体は #675 で撤去済。本 mv 失敗 path は patch /
    # increment mode の atomic write block と現役で対称)。
    # `set -euo pipefail` 下で mv 失敗は script を非 0 exit させるが、else branch は jq 失敗のみを
    # surface するため、disk full / permission denied / EXDEV 等の mv 失敗要因が silent に握りつぶされる。
    #
    # #678: schema_version=2 (Option A per-session file) では create object に schema_version: 2 を含め、
    # Migration 検出条件「schema_version キー無 or < 2」(design doc Migration 戦略) と整合させる。
    # legacy mode では schema_version field を含めず、旧形式 reader (#3-#5 移行前の hook 群) との
    # bytewise 互換を保つ。
    #
    # DRY (review #686 F-02): 旧実装は 11 フィールドの object literal を if/else で全コピーしており、
    # 将来の field 追加で片方を更新し忘れる drift リスクがあった。共通 base を 1 か所に定義し、
    # 新形式は jq の object merge `+` で `schema_version: 2` を prepend する。
    _create_base='{active: $active, issue_number: $issue, branch: $branch, phase: $phase, previous_phase: $prev_phase, pr_number: $pr, parent_issue_number: $parent_issue, next_action: $next, updated_at: $ts, session_id: $sid, last_synced_phase: ""}'
    if [[ "$EFFECTIVE_SCHEMA_VERSION" == "2" ]]; then
      _create_filter="{schema_version: 2} + $_create_base"
    else
      _create_filter="$_create_base"
    fi
    # HIGH-4 (writer/reader 対称化): create-mode atomic write jq の stderr を退避し、failure 時に
    # 詳細を pass-through する。L391-394 で $ACTIVE allowlist 防御済みのため、parse error は実質
    # 発生しにくいが、`$BRANCH` 等の動的値で予期せぬ制御文字が混入する経路への defense-in-depth として、
    # PREV_PHASE 抽出 jq の `_jq_err` 退避 pattern と対称化する。
    _create_write_jq_err=$(mktemp /tmp/rite-fs-create-write-jq-err-XXXXXX 2>/dev/null) || _create_write_jq_err=""
    if jq -n \
      --argjson active "$ACTIVE" \
      --argjson issue "$ISSUE" \
      --arg branch "$BRANCH" \
      --arg phase "$PHASE" \
      --arg prev_phase "$PREV_PHASE" \
      --argjson pr "$PR" \
      --argjson parent_issue "$PARENT_ISSUE" \
      --arg next "$NEXT" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
      --arg sid "$SESSION" \
      "$_create_filter" \
      > "$TMP_STATE" 2>"${_create_write_jq_err:-/dev/null}"; then
      if ! mv "$TMP_STATE" "$FLOW_STATE"; then
        _log_flow_diag "flow_state_mv_failed mode=create phase=$PHASE issue=$ISSUE"
        rm -f "$TMP_STATE"
        [ -n "$_create_write_jq_err" ] && rm -f "$_create_write_jq_err"
        echo "ERROR: mv failed (create mode): $TMP_STATE -> $FLOW_STATE (disk full / permission denied / EXDEV?)" >&2
        exit 1
      fi
    else
      _log_flow_diag "flow_state_jq_failed mode=create phase=$PHASE issue=$ISSUE"
      rm -f "$TMP_STATE"
      echo "ERROR: jq create failed" >&2
      if [ -n "$_create_write_jq_err" ] && [ -s "$_create_write_jq_err" ]; then
        head -3 "$_create_write_jq_err" | sed 's/^/  /' >&2
      fi
      [ -n "$_create_write_jq_err" ] && rm -f "$_create_write_jq_err"
      exit 1
    fi
    [ -n "$_create_write_jq_err" ] && rm -f "$_create_write_jq_err"
    ;;
  patch)
    # Build jq filter: always update phase, timestamp, next_action; conditionally update active.
    # Also capture the outgoing phase into previous_phase so stop-guard can verify the
    # transition whitelist (#490). Use the pre-update .phase value as previous_phase.
    #
    # --preserve-error-count: patch mode のデフォルトは `.error_count = 0` でリセットする
    # (phase transition は「進捗した」signal なのでエスカレーション counter をクリアするのが正しい)。
    # 同一 phase self-patch (例: create_post_interview → create_post_interview) で reset を回避したい
    # caller 向けに、flag 指定時は `.error_count = 0` 条項を omit して既存値を保持する。
    #
    # 現状の dead-code 状態: `stop-guard.sh` は #675 で撤去済で、本リポ内に `error_count` を runtime
    # 参照する reader は flow-state-update.sh / migrate-flow-state.sh 自身しか存在しない (機械検証:
    # `hooks/tests/error-count-runtime-reference.test.sh`)。したがって本 flag は production runtime
    # 影響を持たず、wiki/ingest.md / cleanup.md の residual caller は historical compatibility および
    # 将来 reader 再導入時の forward-compatible 装備として保持されている。
    # 詳細な経緯は `commands/issue/create-interview.md` 末尾 "Forward note" および ADR §3.1
    # (`docs/designs/parent-routing-unification.md`) を参照。ADR PR-2 で create.md Step 0/1
    # (Mandatory After Interview) は撤去済。
    if [[ "$PRESERVE_ERROR_COUNT" == "true" ]]; then
      JQ_FILTER='.previous_phase = (.phase // "") | .phase = $phase | .updated_at = $ts | .next_action = $next'
    else
      JQ_FILTER='.previous_phase = (.phase // "") | .phase = $phase | .updated_at = $ts | .next_action = $next | .error_count = 0'
    fi
    JQ_ARGS=(--arg phase "$PHASE" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" --arg next "$NEXT")
    if [[ -n "$ACTIVE" ]]; then
      JQ_FILTER="$JQ_FILTER | .active = (\$active_val == \"true\")"
      JQ_ARGS+=(--arg active_val "$ACTIVE")
    fi
    if [[ "$PARENT_ISSUE" -ne 0 ]]; then
      JQ_FILTER="$JQ_FILTER | .parent_issue_number = (\$parent_issue_val | tonumber)"
      JQ_ARGS+=(--arg parent_issue_val "$PARENT_ISSUE")
    fi
    # patch mode で session_id を書き戻す経路を追加。
    # 旧 resume.md は legacy direct jq write で `.session_id = $sid` を atomic 更新していた
    # (resume 時の所有権移転 semantics) が、 patch 経由化した際に session_id 書き戻しが
    # drop されていた。SESSION 変数は _resolve_session_id で resolve 済みなので、非空時に
    # patch filter に追加する (caller は自身の session が所有する flow-state を patch する設計のため安全)。
    if [[ -n "$SESSION" ]]; then
      JQ_FILTER="$JQ_FILTER | .session_id = \$session"
      JQ_ARGS+=(--arg session "$SESSION")
    fi
    # writer/reader 対称化 doctrine: create mode の PREV_PHASE 抽出 block 内 `[[ ! -s ]]` 空ファイル
    # guard を patch mode にも適用。0-byte ファイルが残った場合 (race / 部分書き込み crash) に
    # 「parse failed」一律文言で原因不明になる経路を塞ぐ。
    if [[ ! -s "$FLOW_STATE" ]]; then
      _log_flow_diag "flow_state_empty_file mode=patch phase=$PHASE"
      echo "ERROR: flow-state file exists but is empty (patch mode): $FLOW_STATE" >&2
      echo "  対処: 既存ファイルを削除してから create-mode で再初期化、または /rite:resume で復旧" >&2
      exit 1
    fi
    # HIGH-3 (writer/reader 対称化 doctrine): patch-mode jq の stderr を退避し、failure 時に
    # 詳細を pass-through する。create mode の `_jq_err` 退避 pattern と対称化。
    _patch_jq_err=$(mktemp /tmp/rite-fs-patch-jq-err-XXXXXX 2>/dev/null) || _patch_jq_err=""
    if jq "${JQ_ARGS[@]}" -- "$JQ_FILTER" "$FLOW_STATE" > "$TMP_STATE" 2>"${_patch_jq_err:-/dev/null}"; then
      if ! mv "$TMP_STATE" "$FLOW_STATE"; then
        _log_flow_diag "flow_state_mv_failed mode=patch phase=$PHASE"
        rm -f "$TMP_STATE"
        [ -n "$_patch_jq_err" ] && rm -f "$_patch_jq_err"
        echo "ERROR: mv failed (patch mode): $TMP_STATE -> $FLOW_STATE (disk full / permission denied / EXDEV?)" >&2
        exit 1
      fi
    else
      _log_flow_diag "flow_state_jq_failed mode=patch phase=$PHASE"
      rm -f "$TMP_STATE"
      echo "ERROR: flow-state file parse failed (patch mode): $FLOW_STATE" >&2
      if [ -n "$_patch_jq_err" ] && [ -s "$_patch_jq_err" ]; then
        head -3 "$_patch_jq_err" | sed 's/^/  /' >&2
      fi
      [ -n "$_patch_jq_err" ] && rm -f "$_patch_jq_err"
      exit 1
    fi
    [ -n "$_patch_jq_err" ] && rm -f "$_patch_jq_err"
    ;;
  increment)
    # HIGH-2 (writer/reader 対称化): increment mode にも空ファイル guard を適用。
    if [[ ! -s "$FLOW_STATE" ]]; then
      _log_flow_diag "flow_state_empty_file mode=increment field=$FIELD"
      echo "ERROR: flow-state file exists but is empty (increment mode): $FLOW_STATE" >&2
      echo "  対処: 既存ファイルを削除してから create-mode で再初期化、または /rite:resume で復旧" >&2
      exit 1
    fi
    # HIGH-3 (writer/reader 対称化): increment-mode jq の stderr を退避。
    _inc_jq_err=$(mktemp /tmp/rite-fs-inc-jq-err-XXXXXX 2>/dev/null) || _inc_jq_err=""
    if jq --arg field "$FIELD" \
       '.[$field] = ((.[$field] // 0) + 1)' \
       "$FLOW_STATE" > "$TMP_STATE" 2>"${_inc_jq_err:-/dev/null}"; then
      if ! mv "$TMP_STATE" "$FLOW_STATE"; then
        _log_flow_diag "flow_state_mv_failed mode=increment field=$FIELD"
        rm -f "$TMP_STATE"
        [ -n "$_inc_jq_err" ] && rm -f "$_inc_jq_err"
        echo "ERROR: mv failed (increment mode): $TMP_STATE -> $FLOW_STATE (disk full / permission denied / EXDEV?)" >&2
        exit 1
      fi
    else
      _log_flow_diag "flow_state_jq_failed mode=increment field=$FIELD"
      rm -f "$TMP_STATE"
      echo "ERROR: flow-state file parse failed (increment mode): $FLOW_STATE" >&2
      if [ -n "$_inc_jq_err" ] && [ -s "$_inc_jq_err" ]; then
        head -3 "$_inc_jq_err" | sed 's/^/  /' >&2
      fi
      [ -n "$_inc_jq_err" ] && rm -f "$_inc_jq_err"
      exit 1
    fi
    [ -n "$_inc_jq_err" ] && rm -f "$_inc_jq_err"
    ;;
esac
