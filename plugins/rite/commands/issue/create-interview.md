---
description: |
  (Internal sub-skill — invoked by /rite:issue:create only. Do NOT invoke directly.)
  Issue 作成のための適応的インタビューを実行する sub-skill。
  Phase 1 規模感判定 + Phase 1.1 深堀り質問を担当。
---

# /rite:issue:create-interview

Execute the adaptive interview for Issue creation. This sub-command is invoked from `create.md` after Phase 0 (Preconditions) completes.

**Prerequisites**: Phase 0 (Preconditions) has completed in the parent `create.md` flow. The following information is available in conversation context:
- Extracted elements (What/Why/Where/Scope/Constraints) from Phase 0.1
- Goal classification from Phase 0.5
- Tentative slug from [Phase 0.2](./references/slug-generation.md) — generated per [Slug Generation Rules](./references/slug-generation.md#slug-generation-rules)

---

## 🚨 MANDATORY Pre-flight: Flow State Update (MUST execute FIRST)

> 本 Pre-flight は sub-skill の **先頭** で実行し interview scope に関係なく flow-state write を保証する (Bug Fix / Chore preset path でも skip 不可)。末尾配置だと scope=skip path で sub-skill が早期 return し flow-state write が抜けるため、先頭配置が必須。

**MUST run before any interview logic** (Phase 1 scope evaluation / Phase 1.1 deep-dive / return-output emission)。**not optional**、**interview scope に conditional でない** — Bug Fix / Chore preset (scope = "skip") でも実行:

```bash
# Rationale 詳細 (helper failure 可視化 / cold-start 二段書き込み) は本セクション末尾の
# blockquote 群を参照。
if ! state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh); then
  echo "[CONTEXT] STATE_PATH_RESOLVE_FAILED=1; reason=helper_exit_nonzero" >&2
  bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type "manual_fallback_adopted" \
      --details "create-interview.md:state-path-resolve.sh exit non-zero; falling back to /tmp" \
      --pr-number 0 \
      || echo "WARNING: workflow-incident-emit.sh failed — manual_fallback_adopted sentinel emit incomplete (state-path-resolve fallback path)" >&2
  state_root=""
fi
diag_log="${state_root:-/tmp}/.rite-flow-state-diag.log"
if ! mkdir -p "$(dirname "$diag_log")" 2>/dev/null; then
  # mkdir 失敗時に redirect 自体が失敗して helper が
  # 起動できなくなり、`FLOW_STATE_PATH_RESOLVE_FAILED=1` が `helper_exit_nonzero` 理由で立つが
  # 実態は「redirect 失敗で helper 起動不能」となる診断ズレを解消する。diag_log を /dev/null
  # に fallback して redirect が常に成立するようにし、診断情報のみ失う形で helper は確実に起動する。
  echo "WARNING: cannot create diag_log dir $(dirname "$diag_log") — diagnostic output redirected to /dev/null instead" >&2
  diag_log="/dev/null"
fi
if ! state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>>"$diag_log"); then
  echo "[CONTEXT] FLOW_STATE_PATH_RESOLVE_FAILED=1; reason=helper_exit_nonzero" >&2
  bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type "manual_fallback_adopted" \
      --details "create-interview.md:_resolve-flow-state-path.sh exit non-zero; routing to cold-start path" \
      --pr-number 0 \
      || echo "WARNING: workflow-incident-emit.sh failed — manual_fallback_adopted sentinel emit incomplete (_resolve-flow-state-path fallback path)" >&2
  state_file=""
fi
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "create_post_interview" \
      --active true \
      --next "rite:issue:create-interview Pre-flight completed. Proceed to Phase 1/1.1 if applicable, then return to caller. Caller MUST proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --if-exists; then
    echo "[CONTEXT] PREFLIGHT_PATCH_FAILED=1" >&2
    # 非 blocking: pre-return re-patch + phase-transition-whitelist.sh の case arm が safety net。
    # workflow-incident-emit.sh は stdout に sentinel を emit し Bash tool 経由で context にマージされる
    # (canonical pattern との差分は ADR `docs/designs/parent-routing-unification.md` 参照)。
    bash {plugin_root}/hooks/workflow-incident-emit.sh \
        --type "manual_fallback_adopted" \
        --details "create-interview.md:pre-flight patch failed; pre-return re-patch covers state" \
        --pr-number 0 \
        || echo "WARNING: workflow-incident-emit.sh failed — manual_fallback_adopted sentinel emit incomplete (pre-flight patch path)" >&2
  fi
else
  # 二段書き込み (cold start): create で create_interview を bootstrap → patch で create_post_interview。
  # rationale 詳細は本セクション末尾の "Why cold-start ... 二段書き込み" blockquote (canonical SoT) 参照。
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "create_interview" --issue 0 --branch "" --pr 0 \
      --next "rite:issue:create-interview Pre-flight bootstrapping cold-start state; will transition to create_post_interview immediately."; then
    echo "[CONTEXT] PREFLIGHT_CREATE_FAILED=1" >&2
    bash {plugin_root}/hooks/workflow-incident-emit.sh \
        --type "manual_fallback_adopted" \
        --details "create-interview.md:pre-flight cold-start create failed; sub-skill cannot bootstrap state" \
        --pr-number 0 \
        || echo "WARNING: workflow-incident-emit.sh failed — manual_fallback_adopted sentinel emit incomplete (pre-flight cold-start create path)" >&2
  elif ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "create_post_interview" \
      --active true \
      --next "rite:issue:create-interview Pre-flight completed. Proceed to Phase 1/1.1 if applicable, then return to caller. Caller MUST proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --if-exists; then
    echo "[CONTEXT] PREFLIGHT_CREATE_THEN_PATCH_FAILED=1" >&2
    # skip path (XS / Bug Fix / Chore) + Return Output re-patch も同 transient cause で失敗した場合、
    # state は `create_interview` のまま停滞する。詳細は "`[interview:error]` halt 判定ルール" 表参照。
    bash {plugin_root}/hooks/workflow-incident-emit.sh \
        --type "manual_fallback_adopted" \
        --details "create-interview.md:pre-flight create succeeded but follow-up patch failed; state may stick at create_interview if Return Output re-patch also fails on skip path" \
        --pr-number 0 \
        || echo "WARNING: workflow-incident-emit.sh failed — manual_fallback_adopted sentinel emit incomplete (pre-flight create-then-patch path)" >&2
  fi
fi
```

**Why `create_post_interview` (not `create_interview_running`)**: caller (`create.md` Phase 1 Delegation to Interview Pre-write) は既に `create_interview` を書込済 (delegation in flight signal)。本 Pre-flight が **interview 実行前** に `create_post_interview` へ進めることで、normal completion / Bug Fix preset early exit / unexpected stop のいずれの exit point でも orchestrator が flow state の `.phase = create_post_interview` を読んで Phase 2 へ進む経路に切り替わる。`phase-transition-whitelist.sh` が `create_post_interview → create_delegation` を唯一の whitelisted forward transition として graph 定義するため、orchestrator は Phase 3 Delegation Routing を実行することが期待される (graph 自体は advisory; 詳細は次段注記参照)。

**Why cold-start (state file 不在) 経路で create→patch 二段書き込み**: 直接 `create --phase create_post_interview` を書くと `previous_phase=""` (cold start) のまま `.phase = create_post_interview` が記録される。`phase-transition-whitelist.sh` の cold-start guard (`[ -z "$prev" ] && return 0` predicate) は単段 create でも runtime accept するため、機能的な runtime defeat は発生しない。ただし audit-trail fidelity (= 「conceptually `create_interview` を経由してから `create_post_interview` に進んだ」という履歴の semantic clarity) が失われ、将来 stricter gating (cold-start guard を厳格化、または conversation-context observer が `previous_phase` を読む下流処理) を有効化した際に正規 path として認識されない。caller 側 Pre-write 失敗時や手動 sub-skill invocation 時にこの cold-start 経路が踏まれるため、create で `create_interview` を bootstrap してから patch で `previous_phase=create_interview` を残す二段書き込みを採用する。

> **Note — `phase-transition-whitelist.sh` の現状 runtime semantics**: `rite_phase_transition_allowed` predicate **単体** は本リポ内で **runtime caller 0 件** (stop-guard.sh 撤去 #675 以降)。一方で **同じファイル** が export する `rite_phase_is_create_lifecycle_in_progress` / `rite_phase_is_cleanup_lifecycle_in_progress` は依然 runtime caller を持つ (`pre-tool-bash-guard.sh:201-202` の Pattern 5 / `session-end.sh:87-88, 95-96`)。したがって `_RITE_PHASE_TRANSITIONS` graph 自体は advisory (transition の機械的 reject は行われない) だが、graph 上の phase 名は lifecycle predicate の判定に load-bearing で参照される。**ファイル全体を documentation-only と推論せず**、phase 名や lifecycle 定義を削除する際は predicate caller への影響を必ず確認すること。本二段書き込み rationale (audit-trail fidelity) は「現状 advisory な transition graph が将来 reactivate された場合のための future-proofing」であり、現在の runtime 影響は副次的 (caller-side / 手動 invocation 時の `previous_phase` log 整合性のみ)。

**`[interview:error]` halt 判定ルール**: `.phase = create_post_interview` を確定できないまま sub-skill が終了する経路は audit-trail 破損または state 不在のため、Phase 2 進入禁止で halt する。**Return Output bash block (本ファイル末尾) は `--if-exists` で file 不在時 silent skip (exit 0、`flow-state-update.sh` の patch / increment mode 内 `IF_EXISTS && ! -f $FLOW_STATE` 分岐参照) する**ため、`INTERVIEW_RETURN_PATCH_FAILED` だけでは捕捉できない経路がある。Claude (本 sub-skill) は Return Output bash block 完了後、conversation context を grep して以下のいずれかが立っていれば `[interview:completed]` / `[interview:skipped]` ではなく `[interview:error]` を emit し、caller (`create.md`) に manual intervention を要求する:

| 観測される retained flag (一つ以上満たせば halt) | 状態 | 理由 |
|--|--|--|
| `PREFLIGHT_CREATE_FAILED=1` | state file 不在 | cold-start で state file を bootstrap できず、Return Output re-patch は `--if-exists` で silent skip。最悪状態 (audit-trail 不在 + 後続 phase が cold-start path に永続誘導される) |
| `PREFLIGHT_PATCH_FAILED=1` AND `INTERVIEW_RETURN_PATCH_FAILED=1` | state stuck at `create_interview` | caller 書込済の phase から進めず audit-trail 破損 |
| `PREFLIGHT_CREATE_THEN_PATCH_FAILED=1` AND `INTERVIEW_RETURN_PATCH_FAILED=1` | state stuck at `create_interview` | cold-start で bootstrap 後に follow-up patch も Return Output re-patch も両失敗 |
| `PREFLIGHT_CREATE_THEN_PATCH_FAILED=1` AND skip path (Phase 1.1 bypass) | state stuck at `create_interview` | Skip path も Return Output re-patch は走るが、cold-start bootstrap 失敗で state file 不在のまま `--if-exists` で silent skip するため `INTERVIEW_RETURN_PATCH_FAILED` retained flag が立たず捕捉不能 (skip path Return Output 必須化は本ファイル `Applying the Scope` / `Defense-in-Depth: Flow State Update (Before Return)` 参照) |

両 flag が同一 turn 内で観測された場合 (および PREFLIGHT_CREATE_FAILED 単独経路) は silent corrupt audit-trail よりも明示 error を優先する。transient FS pressure 等の稀なケースが対象で、通常運用では発火しない。

> **注記 — halt 対象外の retained flag**: 本ファイル冒頭 bash block で emit される 6 種の retained flag のうち、`STATE_PATH_RESOLVE_FAILED=1` と `FLOW_STATE_PATH_RESOLVE_FAILED=1` は **halt 対象外**。両者は state 解決 helper 経路の失敗で diag_log 出力先のみ失う非致命的経路。後続の `flow-state-update.sh create/patch` は引数として `state_root` を受け取らず、subshell 内で `state-path-resolve.sh "$(pwd)"` を独立 resolve するため、本 Pre-flight 経路の helper failure は flow-state 書込み自体には伝播せず成功する (失敗時は別の retained flag `PREFLIGHT_PATCH_FAILED` / `PREFLIGHT_CREATE_FAILED` / `PREFLIGHT_CREATE_THEN_PATCH_FAILED` で halt 判定表 row 1-4 に流れる)。`[interview:error]` halt は state stuck at `create_interview` の audit-trail 破損経路 (上記 4 row) に限定する。

> **二次防御 — LLM context grep が落ちる前提の defense-in-depth**: 本判定は LLM (Claude) が conversation context を grep して retained flag を観測することに依存する canonical な parent-routing pattern を採用している (`start.md` / `parent-routing.md` / `branch-setup.md` と同型)。LLM context grep が落ちる経路 (auto-compact / context truncation / LLM の不注意な早期 emit) に対する二次防御は以下に集約される:
> 1. **caller-side halt rule の prose 明示** (`create.md` Sub-skill Return Protocol "Halt rule"、`references/pre-check-routing.md` Item 0 の `[interview:error] matched` 経路): caller も独立に halt 判定を持ち、sub-skill が `[interview:completed]` / `[interview:skipped]` を誤 emit しても workflow_incident sentinel + retained flag による post-hoc auto-register (Phase 5.4.4.1) で追跡される
> 2. **workflow_incident sentinel** (`manual_fallback_adopted`): 各 PREFLIGHT_*_FAILED emit と同時に発火し、conversation context 破損時も hooks/workflow-incident-emit.sh 経由で stdout に残る (Bash tool が context にマージ)
> 3. **`hooks/tests/parent-routing-pattern-interim.test.sh` TC-7**: caller-side halt rule prose の silent weakening を mechanical に検出する
>
> 機械化 (bash 内 retained flag 集約) は parent-routing pattern 全体の非対称を生むため本 PR scope 外。tempfile 経由の collector pattern による完全機械化は future ADR / follow-up Issue で検討する。

> **Known design debt — `workflow-incident-emit.sh --type` 粒度**: 本ファイルおよび `create.md` の合計 14 emit sites がすべて `--type manual_fallback_adopted` に collapse し、失敗モードの分類は `--details` 自由テキスト parsing 依存となる。中期的には dedicated enum 値追加 (`parent_routing_pre_flight_failed` 等) または `--subtype` opaque arg 導入を検討。Follow-up は ADR `docs/designs/parent-routing-unification.md` §6.x で tracking。

**Idempotence**: 単一 sub-skill invocation 内で複数回実行されても safe — patch mode は pre-update `.phase` から `previous_phase` を設定し、re-entry で `create_post_interview` のまま phase regression しない。

---

## Phase 1: Adaptive Interview Depth

After Phase 0 completes, determine the interview scope for Phase 1.1 based on tentative complexity and task type. This avoids excessive questioning for simple Issues.

### Tentative Complexity Estimation

詳細は [`references/complexity-gate.md#tentative-complexity-estimation`](./references/complexity-gate.md#tentative-complexity-estimation) を参照。Phase 0 の情報から複雑度 (XS/S/M/L/XL) を暫定推定するロジックで、(1) 後続の Adaptive Interview Depth による perspective filtering と (2) Phase 2 task decomposition decision (XL のみ trigger) に使う。最終 complexity は Phase 3 Heuristics Scoring (`create-register.md`) で確定する。

### Complexity-Based Interview Scope

| Tentative Complexity | Interview Scope | Target Perspectives |
|---------------------|----------------|---------------------|
| **XS** | No deep-dive needed | Skip Phase 1.1 entirely → proceed to Phase 2 |
| **S** | Minimal deep-dive | Perspective 1 (Technical Implementation) and 3 (Edge Cases) only |
| **M** | Standard deep-dive | Perspectives 1, 2, 3, 4 (5, 6 only if user-initiated) |
| **L** | Full deep-dive | All 6 perspectives + follow-up questions |
| **XL** | Full + decomposition | All 6 perspectives + set decomposition flag for Phase 2 |

### Task Type Presets

Task type が complexity-based scope より強い signal となる場合、以下で override（task type が ambiguous なら complexity-based に fallback、user は scope に関係なく追加質問を要求可能）:

| Task Type | Detection Method | Interview Override |
|-----------|-----------------|-------------------|
| **Bug Fix** | goal = "既存機能のバグ修正" or labels contain `bug` | Phase 0 → 2 direct (skip deep-dive) |
| **Chore** | goal = "その他" + maintenance context (依存更新 / CI修正 / リネーム / cleanup / linter設定 / ツール更新) or labels `chore` | Phase 0 → 2 direct (skip deep-dive) |
| **Feature** | goal = "新機能の追加" | complexity-based scope を適用 |
| **Refactor** | goal = "リファクタリング" | complexity-based scope を適用 |
| **Documentation** | goal = "ドキュメントの更新" or labels `documentation` | Abbreviated Phase 1.1 (perspectives 2, 4, 6 only) |

### Applying the Scope

After determining the interview scope:

1. **skip** (XS, Bug Fix, Chore): Skip Phase 1.1。**ただし本ファイル末尾の "Defense-in-Depth: Flow State Update (Before Return)" bash block (Return Output re-patch) は skip path でも必ず実行してから return すること** — Skip path で再 patch を省略すると `PREFLIGHT_CREATE_THEN_PATCH_FAILED` 単独経路で audit-trail が `create_interview` に停滞する経路を防げない。再 patch 実行後、`[interview:skipped]` を emit して caller へ return → Phase 2 へ
2. **limited** (S, Documentation): Enter Phase 1.1 with the specified perspectives only
3. **standard / full** (M, L, XL): Enter Phase 1.1 with the full interview flow + perspective filtering

When entering Phase 1.1, display the scope to the user. Select language per `language` setting (`ja` / `en` / `auto` based on input language):

| Scope | Japanese | English |
|-------|----------|---------|
| limited | `複雑度 {complexity} / タスク種別 {task_type} に基づき、以下の視点に絞って確認します:\n- {perspective_list}\n追加の確認が必要な場合はお知らせください。` | `Based on complexity {complexity} / task type {task_type}, focusing on the following perspectives:\n- {perspective_list}\nLet me know if you need additional confirmation.` |
| standard / full | `複雑度 {complexity} に基づき、{standard:標準 / full:フル}の深堀インタビューを実施します。` | `Based on complexity {complexity}, conducting a {standard / full} deep-dive interview.` |

---

## Phase 1.1: Deep-Dive Interview

- **Boundary with Phase 0.5 (Quick Confirmation)**: Phase 0.5 は **quick confirmation** (What/Why/Where ギャップ充填 + task type 分類、0-1 AskUserQuestion calls)。Phase 1.1 は **deep-dive interview** (実装詳細を multiple perspective から探求、complexity に応じ複数 round)
- **Purpose**: 実装詳細を明確化（surface requirements ではない）。decision-divergence point と easily-overlooked aspect に focus
- **Prerequisite**: Phase 1 の interview scope を確認。"skip" なら本 phase を完全 skip、limited なら perspective filtering を適用

### EDGE-5: Context Window Pressure Mitigation

詳細は [`references/edge-cases-create.md#edge-5-context-window-pressure-mitigation`](./references/edge-cases-create.md#edge-5-context-window-pressure-mitigation) を参照。Phase 1.1 開始前に context pressure を heuristics で評価し、High pressure 時は auto-shortening mode (perspectives 削減 + batching + 早期 exit option) を発動する。

---

> **Important**: AskUserQuestion でインタビューを実施し、user が明示的に「no more points to confirm」と回答するまで継続。当て推量で打ち切らない。迷ったら質問する（聞きすぎは無害、品質基準は下記）。

### Basic Interview Guidelines

**Principle of Continuous Interviewing**: User 明示終了まで継続。AI 判断 (`enough information gathered`) での打ち切りは禁止 (canonical: [Termination Logic > Phase 1.1](#phase-11-interview-termination))。Phase 1 scope の perspective を確認し、user が「任せる」「skip」と言うまで終了せず、各 perspective を掘り下げ回答から follow-up を導出する。

**Quality Standards**: 自明な質問 (Yes/No 即答可、選択肢が 1 つ) は避ける。tradeoff を伴う複数選択肢の質問を優先。見落としやすい edge case / concern を能動的に確認。

### Tentative Complexity & Interview Perspectives

- **Tentative Complexity**: Phase 1 で推定。詳細は [`references/complexity-gate.md#tentative-complexity-estimation`](./references/complexity-gate.md#tentative-complexity-estimation) 参照。Phase 1 interview scope と Phase 2 task decomposition decision に使われる
- **Filtering rule**: Phase 1 で決定された scope に含まれる perspective のみ質問。scope 外は user 明示要求がない限り silent skip
- **Template reference**: Perspective 定義・confirmation 条件・question template は `{plugin_root}/templates/issue/interview-perspectives.md` を参照

### Interview Flow

1. **First question**: 最重要 decision point から開始
2. **Deep-dive**: 回答から follow-up を導出
3. **End confirmation**: 全 applicable perspective 確認後、必ず end confirmation dialog を提示 ([Termination Logic > Phase 1.1](#phase-11-interview-termination))
4. **Specification summary**: user が "no" と回答したら interview results を Issue body に反映

**End confirmation question format**:
```
質問: 他に確認したい点はありますか？

オプション:
- ある（追加の質問・要望を入力）
- ない、この内容で進めてください
- 残りの詳細は任せる
```

### EDGE-2: Re-entry After Exit Confirmation

詳細は [`references/edge-cases-create.md#edge-2-re-entry-after-exit-confirmation`](./references/edge-cases-create.md#edge-2-re-entry-after-exit-confirmation) を参照。Phase 1.1 終了確認後にユーザーが新規情報を追加入力した場合の re-entry trigger 検出基準と、再開・spec 追加・無視の 3 分岐挙動 (1 セッション 1 回 limit 付き) を定義する。

### AskUserQuestion Batch Optimization

**Applies to**: Modifies the Interview Flow above. Apply the batching rules below instead of asking each perspective independently to minimize context pressure from many small interactions.

**Batching Rules**: Group perspectives into **1-2 AskUserQuestion calls** (use `multiSelect: true` when multi-select is appropriate):

| Interview Scope | Batch Strategy | Max Calls |
|-----------------|---------------|-----------|
| **S** (Perspectives 1, 3) | Single batch: Technical + Edge Cases | 1 + follow-ups |
| **M** (1, 2, 3, 4) | B1: Technical + Edge Cases. B2: UX + Consistency | 2 + follow-ups |
| **L/XL** (All 6) | B1: Technical + Edge Cases + NFR. B2: UX + Consistency + Tradeoffs | 2 + follow-ups |
| **Documentation** (2, 4, 6) | Single batch: all 3 perspectives | 1 + follow-ups |

**Example (S scope, Batch 1)**:
```
以下の点について確認させてください:
1. {機能} の実装アプローチはどちらを想定していますか？
2. 以下のエッジケースへの対応は必要ですか？

オプション:
- {アプローチA} / エッジケース対応あり
- {アプローチB} / 正常系のみ
- 詳細を説明するので提案してほしい（番号ごとに個別回答可）
- 判断を任せる
```

> **Note**: 組み合わせがオプションに該当しない場合（例: "A + 正常系のみ"）はユーザーが "Other" で自由記述で回答できる。M/L/XL スコープでも同形式で「技術 + エッジケース」「UX + 一貫性」等を Batch 化する。

**Pre-condition Evaluation**: Before asking, evaluate whether the question is necessary:

| Pre-condition | Action |
|--------------|--------|
| Implementation approach is uniquely determined | Skip Technical Implementation |
| No UI/UX changes | Skip UX |
| Input well-constrained (enum, fixed format) | Skip Edge Cases |
| No existing features affected | Skip Consistency |
| No performance/security concerns | Skip NFR (unless L/XL) |

**Important**: Pre-condition は batch 内の質問を減らすが user 確認を代替しない。batch 内の全質問が排除された場合は batch 全体を skip する。

**Follow-up Questions**: After batch responses, follow-ups are asked individually (not batched) as they require specific context from prior answers. After **2 rounds** of follow-ups, present the end confirmation dialog. User judgment is final — continue if requested (UX-2: No AI auto-termination).

### Deep-Dive Examples

各ユースケースの representative な質問パターンを示す（実際の質問は要件に応じて perspective filtering に従い導出）:

| Use Case | First Question | Representative Options | Follow-up Examples |
|----------|----------------|----------------------|---------------------|
| **User Authentication** | 認証方式は？ | メール/パスワード, ソーシャルログイン, 両方, 提案要 | (email/password 選択時) パスワードリセット機能の要否 / 認証状態の保持期間 (セッション/永続/期限付き) |
| **UI Component (Data Table)** | 必要な機能は？ | ソート, フィルタ, ページネーション, 全部 | 想定データ量 (少量100件以下 / 中量1000件 / 大量1万件以上) → クライアント or サーバーサイド処理判断 |
| **Refactoring (API Client)** | 主目的は？ | 可読性, テスタビリティ, パフォーマンス, 新機能準備 | インターフェース影響 (破壊的変更 / インターフェース維持 / 段階的移行) |

> **Pattern**: 第一質問はユースケースの最も重要な分岐点を提示し、follow-up は回答に応じて edge case / NFR / tradeoff を掘り下げる。option には常に「提案してほしい」「判断を任せる」を含めて user の judgment escape hatch を残す。

### Interview Termination Conditions

> **Reference**: See [Termination Logic > Phase 1.1 Interview Termination](#phase-11-interview-termination) for the complete termination rules, including the mandatory exit confirmation dialog and AI auto-termination prohibition (UX-2).

### Reflecting Interview Results

Interview Perspective → Target Sections の正規 mapping table は [`references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping`](./references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping) を参照。Phase 1.1 では本 reference の mapping に従って interview results を Section 1-9 に割り当てる。

**Note**: Phase 1.1 は raw interview results を会話コンテキストに保持するのみ。Implementation Contract Section 1-9 への構造化 mapping は Issue body 生成時 (`create-register.md` Phase 3) に実施する。

**Retention format** (会話コンテキスト保持、Issue body には書き込まない): JSON object `interview_results` に 6 perspective キー (`technical_implementation` / `user_experience` / `edge_cases` / `existing_feature_impact` / `non_functional_requirements` / `tradeoffs`) を持ち、各キーは「<項目>: <選択値>」形式の string array を保持する（例: `"technical_implementation": ["認証方式: JWT", "トークン保存: HttpOnly Cookie"]`）。スコープ外 perspective は空配列。

---

## Termination Logic

### Phase 1.1 Interview Termination

> **UX-2: Exit Condition Enforcement** — 全 applicable perspective 確認後、end confirmation dialog の提示は **MUST**（無条件、AI 判断 skip 禁止）。

**Rules**: (1) scope 内 perspective 完了後は無条件で end confirmation dialog 提示、(2) 「enough information gathered」AI 自己判断での終了禁止（終了判断は user のみ）、(3) user が明示的に "skip" を選択した場合のみ skip 可能、(4) Phase 1 scope が対象 perspective を決定。

**Scope-specific termination**:

| Interview Scope | Termination Rule |
|----------------|-----------------|
| **Skip** (XS, Bug Fix, Chore) | Phase 1.1 不実行、終了処理不要 |
| **Limited** (S, Documentation) | 指定 perspective 完了後 dialog 提示、追加なしなら Phase 2 へ |
| **Standard** (M) | Perspective 1-4 完了後 dialog 提示、追加あれば継続 |
| **Full** (L, XL) | 全 6 perspective 完了後 dialog 提示、user 明示終了まで継続 |

**Dialog format**: [Interview Flow > End confirmation question format](#interview-flow) を使用。

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0)。Flow-state write は 🚨 MANDATORY Pre-flight (本ファイル冒頭) で interview scope に関係なく post-interview phase を記録済み。本セクションは pre-return idempotent re-patch として timestamp / `next_action` を refresh する。
>
> **⚠️ Skip path でも必ず実行する**: Bug Fix / Chore preset (scope=skip) や XS (Phase 1.1 完全 skip) 経路でも、本 Defense-in-Depth bash block を return 前に必ず実行する。Skip path で本 re-patch を省略すると、Pre-flight cold-start 二段書き込みの第二段が失敗した時 (`PREFLIGHT_CREATE_THEN_PATCH_FAILED=1` 単独経路) に Return Output `INTERVIEW_RETURN_PATCH_FAILED` retained flag が立たず、`[interview:error]` halt 判定表の row 4 で halt 対象とならない silent regression を起こす。skip path / standard path / limited path / full path のいずれも実行する。
>
> **`--preserve-error-count` 撤去の rationale (ADR §3.1)**: parent-routing pattern では caller-side Mandatory After Interview Step 0/1 が廃止される。`stop-guard.sh` 撤去 (#675) 以降、`session-end.sh` / `preflight-check.sh` / `phase-transition-whitelist.sh` のいずれも `error_count` を runtime 参照しておらず、`error_count` の RE-ENTRY DETECTED + THRESHOLD bail-out path は production runtime では既に dead code 化している (機械検証: `hooks/tests/error-count-runtime-reference.test.sh`)。本 sub-skill 単独で `create_post_interview` を完結させる設計のため、同一 phase self-patch (Pre-flight + Return Output) で error_count が 0 にリセットされても production 影響なし。
>
> **Forward note**: `wiki/ingest.md` / `cleanup.md` は依然 `--preserve-error-count` を維持しており、両 site の prose は「RE-ENTRY DETECTED escalation + THRESHOLD bail-out を機能させるため」load-bearing として記述されている。一方で `hooks/tests/error-count-runtime-reference.test.sh` の機械検証では `production runtime には reader 不在` (dead code) と確認されている。表現の矛盾を整理すると: **production runtime での機能は不在だが、両 site の prose は historical context として保持され、`error_count` が runtime 復活した場合の forward-compatible 装備として残っている**。両 site の prose 更新 (load-bearing 主張削除 + historical context への置換) は PR-3/PR-4 (`wiki/ingest.md` / `cleanup.md` を parent-routing pattern に移行する PR) で実施予定。経過期間中に reader が `error_count` を runtime 復活させた瞬間に create-interview だけ reset 経路を持つ非対称が出現するリスクは `hooks/tests/error-count-runtime-reference.test.sh` の dead code 機械検証で防御している。

Idempotent re-patch (the 🚨 MANDATORY Pre-flight at the head of this file already wrote `create_post_interview`; this re-patch refreshes timestamp / `next_action`):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_interview" \
    --active true \
    --next "rite:issue:create-interview completed. Proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
    --if-exists; then
  echo "[CONTEXT] INTERVIEW_RETURN_PATCH_FAILED=1" >&2
  # 非 blocking: Pre-flight (head) で同 phase 書込済のため caller は正常動作可能。
  # 同 phase 自己 patch であり idempotent。`--if-exists` は idempotent guard として機能する
  # — `flow-state-update.sh` の **patch / increment 両 mode** 内 `IF_EXISTS && ! -f $FLOW_STATE` 分岐で file 不在時に exit 0 で silent skip する。
  # Pre-flight 成功時は file 存在保証下で no-op 化を不要にし、Pre-flight 失敗 + cold-start `create` 失敗の
  # 二重失敗時のみ silent skip する。後者は Pre-flight 側の retained flag (`PREFLIGHT_CREATE_FAILED`)
  # が context に残っているため、post-hoc 検出は Pre-flight 側 flag に依存する設計
  # ("`[interview:error]` halt 判定ルール" 表参照 — PREFLIGHT_CREATE_FAILED 単独経路も halt 対象)。
  # workflow_incident sentinel を併発させて post-hoc 検出経路を補強する:
  bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type "manual_fallback_adopted" \
      --details "create-interview.md:return-output flow-state patch failed; Pre-flight write covers caller-side state" \
      --pr-number 0 \
      || echo "WARNING: workflow-incident-emit.sh failed — manual_fallback_adopted sentinel emit incomplete (return-output path)" >&2
fi
```

After the flow-state update above, output the result pattern:

- **Interview completed**: `[interview:completed]`
- **Interview skipped** (XS / Bug Fix / Chore): `[interview:skipped]`
- **Halt with error** (前述 "`[interview:error]` halt 判定ルール" 表のいずれかの条件成立時): `[interview:error]` — caller は manual intervention を要求して halt する。`PREFLIGHT_CREATE_FAILED` 単独経路も含むため、Return Output bash block 完了後に context grep で retained flag を確認してから emit する形式を選択する

This pattern is consumed by the orchestrator (`create.md`) to determine the next action.

---

## Caller Return Protocol

Control **MUST** return to caller (`create.md`). Caller **MUST immediately** proceed to Phase 2 (Task Decomposition Decision) in the same response turn — no GitHub Issue has been created yet.

**→ Return to `create.md` and proceed to Phase 2 now. Do NOT stop.**
