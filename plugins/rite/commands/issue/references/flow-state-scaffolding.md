# Flow State Scaffolding — Pre-write + Mandatory After 契約 SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` ワークフローにおける **`flow-state-update.sh create` の Pre-write + Mandatory After 契約** の SoT である。`start.md` 内の各 phase Pre-write block と Mandatory After section は本ファイルへ semantic 参照する。サブスキル (`parent-routing.md` / `child-issue-selection.md` / `branch-setup.md` / `work-memory-init.md` / `implementation-plan.md` の Defense-in-Depth 1 回目書き込み) と orchestrator (`start.md` の 2 回目 atomic 書き込み) の二段構造、5 引数 canonical literal、second-write rationale を 1 ファイルに閉じ込めることで、本体の認知負荷を下げる。
>
> **抽出経緯**: `start.md` 2303 行のうち約 17 箇所の Mandatory After section が「`Do **NOT** stop after ... returns.` + `The sub-skill has already updated to ... via its Defense-in-Depth section; this second write ensures stop-guard routes to the correct next branch:` + 5 引数 bash literal + `**Step 2**: → Proceed to ...`」という同型構造を散文と bash literal で 17 回繰り返していた。これを Issue #899 (PR C — #896 親 Issue) で 2 文 contract phrase に標準化し、本 reference に SoT として集約する。

## 2 文 contract phrase（標準化形式）

すべての Mandatory After section の rationale 散文は以下の 2 文に統一する:

```
> See [Flow State Scaffolding](./references/flow-state-scaffolding.md).
> MUST execute in the SAME response turn. DO NOT stop, do NOT re-invoke.
```

- 第 1 文: 本 reference への semantic anchor。LLM は本ファイルを読み「なぜ second write が必要か」「なぜ stop してはいけないか」を理解できる。
- 第 2 文: 不変条件の宣言。`MUST execute in the SAME response turn` は「sub-skill return 直後に同一 turn 内で続行」を、`DO NOT stop, do NOT re-invoke` は「停止せず、また同じ sub-skill を再起動しない」を意味する。

bash literal (5 引数 `flow-state-update.sh create` invocation) は **本体に残す**。これは runtime contract であり references 集約の対象外。

## Pre-write の役割

各 phase の Pre-write block は、**sub-skill 起動前** に flow state を更新する。目的:

1. **stop-guard の resume 経路保証**: コンテキスト消失 / セッション中断時、`flow-state-update.sh create` で書き込まれた `phase` / `issue` / `branch` / `pr` / `next` フィールドを `/rite:resume` が読み取り、適切な phase に復帰する。
2. **whitelist 整合**: `phase-transition-whitelist.sh` は隣接 phase 間の遷移のみを許可するため、Pre-write で正しい phase を記録しないと whitelist が遷移を reject し永久 block する。
3. **next フィールドによる継続指示**: `next` 文字列は「sub-skill 返却後の次行動」を natural language で記述し、LLM が `/rite:resume` 経由で復帰した際の routing hint として機能する。

## Mandatory After の役割（second write）

各 sub-skill は Defense-in-Depth として自身の Phase 末尾で `flow-state-update.sh create --phase <skill_name>_post_*` を 1 回目書き込みする。orchestrator (`start.md`) はその後 **同一 turn 内**で `Mandatory After` block の **2 回目 atomic 書き込み**を実行する。

### なぜ 2 回必要か

| 1 回目 (sub-skill 内) | 2 回目 (orchestrator) |
|-----------------------|----------------------|
| sub-skill 自身の完了マーカ | orchestrator が「次の phase に進む」意思表示 |
| sub-skill 単独で停止しても resume 可能にする safety net | 隣接 phase の whitelist 遷移を 1 hop で進める |
| Defense-in-Depth (sub-skill が orchestrator の制御外で stop されても state 整合性を保つ) | stop-guard が「次の phase」を判定する根拠 |
| `--next` は「sub-skill 単体の return まで」 | `--next` は「次の phase の continuation hint」 |

両者が無いと、sub-skill が return 直後に stop された場合、`previous_phase = pre-write 時の phase`, `phase = sub-skill 内 1 回目 write の phase` のままで、whitelist の許可エッジが「pre-write phase → post phase」ではなく「sub-skill 1 回目 phase → 次の phase」を期待する経路で routing できず block する。

## 5 引数 canonical literal

`flow-state-update.sh create` 呼び出しは **必ず以下の 5 引数**を含む:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "{phase_name}" \
  --issue {issue_number} \
  --branch "{branch_name}" \
  --pr {pr_number} \
  --next "{next_action_hint}"
```

| 引数 | 型 | 意味 |
|------|----|----|
| `--phase` | string | 現 phase 名 (例: `phase2_post_branch`)。`phase-transition-whitelist.sh` の許可エッジで使われる |
| `--issue` | int | 対象 Issue 番号。session 識別子の一部 |
| `--branch` | string | 作業ブランチ名。Phase 2.3 前は空文字列 `""` (まだブランチ未作成のため) |
| `--pr` | int | PR 番号。Phase 5.3 前は `0` (まだ PR 未作成のため) |
| `--next` | string | 次行動の natural language hint。stop-guard / resume が LLM に渡す continuation 指示 |

この 5 引数構造は `plugins/rite/hooks/tests/start-md-charter.test.sh` の Symmetry assertion で機械検証されている。1 つでも欠けると test fail。

## stop-guard 通称と実体

> **重要**: `start.md` 本体および本 reference 内で散見される「stop-guard」「stop-guard が flow を resume する」等の表現は **通称** である。`develop` ブランチでは `plugins/rite/hooks/stop-guard.sh` は実体不在となり、機能は **`pre-tool-bash-guard.sh`** (574 行) および `phase-transition-whitelist.sh` (source-only helper) に統合・移管されている。同期更新時はこれらのファイルを編集すること。本体の `stop-guard` 通称言及の整理は後続 PR の射程に委ねる。

歴史的経緯:

- `main` ブランチには旧 `stop-guard.sh` (blob `d26a4e0d`) が残存し、`hooks.json` に Stop hook として登録されている。
- `develop` では Stop hook 経路ごと撤去され、`pre-tool-bash-guard.sh` の `PreToolUse(Bash)` matcher 経由で同等の防御機能を提供する設計に移管。
- `start.md` 内 29 箇所の `stop-guard` 言及は通称として残置されており、PR C では reference 集約と 2 文 contract 標準化を通じて副次的に削減される（完全な置換は後続 PR）。

## 適用箇所（start.md）

PR C 時点で本 reference を参照する Mandatory After section（h3/h4 含む 17 箇所）:

| section | location | sub-skill |
|---------|----------|-----------|
| Mandatory After 1.5 | `rite:issue:parent-routing` 後 | parent-routing.md |
| Mandatory After 1.6 | `rite:issue:child-issue-selection` 後 | child-issue-selection.md |
| Mandatory After 2.3 | `rite:issue:branch-setup` 後 | branch-setup.md |
| Mandatory After 2.4 | Projects Status 更新後 | (inline) |
| Mandatory After 2.5 | Iteration assignment 後 | (inline) |
| Mandatory After 2.6 | `rite:issue:work-memory-init` 後 | work-memory-init.md |
| Mandatory After 3 | `rite:issue:implementation-plan` 後 | implementation-plan.md |
| Mandatory After 5.0 | Stop hook verification 後 | (inline) |
| Mandatory After 5.2 | `rite:lint` 後 | lint.md |
| Mandatory After 5.3 | `rite:pr:create` 後 | pr/create.md |
| Mandatory After 5.4.3 (After Review) | `rite:pr:review` 後 | pr/review.md |
| Mandatory After 5.4.6 (After Fix) | `rite:pr:fix` 後 | pr/fix.md |
| Mandatory After 5.5 / 5.5.0.1 | `rite:pr:ready` 後 | pr/ready.md |
| Mandatory After 5.5.1 | Issue Status In Review 更新後 | (inline) |
| Mandatory After 5.5.2 | Metrics recording 後 | (inline) |
| Mandatory After 5.7.2 | `rite:issue:close` 後（parent close） | issue/close.md |
| Mandatory After 5.7 | Parent completion 全体 | (inline) |

各 section の `**Step 1**` で 5 引数 bash literal を実行し、`**Step 2**` で次 phase への遷移を宣言する。

## アンチパターン

以下は本契約違反であり禁止:

1. **同 turn 内で stop する**: sub-skill return 直後に LLM が turn を終了するパターン。stop-guard が detect して stderr に diagnose を残すが、結果として workflow が中断する。
2. **sub-skill を再起動する**: return 直後に同じ sub-skill を `skill:` 経由で再 invoke。state は 2 重書きされ whitelist が reject する。
3. **second write を skip する**: sub-skill 内 1 回目書き込みだけで次 phase に進むと、whitelist 期待エッジから外れて resume 時に block する。
4. **5 引数のうちどれかを省略する**: 例えば Phase 2.3 前で `--branch ""` を省略すると state file の `branch` フィールドが残り、後続 phase が古い branch を参照するリスクがある。

## 関連

- [`pre-condition-gate.md`](./pre-condition-gate.md) — pre-condition の `state-read.sh` fail-fast pattern
- `plugins/rite/hooks/flow-state-update.sh` — `create` / `patch` / `increment` modes の実装
- `plugins/rite/hooks/phase-transition-whitelist.sh` — 隣接 phase 遷移の許可エッジ定義
- `plugins/rite/hooks/state-read.sh` — per-session flow-state 読み出し
- `plugins/rite/hooks/tests/start-md-charter.test.sh` — Charter assertions (`MUST execute` / `DO NOT stop` 下限、5 引数 Symmetry)
- `plugins/rite/hooks/tests/flow-state-create-symmetry.test.sh` — 5 引数対称性の機械検証 (PR C 新規)
