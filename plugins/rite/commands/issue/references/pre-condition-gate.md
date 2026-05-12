# Pre-condition Gate — `state-read.sh` fail-fast Pattern SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` ワークフローにおける **pre-condition check (#490 AC-5)** の `state-read.sh` fail-fast pattern の SoT である。`start.md` の Phase 3 / Phase 5.5.1 / Phase 5.6 の pre-condition block、および Phase 5.5.2 内 metrics step (`plan_deviation_count` 取得) と Phase 5.7 (`parent_issue_number` 取得) で同型の capture pattern を共有する。本 reference は **5 site で重複していた if/else capture pattern**、 **`.phase` vs `.previous_phase` の使い分け根拠**、 **`state-read.sh` を使う理由 (per-session vs legacy state file)** を 1 ファイルに集約する。
>
> **抽出経緯**: `start.md` の Pre-condition check 3 箇所 (Phase 3: L484-540 / Phase 5.5.1: L1697-1758 / Phase 5.6: L1992-2050、合計約 178 行) が同型の散文 + bash block で書かれていた。加えて Phase 5.5.2 内 metrics step の `plan_deviation_count` 取得 (L1795-1840) と Phase 5.7 の `parent_issue_number` 取得もまた同一 capture pattern を inline で再掲していた。Issue #899 (PR C — #896 親 Issue) で本 reference に集約し、各 caller は anchor reference + 5 引数 bash literal のみに圧縮する。

## なぜ pre-condition check が必要か (#490 AC-5)

`/rite:issue:start` の workflow は phase 単位の sequential transition で構成され、各 phase の Mandatory After block が次 phase 向けの flow state を書き込む。LLM が **意図的または事故で intermediate phase を skip した**場合、後段の phase は「期待する事前状態」を満たさない state で実行され、silent skip による partial corruption (e.g., `metrics.enabled: false` で Metrics body を skip しつつ Mandatory After marker も skip → Phase 5.6 が `phase5_post_status_in_review` で誤起動) が発生しうる。

Pre-condition check は **`state-read.sh` で `.phase` を読み、期待する post-marker と一致しない場合は ERROR と ACTION 指示を出して abort する** ことで、silent skip を fail-fast に変換する防御層である。

## `.phase` vs `.previous_phase`

| 評価対象 | 意味 |
|----------|------|
| `.phase` | **直前に完了した phase の post-marker** (例: `phase2_post_work_memory`) |
| `.previous_phase` | `.phase` の predecessor (1 hop 前の phase) |

`flow-state-update.sh create` mode は新 phase を `.phase` に書き込む際、 **旧 `.phase` を `.previous_phase` にシフトする** 設計 (`hooks/flow-state-update.sh` の create branch 実装)。したがって:

- **Pre-condition check は `.phase` を読む**: 期待値は「直前 Mandatory After が書き込んだ post-marker」であり、これは `.phase` に格納されている。
- **`.previous_phase` を読むのは誤り**: predecessor を比較すると normal entry でも常に 1 hop 前を expected と認識し、毎回 ERROR を発火する false-positive となる (prompt-engineer cycle-3 CRITICAL で検出済みの過去 regression)。

## `state-read.sh` を使う理由 (per-session vs legacy state file)

`flow_state.schema_version=2` 以降、active state は **per-session file** (`.rite/sessions/{session_id}.flow-state`) に書き込まれる。一方、legacy state file (`.rite/flow-state.json`) は schema_version=1 の互換のために残置されており、別 session の残骸が混在する可能性がある。

```
.rite/
├── flow-state.json                    ← legacy snapshot (互換用、他 session の residue を含む)
└── sessions/
    └── {session_id}.flow-state         ← 現 session 固有 state (authoritative)
```

`state-read.sh` は **per-session file を優先解決し、存在しない場合のみ legacy にフォールバック** する。Pre-condition check で legacy を直接 `jq` で読むと、別 session の `phase5_post_stop_hook` 等が leak して **fresh Phase 3 check で誤 ERROR** を出すリスクがある (Issue #680 で実際に発生したケース)。

したがって Pre-condition check は **必ず `state-read.sh` 経由**で `.phase` を読むこと。`cat .rite/flow-state.json | jq -r .phase` 形式は禁止。

## Canonical capture pattern (2 forms)

`state-read.sh` 起動失敗と pre-condition 失敗を**区別**するため、以下の if/else 形式を使う。 form は site の用途に応じて 2 種類を使い分ける。

### Form A: 複数行 form (Pre-condition + 値取得 用)

Phase 3 / 5.5.1 / 5.6 の pre-condition check (3 site) + Phase 5.7 parent close (`parent_issue_number` 取得、pre-condition ではないが Form A canonical を共有する 1 site) の **start.md 内 4 箇所** はこの form を使う。 `ERROR:` 行と `ACTION:` 行を後続 if 文で複数行に渡って出力するため、可読性のため複数行 form が canonical:

```bash
if curr=$(bash {plugin_root}/hooks/state-read.sh --field phase --default ""); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field phase in {Phase X} pre-condition" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase={phase_X_pre_condition}; rc=$rc" >&2
  exit 1
fi
```

`caller-markdown-block.test.sh` TC-3 は本 form を `^if .*then$` (行末 `then`) で grep pin している (start.md 4 箇所、implement.md 1 箇所、review.md 1 箇所、resume.md 1 箇所)。

### Form B: inline 1 行 form (metrics step 用)

Phase 5.5.2 内 `implementation_round` 取得 (`plan_deviation_count` 算出) は単純な capture (失敗時 warning 出力 + 値 default 化) のため、1 行 form が canonical。Form A と同様に **`[CONTEXT] STATE_READ_FAILED=1` sentinel を emit する**ことで downstream observability (cross-session-incident 集計 / workflow-incident-emit-protocol grep) に統一形式で通知する:

```bash
if val=$(bash {plugin_root}/hooks/state-read.sh --field implementation_round --default 0); then :; else rc=$?; echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_5_2_metrics; rc=$rc" >&2; echo "WARNING: state-read.sh failed (rc=$rc) — metrics for plan_deviation_count skipped" >&2; val=""; fi
```

`caller-markdown-block.test.sh` TC-6 は本 inline form を `if val=...; then :; else rc=$?` の 1 行 canonical で grep pin している (Issue #908 で確立)。

> **Form A と Form B の sentinel emit 共通化**: 両 form ともに `[CONTEXT] STATE_READ_FAILED=1; phase={site}; rc=$rc` を必ず emit する。両者の唯一の差異は (a) **severity prefix** (Form A: `ERROR:` で `exit 1`、Form B: `WARNING:` で値 default 化して fall-through)、(b) **行展開** (Form A: 複数行 / Form B: 1 行) のみ。downstream observability tooling は単一 sentinel pattern (`STATE_READ_FAILED`) を grep するだけで Form A / B の両経路を捕捉できる。

### 共通禁止事項

> **NG パターン**: `if ! curr=$(...); then rc=$?; ... fi` は bash 仕様上、「!」 が pipeline 全体を反転するため `rc` には常に 0 が入る。 helper 起動失敗 (state-read.sh の exit 非 0) と pre-condition 失敗 (state-read.sh は exit 0 で値を返したが `curr` が期待値と不一致) を区別できなくなる。 **`if cmd; then :; else rc=$?; fi`** 形式を form A / B のいずれでも必ず使うこと。

> **capture を伴わない `if ! cmd; then ...`** (例: `if ! mapfile ...` / `if ! gh ...`) は本 guard の適用範囲外。capture と exit code を両方取る場合のみ if/else 形式が必須。

## Phase 別の期待値テーブル

| Phase | Pre-condition expected `.phase` | Resume re-entry も accept する代替値 | 対応する whitelist edge | Skip 検出時の指示 |
|-------|--------------------------------|--------------------------------------|-------------------------|------------------|
| **Phase 3** (implementation-plan) | `phase2_post_work_memory` | `phase3_post_plan` (`/rite:resume` re-entry) | `phase2_post_work_memory → phase3_plan`、resume 経路は `phase3_post_plan → phase3_plan` | Phase 2.4 / 2.5 / 2.6 の missing step に return |
| **Phase 5.5.1** (Issue Status In Review) | `phase5_post_ready` | なし | `phase5_post_ready → phase5_status_in_review` | Phase 5.5 (Ready for Review) に return |
| **Phase 5.6** (Completion Report) | `phase5_post_metrics` | なし | `phase5_post_metrics → phase5_completion` | Phase 5.5.1 (Status) / 5.5.2 (Metrics) に return |

> **Pre-condition と whitelist の二重防御**: 各 Pre-condition check は LLM 向け enforcement (本 reference 後段の "Enforcement note") で routing を駆動するが、 **`phase-transition-whitelist.sh` も独立に許可エッジを検証**する。例: Phase 5.6 の pre-condition が `phase5_post_status_in_review` 等を誤って受容しても、whitelist が `phase5_post_metrics → phase5_completion` 以外の source を reject するため、defense-in-depth として silent skip が阻止される。両層の整合性は `phase-transition-whitelist.sh` の許可エッジ定義を SoT として参照すること。

### Resume re-entry の `phase3_post_plan` 受容

`/rite:resume` でフローを再開した場合、Phase 3 (implementation-plan) は既に完了している可能性がある。その状態で再度 Phase 3 を通過させると plan が重複生成される。これを避けるため、Phase 3 pre-condition は `phase3_post_plan` を **追加 accept value** として受け入れる (normal first-entry では `phase2_post_work_memory` のみ accept、resume 経路でのみ `phase3_post_plan` が現れる)。 `phase3_post_plan → phase3_plan` の whitelist エッジが対応する retry edge を許可する。

Phase 5.5.1 / 5.6 は resume re-entry でも skip 不可なので追加 accept は不要。

## Enforcement note (LLM 向け)

bash の `exit 1` は **shell process を終わらせるだけで、Claude Code の LLM 駆動 turn を halt しない**。Pre-condition check が ERROR を出した場合、 **LLM は stderr の `ERROR:` / `ACTION:` 行を認識して、指示された missing phase に return する責務**を負う。silent に「次の Pre-write block を実行する」経路は禁止。

各 pre-condition block の bash literal は以下の 3 種類の echo を必ず emit する:

1. `ERROR: {Phase X} pre-condition failed. .phase=$curr (expected: {expected_marker})` — diagnostic
2. `ACTION: Return to the missing {Phase Y} step and execute its Pre-write + main procedure + Mandatory After before entering {Phase X}.` — recovery instruction
3. `⚠️ LLM MUST NOT proceed to {Phase X} Pre-write below. Re-invoke the missing phase first.` — anti-silent-continue guard

これら 3 行は **LLM 向け enforcement** であり、シェル制御フローではなく LLM の routing 判断を駆動する。

## 5 site canonical (capture pattern 共有)

Pre-condition check (3 site) に加えて、以下 2 site も同一の `if val=$(cmd); then :; else rc=$?; fi` capture pattern を共有する (start.md 内合計 **5 site** が `state-read.sh` capture 共通形式)。 Form A (4 site: Pre-condition 3 + Phase 5.7 parent close) と Form B (1 site: Phase 5.5.2 metrics) の使い分けは上記 [Canonical capture pattern (2 forms)](#canonical-capture-pattern-2-forms) を参照:

| Site | Field | 用途 |
|------|-------|------|
| Phase 3 pre-condition | `phase` | Phase 2 完了確認 |
| Phase 5.5.1 pre-condition | `phase` | Phase 5.5 完了確認 |
| Phase 5.6 pre-condition | `phase` | Phase 5.5.2 完了確認 |
| Phase 5.5.2 Metrics Step 1 | `implementation_round` | `plan_deviation_count` 算出 (non-numeric は 0 降格、空文字列は METRICS_SKIPPED sentinel emit) |
| Phase 5.7 parent close | `parent_issue_number` | parent Issue の auto-close 判定 (non-numeric は 0 降格 = "no parent" 扱い) |

Pre-condition (phase / parent_issue_number) は **複数行 form (Form A)**、metrics step (implementation_round) は **inline 1 行 form (Form B)** を使う。 numeric type validation (非数値 → 0 降格) は metrics / parent_issue_number 等の数値 field で同型対応する: writer / reader / resume の 3 layer 対称化 doctrine (詳細は `implement.md` / `pr/review.md` / `resume.md` の同 pattern site を参照)。

## アンチパターン

1. **直接 `jq` で legacy state file を読む**: `cat .rite/flow-state.json | jq -r .phase` 形式は禁止。`state-read.sh` 経由のみ許可。
2. **「!」 反転で capture**: `if ! val=$(cmd); then rc=$?; fi` は `rc` に常に 0 が入る (bang inversion を pipeline 全体に適用するため)。
3. **`.previous_phase` を expected と比較**: 1 hop 前を見るため normal entry で毎回 fail。
4. **silent 0 降格**: `state-read.sh` 起動失敗時に `val=0` 等で fallback すると、`implementation_round=0` が「乖離なし」と誤分類される (silent partial corruption)。空文字列 `val=""` を保持し、METRICS_SKIPPED sentinel を別途 emit して下流 step を skip させる。
5. **form の混同**: Pre-condition (`^if .*then$` で複数行 form を expect) を inline 1 行に圧縮すると TC-3 が fail。逆に inline 1 行 form (`if val=...; then :; else rc=$?` で 1 行 canonical を expect) を複数行に展開すると TC-6 が fail。site ごとの canonical form を保つこと。

## 関連

- [`flow-state-scaffolding.md`](./flow-state-scaffolding.md) — Pre-write + Mandatory After 契約 SoT
- `plugins/rite/hooks/state-read.sh` — per-session flow-state 読み出し (legacy フォールバック含む)
- `plugins/rite/hooks/_resolve-flow-state-path.sh` — per-session vs legacy path 解決ロジック
- `plugins/rite/hooks/flow-state-update.sh` — `create` mode の `.previous_phase` シフト実装
- `plugins/rite/hooks/tests/caller-markdown-block.test.sh` — TC-6 で 1 行 capture pattern を grep pin
- `plugins/rite/commands/issue/start.md` Phase 3 / 5.5.1 / 5.6 — 3 site の caller
