# Flow State Scaffolding — Pre-write 契約 SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` ワークフローにおける **`flow-state.sh set` の Pre-write 契約**の SoT である。`start.md` の各ステップ冒頭 Pre-write block は本ファイルへ semantic 参照する。
>
> **変更点**: 旧 sub-skill chain (`parent-routing` / `child-issue-selection` / `branch-setup` / `work-memory-init` / `implementation-plan` の Defense-in-Depth 1 回目書き込み + orchestrator の 2 回目 atomic 書き込み) は retire。flat workflow では各ステップが Pre-write 1 回のみを実行する。

## 5 引数 canonical literal

`flow-state.sh set` 呼び出しは **必ず以下の 5 引数**を含む:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
 --phase "{phase_name}" \
 --issue {issue_number} \
 --branch "{branch_name}" \
 --pr {pr_number} \
 --next "{next_action_hint}"
```

| 引数 | 型 | 意味 |
|------|----|----|
| `--phase` | string | 現 phase 名 (例: `branch`, `plan`, `implement`)。`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の phase→step routing で使われる |
| `--issue` | int | 対象 Issue 番号。session 識別子の一部 |
| `--branch` | string | 作業ブランチ名。ステップ 2 前は空文字列 `""` (まだブランチ未作成のため) |
| `--pr` | int | PR 番号。ステップ 6 前は `0` (まだ PR 未作成のため) |
| `--next` | string | 次行動の natural language hint。`/rite:resume` が LLM に渡す continuation 指示 |

## Phase-boundary write の役割

各ステップ末尾の write block は、**当該ステップの完了直後**（= 次ステップ開始前）に flow state を更新する。本 SoT では従来「Pre-write」と呼称していたが、実装上は post-step / phase-boundary write が正確な記述。目的:

1. **`/rite:resume` の復帰経路保証**: コンテキスト消失 / セッション中断時、書き込まれた `phase` / `issue` / `branch` / `pr` / `next` フィールドを `/rite:resume` が読み取り、`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) で対応する step に復帰する。
2. **next フィールドによる継続指示**: `next` 文字列は「中断時の次行動」を natural language で記述し、LLM が `/rite:resume` 経由で復帰した際の routing hint として機能する。

## patch mode の例外 (Workflow Termination の 1 site)

`start.md` のステップ 8 終端 1 site のみ `flow-state.sh set` を使う。terminal state (`completed` + `active false`) を書き込み、workflow 終了をマークする:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
 --phase completed --active false --next "none" \
 --if-exists --preserve-error-count
```

`create` mode は新規 phase marker 専用で、`previous_phase` をシフトする。terminal state は phase progression ではないため preserving operation の `patch` を使う。`--if-exists` で state file 不在時の no-op、`--preserve-error-count` で過去 review-fix loop の error count を保持する。

## 適用箇所 (start.md flat workflow)

| Step | Phase 名 | Phase-boundary write 位置 (実 start.md 行) |
|------|---------|--------------------------------------------|
| 1 | `init` | ステップ 1.5 |
| 2 | `branch` | ステップ 2.7 |
| 3 | `plan` | ステップ 3.7 |
| 4 | `implement` | ステップ 4.5 |
| 5 | `lint` | ステップ 5.2 |
| 6 | `pr` | ステップ 6.3 |
| 7.1 | `review` | ステップ 7.4 |
| 7.2 | `fix` | ステップ 7.4 |
| 8 | `completed` (patch) | ステップ 8.7 |

(step 名 / phase 名は `commands/issue/start.md` を参照。`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) が phase → step の正規 mapping)

> **位置のセマンティクス**: 表の write 位置は「当該 phase 名を `create` mode で書き込む sub-step」を指し、その実行時点ではすでに当該 phase の作業（lint 実行 / PR 作成 / review 実行など）が完了している。`/rite:resume` から復帰する際、書き込まれた phase は **その次のステップ**（`resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の Resume action 行）への routing キーとして使われる。

## アンチパターン

1. **5 引数のうちどれかを省略する**: 例えばステップ 2 前で `--branch ""` を省略すると state file の `branch` フィールドが未定義になり、`/rite:resume` の routing が失敗する
2. **terminal state を `create` で書く**: `create` は `previous_phase` シフトを伴うので、`completed` を `create` で書くと過去 phase 履歴が消える。必ず `patch` を使う

## 関連

- [`pre-condition-gate.md`](./pre-condition-gate.md) — pre-condition の `flow-state.sh` fail-fast pattern
- `plugins/rite/hooks/flow-state.sh` — `create` / `patch` / `increment` modes の実装
- `plugins/rite/hooks/phase-transition-whitelist.sh` — 遷移許可定義 (flat phase 群を反映)
- `plugins/rite/hooks/flow-state.sh` — per-session flow-state 読み出し
- `plugins/rite/commands/resume.md` Phase 5.3 — Phase enum → Step mapping (SoT)
- [Sub-skill Return Auto-Continuation Contract (Retired)](../../../skills/rite-workflow/references/sub-skill-return-protocol.md) — retirement note
