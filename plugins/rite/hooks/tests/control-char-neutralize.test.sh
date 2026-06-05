#!/bin/bash
# Tests for plugins/rite/hooks/control-char-neutralize.sh (Issue #1274)
#
# Purpose:
#   neutralize_ctrl は flow-state.sh (_emit_jq_err_snippet) と
#   stop-loop-continuation.sh (unknown-prefix WARNING) が共有する
#   「制御文字 → ?」規約の single source of truth。glibc の [[:cntrl:]] が
#   分類しない C1 8-bit 制御バイト (0x80-0x9f、特に CSI introducer 0x9b) を
#   バイト単位で `?` 置換することを直接 pin する (jq / state file を介さない
#   単体層 — 統合層は flow-state.test.sh TC-23 / stop-loop-continuation.test.sh
#   TC-14 が担う)。
#
# Test cases:
#   TC-1: C0 制御文字 (0x01 / TAB / ESC) → ?
#   TC-2: DEL (0x7f) → ?
#   TC-3: C1 境界 (0x80 / 0x9b CSI / 0x9f) → ? (Issue #1274 本丸 pin)
#   TC-4: 0xa0 (C1 上限 +1) は保持される (過剰置換しない上側境界 pin)
#   TC-5: UTF-8 U+009B (0xc2 0x9b) の 0x9b バイトが ? 化され生 0x9b が残らない
#   TC-6: default モード: \n も ? 化 (旧 ${var//[[:cntrl:]]/?} の 1 行化挙動と同じ)
#   TC-7: --keep-newline: \n は保持、他の制御文字は ? (旧 sed 行指向挙動と同じ)
#   TC-8: 可読 ASCII は無傷 + 1:1 置換 (削除ではない — 長さ保存)
#   TC-9: NUL バイト (0x00) → ? (LC_ALL=C tr のバイトストリーム性 pin)
#   TC-10: --c0-only: C0 (0x01 / TAB / ESC) + DEL → ? (Issue #1275)
#   TC-11: --c0-only: C1 境界 (0x80 / 0x9b / 0x9f) は素通し (default との差分 pin)
#   TC-12: --c0-only: UTF-8 マルチバイト (日本語) が無傷 (JSON フォールバック reason 保護の本丸 pin)
#   TC-13: --c0-only: \n も ? 化 (C0 範囲 — caller は改行を先にエスケープしてから呼ぶ契約)
#
# Usage: bash plugins/rite/hooks/tests/control-char-neutralize.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HELPER="$PLUGIN_ROOT/hooks/control-char-neutralize.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: $HELPER not found" >&2
  exit 1
fi
# shellcheck source=../control-char-neutralize.sh
source "$HELPER"

# stdout を hex 列へ (バイト単位比較用 — od のスペース/改行を除去)
to_hex() { od -An -tx1 | tr -d ' \n'; }

echo "=== TC-1: C0 制御文字 (0x01 / TAB / ESC) → ? ==="
assert "TC-1: C0 bytes neutralized" "A?B?C?D" "$(printf 'A\x01B\tC\x1bD' | neutralize_ctrl)"

echo ""
echo "=== TC-2: DEL (0x7f) → ? ==="
assert "TC-2: DEL neutralized" "A?B" "$(printf 'A\x7fB' | neutralize_ctrl)"

echo ""
echo "=== TC-3: C1 境界 (0x80 / 0x9b CSI / 0x9f) → ? (Issue #1274) ==="
# 旧実装 (sed [[:cntrl:]] / bash ${var//[[:cntrl:]]/?}) はこの 3 バイトを素通し
# していた — glibc は C/UTF-8 両ロケールで C1 を cntrl と分類しないため。
assert "TC-3: C1 range boundaries neutralized" "A?B?C?D" "$(printf 'A\x80B\x9bC\x9fD' | neutralize_ctrl)"

echo ""
echo "=== TC-4: 0xa0 (C1 上限 +1) は保持 (過剰置換しない境界 pin) ==="
assert "TC-4: byte just above C1 preserved" "41a042" "$(printf 'A\xa0B' | neutralize_ctrl | to_hex)"

echo ""
echo "=== TC-5: UTF-8 U+009B (0xc2 0x9b) の 0x9b が ? 化される ==="
# valid UTF-8 の U+009B は jq の JSON 読み書きを素通りして call site まで届く
# 現実の攻撃バイト列 (xterm 等は UTF-8 モードでも C1 を制御文字として解釈する)。
# バイト単位置換は 2 バイト目の 0x9b を潰すため、出力に生 0x9b が残らない。
_tc5_hex=$(printf 'X\xc2\x9bY' | neutralize_ctrl | to_hex)
assert "TC-5: U+009B second byte neutralized (0xc2 remains, harmless)" "58c23f59" "$_tc5_hex"

echo ""
echo "=== TC-6: default モード — \\n も ? 化 (1 行 WARNING 埋め込み用) ==="
assert "TC-6: newline neutralized in default mode" "l1?l2" "$(printf 'l1\nl2' | neutralize_ctrl)"

echo ""
echo "=== TC-7: --keep-newline — \\n は保持、他は ? (行構造保持 snippet 用) ==="
assert "TC-7: newline preserved, others neutralized" "6c313f0a6c323f0a" "$(printf 'l1\x9b\nl2\x1b\n' | neutralize_ctrl --keep-newline | to_hex)"

echo ""
echo "=== TC-8: 可読 ASCII 無傷 + 1:1 置換 (長さ保存 — 空削除への revert を catch) ==="
assert "TC-8: printable ASCII untouched" "readable TEXT-123_ok" "$(printf 'readable TEXT-123_ok' | neutralize_ctrl)"
assert "TC-8: 1:1 replacement preserves byte length" "3" "$(printf 'A\x9bB' | neutralize_ctrl | wc -c)"

echo ""
echo "=== TC-9: NUL バイト (0x00) → ? (バイトストリーム性 pin) ==="
assert "TC-9: NUL neutralized" "413f42" "$(printf 'A\x00B' | neutralize_ctrl | to_hex)"

echo ""
echo "=== TC-10: --c0-only — C0 (0x01 / TAB / ESC) + DEL → ? (Issue #1275) ==="
assert "TC-10: C0 bytes neutralized" "A?B?C?D?E" "$(printf 'A\x01B\tC\x1bD\x7fE' | neutralize_ctrl --c0-only)"

echo ""
echo "=== TC-11: --c0-only — C1 境界 (0x80 / 0x9b / 0x9f) は素通し (default との差分 pin) ==="
# C1 (valid UTF-8 の U+0080-009F) は RFC 8259 では JSON 文字列内で合法であり、jq の
# JSON エンコードも素通しする。--c0-only はこの jq 挙動と対称 (default は ? 化する)。
assert "TC-11: C1 range preserved (hex)" "4180429b439f44" "$(printf 'A\x80B\x9bC\x9fD' | neutralize_ctrl --c0-only | to_hex)"

echo ""
echo "=== TC-12: --c0-only — UTF-8 マルチバイト (日本語) が無傷 (本丸 pin) ==="
# default モードは「停」(0xe5 0x81 0x9c) の継続バイト 0x81/0x9c を ? 化して本文を破壊する。
# --c0-only は 0x80 以上に触れないため、JSON フォールバック reason の日本語指示文が保持される。
assert "TC-12: Japanese text untouched" "停止せず継続" "$(printf '停止せず継続' | neutralize_ctrl --c0-only)"

echo ""
echo "=== TC-13: --c0-only — \\n も ? 化 (C0 範囲 — caller は改行を先にエスケープする契約) ==="
assert "TC-13: newline neutralized in c0-only mode" "l1?l2" "$(printf 'l1\nl2' | neutralize_ctrl --c0-only)"

if ! print_summary "$(basename "$0")" "control-char-neutralize.sh — Issue #1274 C0+DEL+C1 byte-wise neutralization shared helper"; then
  exit 1
fi
