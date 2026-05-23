# Pre-condition Gate — `flow-state.sh` fail-fast Pattern SoT (reduced scope)

> **変更点**: 旧 sub-skill chain (start-execute / start-publish / start-finalize) と
> それに付随する 5 site の pre-condition gate (Phase 3 / 5.5.1 / 5.6 / 5.5.2 metrics / 5.7
> parent close) は flat workflow への統合に伴い退役。flat workflow `start.md` の各ステップは
> sub-skill delegation を経由せず単一フローで連結されているため、 **「直前 phase が完了
> していない場合に silent skip する」リスクが構造的に消失** し、pre-condition gate も不要
> となった。
>
> 本 reference は **flat workflow 外部 (`commands/issue/implement.md`, `commands/pr/review.md`,
> `commands/resume.md`) で残存する `flow-state.sh` capture pattern** のみを SoT として残す。

## `flow-state.sh` を使う理由 (per-session vs legacy state file)

`flow_state.schema_version=2` 以降、active state は per-session file
(`.rite/sessions/{session_id}.flow-state`) に書き込まれる。一方、legacy state file
(`.rite/flow-state.json`) は schema_version=1 互換のため残置されており、別 session の残骸が
混在する可能性がある。

```
.rite/
├── flow-state.json ← legacy snapshot (互換用、他 session の residue を含む)
└── sessions/
 └── {session_id}.flow-state ← 現 session 固有 state (authoritative)
```

`flow-state.sh` は per-session file を優先解決し、存在しない場合のみ legacy にフォールバックする。
直接 `cat .rite/flow-state.json | jq -r .phase` のような形で legacy を読むと別 session の
state が leak するため、 **必ず `flow-state.sh` 経由で読むこと**。

## Canonical capture pattern (1 form)

`flow-state.sh` 起動失敗と値取得を区別するため、以下の if/else 形式を使う。複数行 form を canonical とする:

```bash
if val=$(bash {plugin_root}/hooks/flow-state.sh get --field <field> --default "<default>"); then
 :
else
 rc=$?
 echo "WARNING: flow-state.sh failed (rc=$rc) for --field <field>" >&2
 echo "[CONTEXT] STATE_READ_FAILED=1; phase=<site_phase>; rc=$rc" >&2
 echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:resume で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2
 val=""
fi
```

> **NG パターン**: `if ! val=$(...); then rc=$?; ... fi` は bash 仕様上、bang 演算子が pipeline 全体を反転するため `rc` には常に 0 が入る。 helper 起動失敗 (flow-state.sh の exit 非 0) と pre-condition 失敗 (flow-state.sh は exit 0 で値を返したが `val` が期待値と不一致) を区別できなくなる。 必ず `if cmd; then :; else rc=$?; fi` 形式を使うこと。

## 適用箇所 (現在の生存 site)

| Site | 所在ファイル | Field | 用途 |
|------|-------------|-------|------|
| Phase 5.1.2 parent_issue_number | `commands/issue/implement.md` | `parent_issue_number` | child Issue 作業時の親 Issue 進捗更新判定 |
| Phase 5.3.8 loop_count | `commands/pr/review.md` | `loop_count` | finding attribution の review loop count 判定 |
| Phase 2.1 parent_issue_number_raw | `commands/resume.md` | `parent_issue_number` | resume 時の親 Issue display 整形 |

(旧 5 site canonical のうち 4 site は start-finalize.md / 旧 start.md Phase 3 削除に伴い消失。新 start.md では「ステップ N」体系に再構成されており、旧 Phase 3 番号には対応しない)

## 関連

- [`flow-state-scaffolding.md`](./flow-state-scaffolding.md) — Pre-write 契約 SoT
- `plugins/rite/hooks/flow-state.sh` — per-session flow-state 読み出し (legacy フォールバック含む)
- `plugins/rite/hooks/_resolve-flow-state-path.sh` — per-session vs legacy path 解決ロジック
