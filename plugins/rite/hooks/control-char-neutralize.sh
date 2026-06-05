#!/bin/bash
# rite workflow - Control Character Neutralization (shared)
# Provides the single source of truth for the "control chars → ?" diagnostic
# neutralization convention shared by flow-state.sh (_emit_jq_err_snippet) and
# stop-loop-continuation.sh (unknown handoff prefix WARNING), plus the
# detection-side counterpart contains_ctrl() for reject-purpose validation
# (flow-state.sh _validate_session_id, wiki-ingest-trigger.sh SOURCE_REF /
# TITLE — Issue #1276).
#
# WHY a shared helper (Issue #1274): the POSIX class [[:cntrl:]] on glibc
# (C and UTF-8 locales, byte-wise verified) does NOT classify C1 8-bit control
# bytes (0x80-0x9f, notably the CSI introducer 0x9b) as cntrl, so the previous
# per-site `s/[[:cntrl:]]/?/g` / `${var//[[:cntrl:]]/?}` idioms let 0x9b through
# — an ESC-free 8-bit escape path some terminals interpret as `ESC [`. The
# replacement set here is C0 (0x00-0x1f) + DEL (0x7f) + C1 (0x80-0x9f), applied
# byte-wise under LC_ALL=C so both the raw-byte path (latin1-style terminals)
# and the UTF-8 U+0080-U+009F encoding path (0xc2 0x80-0x9f — its second byte
# falls in the C1 range) are closed at once.
#
# Trade-off (accepted, Issue #1274): byte-wise replacement also hits UTF-8
# continuation bytes in the 0x80-0x9f overlap, so multibyte text (e.g. Japanese)
# in a corrupt-state-file fragment degrades to `?` runs. The call sites are
# diagnostic-only output for corrupt/unknown input, where neutralizing on the
# safe side outweighs snippet readability.
#
# Usage (source from another script):
#   source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"
#   printf '%s' "$value" | neutralize_ctrl                  # \n も ? 化 (1 行 WARNING 埋め込み用)
#   head -3 "$file" | neutralize_ctrl --keep-newline        # \n は保持 (行構造を保つ snippet 用)
#   printf '%s' "$value" | neutralize_ctrl --c0-only        # C0+DEL のみ (UTF-8 本文を保持する JSON 用)
#   contains_ctrl "$value" && reject                        # 検出 (reject) 用 — 範囲は default と同一
#
# Contract:
#   - stdin → stdout byte filter; LC_ALL=C tr なので NUL を含む任意バイト列を扱える
#   - default: C0 + DEL + C1 をすべて `?` へ (改行含む — 旧 `${var//[[:cntrl:]]/?}` と同じ 1 行化挙動)
#   - --keep-newline: \n (0x0a) のみ素通し (旧 `sed 's/[[:cntrl:]]/?/g'` の行指向挙動と同じ)
#   - --c0-only: C0 (0x00-0x1f) + DEL (0x7f) のみ `?` へ、0x80 以上は素通し (Issue #1275)。
#     RFC 8259 が JSON 文字列リテラル内で生バイトを禁じるのは C0 のみで、0x80-0x9f を
#     バイト単位で潰す default は UTF-8 継続バイト (例: 日本語) を巻き込んで本文を破壊する。
#     モデル/consumer が読む実テキストを保持したまま invalid-JSON バイトだけを除去する
#     JSON emit フォールバック用モード。C1 の素通しが jq の JSON エンコードと対称なのは
#     valid UTF-8 エンコードの C1 (例 0xc2 0x9b = U+009B) のみ (jq もエスケープせず通す)。
#     raw 8-bit 単独の C1 バイト (例 latin1 の 0x9b) は jq が U+FFFD に置換するのに対し
#     本モードは素通しする点で非対称 — 8-bit CSI の sanitize は jq プライマリ経路依存。
#   - exit code は tr のものをそのまま返す (引数固定のため実質失敗しない; 診断経路の caller は
#     既存規約どおり `|| true` 相当で防御する)

neutralize_ctrl() {
  if [ "${1:-}" = "--keep-newline" ]; then
    LC_ALL=C tr '\000-\011\013-\037\177\200-\237' '[?*]'
  elif [ "${1:-}" = "--c0-only" ]; then
    LC_ALL=C tr '\000-\037\177' '[?*]'
  else
    LC_ALL=C tr '\000-\037\177\200-\237' '[?*]'
  fi
}

# Detection-side counterpart (Issue #1276): reject-purpose call sites
# (flow-state.sh _validate_session_id, wiki-ingest-trigger.sh SOURCE_REF /
# TITLE) previously used bash `=~ [[:cntrl:]]`, which on glibc misses the same
# C1 8-bit range the neutralize side closes — letting e.g. 0x9b slip through
# validation. Sharing the byte-range definition here keeps detection and
# replacement symmetric.
#
# Usage: contains_ctrl "$value"   # rc 0 = C0/DEL/C1 byte present, rc 1 = clean
#
# Contract:
#   - argument-based, not a stdin filter: every call site tests a bash
#     variable, and bash variables cannot carry NUL — so 0x00 is structurally
#     unreachable here (the stdin-filter neutralize_ctrl still covers it)
#   - byte-wise under LC_ALL=C: UTF-8 continuation bytes overlapping 0x80-0x9f
#     (e.g. most Japanese characters) are detected as control bytes — accepted
#     (Issue #1276 設計判断): all call sites are ASCII-identifier / ASCII-title
#     fields. 日本語 TITLE が必要になったら UTF-8 セーフモードを別途追加する
#   - implementation reuses the exact neutralize_ctrl default tr range and
#     compares byte counts before/after deletion. grep は使わない — grep 実装に
#     よっては (例: ugrep) LC_ALL=C でも raw 8-bit バイトを UTF-8 として扱い
#     リテラル 0x9b にすらマッチしないため、検出が環境依存で silent に壊れる
#   - fail-closed: pipeline failure / non-numeric wc output counts as
#     "detected" so the reject path cannot silently degrade into pass-through
contains_ctrl() {
  local _in_bytes _stripped_bytes
  _in_bytes=$(printf '%s' "$1" | LC_ALL=C wc -c) || _in_bytes=""
  _stripped_bytes=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177\200-\237' | LC_ALL=C wc -c) || _stripped_bytes=""
  # BSD wc は数値を空白パディングするため除去してから数値検証する
  _in_bytes=${_in_bytes//[[:space:]]/}
  _stripped_bytes=${_stripped_bytes//[[:space:]]/}
  case "${_in_bytes}:${_stripped_bytes}" in
    *[!0-9:]*|:*|*:) return 0 ;;
  esac
  [ "$_in_bytes" -ne "$_stripped_bytes" ]
}
