# `/clear` 毎コマンド運用と session-scoped flow-state の設計不整合 — 調査と方針決定

> **Status**: ✅ 方針決定（調査・設計のみ。実装は後続 Issue に委ねる — Issue #1256）
>
> **本ドキュメントの位置付け**: Issue #1256 の成果物。離散実行する各 rite コマンド（`issue:create` / `pr:open` / `pr:ready` / `pr:merge`）を session-scoped flow-state への依存から切り離す設計の是非・影響範囲・最小修正案を確定する。実装 PR は本 Issue では作成せず、§7 の後続 Issue 分割案へ委ねる。
>
> **関連設計ドキュメント**:
> - [`multi-session-state.md`](./multi-session-state.md) — flow-state を per-session file（`.rite/sessions/{session_id}.flow-state`）にした構造。本ドキュメントの前提。
> - [`session-ownership-flow-state.md`](./session-ownership-flow-state.md) — session_id によるオーナーシップ判定の歴史的経緯。技術的決定事項 #5（`/clear` 後の自インスタンス想定）が本問題の伏線。

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

本リポの通常運用は「コンテキスト圧迫回避のため各 rite コマンド実行前に `/clear` を挟む」である。この運用下では、session-scoped に隔離された flow-state（`.rite/sessions/{session_id}.flow-state`）が各コマンド開始時に**構造的に常に空**となり、flow-state を前提条件チェックに使うコマンドが false-positive の確認プロンプト・警告を出す。

調査の結論を先に述べる:

1. **真の false-positive は `pr:merge` Step 1 の 1 箇所のみ**である。Issue 本文が挙げた 4 コマンドのうち、`pr:ready` / `pr:open` / `issue:create` は設計通りの挙動か flow-state に非依存であり、修正不要。
2. **`pr:merge` Step 1 の flow-state 前提チェックは `gh pr view`（Step 2）と冗長**であり、安全性を一切追加していない。flow-state 不在を正常系として無警告化し、権威ある状態源を `gh pr view` に一本化するのが正しい。
3. **継続ループ系（`pr:iterate` の review↔fix、Stop hook、handoff、sprint e2e、compact recovery、resume）は single-session 前提のまま温存する**。これらは「1 セッション内連続実行」が本質であり、session-scoped flow-state が正しく機能する領域である。切り離すのは離散コマンドの権威判定だけ。

<!-- Section ID: SPEC-ROOT-CAUSE -->
## 問題の構造（root cause）

### なぜ flow-state は離散コマンド間で常に空になるか

flow-state は並行セッション対応のため per-session file 設計（[`multi-session-state.md`](./multi-session-state.md) PR #677, Option A）を採る。ファイル名が session_id（UUID）であり、各 hook / コマンドは自セッションの state file のみを読み書きする。

`/clear` をまたぐと、以下の機構により flow-state は新セッションから見て不在になる:

| # | 機構 | 該当箇所 |
|---|------|---------|
| 1 | `/clear` で新しい session_id が払い出され、`.rite-session-id` に上書き保存される | `hooks/session-start.sh` L63（`session_id` を `.rite-session-id` へ保存） |
| 2 | `source=clear` で `_reset_active_state`（`active=false`）が走る = rite は **`/clear` をワークフロー継続の終端**として設計している | `hooks/session-start.sh` L428-431（`_reset_active_state` 定義は L353） |
| 3 | 新セッションの state file（`.rite/sessions/{new_sid}.flow-state`）は未作成。`flow-state.sh get --default ""` は file 不在を `--default` に縮退し、`possible stale .rite-session-id` WARNING を出す | `hooks/flow-state.sh` cmd_get L281 |

結果として、**flow-state の writer（`pr:open`）と reader（`pr:ready` / `pr:merge`）は `/clear` をまたぐと別セッションになる**。session-scoped flow-state は離散コマンド間では構造的に死んだチャネルであり、reader 側は常に空を読む。

> **本リポでの実証**: PR #1255 を `/rite:pr:ready` → `/rite:pr:merge` と別ターンで実行した際に、`pr:merge` Step 1 が「Ready 化されていない可能性があります」確認と `possible stale .rite-session-id` WARNING を出した。マージ自体は `gh pr view` が `MERGEABLE`/`CLEAN` だったため安全だったが、警告 UX が「壊れている」ように見えた。本ドキュメント作成セッションでも、`flow-state.sh get` 実行時に同 WARNING が再現している（ドッグフーディングによる自己実証）。

### これは設計通りであり、`/clear` 越しの永続化は非推奨

機構 2 が示す通り、`/clear` を継続の終端として扱うのは **意図された設計**。flow-state を `/clear` 越しに持続させる案は **Out of Scope**。理由:

- Stop hook（`stop-loop-continuation.sh`）による継続再注入は**コンテキスト連続が前提**であり、`/clear` で文脈が消えた後に flow-state だけ残しても継続再開はできない。
- per-session 隔離（並行セッションの state 独立性, [`multi-session-state.md`](./multi-session-state.md) AC-1）を壊す。

したがって解決策は「flow-state を永続化する」ではなく「**離散コマンドの権威判定を永続 SoT（`gh` 状態 / work-memory）へ寄せる**」方向に限定する。

<!-- Section ID: SPEC-AC1 -->
## AC-1: 離散コマンドの flow-state 依存 全件洗い出し

「離散コマンド」= 各実行前に `/clear` を挟む単発実行が想定されるコマンド。各コマンドの flow-state 依存を全件列挙し、`/clear` 毎運用での false-positive リスクを分類する。

### サマリ表

| コマンド | 依存箇所 | モード / field | 用途 | `/clear` 毎運用での挙動 | 判定 |
|---|---|---|---|---|---|
| **pr:merge** | `commands/pr/merge.md` L39-41 → 判定 L46-48 | `get` phase / pr_number / branch | Ready 化確認の警告判定 | `phase=""` → `MERGE_STATE_PHASE != "ready"` true → **毎回「Ready 化されていない可能性があります」AskUserQuestion** | ❌ **真の false-positive（要修正）** |
| pr:ready | `commands/pr/ready.md` L210 / L224 → 判定 L244 | `get` phase / active | e2e flow 検出（confirmation スキップ条件） | flow-state 不在 → `in_e2e_flow=false` → standalone confirmation 表示。`/clear` 毎なら実際 standalone なので**設計通り（fail-safe）** | ✅ 仕様通り（修正不要） |
| pr:open | `commands/pr/open.md` Step 0 L39-44 | `get` phase / active / issue / pr | Resume Dispatch 判定 | 全 field 空 → `RESUME_DISPATCH=0`（新規セッション）= 正しい判定。実害なし | ✅ 仕様通り（修正不要） |
| issue:create | （なし） | — | flow-state に**一切触れない**（#1184 設計: 親セッション state 誤上書き防止） | 無関係 | ✅ 該当なし |

### writer（状態を作る側 — false-positive 源ではない）

| コマンド | 箇所 | モード | 備考 |
|---|---|---|---|
| pr:open | merge.md と別の `set`（Step 1/2/3/6） | `set`（`--if-exists` なし、無条件） | flow-state を**新規作成する唯一の writer**。ただし書いた state は次の `/clear` で reader から不可視 |
| pr:ready | ready.md L307-311 / L441-445 | `set --if-exists` | file 不在なら skip（`/clear` 毎運用では常に skip）= 無害 |

### 権威ある状態源（再構築の材料）

各離散コマンドは flow-state 以外に「常に取得可能な権威状態源」を既に参照している。これが再構築の材料になる。

| コマンド | 権威状態源 | 箇所 |
|---|---|---|
| pr:merge | `gh pr view --json mergeable,mergeStateStatus,isDraft` | merge.md Step 2 L54-64 |
| pr:ready | `gh pr view --json number,title,state,isDraft,...` / `.rite-work-memory/issue-{n}.md` | ready.md L156 / L57 |
| pr:open | `gh issue view {issue}` / `gh pr create` sentinel `[pr:created:N]` | open.md Step 1.1 / Step 6.2 |
| issue:create | `gh issue list --search`（重複検出） / `rite-config.yml` | create.md Step 2.1 |

<!-- Section ID: SPEC-AC2 -->
## AC-2: 永続 SoT からの再構築 設計案と影響範囲

唯一の修正対象 `pr:merge` Step 1 について、永続 SoT から状態を再構築する設計案を示す。

### 現状（問題）

```
Step 1: flow-state.sh get phase/pr_number/branch
        → phase != "ready" OR pr_number != arg なら
          AskUserQuestion「Ready 化されていない可能性があります。それでも merge しますか？」
Step 2: gh pr view --json mergeable,mergeStateStatus,isDraft
        → isDraft なら [merge:not-ready] + ready 案内 + 終了
        → mergeable != MERGEABLE なら [merge:not-ready]
        → MERGEABLE なら Step 3 (merge)
```

Step 1 の警告は flow-state 由来だが、**Step 2 が既に `isDraft` を権威判定している**。draft PR は Step 2 で確実に弾かれるため、Step 1 の「Ready 化されていない」警告は安全性を一切追加せず、`/clear` 毎運用では毎回 false-positive として発火するだけ。

### 設計案（採択）

| 項目 | 変更内容 |
|---|---|
| Step 1 の flow-state 前提チェック（phase/pr_number 警告） | **削除**。flow-state 不在を正常系として扱い、警告を出さない |
| Ready 状態の権威判定 | Step 2 の `gh pr view --json isDraft` に一本化（`isDraft == true` → `[merge:not-ready]` + `/rite:pr:ready` 案内）。実質的に既存挙動で担保済み |
| 完了通知の `{branch_name}`（merge.md L119） | flow-state の branch ではなく `gh pr view --json headRefName` から取得（flow-state 不在でも空にならない） |
| flow-state（あれば読む） | 任意の continuation hint に格下げ。**存在すれば** 同一セッション内 hint として利用可、不在は無警告（離散運用の正常系） |

### 影響範囲・リスク評価

| 観点 | 評価 |
|---|---|
| 安全性 | **不変**。merge 可否は Step 2 の `gh pr view`（isDraft/mergeable/mergeStateStatus）が権威。Step 1 の警告削除で安全性は低下しない（draft は Step 2 で弾かれる） |
| 後方互換 | flow-state がある同一セッション運用でも壊れない（hint として読むだけ、不在を許容） |
| UX | `/clear` 毎運用での false-positive 警告が消える。`possible stale .rite-session-id` WARNING も、Step 1 が flow-state を読まなくなれば該当 callsite からは出なくなる |
| 波及 | merge.md 単独で完結。他コマンド・hook への変更不要 |
| リスク | 低。唯一の留意点は「同一セッション内で `pr:open`→`pr:merge` を `/clear` なしに連続実行し、誤った PR 番号を渡した場合の取り違え検知」が弱まること。ただしこれも `gh pr view {pr_number}` が対象 PR の実状態を引くため、存在しない/別状態の PR は Step 2 で検知される |

<!-- Section ID: SPEC-AC3 -->
## AC-3: 触らない範囲と切り離す範囲の線引き

設計の肝は「継続ループ系（single-session 前提）」と「離散コマンド（永続 SoT 寄せ）」の区別である。

### 切り離す範囲（永続 SoT へ寄せる）

- **`pr:merge` Step 1 のみ**。flow-state 前提チェックを `gh pr view` 主体へ。

### 触らない範囲（single-session 前提のまま温存）

| 対象 | 理由 |
|---|---|
| `pr:iterate` の review↔fix ループ（iterate.md L49-50 の get、L63-64/L91-92 の set --phase review/fix。`--handoff` は review.md Step 8.0 / fix.md Step 5.1 がセット、機構は iterate.md L164-170 に記載） | 1 セッション内連続実行が本質。`/clear` を挟むとループ自体が break する設計 |
| Stop hook `stop-loop-continuation.sh` + `handoff` field | コンテキスト連続前提の one-shot 継続マーカー（#1168 / #1176 / #1245 WIKICHAIN cleanup チェーン）。`/clear` 越しには機能し得ない |
| `pr:review` / `pr:fix`（handoff set/consume） | review↔fix ループの構成要素。同上 |
| sprint e2e（`sprint/execute.md` 経由の orchestrator flow） | orchestrator が 1 セッション内で sub-skill を駆動。flow-state が正しく機能する領域 |
| compact recovery（pre/post-compact hook） | 同一セッション内の context 復元。session-scoped が正しい |
| `resume.md`（flow-state を cross-check SoT として読む） | 中断再開ハーネスそのもの。flow-state が一次情報 |
| `pr:open` Step 0 の resume dispatch / 内部 step の writer | `pr:open` は単一 invocation 内で init→pr まで進む。内部の flow-state は同一セッション内で正しく機能する |
| `pr:ready` Phase 2.1 の e2e 検出 | flow-state 不在 → standalone confirmation は**設計通りの fail-safe**。`/clear` 毎運用では実際に standalone なので正しい挙動。**現状維持** |
| `issue:create` | 既に flow-state 非依存。変更不要 |

### 線引きの原則

> flow-state は「**同一セッション内の continuation hint**」として再定義する。離散コマンドが `/clear` をまたいで参照する「権威ある状態」は flow-state ではなく、`gh pr view`（isDraft / mergeable / mergeStateStatus）と Projects Status、`.rite-work-memory/issue-{n}.md` に置く。

<!-- Section ID: SPEC-AC4 -->
## AC-4: pr:merge Step 1 最小修正案の是非（結論）

**結論: 採択する。**

`pr:merge` Step 1 の flow-state 前提チェックを「`gh pr view` 主体・flow-state 不在は正常系として無警告」へ変更する。

| 判断軸 | 結論 |
|---|---|
| 安全性は保たれるか | **保たれる**。merge 可否の権威判定は Step 2 の `gh pr view`（isDraft/mergeable）。Step 1 の警告判定は `phase != "ready"` **OR** `pr_number != {arg}`（merge.md L48）の OR だが、両条件とも Step 2 で代替される: (a) **phase 条件**は Step 2 の `isDraft` が draft PR を確実に弾くため冗長、(b) **pr_number 取り違え条件**は Step 2 が `gh pr view {pr_number}`（引数の PR 番号を直接照会）で対象 PR の実状態を引くため、存在しない/別状態の PR は Step 2 で検知される。よって Step 1 の警告削除で安全性は低下しない |
| false-positive は解消するか | **解消する**。`/clear` 毎運用で毎回出ていた「Ready 化されていない可能性」確認と `possible stale .rite-session-id` WARNING（Step 1 callsite 由来）が消える |
| 既存仕様との整合 | 整合。merge.md の設計判断「責務は merge のみ」「flow-state は触らない（phase=ready のまま）」と矛盾しない。むしろ flow-state 依存を減らす方向で一貫 |
| 最小性 | merge.md 単独で完結。新規設定キー・hook・抽象を追加しない |

<!-- Section ID: SPEC-AC5 -->
## AC-5: 決定事項と後続実装 Issue 分割案

### 決定事項

1. 離散コマンドの権威状態源を **`gh pr view` / Projects Status / work-memory** に置く。flow-state は「**同一セッション内 continuation hint**」と再定義する。
2. **修正対象は `pr:merge` Step 1 のみ**。`pr:ready` / `pr:open` / `issue:create` は現状維持（設計通り or 非依存）。過剰修正を明示的に避ける。
3. flow-state を `/clear` 越しに持続させる案は **不採用**（継続ループ系のコンテキスト連続前提を壊し、per-session 隔離に反するため）。

### 後続実装 Issue 分割案

| # | 種別 | 内容 | 優先度 | 受入基準（骨子） |
|---|---|---|---|---|
| A | `refactor` | `pr:merge` Step 1 を `gh pr view` 主体へ。flow-state 前提チェック（phase/pr_number 警告）を削除し、不在を正常系として無警告化。完了通知の branch は `gh pr view --json headRefName` から取得 | **高（必須）** | `/clear` 毎運用で merge 時に false-positive 警告が出ない / draft PR は引き続き `[merge:not-ready]` で弾かれる / 既存の同一セッション運用が壊れない |
| B | `docs` | `docs/SPEC.md` の flow-state 記述に「離散コマンドは永続 SoT を権威とし、flow-state は同一セッション内 continuation hint」という再定義を明記。本ドキュメントへの相互参照を追加 | 中（任意） | SPEC に再定義が記載される / 本設計ドキュメントが参照される |

> **ready.md は対象外**: Phase 2.1 の confirmation は `/clear` 毎運用でも「standalone での misuse safety net」として設計通りに機能するため、Issue 化しない。過剰修正の予防として本ドキュメントに明記する。

<!-- Section ID: SPEC-RELATED -->
## 関連

- 親問題系列: Session Ownership #173 / #206 / #781 / #133（`/clear` を継続終端とする設計の出典）
- 前提設計: [`multi-session-state.md`](./multi-session-state.md)（per-session file, PR #677）、[`session-ownership-flow-state.md`](./session-ownership-flow-state.md)
- continuation 機構: handoff #1168 / #1176 / #1245、Stop hook `stop-loop-continuation.sh`
- 実証: PR #1255 の `pr:ready` → `pr:merge` 別ターン実行で観測
