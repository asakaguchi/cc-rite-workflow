#!/bin/bash
# sentinel-disambiguator-adjacency.test.sh
#
# Cross-producer parity verification for sentinel + disambiguator marker pairs.
#
# 背景:
#   Issue #1165 で sub-skill return sentinel を `:returned-to-caller` 形式に rename し、
#   各 sentinel の直前に `<!-- skill return signal: caller must continue next step -->`
#   disambiguator marker を併記する契約を導入した。`create-md-invocation-symmetry.test.sh`
#   の TC-7a/7b は create.md 専用の adjacency 検証として既に機能している。
#
#   一方で他 5 producer (cleanup.md / merge.md / ready.md / wiki/lint.md / wiki/ingest.md)
#   には同等の自動検査が存在せず、wiki/lint.md ステップ 1.1/1.3 早期 return path で echo 順序が
#   sentinel → disambiguator に swap されても既存 test 群は通過する非対称 gap があった。
#   本 meta-test は全 producer 横断で **count parity** (disambiguator count >= sentinel count)
#   を機械検証することで silent marker strip (rename 漏れ等で disambiguator のみ落ちた状態) を
#   構造的に予防する。
#
# 検出する drift:
#   - 各 producer で sentinel 数 > disambiguator 数 になっていれば silent strip suspected
#
# 検出しない drift (本 test の scope 外):
#   - sentinel literal の rename 漏れ → CHANGELOG / grep / 他 test で別途検出
#   - adjacency 順序の swap (sentinel → disambiguator) → 各 emit site の format 多様性
#     (multi-line markdown / bash echo / inline cleanup) により単一 awk pattern で
#     表現困難。本 test の count parity でも「片方が落ちた状態」は検出可能だが、両方残って
#     順序のみ swap した状態は対象外 (create-md TC-7b の line-head anchor 方式で create.md は
#     covered、他 producer は本 test の count parity でカバー)
#
# 対応する 3 emit format:
#   (1) Multi-line markdown (ready.md / merge.md ステップ 4 / lint.md ステップ 9.2 / ingest.md):
#         <!-- skill return signal: caller must continue next step -->
#         <!-- [skill:returned-to-caller] -->
#   (2) Bash echo (lint.md ステップ 1.1/1.3 / merge.md ステップ 3):
#         echo "<!-- skill return signal: caller must continue next step -->"
#         echo "<!-- [skill:returned-to-caller] -->"
#   (3) Inline single-line (cleanup.md:486 ordered list item):
#         2. <list item text> <!-- skill return signal: ... --> <!-- [cleanup:returned-to-caller] -->
#
# When this test fails:
#   該当 producer の sentinel emit site と disambiguator marker の対称性が崩れている。
#   sentinel rename / disambiguator 追加時に片方を更新し忘れた可能性が高い。
#   失敗 producer の emit site と disambiguator site を再走査して同期させる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

# Producers under test (create.md は create-md-invocation-symmetry.test.sh の TC-7a/7b で
# 別途 covered のため除外。本 test は残り 5 producer の cross-producer 非対称 gap を埋める)
# Format: "skill_name:relative_path"
PRODUCERS=(
  "cleanup:commands/pr/cleanup.md"
  "merge:commands/pr/merge.md"
  "ready:commands/pr/ready.md"
  "lint:commands/wiki/lint.md"
  "ingest:commands/wiki/ingest.md"
)

# ──────────────────────────────────────────────────────────────────────
# Per-producer count parity test (TC-{name})
# ──────────────────────────────────────────────────────────────────────
# 各 producer について以下を assert する:
#   1. sentinel emit site が 1 件以上存在する (file の構造が壊れていないこと)
#   2. disambiguator marker emit site count >= sentinel emit site count
#
# emit site の判定:
#   - 行頭 `<!-- [name:returned-to-caller...] -->` (multi-line markdown format)
#   - 行頭 (任意 indent あり) `echo "<!-- [name:returned-to-caller...] -->"` (bash echo format)
#   - 行末 ` <!-- [name:returned-to-caller...] -->` (inline format、leading space 必須で
#     backtick 内 prose mention を除外)
#
# prose 内の literal mention (例: "...sentinel ``<!-- [name:returned-to-caller] -->``..." や
# `<!-- [name:returned-to-caller] -->` HTML コメント sentinel という説明テキスト) は上記
# パターンのいずれにもマッチせず除外される。
for entry in "${PRODUCERS[@]}"; do
  name="${entry%%:*}"
  rel_path="${entry##*:}"
  abs_path="$PLUGIN_ROOT/$rel_path"

  if [ ! -f "$abs_path" ]; then
    fail "TC-${name}: Producer file not found: $rel_path"
    continue
  fi

  # sentinel emit site count
  # 3 format をまとめて捕捉する OR pattern。
  # 各 alternative はそれぞれ 1 つの format に対応する:
  #   alt1: `^<!-- [name:returned-to-caller...] -->$`                       multi-line markdown
  #   alt2: `^[[:space:]]*echo "<!-- [name:returned-to-caller...] -->"$`    bash echo
  #   alt3: ` <!-- [name:returned-to-caller...] -->$`                       inline (leading space)
  sentinel_pattern="(^<!-- \[${name}:returned-to-caller[^]]*\] -->$)|(^[[:space:]]*echo \"<!-- \[${name}:returned-to-caller[^]]*\] -->\"$)|( <!-- \[${name}:returned-to-caller[^]]*\] -->$)"
  sentinel_count=$(grep -cE "$sentinel_pattern" "$abs_path" 2>/dev/null || true)
  # POSIX wc -l 互換: grep -c は match なしで rc=1 を返すため `|| true` で吸収する
  case "$sentinel_count" in ''|*[!0-9]*) sentinel_count=0 ;; esac

  # disambiguator emit site count (3 format 同様に capture)
  disambig_pattern='(^<!-- skill return signal: caller must continue next step -->$)|(^[[:space:]]*echo "<!-- skill return signal: caller must continue next step -->"$)|( <!-- skill return signal: caller must continue next step -->)'
  disambig_count=$(grep -cE "$disambig_pattern" "$abs_path" 2>/dev/null || true)
  case "$disambig_count" in ''|*[!0-9]*) disambig_count=0 ;; esac

  if [ "$sentinel_count" -eq 0 ]; then
    fail "TC-${name}: sentinel emit site が ${rel_path} に存在しません (期待: >= 1)。ファイル構造が壊れているか、sentinel rename で literal が変わった可能性"
    continue
  fi

  if [ "$disambig_count" -ge "$sentinel_count" ]; then
    pass "TC-${name}: ${rel_path} disambiguator emit site (${disambig_count}) >= sentinel emit site (${sentinel_count})"
  else
    echo "  sentinel emit sites:" >&2
    grep -nE "$sentinel_pattern" "$abs_path" 2>/dev/null | sed 's/^/    /' >&2
    echo "  disambiguator emit sites:" >&2
    grep -nE "$disambig_pattern" "$abs_path" 2>/dev/null | sed 's/^/    /' >&2
    fail "TC-${name}: ${rel_path} disambiguator (${disambig_count}) < sentinel (${sentinel_count}) — silent marker strip suspected (rename 漏れで marker のみ落ちた状態の可能性)"
  fi
done

print_summary "sentinel-disambiguator-adjacency.test.sh" "drift hint: 失敗 producer の sentinel と disambiguator の数を合わせてください。silent strip は rename 中に echo 行の片方だけ更新したケースで発生します"
