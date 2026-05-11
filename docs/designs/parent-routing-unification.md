# parent-routing pattern 統一 — 累積系列 implicit stop の構造的根絶

> **Status**: 📝 Proposed (PR-1 ADR、実装は PR-2 以降に分割)
>
> **関連 Issue**: #920 (`/rite:issue:create` の create-interview return 後 implicit stop) / #923 (`/rite:pr:cleanup` の wiki:lint / wiki:ingest return 後 implicit stop) — および累積系列 (#552 → #622 → #634 → #651 → #687 → #910 → #917)
>
> **関連 plan**: `~/.claude/plans/issue-920-923-flickering-storm.md`

## 0. 概要

累積系列 (7 連発の prompt-side 対策) が解消しない「sub-skill return 直後の caller orchestrator implicit stop」問題を、**問題 3 sub-skill (create-interview / wiki:lint --auto / wiki:ingest) を parent-routing pattern に統一する構造変更**で根絶する。

本 ADR は **PR-1 (本 PR-only)** として提出し、実装は PR-2..PR-8 の合計 7 PR (本 ADR 含めて 8 PR 構成) で線形マージする。Phase 分割案・PR-2 内部分割案 (self-review で検討) は坂口さんの判断により採用せず、**8 PR を一括連続マージする方針**。実証失敗時の fallback として Plan B (stop-guard 軽量復活) を記憶。

## 1. 背景・問題

### 1.1 累積系列の概要

| Issue | 起票日 | 対策内容の主旨 | site |
|---|---|---|---|
| #552 | 2026-04-17 | Pre-check list + dual form caller hint + stop-guard 連動 | create |
| #622 | 2026-04-20 | whitelist 確認 + Multi-layer Mandatory After | create |
| #634 | 2026-04-21 | Step 0 Immediate Bash Action 明示 + `[CONTEXT] INTERVIEW_DONE=1` marker 追加 | create |
| #651 | 2026-04-24 | 4-site 対称化 (caller HTML literal の Step 0 embed) | create |
| #687 | 2026-04-26 | multi-state .rite-flow-state API 整備 | wiki/ingest |
| #910 | 2026-05-09 | imperative phrasing 強化 (`MUST execute as VERY FIRST tool call BEFORE any text output`) + 4 site 対称化 | cross |
| #917 | 2026-05-10 | 5 site 対称化拡張 (wiki/ingest Mandatory After Auto-Lint) | wiki/ingest |
| #920 | 2026-05-10 | (累積 27 回目を観測) | create |
| #923 | 2026-05-11 | (cleanup chain で 2 接続点同時 implicit stop) | cleanup |

対策は全て **prompt-side defense** (imperative phrasing 強化 + structural invariant + invariant test 追加)。**機械的 enforcement layer** は #674/#675 の `stop-guard.sh` 撤去以降ゼロ。

### 1.2 根本原因の特定 (本 ADR の核心発見)

rite plugin 内には複数の sub-skill 呼び出し経路 (Phase 1 探索で約 20 経路を網羅確認、本 ADR §5 PR 分割対象 8 経路 + 周辺の caller-orchestrator から呼ばれる経路を含む。詳細列挙は plan `~/.claude/plans/issue-920-923-flickering-storm.md` の Phase 1 第 2 ラウンド調査結果を参照) があるが、implicit stop が累積系列として報告されているのは **3 経路だけ**:

1. `create-interview` → `create.md` の return
2. `wiki:lint --auto` → `wiki:ingest` の return
3. `wiki:ingest` → `cleanup.md` の return

これに対し、**問題が報告されていない 5 sub-skill** (`parent-routing` / `child-issue-selection` / `branch-setup` / `work-memory-init` / `implementation-plan`) は完全に異なる pattern を採用している。

#### 問題 3 経路だけに共通する 4 属性 ("completion ceremony")

| 属性 | 問題 3 経路 | parent-routing 5 経路 |
|---|---|---|
| ① flow-state patch 責務 | caller-side (Step 0 bash literal) | sub-skill 側 pre-return |
| ② blockquote `> ⏭ MUST continue (turn を閉じない):` | 全 3 経路で搭載 | なし |
| ③ 完了感の強い末尾 (`[CONTEXT] INTERVIEW_DONE=1` / `Lint: contradictions=N, ...` / `Wiki Ingest が完了しました`) | 全 3 経路で emit | なし |
| ④ 末尾要素 | HTML comment sentinel (`<!-- [foo:completed] -->`) | plain-text narrative (`→ Return to {caller}.md Phase X now. Do NOT stop.`) |

LLM の普遍的な turn-boundary heuristic であれば全 20 経路で発生するはず。**問題は 3 経路が独自に作り上げた "completion ceremony" 構造が turn-boundary signal として誤発火している**こと。

### 1.3 「もともとはうまくいっていた」の歴史検証 (V0 結果)

`git log --follow` で問題 3 file の defense layer 導入時期を遡及:

| File | defense layer 導入 commit | Issue |
|---|---|---|
| `create-interview.md` | `67a6b118 fix(issue-create): create-interview sub-skill return 後の implicit stop を防ぐ多層防御` | **#628** (累積系列の起点) |
|  | `87e2f33c fix(issue-create): create-interview return 後の implicit stop を多層防御で防ぐ` | **#634** |
|  | `02cd4b26 fix(issue-create): caller HTML コメントに Step 0 bash literal を 4-site 対称化` | #651 |
| `wiki/lint.md` (Phase 9.2) | `6ac36bc1 fix(wiki): lint.md Phase 9.2 --auto 出力に continuation sentinel を追加` | **#625** (起点) |
|  | `7a64ae6f refactor(wiki): lint.md Phase 1.1/1.3 --auto 早期 return を Phase 9.2 三点セット規約に整合` | #630/#632 |
| `wiki/ingest.md` (Phase 9.1 / Mandatory After) | `8410ab03 fix(pr-cleanup): wiki-auto-ingest 後の Phase 5 停止を多層防御で解消` | **#604** (起点) |
|  | `f16dfa6c fix(wiki): ingest.md Phase 8 auto-lint return 後の implicit stop を多層防御で防ぐ` | #618 |
|  | `9df1d6d4 fix(pr-cleanup): wiki-ingest sub-skill return 後の implicit stop 対策` | #621 |
|  | `c1f3d175 fix(workflow): #917 ingest.md Mandatory After Auto-Lint を 5 site canonical 対称化` | #917 |

**重要な発見**: #604 / #618 / #625 / #628 (累積系列の **起点**) **以前**は問題 3 経路もシンプルな返り値構造だった蓋然性が高い。坂口さんの「もともとはうまくいっていた」発言と整合する fact が揃った。

つまり累積系列の真の origin story は:

1. 元々問題 3 経路もシンプルな return-block (parent-routing pattern 同型)
2. ある日短期的な implicit stop が観測される (provider 側の挙動変化か session 個別の確率的事象)
3. 対策として "completion ceremony" を導入 (#604/#618/#625/#628)
4. **その対策 layer 自身が新たな turn-boundary signal を作り出し implicit stop を恒常化させた**
5. 以後 7 連発の追加対策はすべて completion ceremony の強化 → 悪化スパイラル

これが本 ADR が逆方向 (ceremony を**撤去**して parent-routing pattern に戻す) を選ぶ根拠である。

## 2. Decision

**parent-routing pattern を canonical とし、問題 3 sub-skill + terminal sub-skill (`create-register` / `create-decompose`) + `pr/cleanup.md` Phase 5 terminal emit を一括移行する**。累積系列の defense layer (4-line return block / 三点セット / Step 0 bash literal / Mandatory After section / 各種 invariant test) は**全て撤去**する。

#674/#675 の stop-guard.sh 撤去判断は**反転しない**。stop-guard 軽量復活は対症療法であり、本 ADR の構造変更で根本対策を実施。

## 3. parent-routing pattern の正規仕様

非問題 5 sub-skill から抽出した正規構造の骨格を以下に示す。完全な canonical form (実装側の導入文・blockquote 含む byte-equivalent な形式) は `plugins/rite/commands/issue/parent-routing.md:325-357` および `plugins/rite/commands/issue/branch-setup.md:123-153` を SoT として参照すること。本 ADR は本 8 PR 構成での移行先テンプレートの骨格のみを示す:

````markdown
---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model.

Before returning control to the caller, update flow state to the post-{phase} phase:

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands below.

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "{post_X_phase_name}" \
  --active true \
  --next "rite:{namespace}:{sub-skill} completed. Proceed to Phase Y. Do NOT stop." \
  --if-exists
```

After the flow-state update above, output the result pattern:

- **{outcome A}**: `[{sub-skill}:{outcome_a}]`
- **{outcome B}**: `[{sub-skill}:{outcome_b}]`

This pattern is consumed by the orchestrator (`{caller}.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes, control **MUST** return to the caller (`{caller}.md`). The caller **MUST immediately** proceed to Phase Y in the same response turn.

**→ Return to `{caller}.md` and proceed to Phase Y now. Do NOT stop.**
````

### 3.1 統一後に消える要素

- `[CONTEXT] *_DONE=1` plain-text marker
- `> ⏭ MUST continue (turn を閉じない):` Markdown blockquote
- `<!-- caller: MUST execute the following bash command ... -->` HTML literal (Step 0 bash の embed)
- `<!-- [foo:completed] -->` HTML comment sentinel → bare bracket `[foo:completed]` に変更
- `--preserve-error-count` argument (parent-routing pattern では使用しない)
- caller-side `🚨 Mandatory After {X}` section 全体
- 「MUST execute as VERY FIRST tool call BEFORE any text output」imperative phrasing 群

### 3.2 機序 hypothesis (LLM heuristic と HTML sentinel の関係)

parent-routing pattern が implicit stop を起こさない構造的理由 (仮説):

末尾要素が **plain-text narrative directive** (`→ Return to ... Do NOT stop.`) で、文末が "forward-momentum cue" として作用する。一方、HTML comment sentinel (`<!-- [foo:completed] -->`) は terminator 様 token として LLM の turn-boundary heuristic を誤発火させる可能性が高い (training data 由来の inductive bias 推定)。

この仮説は本 ADR の §4.4 VC1 dogfood で検証する。

## 4. Pre-implementation Verification Results

PR-1 着手時に実施した事前検証 (一部は PR-2 以降の着手時に再確認):

### V0: 4-line ceremony / 三点セット / HTML sentinel の導入時期

**結果**: §1.3 に記載の通り、累積系列の起点 (#604 / #618 / #625 / #628) で defense layer が**意図的に導入**された。それ以前は parent-routing pattern 同型だった蓋然性が高い。坂口さんの直感と整合。

### V1: `[CONTEXT] INTERVIEW_DONE=1` grep 影響範囲

**結果**: 影響範囲は 3 ファイルに限定:
- `plugins/rite/commands/issue/create.md:203` (imperative phrasing 段落内で参照)
- `plugins/rite/commands/issue/create-interview.md:265, 270, 275, 284, 317, 324` (Output rules / Return block の FIRST line)
- `plugins/rite/commands/issue/references/pre-check-routing.md:5, 23` (Item 0 routing dispatcher の grep 対象)

削除は安全。grep marker としての役割は bare bracket sentinel (`[interview:completed]` / `[interview:skipped]`) に統一される。

### V2: `wiki/lint.md` の `--auto` モード分岐機構

**結果**: `wiki/lint.md` は引数 `$mode` を `printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'` で判定。Phase 1.1 / 1.3 / 9.2 で `--auto` モード時のみ三点セット (6 フィールド + blockquote + sentinel) を出力。**標準モード (`/rite:wiki:lint` user 直接実行) は Phase 9.1 で完了レポート**を表示。本 ADR では `--auto` モードのみ移行し、標準モードは変更しない (caller orchestrator なし)。

### V3: `rite:wiki:lint` 呼び出し元

**結果**: `--auto` モードで呼び出しているのは `wiki/ingest.md` のみ。他 sub-skill / orchestrator から呼ばれていない (SKILL.md / init.md / wiki/* の reference は doc-only)。

### R1: parent-routing 5 sub-skill の flow-state patch timing

**結果**: parent-routing.md (line 333-339) / branch-setup.md (line 131-137) いずれも bash block (patch) → bullet list (result pattern) の **document order**。LLM は document order で tool call を発火するため、patch が text emit より先に実行される。

### R2: wiki/ingest.md Phase 9.1 Step 3 の timing inversion 影響

**結果**: 現状 (line 1173-1186) では Step 3 terminal patch (`ingest_completed`, `active=false`) を sentinel emit の**後**に実行。これは「bash output は assistant response markdown text と別チャンネル」を根拠にしているが、parent-routing pattern では bash → result pattern の document order に統一する。

**inversion 影響**: Step 3 を sentinel emit より先に実行すると、bash failure 時に sentinel 未 emit のまま turn が終了する risk あるが、`if ! cmd; then echo WARNING; fi` パターンで stderr に WARNING を残せば caller は flow-state を参照して回復可能。Plan の R2 に記載。

### R3: grep matcher の scope 限定性

**結果**: `verify-terminal-output.sh` は `--repo-root <path>` 引数で scope 限定可能 (line 43)。本 ADR では migration 期に `commands/` 配下に限定した検査に変更し、`docs/` / `CHANGELOG*` / `tests/` への誤検出を防ぐ。

### R4: 自己参照ループ risk

**結果**: 本 ADR (PR-1) は `/rite:issue:create` を使わず**直接 git commit + `gh pr create`** で実施。PR-2 (`create-interview.md` 改修) 以降も同様に skill 経由を避ける。Phase A soak 完了後に通常 skill 経由を再開する。

### VC1 / VC1b / VC2 dogfood 計画

**未実施** (interactive で時間を要するため別タイミング):

- **VC1**: `/rite:issue:start <parent issue>` を **20 回連続**実行し、parent-routing → child-issue-selection → branch-setup → work-memory-init → implementation-plan chain で implicit stop が発生しないことを実機確認。**PR-2 着手前に実施**。
- **VC1b**: `/rite:pr:create` を **10 回**実行し、pr/create 経路 (bare bracket sentinel `[pr:created:N]`) も implicit stop しないことを確認。**PR-2 着手前**。
- **VC2**: `workflow-incident-emit.sh` log を遡り (もしあれば) parent-routing 系 sub-skill が原因の incident がないことを確認。

VC1 / VC1b で stop が観測されたら本 ADR の前提 (parent-routing pattern 仮説) が崩れ、Plan B (§9) に方針転換。

## 5. Implementation Strategy

PR-1 (本 ADR) → PR-8 の 8 PR で線形マージ。詳細は plan `~/.claude/plans/issue-920-923-flickering-storm.md` §3 参照。

| PR | 内容 | 依存 |
|---|---|---|
| **PR-1** | 本 ADR + V0〜R4 事前検証結果 (本ドキュメント) | — |
| **PR-2** | `create-interview.md` 移行 + `create.md` Mandatory After Interview 削除 + `pre-check-routing.md` grep matcher 更新 | PR-1 + VC1 |
| **PR-3** | `wiki/lint.md` `--auto` モード移行 + `wiki/ingest.md` Mandatory After Auto-Lint 削除 | PR-1 |
| **PR-4** | `wiki/ingest.md` Phase 9.1 移行 + `pr/cleanup.md` Mandatory After Wiki Ingest 削除 | PR-3 |
| **PR-5** | `create-register.md` / `create-decompose.md` 移行 + `create.md` Phase 3 Mandatory After Delegation 削除 | PR-2 |
| **PR-6** | `pr/cleanup.md` Phase 5 terminal emit を bare bracket 化 | PR-4 |
| **PR-7** | 累積 invariant test 5 削除 + `parent-routing-pattern-uniformity.test.sh` 新規 + `verify-terminal-output.sh` 緩和 | PR-2〜6 |
| **PR-8** | SPEC.md / sub-skill-return-protocol.md / start.md 全面更新 + CHANGELOG + i18n | PR-7 |

**順序制約**: PR-7 は PR-2..6 全てマージ後でなければ CI が red になる (削除対象 test が移行先 sub-skill にもう存在しない marker を pin している)。allowlist 形式で段階拡張する案も可。

**LoC 目安**: 累積 −1000 LoC 以上 (defense 層を解体するため、追加より削除が多い)。

## 6. Consequences

### 6.1 撤去される layer

| Layer | 撤去対象 | PR-status |
|---|---|---|
| Layer 1 (orchestrator prompt contract) | `create.md` Mandatory After Interview | **PR-2 撤去済** |
| Layer 1 (orchestrator prompt contract) | `create.md` Mandatory After Delegation | PR-5 撤去予定 |
| Layer 1 (orchestrator prompt contract) | `pr/cleanup.md` Mandatory After Wiki Ingest | PR-4 撤去予定 |
| Layer 1 (orchestrator prompt contract) | `wiki/ingest.md` Mandatory After Auto-Lint | PR-3 撤去予定 |
| Layer 3a (caller HTML hint) | `create-interview.md` caller HTML literal (Step 0 bash embed) | **PR-2 撤去済** |
| Layer 3a (caller HTML hint) | `wiki/ingest.md` continuation HTML comment | PR-4 撤去予定 |
| Layer 3b (plain-text reminder) | `> ⏭ MUST continue (turn を閉じない):` blockquote (create-interview) | **PR-2 撤去済** |
| Layer 3b (plain-text reminder) | `> ⏭ MUST continue (turn を閉じない):` blockquote (wiki/lint Phase 9.2) | PR-3 撤去予定 |
| Layer 3c (sub-skill HTML sentinel) | `create-interview.md` `<!-- [interview:*] -->` → bare bracket | **PR-2 撤去済** |
| Layer 3c (sub-skill HTML sentinel) | `create-register.md` / `create-decompose.md` `<!-- [create:completed:{N}] -->` → bare bracket | PR-5 撤去予定 |
| Invariant test | **PR-2 削除**: `4-site-symmetry.test.sh` (-135) / `caller-html-literal-symmetry.test.sh` (-129) / `step0-immediate-bash-presence.test.sh` (-455) / `create-interview-responsibility-separation.test.sh` (-120) = PR-2 累計 **-839 LoC**。**[PR-5] 削除予定 (本 PR では未削除)**: `caller-html-literal-symmetry-decompose-register.test.sh` (-229 LoC、現在は強化済で残存)。**合計 -1068 LoC** = PR-2..PR-7 累計撤去 (`wc -l` 実測) | PR-2 / PR-5 / PR-7 |

**PR-7 計画上の議論ポイント** (責務分離 meta-invariant の再導入要否):

`create-interview-responsibility-separation.test.sh` (PR-2 で削除済) が pin していた「bash fenced block 内 vs prose 側の責務境界 (caller HTML literal SoT が bash block 内に混入していないこと)」は、parent-routing pattern 移行後では検証対象 (Caller Return Protocol section) 自体が消滅するため自然消滅で妥当。ただし PR-7 で新設する `parent-routing-pattern-uniformity.test.sh` 設計時に以下を判断する:

- (a) 全 8 sub-skill が **責務分離なしの parent-routing pattern canonical form** に統一されている前提のため、責務分離 meta-invariant の再導入は **不要**
- (b) 将来 SoT hub が新たに再導入された場合 (例: `sub-skill-return-protocol.md` に bash block embed が復活する経路) の保護網を別途設けるか、必要時点で個別 test 追加する方針とする

PR-7 PR description / commit message にも本判断 ((a) を採用する場合は「責務分離 meta-invariant は parent-routing pattern 統一で自然消滅、再導入不要」と明記すること) を残す。

**PR-7 task list 引き継ぎ** (Skip path 構造 pin):

`parent-routing-pattern-interim.test.sh` TC-2f は現状 prose 文字列 (`skip path / standard path / limited path / full path のいずれも実行する`) の grep 1 件のみで Skip path 必須化を pin している。bash block (Return Output re-patch) が将来 `if [ "$scope" != "skip" ]; then ... fi` 等の conditional で gate された場合、prose は変更なく通過するため regression を catch できない。PR-7 で新設する `parent-routing-pattern-uniformity.test.sh` に以下を追加する:

- Return Output re-patch bash block の **構造 pin** (awk-based、`## Defense-in-Depth: Flow State Update (Before Return)` H2 anchor 以降の bash block 領域を切り出して最も近い祖先 conditional が `if [ ! -f ... ]` 以外の case 文/scope 比較でないことを検証)。行番号 (旧 `L324-345`) は無関係な prose 編集で drift するため、anchor base で領域を特定する
- bash block 直前 H2 anchor (`## Defense-in-Depth: Flow State Update (Before Return)`) と bash block 間に許容されない conditional が挿入されていないこと

**PR-2 で実装済** (本 PR `parent-routing-pattern-interim.test.sh` / `verify-terminal-output.sh` 内に組み込み済):

- ~~IMP-2: TC-7a を `count >= 2` に強化~~ → 本 PR `parent-routing-pattern-interim.test.sh` TC-7a (L428-433) で `grep -cE '\[interview:error\].*halt' "$CREATE_MD"` >= 2 を実装済
- ~~IMP-3: TC-2 に `--if-exists` count >= 3~~ → 本 PR `parent-routing-pattern-interim.test.sh` TC-2h で `grep -cE '\-\-if-exists' "$INTERVIEW_MD"` >= 3 を実装済
- ~~IMP-4: `verify-terminal-output.sh` Check 3 を独立 grep に分割~~ → 本 PR `verify-terminal-output.sh:262-268` で `completed` / `skipped` 独立 grep を実装済 (`error` は legacy OR-form として historical fixture 互換性のため維持)

**PR-7 残作業** (uniformity test 新設時に組み込み):

- IMP-5: anti-pattern catalog を `references/parent-routing-anti-patterns.md` 等の SoT に集約
- TQ-4: `and-logic-defense-chain.test.sh` Layer 7 撤去 (numbering gap 解消)
- Return Output re-patch bash block の構造 pin (上記の anchor-based awk validator)

### 6.2 追加される layer

| Layer | 追加対象 |
|---|---|
| sub-skill 側 flow-state patch | 全 8 sub-skill (parent-routing pattern canonical form) |
| Invariant test | `parent-routing-pattern-uniformity.test.sh` (8 sub-skill × 6 TC、+250 LoC) |
| Doc | 本 ADR、SPEC.md 改訂、sub-skill-return-protocol.md 改訂 |

### 6.3 ポジティブな副次効果

- 累積系列の cycle 数の異常な増加 (PR #916 9 cycle / PR #918 7 cycle) が解消する見込み (構造がシンプルになるため review 指摘が減る)
- `phase-transition-whitelist.sh` の edge は変更なし (forward transition graph は temporal layer のみ変更)
- `verify-terminal-output.sh` の AC-3 非 regression check は regex 緩和で両 form を許容 (forward-compatible)

## 7. Relationship to #674/#675 Decision Log

stop-guard.sh の撤去判断 (#674/#675) との integrity:

| #674/#675 | 本 ADR |
|---|---|
| 撤去判断: stop-guard.sh の **block-every-implicit-stop posture** が LLM thinking loop の原因と診断 | block posture ではなく **構造変更 (completion ceremony 撤去)** で対処 |
| 「stop-guard.sh を復活させない」decision | **遵守**。stop-guard 軽量復活は Plan B (§9) として fallback 記憶のみ |
| 撤去後 prompt-side defense のみが SPOF として残った | 本 ADR で **SPOF 自体を解消** (sub-skill 側で flow-state patch を完結) |

**新規 decision**: 累積系列の対策が拠って立っていた前提 (caller-side mandatory continuation) そのものが parent-routing pattern では不要であることを明示。これは #674/#675 の反転ではなく、**直交する新たな構造判断**である。

## 8. Rollback Plan

各 PR は単独 revert 可能 (`git revert <PR merge SHA>`):

- **Soft rollback**: PR-3 + PR-4 マージ後に cleanup chain で問題発生時、PR-4 のみ revert して `wiki/ingest` Phase 9.1 を旧 form に戻し、lint --auto migration は維持する (parser 互換性のため lint 6-field stats 行が両 form で動作する設計)
- **Hard rollback**: PR-8 → PR-1 の逆順 revert
- 本 ADR の rollback log section (§11) に記録

## 9. Plan B (前提が崩れた場合の fallback)

VC1 / PR-2 後 dogfood で `auto_continuation_failed` / `manual_fallback_adopted` が観測されたら、本 ADR の前提 (parent-routing pattern 仮説) が崩れている。その場合は **stop-guard 軽量復活案** (Plan モード Phase 2 第 1 ラウンドで検討) に切り替える:

- `stop-guard.sh` (撤去済) ではなく 80 LOC 程度の `stop-guard-light.sh` を Stop hook として実装
- **fire-once-then-yield posture** (#674/#675 撤去理由の block-every posture とは異なる)
- `last_stop_guard_fire_at` 等のフィールドで「同じ phase window で 1 度だけ block、それ以降は pass-through」を保証
- LLM thinking loop の再発を回避

Plan B 採用時は本 ADR を superseded とし、新規 ADR (`docs/designs/stop-guard-light-revival.md`) を作成。

## 10. 観察期間と成功判定

PR-8 マージ後、**回数 + 時間ハイブリッド**で観察:

- `/rite:issue:create` を **20 回以上** dogfood
- `/rite:pr:cleanup` を **10 回以上** dogfood
- 最低 **2 週間** soak
- `auto_continuation_failed` / `manual_fallback_adopted` sentinel が **0 件**で成功

soak 期間中に並行する他 PR が本 plan 対象 file を変更する場合は merge conflict resolution を慎重に実施。

## 11. Rollback Log

(本 ADR マージ後、各 PR で発生した rollback を時系列で記録する section。マージ前は空)

| Date | PR | Revert reason | Recovery action |
|---|---|---|---|
| (none yet) | | | |

## 12. References

- Plan: `~/.claude/plans/issue-920-923-flickering-storm.md`
- Issue #920: `gh issue view 920`
- Issue #923: `gh issue view 923`
- 累積系列: #552 / #622 / #634 / #651 / #687 / #910 / #917
- stop-guard.sh 撤去: #674 / #675 (commit `e2dfae0c`)
- `docs/designs/multi-session-state.md` — multi-state .rite-flow-state API (#686)
- `plugins/rite/skills/rite-workflow/references/sub-skill-return-protocol.md` — 現行 5 layer defense doc (本 ADR で改訂対象)
- `plugins/rite/commands/issue/parent-routing.md` — canonical pattern の reference (line 325-357)
