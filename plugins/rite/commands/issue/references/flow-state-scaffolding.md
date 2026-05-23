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

## Terminal state write の例外 (Workflow Termination の 1 site)

flat workflow では全ステップが同一の `flow-state.sh set` を呼ぶ (v3 では mode 区別はなく、merge semantics により未指定フィールドは既存値を保持する)。`start.md` のステップ 8 終端 1 site のみ、上記 5 引数の標準形ではなく terminal 専用の引数セットで `set` を呼び、terminal state (`completed` + `active false`) を書き込んで workflow 終了をマークする:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
 --phase completed --active false --next "none" \
 --if-exists --preserve-error-count
```

この呼び出しは phase progression ではなく terminal marker なので、`--issue` / `--branch` / `--pr` を指定せず merge semantics で既存値を保持する。`--active false` で workflow 終了をマーク、`--if-exists` で state file 不在時は no-op (idempotent)、`--preserve-error-count` で過去 review-fix loop の `error_count` を保持する (`--preserve-error-count` を付けない通常の `set` は `error_count` を 0 にリセットする)。

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
| 8 | `completed` (terminal) | ステップ 8.6 |

(step 名 / phase 名は `commands/issue/start.md` を参照。`commands/resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) が phase → step の正規 mapping)

> **位置のセマンティクス**: 表の write 位置は「当該 phase 名を `flow-state.sh set` で書き込む sub-step」を指し、その実行時点ではすでに当該 phase の作業（lint 実行 / PR 作成 / review 実行など）が完了している。`/rite:resume` から復帰する際、書き込まれた phase は **その次のステップ**（`resume.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の Resume action 行）への routing キーとして使われる。

## アンチパターン

1. **5 引数のうちどれかを省略する**: 例えばステップ 2 前で `--branch ""` を省略すると state file の `branch` フィールドが未定義になり、`/rite:resume` の routing が失敗する
2. **terminal state を 5 引数標準形で書く**: ステップ 8 の `completed` を per-step と同じ 5 引数形 (`--issue` / `--branch` / `--pr` を明示) で書くと、`--preserve-error-count` が付かず過去 review-fix loop の `error_count` がリセットされる。terminal write は `--active false --if-exists --preserve-error-count` を使う

## 関連

- [`pre-condition-gate.md`](./pre-condition-gate.md) — pre-condition の `flow-state.sh` fail-fast pattern
- `plugins/rite/hooks/flow-state.sh` — `set` / `get` / `deactivate` / `migrate` subcommand の実装 (`set` の merge semantics + `--if-exists` / `--preserve-error-count` flag を含む)
- `plugins/rite/hooks/phase-transition-whitelist.sh` — 遷移許可定義 (flat phase 群を反映)
- `plugins/rite/hooks/flow-state.sh` — per-session flow-state 読み出し
- `plugins/rite/commands/resume.md` Phase 5.3 — Phase enum → Step mapping (SoT)
- [Sub-skill Return Auto-Continuation Contract (Retired)](../../../skills/rite-workflow/references/sub-skill-return-protocol.md) — retirement note
