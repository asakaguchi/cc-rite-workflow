---
title: "Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する"
domain: "patterns"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-05-20T03:11:31Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260426T235945Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T000422Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T020357Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T050216Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T051514Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T095733Z-pr-765.md"
  - type: "reviews"
    ref: "raw/reviews/20260509T071343Z-pr-915.md"
  - type: "reviews"
    ref: "raw/reviews/20260520T011841Z-pr-1066.md"
  - type: "fixes"
    ref: "raw/fixes/20260520T022118Z-pr-1066-cycle1.md"
tags: ["test", "mutation-testing", "false-positive", "dead-code", "verification", "bytes-exact-pin", "trailing-newline-strip", "self-grep-tautology", "count-threshold-mutation-evasion", "path-filter-coverage-gap", "load-bearing-whitespace-pin", "regex-alternation-per-branch-coverage", "regex-quantifier-semantic-coverage"]
confidence: high
---

# Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する

## 概要

test が **「正しい input で PASS する」だけでは不十分**で、**「実装を mutate (sed で改変 / 削除) すると確実に FAIL する」** ことを empirical に確認することで初めて regression detection power が保証される。Mutation testing は (a) test が dead code (実用上到達しない code path) を validate していないか、(b) test の assert が identification power をもつか (fixture old value と patch new value が同値で revert test 不能になっていないか) の 2 観点を decisively 検出する。test author は同値設計に気付きにくいため、reviewer 側で mutation testing による真正性検証を strongly recommended と位置付ける。

## 詳細

### 適用 1: dead code を validate する false-positive TC の検出

cycle 3 で新規追加した TC-10 (JSON null normalization) を test reviewer が mutation testing で検証:

```bash
# Original implementation (state-read.sh:135-137)
if [ "$value" = "null" ]; then
  value="$default"
fi

# Mutation: 上記 3 行を削除
# 期待: TC-10 が FAIL する
# 実測: TC-10 が PASS する → dead code
```

→ jq の `// $default` 演算子が null を `$default` で先に置換するため、Bash 側 normalization は実用上到達しない dead code。

### Fix 方針

「dead code を test で pin」ではなく「実装の真の動作を test で pin」に書き直す:

```bash
# Before: TC-10 は normalization 自体を検証 (dead code を mock 経由で起動)
# After: TC-10 は jq の `// $default` 演算子が null/false に対して default を返すことを検証
```

simpler + mutation 耐性のある test に変換できる。

### 適用 2: identification power 0 の dead assertion 検出

cycle 31 で TC-AC-4-WRITER-FALLBACK の 6 sub-assertions を mutation testing:

```bash
# Fixture
echo '{"phase":"foo"}' > legacy_state.json

# Patch
flow-state-update.sh patch --phase "foo" --if-exists

# Assertion (dead — fixture old value と patch new value が同値)
assert_eq "$(jq -r .phase legacy_state.json)" "foo"
```

→ 「legacy phase updated」assertion は fixture phase と patch phase が同値で **identification power がゼロ**。empirical revert test (pre-fix base に対し新 TC 実行) で機械的に検出可能だが、test author が同値設計に気付きにくい failure mode。

### Fix 方針

fixture old value と patch new value を **意識的に分離** する:

```bash
echo '{"phase":"old_value"}' > legacy_state.json
flow-state-update.sh patch --phase "new_value" --if-exists
assert_eq "$(jq -r .phase legacy_state.json)" "new_value"
```

これで「patch が legacy file を update した」という invariant が真に検証される。

### 適用 3: load-bearing test の verification

cycle 2 で error-handling reviewer が pre-fix code を `/tmp/state-read-revert-test` に再現して silent exit 1 / empty stdout を確認、test reviewer が TC-8 を pre-fix で revert すると 11/12 PASS + TC-8.1 FAIL → post-fix 12/12 PASS の **2 段階を実機で検証**。

これは「fix が真に bug を防いでいることを実証する load-bearing test」の canonical pattern。

### 適用累積実績 (PR #688 cycles 3 → 4 → 5 → 31 → 42)

| cycle | 適用先 | 検出内容 |
|-------|--------|---------|
| 3 | TC-10 (null normalization) | dead code (PASS のまま) |
| 4 | fix verification | dead code 削除 + 真の動作 (jq `// $default`) verify に書き直し |
| 5 | TC-13 追加時の自己検証 | TC-13 false-positive 判明 |
| 31 | TC-AC-4-WRITER-FALLBACK | 6 sub-assertions のうち `legacy phase updated` が identification power 0 |
| 42 | TC-9 (`_resolve-cross-session-guard.test.sh`) | bash command substitution の trailing newline strip 仕様により helper が `printf '%s\n'` に regress しても test PASS する false-positive (assertion が `wc -c` ではなく `=` 比較のため byte 差分が消失) |

→ Wiki 経験則として **新規 test 追加時は mutation testing による真正性検証を strongly recommended** と位置付け。

### 適用 4: bash command substitution trailing newline strip 仕様による false-positive (PR #688 cycle 42 での evidence)

cycle 42 review で `_resolve-cross-session-guard.test.sh` TC-9 が **bash の `$(...)` command substitution が末尾 newline を strip する仕様** により helper の出力が `printf '%s'` (newline 無し) ↔ `printf '%s\n'` (newline 有り) のいずれでも assertion `[ "$got" = "$expected" ]` が PASS する false-positive 構造として実測:

```bash
# helper canonical (no trailing newline)
printf '%s' "$value"

# 想定 mutation (trailing newline regression)
printf '%s\n' "$value"

# Test (false-positive)
got=$(_resolve-cross-session-guard.sh ...)  # bash strips trailing \n
[ "$got" = "expected_value" ]  # 両 mutation で PASS
```

→ **`got=$(cmd); echo -n "$got" | wc -c` で byte count を assert** する canonical pattern に変更。bash command substitution の strip 仕様が assertion を bypass する false-positive 構造は **portable shell idiom 全般に潜在** するため、**helper 出力に newline 有無の規約がある場合は必ず byte-exact pin** を mandatory 化する。

```bash
# Canonical (bytes-exact pin)
got=$(_resolve-cross-session-guard.sh ...)
got_bytes=$(printf '%s' "$got" | wc -c | tr -d ' ')
expected_bytes=5  # "value" の byte 数
[ "$got_bytes" = "$expected_bytes" ] || fail "expected $expected_bytes bytes, got $got_bytes"
```

**Detection idiom**: helper 出力の trailing newline 規約を test で pin する場合、以下を mandatory 化:

1. **`$(...)` 経由の string compare assertion は trailing newline 規約を捕捉できない前提で書く**: `assert_eq` の前に `wc -c` で byte count を pin する 1 行を追加
2. **mutation testing で empirical 検証**: helper 実装を `printf '%s'` ↔ `printf '%s\n'` で双方 mutate し test suite を再実行 → 両 mutation で PASS したら trailing newline 規約は実質 unguarded 状態
3. **portable shell idiom レビューの check item に追加**: `$(...)` / `<<<` / `read -r` のいずれも trailing newline strip / preserve 挙動が異なる。helper 出力の byte-level 規約を test で pin する場合は `wc -c` / `od -c` 等 byte-level 検査の併用を canonical とする

### 実装手順 (canonical)

1. test 対象の実装行を `git stash` または `sed` で削除 / 改変する。
2. 当該 test を再実行する。
3. **FAIL すれば真正、PASS すれば dead code or identification power 0**。
4. 復元して fix 方針を決める (dead code なら test を実装の真の動作に書き直す、identification power 0 なら fixture old/new value を分離)。

### 検出が困難な領域

- jq の null/false 扱いのような「演算子レベルで先に置換される」semantics — 実装の Bash 行を pin するだけでは jq 内部の normalization に到達しない。
- fixture と patch value の同値設計 — test author の盲点になりやすい。
- helper 共通化後の caller-side routing — helper 単体 test は通っても caller 経由経路が pin されていない。

### 適用 5: review test の identification power 不足 — 3 種 dead code 化 pattern (PR #765 review での evidence)

PR #765 (Issue #691 = bang-backtick-check 二段ガード昇格) cycle 1 review で、新規追加された **review test 自身が mutation 耐性を持たない 3 種の dead code 化 pattern** が cross-validation で検出された。新規 lint rule / hook の test を書く際の canonical な反面教材:

#### Pattern 5-A: Self-grep tautology (TC-3)

test 自身が echo した文字列を自身で grep する循環構造。実装の検出ロジックは一切呼ばれず、test fixture の echo string が test 自身の grep 検証で必ず matched する false PASS 経路。

```bash
# 反面教材 (PR #765 TC-3)
echo "[bang-backtick] WARNING: detected pattern" >> "$tmpdir/output"
grep -q '\[bang-backtick\] WARNING' "$tmpdir/output"  # ← echo した自分自身を grep
```

**Mutation: 実装の hook script を空ファイルに置き換えても TC-3 は PASS する** → identification power 0。canonical fix は「実装が emit する canonical phrase を test fixture の prepared input には含めない」「fixture を加工 → 実装 invoke → 実装が emit した output に対して assert」の 3 段階分離。

#### Pattern 5-B: 件数判定の片側 mutation 隠蔽 (TC-4)

`grep -c >= 2` 形式の閾値判定で、同一 literal が 3 箇所に存在する場合、**1 箇所を mutate しても残り 2 箇所で PASS する** dead range pattern。

```bash
# 反面教材 (PR #765 TC-4)
match_count=$(grep -c 'BANG_BACKTICK_CHECK_INVOCATION_FAILED' file)
[ "$match_count" -ge 2 ]  # ← 3 site 中 1 site mutation でも PASS
```

**Mutation: 3 site のうち 1 site を mutate (literal を別文字列に変更) → 残り 2 site で `>= 2` を満たし PASS** → mutation 耐性 0。canonical fix は **`-eq N` 完全一致 assertion** に変更し、N を canonical site count と一致させる。grep -c の閾値判定は dead range を許容する設計欠陥として認識。

#### Pattern 5-C: Path filter coverage gap (TC-3 の glob)

scope filter glob (`agents/*/foo` `references/*/foo` 等) を test fixture に含めるが、**glob 全体を kill (例: glob 自体を空文字に置換) しても全 13 TC が PASS する** identification power 0 のケース。bash case の `*` が `/` を跨ぐ仕様により、glob 削除後も別 fallback path で matched してしまう。

**Mutation: glob 全体を `""` (空文字) に置換 → 13 TC 全 PASS** → glob filter は test 上 dead code。canonical fix は filter 適用前後の matched-file count を `path filter coverage` として独立 assertion 化し、filter ON/OFF の差分を empirical に pin する。

#### 共通教訓 — Review test の identification power empirical gate

新規 lint rule / hook を導入する PR では **必ず review test 側に mutation 耐性 empirical gate を設置**:

1. **Self-grep tautology test**: test fixture を変更せずに **実装の hook 本体を空ファイル / `exit 0` に置き換え** → 全 TC が FAIL することを確認
2. **件数判定の片側 mutation 隠蔽 test**: production の N site canonical 一覧から 1 site を mutate → 該当 TC が FAIL することを確認
3. **Path filter coverage gap test**: filter glob 全体を kill → filter 機能を要求する TC のみが FAIL することを確認

3 種の mutation を 1 つの `mutation-test.sh` script として CI に組み込み、新規 rule / hook 追加 PR の review-fix loop で必須実行する。本 pattern は [test-pin-protection-theater.md](../anti-patterns/test-pin-protection-theater.md) の sub-pattern として接続し、test 真正性の 4 軸 (dead code / identification power / self-grep tautology / count threshold mutation evasion / path filter coverage gap) を canonical 化する。

### 適用 6: Load-bearing whitespace を持つ fixture を formatter から守る pre-check (PR #915 review での evidence)

PR #915 (Issue #914 = mutation fixture M1-M6 永続化) cycle 1 review で、**M6 fixture の末尾 fence の trailing whitespace が M6 識別力の唯一の load-bearing 要素**であるという脆弱性が指摘された。fixture が `prettier` / `editorconfig` / `markdownlint` 等の formatter で silent に剥がされた場合、mutation の identification power は壊れるが test 自身は PASS する false-positive 経路に陥る。

#### 失敗の構造

mutation fixture を永続化すると、fixture file 自身が repository の formatter / linter 設定に晒される。fixture 内のある特定の whitespace / indent / 末尾文字 etc. が「mutation を検出するための唯一の identifying feature」であるとき、その feature は **fixture から 1 文字除去されただけで identification power が 0 に落ちる** が、**fixture 自身は formatter pass で更新済みなので test 上は PASS** する silent regression を引き起こす。

```bash
# M6 fixture (最終 fence の trailing whitespace が load-bearing)
```bash
echo "test"
```␣␣  ← trailing 2 spaces が M6 検出力の唯一の load-bearing 要素

# Mutation: prettier で trailing whitespace 削除
```bash
echo "test"
```  ← trailing whitespace 消失で M6 identification power = 0
```

#### Canonical 防御: pre-check で load-bearing 要素を assertion 化

meta-test の冒頭で fixture 内の load-bearing 要素を **明示的に grep で pin** し、formatter に剥がされた場合は test 自身が FAIL するよう構造化する:

```bash
# M6 fixture pre-check (cycle 2 fix で追加)
grep -qE '```[[:space:]]+$' "$M6_FIXTURE" \
  || fail "M6 fixture lost trailing whitespace on closing fence (formatter strip?)"
```

このように **fixture の load-bearing feature を test 内で明示的に grep pin** することで、formatter / linter による silent strip を防御できる。

#### 共通教訓 — load-bearing fixture feature の self-pin

新規 fixture 永続化 PR で fixture 内の **whitespace / indent / trailing character / inline character** が mutation 識別力の唯一の load-bearing 要素になっている場合、以下を mandatory 化:

1. **load-bearing feature を test 内で grep pin**: meta-test の冒頭で `grep -qE '<load_bearing_pattern>' "$FIXTURE" || fail` を実行
2. **コメントで load-bearing 性を明示**: fixture file 内に「この trailing whitespace は M6 識別力の唯一の load-bearing 要素」とコメント追記し、後続 contributor に formatter run の判断材料を残す
3. **`.editorconfig` / `.prettierignore` で fixture path を除外**: 上記 1, 2 が defense-in-depth でしかないため、formatter 適用範囲から fixture path を排除する設定を導入する

本 pattern は適用 5 の 3 種 dead code 化 pattern (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap) と同じく、**fixture の真正性を mutation testing から守る canonical 防御** の系統。

### 適用 7: Regex alternation / quantifier semantic の per-branch positive coverage (PR #1066 で実証)

PR #1066 cycle 11 で 2 種の regex per-branch coverage gap が cross-validated として検出され、本 pattern を **regex alternation / quantifier semantic** 軸へ拡張する canonical 事例になった。本拡張は適用 5 の「Pattern 5-B 件数判定の片側 mutation 隠蔽」と同型構造 (per-branch coverage gap) を、対象が grep -c 閾値ではなく **regex の構造単位 (alternation の各 branch / quantifier の各 semantic)** に変えた sub-pattern。

#### Pattern 7-A: Regex alternation の片側 positive coverage 欠落

regex の alternation (`A|B|C`) は各 branch 独立に matching するため、test の positive case は **全 branch に対して個別に配置** する必要がある。1 branch のみの positive coverage は他 branch を実質 dead range にする。

```bash
# 反面教材 (PR #1066 初版 test)
regex='could not resolve.*pull\s*request\|no.*pull\s*request found'
# Positive test: `could not resolve to a PullRequest` だけ
echo "could not resolve to a PullRequest" | grep -qE "$regex"  # PASS

# Mutation: `no.*pull request found` alternative を別 literal に置換
regex='could not resolve.*pull\s*request\|DIFFERENT_LITERAL'
# Positive test 全 PASS (no.*pull request found branch の positive case が無いため)
```

→ `no.*pull request found` alternative を別 literal に置換しても全 test PASS → 実質 dead range。

#### Pattern 7-B: Regex quantifier semantic の per-case coverage

regex quantifier (`\s*` / `\s+` / `?` / `*` / `+`) は 0 / 1 / N 回マッチを semantic に表現する。test の positive case は **quantifier semantic の境界値 (0 回 / 1 回 / N 回)** ごとに配置する必要がある。1 境界値のみの coverage は他境界値で発生する quantifier 置換 regression を catch できない。

```bash
# 反面教材 (PR #1066 初版 test)
regex='could not resolve.*pull\s*request'
# Positive test: `PullRequest` (空白なし、0 回) だけ
echo "could not resolve to a PullRequest" | grep -qE "$regex"  # PASS

# Mutation: `\s*` (0 回以上) を `\s+` (1 回以上) に置換
regex='could not resolve.*pull\s+request'
# Positive test の `PullRequest` は `\s+` でマッチしないため FAIL するが、空白あり case
# (`Pull Request`) の positive coverage が欠落していると quantifier semantic の境界値テスト
# として `\s*` ↔ `\s+` の差分を decisive 検出できない (空白なし側 1 case のみで 0 回境界
# しか pin できない)
```

→ `\s*` (0+) を `\s+` (1+) に置換すると空白なし case が FAIL するが、**空白あり case の positive coverage を持たないと quantifier semantic 全体の境界値テスト** (0 回 / 1 回両方) として decisive ではない。境界値の両端を positive で pin することで quantifier mutation を both direction で catch する。

#### Canonical 対策

PR #1066 fix (cycle 1) では positive 6 + negative 6 case で alternation 各 branch と quantifier 各 semantic を網羅:

| Case | Coverage |
|------|---------|
| `Could not resolve to a PullRequest` (空白なし) | quantifier 0 回境界 |
| `Could not resolve to a Pull Request` (空白あり) | quantifier 1 回境界 |
| `GraphQL: Could not resolve to a PullRequest ... (repository.pullRequest)` | 実 gh stderr 形式 (regression 実装互換性) |
| `no pull request found` | alternation `no.*pull request found` branch positive |
| `no PullRequest found` | alternation × quantifier 0 回 cross coverage |
| 大文字小文字混在 case | `-i` flag 削除 regression 検出 |

#### 防止策

1. **regex alternation の各 alternative に positive test を独立配置**: 1 case で複数 alternative を担保する設計は mutation 耐性 0。alternation hit 数を `grep -oE | wc -l` で counter として assert すると alternative 個別の覆遺漏れも検出できる
2. **regex quantifier の各 semantic 境界に positive test を配置**: `\s*` なら 0 回 / 1 回 / N 回、`?` なら 0 回 / 1 回、`*` なら 0 回 / 1 回 / N 回、`+` なら 1 回 / N 回。境界値テストで quantifier 置換 mutation (`\s*` → `\s+` / `?` → `+` 等) を catch
3. **regex flag (`-i` / `-E` / `-P`) の存在を assert する独立 case**: flag 削除 mutation を catch するため flag 必須の test fixture (例: 大文字混在) を持つ独立 case を 1 つ以上配置
4. **negative case でも alternative 境界を確認**: alternation の各 branch がマッチしてはいけない counter case (例: `pull request` 単独で `could not resolve` 前置なしのもの) を配置し、branch 拡張 mutation (alternation 追加) を catch
5. **mutation script に regex 専用 mutator を追加**: alternation の各 branch を 1 つずつ別 literal に置換、quantifier (`\*`, `\+`, `?`, `\s*`, `\s+`) を相互に置換するスクリプトを mutation-test.sh に追加し、新規 regex test PR で必須実行

本 sub-pattern は適用 5 の 3 種 dead code 化 pattern (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap) と並列し、**regex 構造 (alternation / quantifier / flag) を test 真正性 mutation で守る canonical 防御** の系統として位置付ける。

## 関連ページ

- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [Enum 拡張時の few-shot coverage completeness](../heuristics/enum-extension-few-shot-coverage-completeness.md)

## ソース

- [PR #688 review results (cycle 3) — TC-10 false-positive 発見](../../raw/reviews/20260426T235945Z-pr-688.md)
- [PR #688 fix results (cycle 4) — mutation testing による解消パターン](../../raw/fixes/20260427T000422Z-pr-688.md)
- [PR #688 fix results (cycle 5) — TC-13 false-positive + 3 cycle 連続適用実績](../../raw/fixes/20260427T020357Z-pr-688.md)
- [PR #688 cycle 42 review — bash command substitution trailing newline strip 仕様による false-positive 構造](../../raw/reviews/20260428T050216Z-pr-688.md)
- [PR #688 cycle 42 fix — bytes-exact pin (`wc -c`) で trailing newline 規約の mutation 耐性を獲得](../../raw/fixes/20260428T051514Z-pr-688.md)
- [PR #765 cycle 1 review — review test の identification power 不足 3 種 (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap)](../../raw/reviews/20260502T095733Z-pr-765.md)
- [PR #915 review — M6 fixture trailing whitespace の load-bearing 性検出 + pre-check による self-pin canonical 化](../../raw/reviews/20260509T071343Z-pr-915.md)
- [PR #1066 review — regex alternation の片側 positive coverage 欠落 + quantifier `\s*` semantic 片側のみテスト (2 種 cross-validated HIGH)](../../raw/reviews/20260520T011841Z-pr-1066.md)
- [PR #1066 cycle 1 fix — alternation 各 branch + quantifier 境界値 + flag 必須 case + 大文字小文字混在 case で positive 6 + negative 6 に拡張](../../raw/fixes/20260520T022118Z-pr-1066-cycle1.md)
