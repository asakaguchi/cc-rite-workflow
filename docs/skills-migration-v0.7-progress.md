# Skills 移行 (v0.7) 作業記録 / Progress Log

> **目的**: コマンド→スキル全面移行 (v0.7) の進捗を記録し、`/clear`・compact 後も再開可能にする作業ログ。
> **このファイル自体は作業用**であり、Phase 6 の後片付けで削除する（または `.gitignore` 対象）。

## 再開のしかた（新セッション向け）

1. 承認済みプラン: `~/.claude/plans/rite-workflow-issue-1616-validated-bubble.md` を読む（SoT）。
2. 本ファイルの「進捗ステータス」「次のアクション」を読む。
3. 作業ブランチ `refactor/skills-migration-v0.7` に居ることを確認（`git branch --show-current`）。

## 鉄則

- **この移行は rite workflow を使わず実装する**（素の Claude Code + 直接編集 + git/gh + 手動 PR）。`/rite:*` に作業を駆動させない。
- **コミット/プッシュはユーザーが指示したときだけ**。編集は随時可。
- v0.7 = 破壊的リリース、現状 solo 利用のため後方互換不要。
- 命名はコロン2段廃止（`/rite:pr:open`→`/rite:open`、create 系のみ `/rite:issue-create` `/rite:pr-create`）。命名表はプラン §1。

## 進捗ステータス

| Phase | 内容 | 状態 |
|---|---|---|
| 0 | 規約・前倒し是正・棚卸し | **規約確定済**（§A–§D 完了。§E は decision 確定・実行のみ Phase 2/4 へ協調委譲） |
| 1 | 検証スパイク（go/no-go ゲート） | **GO（closeout）** — 第1回〜第3回実行済。§A/§C/§D 設計確定。第3回（fresh reload, 2026-06-30）で §D marker 実書込＋`CLAUDE_PLUGIN_ROOT` 解決を確認し全項目 closeout。スパイク成果物は削除済 |
| 2 | PR lifecycle スキル化 | **完了** — 9/9 スキル移行済（merge, run, open, iterate, ready, cleanup, pr-create, fix, review）+ 参照再配置 + review の reviewer プロンプト抽出（light 分解）。完全性ゲート全パス（旧命名0・全リンク解決・hooks/tests 81/81 green）。残務は Phase 3-6（forward-ref 解決 / hook 剪定 / commands 削除）|
| 3 | issue/wiki/meta/top-level スキル化 | 未着手 |
| 4 | グローバル hook 剪定 & 棚卸し | 未着手 |
| 5 | orchestrator/knowledge 統合 | 未着手 |
| 6 | 後片付け & リリース | 未着手 |

## Phase 0 — 完了した編集

- [x] 作業ブランチ `refactor/skills-migration-v0.7` 作成（develop 起点）。
- [x] `plugins/rite/.claude-plugin/plugin.json`: 明示 `skills` 列挙を削除 → default `skills/` scan に委譲（plugins-reference: default scan は常に走り skills フィールドは「追加」だけ＝rite では重複。無挙動変化の簡素化）。
- [x] `plugins/rite/skills/rite-workflow/SKILL.md`: 広域 auto-activation を除去（description を narrow 化＋「Auto-Activation Keywords」節を削除）。→ `/goal` 汚染の即時緩和。

## Phase 0 — 残タスク

- [x] skill-scoped `hooks` frontmatter の正確な書式を確認（公式 /en/hooks で確定。下記「Phase 0 確定事項 §D」）。
- [x] SKILL.md スケルトン + frontmatter/引数ポリシーの雛形を確定（下記「Phase 0 確定事項 §A・§B」）。**プラン §2 の frontmatter ポリシー表に不整合を発見 → §B で是正案**。
- [x] 共有 reference 置き場の確定（下記「Phase 0 確定事項 §C」）。3スキル以上参照は plugin-root 集約、2以下は co-locate、参照0は削除。
- [ ] SessionStart の CRITICAL 出力（`session-start.sh:606-616`）を silent/最小化。**→ 単純 silent 化は不可と判明（下記「Phase 0 確定事項 §E」）。decision は確定、実行は Phase 2/4 と協調。**

## Phase 0 — 確定事項（成果物 / Phase 1+ の SoT）

### §A. SKILL.md スケルトン（全スキル共通の雛形）

各スキル = `plugins/rite/skills/<name>/{SKILL.md, references/, scripts/}`。SKILL.md は **< 500 行の薄い入口**（progressive disclosure）。frontmatter は §B のポリシーで区分ごとに変える。

```markdown
---
name: <name>                          # ディレクトリ名と一致。呼び出しは /rite:<name>
description: |
  <1–2 行。狭く具体的に。汎用トリガ語 (workflow / PR / review / commit /
  branch / next steps) を auto-activation 誘発語として書かない>
  起動: /rite:<name> <args>
argument-hint: "<arg-hint>"            # autocomplete 表示。引数を取るスキルのみ
# ↓ frontmatter の可視性/呼び出し制御は §B の区分表に従う
# disable-model-invocation: true       # leaf user-only のみ
# user-invocable: false                # 純 sub-skill / knowledge のみ
# hooks: ...                           # skill-scoped hook が要るスキルのみ（§D 書式）
---

# <Title>

<1 段落: このスキルの役割。骨格のみ>

## 手順
1. …（骨格。詳細手順・ルール表・テンプレは references/ に逃がす）

## 引数
- `$1` / `$name` / `$ARGUMENTS`: …（`--flag` 等のフラグは本文で `$ARGUMENTS` テキストからパース）

## 詳細リファレンス
- [references/<topic>.md](./references/<topic>.md) — 必要時のみロード
- 共有 reference は `${CLAUDE_PLUGIN_ROOT}/references/<name>.md`（§C）

## 完了シグナル（caller を持つ sub-skill のみ）
- 末尾に `[<name>:returned-to-caller:<payload>]` を **HTML コメント**で emit し、直前に
  `<!-- skill return signal: caller must continue next step -->` を併記（rite-workflow SKILL.md の Sentinel naming policy 準拠）。
- user-visible な最終行は sentinel ではなく人間可読な完了メッセージにする。
```

- パス参照は `{plugin_root}` 手動解決を全廃し `${CLAUDE_SKILL_DIR}`（自スキル内）/ `${CLAUDE_PLUGIN_ROOT}`（plugin-root 共有）へ置換。**両 env の skill Bash injection 時可用性は Phase 1 spike #3 で実証**。

### §B. frontmatter ポリシー（**プラン §2 の是正**）

**発見した不整合**: プラン §2 の表は open / iterate / ready / merge / cleanup を「`disable-model-invocation: true`」グループに入れているが、実コマンドの呼び出しグラフ上これらは **orchestrator から programmatic に呼ばれる**:

| caller | callee（programmatic 呼び出し対象） |
|---|---|
| `run` | open, iterate, ready, merge, cleanup |
| `open` | issue-implement, iterate, lint, init |
| `iterate` | review, fix |
| `ready` | merge, pr-create, review, lint |
| `cleanup` | open, issue-list |

`disable-model-invocation: true` は **Skill ツール経由の programmatic 呼び出しも遮断する**（プラン Context で確定済の公式仕様）。よって **orchestrator から到達可能なスキルには付けられない**。是正後の区分:

| 区分 | 該当スキル | `disable-model-invocation` | `user-invocable` | /goal 非干渉の担保 |
|---|---|---|---|---|
| **leaf user-only**（他スキルから呼ばれない） | issue-create, issue-update, issue-close, issue-edit, wiki-init, wiki-query, wiki-ingest, wiki-lint, skill-suggest, template-reset, getting-started, workflow, investigate, learn, resume | **`true`** | 既定 true | disable-model-invocation + narrow desc |
| **orchestrator 到達 & user-entry 兼用** | open, iterate, ready, merge, cleanup, lint, init, issue-list | **`false`**（付けられない） | 既定 true（ユーザーも起動） | **narrow description のみ**（disable 不可） |
| **純 sub-skill**（user は直接起動しない） | review, fix, pr-create, issue-implement | **`false`** | **`false`**（メニュー非表示） | narrow desc + 非可視 |
| **knowledge content** | コーディング原則 / gh CLI パターン 等 | — | **`false`** | 背景知識 |

- `/rite:resume` は各所に出るが「ユーザーに `/rite:resume` を案内」する文字列であり programmatic 呼び出しではない → leaf 扱い（disable-model-invocation: true 可）。
- **このポリシーは Phase 1 spike #1 の結果に依存**: orchestration が ①Skill ツール invoke なら上表どおり、②sentinel + 継続 hook による LLM 自然継続なら disable-model-invocation:true を広く使える余地が残る。**spike で invocation 経路を確定してから最終 lock する**。

### §C. 共有 reference 置き場（≥3 参照 = plugin-root 集約 / ≤2 = co-locate / 0 = 削除）

`plugins/rite/references/`（plugin-root）現状22ファイルの処遇（参照数は Phase 0 baseline 実測）:

- **plugin-root 集約を維持**（`${CLAUDE_PLUGIN_ROOT}/references/`、≥3 参照）: `common-error-handling`(10), `wiki-patterns`(5), `severity-levels`(5), `projects-integration`(4), `issue-create-with-projects`(4), `gh-cli-patterns`(4), `box-display-width`(4), `review-result-schema`(3), `git-worktree-patterns`(3), `bottleneck-detection`(3)。
- **置換廃止**: `plugin-path-resolution`(26) → `${CLAUDE_SKILL_DIR}` / `${CLAUDE_PLUGIN_ROOT}` 直接参照に置換し**ファイル削除**。
- **co-locate**（≤2 参照 → 所有スキルの `references/` へ移動。残りは個別判断）: `bash-compat-guard`, `epic-detection`, `execution-metrics`, `gh-cli-error-catalog`, `graphql-helpers`, `investigation-protocol` 等。移動時に参照を `${CLAUDE_SKILL_DIR}/references/` 基準へ書換。
- **削除候補（参照0 = デッド）**: `sub-issue-link-handler`, `state-read-evolution`, `session-id-validation-contract`, `gh-cli-commands`, `bash-defensive-patterns`。
- `commands/<group>/references/`（15）は対応スキルへ co-locate（プラン §2）。

### §D. skill-scoped `hooks` frontmatter 書式（公式 /en/hooks で確定）

settings-based hook と同一スキーマを SKILL.md frontmatter に書く。**当該スキルが active な間だけ発火し、終了時に自動クリーンアップ**される（= プランの「Stop continuation を iterate/cleanup に局在化」が仕様上成立）。

```yaml
---
name: iterate
description: |
  ...
hooks:
  Stop:
    - hooks:
        - type: command
          command: "bash ${CLAUDE_PLUGIN_ROOT}/skills/iterate/scripts/stop-loop-continuation.sh"
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash ${CLAUDE_PLUGIN_ROOT}/skills/iterate/scripts/guard.sh"
          timeout: 30
---
```

- **hook command は `bash ${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/<x>.sh` 形式が正準**（`hooks.json` の既存8 hook 全てがこの `bash ${CLAUDE_PLUGIN_ROOT}/...` 形）。**`${CLAUDE_SKILL_DIR}` は hook command では空に展開される**（bash injection 専用・hook 実行環境には来ない）。`bash ` プレフィックスは exec ビット依存を避けるための既存規約 → 踏襲。**第2回スパイクで実証**（下記「Phase 1 — 第2回」）。
- **subagent では `Stop` → `SubagentStop` に自動変換**されるが、**skill では `Stop` のまま**（continuation 用途に必要）。
- `once: true` は **skill frontmatter でのみ有効**（session 内 1 回で除去）。settings / agent では無視。
- 公式上 plugin 固有の制限は明記なし。ただし **「プラグインスキルで実際に発火するか」「ネストした sub-skill 実行中も発火するか」「`${CLAUDE_PLUGIN_ROOT}`/`CLAUDE_CODE_SESSION_ID` が hook+skill Bash で解決するか」は runtime 未確定 → Phase 1 spike #2/#3 で実機実証**。書式は確定、挙動保証は spike 待ち。

### §E. SessionStart CRITICAL 出力の decision（**実行は Phase 2/4 と協調**）

`session-start.sh:606-616` の `CRITICAL: Active rite workflow detected ...` 多行ブロックの実態を精査した結果、**単純 silent 化は不可**:

- **発火条件**: `ACTIVE=true` かつ `SOURCE ∈ {resume, compact}`（startup/clear は手前で `_reset_active_state` が exit）。
- **これは post-compact recovery の本体**: `session-start.test.sh` の TC-012/013/014 が「`source=compact` → CRITICAL にフォールスルーして回復させる」を明示的に検証（コメント: "PostCompact hook now handles recovery; SessionStart(compact) falls through to CRITICAL."）。他にも TC（L243-247）, TC-per-session-detect-A（L866-884）が出力文言に依存。**文言変更は計5+ assert の更新を伴う**。
- v0.7 では継続機構が skill-scoped Stop hook（iterate/cleanup）+ `/rite:resume` に移る予定。session-start 再注入は「中断検出 → /rite:resume 案内」の静かな1行に降格するのが筋だが、**その置換（skill-scoped 継続）が存在する Phase 2 以降でないと、降格＝compact 回復の劣化**になる。
- **確定した decision**: ①Phase 0 では現状維持（gut しない）。②Phase 2 で iterate/cleanup の skill-scoped 継続が入った後、Phase 4 の global hook 剪定で「所有セッション一致時のみの静かな1行 + `${CLAUDE_PLUGIN_ROOT}` 化（脆い `{plugin_root}` 廃止）」へ降格し、TC-012/013/014 を新文言へ更新。③`/goal` 汚染の即時緩和は **既に完了した rite-workflow auto-activation 除去**が主担当（session-start は ACTIVE rite state がある cwd でしか発火しない狭いケース）。

## Phase 1 — 検証スパイク（次のアクション）

未文書化の前提を最小スキルで実機実証してから本格移行に入る:
1. **skill-invokes-skill**: orchestrator が Skill ツールで sub-skill を呼べるか（sub-skill `user-invocable:false` でも）。
2. **skill-scoped hooks** がプラグインスキルで発火するか／ネスト sub-skill 実行中も発火するか。
3. **継続 handoff** + `CLAUDE_CODE_SESSION_ID` / `${CLAUDE_PLUGIN_ROOT}` が skill Bash injection で解決するか。
4. フルロード・`/doctor` budget・`/goal` 非干渉。
- **go** → §2 設計で続行。**no-go** → fallback（継続を orchestrator 本文の Skill 戻り値判定で行う / sub-procedure を別スキルでなく同一スキルの reference 内包）。
- ※ runtime 検証（plugin reload + 起動 + hook 発火観測）は **fresh セッションでの実機確認**が確実。スパイク用スキル成果物を用意してから実行する。

### スパイク成果物（throwaway）

go/no-go 判定後に**3スキルとも削除**する。`.spike-stop-marker.txt`（cwd に生成）も削除。

> **round 2 修正済（第1回の取り違え是正）**: `spike-orch/SKILL.md` は ①`${CLAUDE_SKILL_DIR}` を **bash injection（`!`+backtick`）**で観測（フェンスブロックとの対照）②hook command を `${CLAUDE_PLUGIN_ROOT}/skills/spike-orch/scripts/spike-stop.sh` に変更 ③co-located reference `references/probe.md` の Read テストを追加。`spike-stop.sh` は marker 行に `CLAUDE_PLUGIN_ROOT` を記録するよう更新。第2回を実施する場合は fresh セッションで `/rite:spike-orch` を再実行し、SKILL.md 末尾の報告フォーマットに沿って観測する。

| 成果物 | frontmatter | 検証する前提 |
|---|---|---|
| `plugins/rite/skills/spike-orch/SKILL.md` | user-action + `hooks.Stop`（skill-scoped） | spike #1/#2/#3 の orchestrator。env echo → spike-sub 呼出 → spike-leaf 遮断 → Stop hook 発火 |
| `plugins/rite/skills/spike-orch/scripts/spike-stop.sh` | — | Stop hook 本体。発火時 cwd の `.spike-stop-marker.txt` に1行追記（単体テスト済: JSON パース→追記→exit 0） |
| `plugins/rite/skills/spike-sub/SKILL.md` | `user-invocable:false` + `disable-model-invocation:false` | spike #1: user-invocable:false でも Skill 呼出が通るか |
| `plugins/rite/skills/spike-leaf/SKILL.md` | `disable-model-invocation:true` | §B 前提: programmatic 呼出が遮断されるか |

### 実機検証手順（fresh セッションで坂口さんが実行）

1. **fresh セッション**を開く（plugin reload のため）。`refactor/skills-migration-v0.7` ブランチ上、`rite@rite-marketplace:false` 維持を確認。
2. **フルロード & budget**: `/doctor` で spike-* 3スキルがロードされ description budget が破綻しないか確認（spike #4）。spike-sub が user-invocable:false でメニュー非表示、spike-leaf が disable で description 非掲載になっているかも観測。
3. **orchestrator 起動（round 2）**: `/rite:spike-orch` を実行。SKILL.md 内に round 2 手順が埋め込み済。観測の要点:
   - **#3a（injection・要確認）**: bash injection（`!`+backtick`）で `${CLAUDE_SKILL_DIR}` / `${CLAUDE_PLUGIN_ROOT}` が**解決する**か。第1回はフェンスブロック（Bash tool call）で観測して `<unset>` だった取り違えの是正。
   - **#3b（Bash tool call・対照）**: フェンスブロックでは `<unset>`（第1回の追認）。
   - **#5（reference Read）**: 相対リンク `./references/probe.md` を Read でき sentinel `[spike-probe:read-ok]` が返るか。
   - **#1 / §B（再確認）**: spike-sub 呼出成功・spike-leaf 遮断（第1回で確定済・回帰確認）。
4. **#2（Stop hook 発火・唯一の load-bearing）**: turn 終了後、次の入力で `cat .spike-stop-marker.txt` を確認。round 2 の hook command は `${CLAUDE_PLUGIN_ROOT}/skills/spike-orch/scripts/spike-stop.sh`。marker 行に `CLAUDE_PLUGIN_ROOT=` が**解決値**で入っていれば §D 継続機構が確定する（`<unset>` や not-found なら §D 設計を再検討）。
5. **/goal 非干渉（spike #4）**: 別途 `commit`/`branch`/`review` を含むプロンプトで `/goal` を実行し、spike-* が割り込まないか（narrow description の効果確認）。
6. **判定記録**: 各項目 go/no-go を本ファイル「未解決の決定事項」に追記。**no-go 項目があれば fallback 設計を確定してから Phase 2 へ**。
7. **後片付け**: 判定後に spike-orch/spike-sub/spike-leaf と `.spike-stop-marker.txt` を削除。

## Phase 1 — 実行結果（第1回 2026-06-29 + 公式ドキュメント裏取り）

### 判定: **GO（条件付き）** — Phase 2 へ進める。§A/§C/§D を下記で差し替え、§D の hook path 解決のみ任意の第2回で確定。

| spike | 検証項目 | 実機結果（第1回） | 公式ドキュメント裏取り | 確定判定 |
|---|---|---|---|---|
| #1 | skill-invokes-skill（user-invocable:false 越し） | spike-sub 呼出成功・内部 Bash 実行・sentinel `[spike-sub:returned-to-caller:OK]` 受領 | user-invocable:false は menu 非表示のみ／Skill ツール programmatic 呼出は通る | **GO** |
| §B | disable-model-invocation:true の遮断 | spike-leaf が "cannot be used with Skill tool due to disable-model-invocation" で**遮断** | disable-model-invocation:true は **programmatic 呼出も遮断**と明記 | **前提確定（§B lock）** |
| #2 | skill-scoped Stop hook 発火 | hook は**発火**（"Ran 3 stop hooks"）。ただし command の `${CLAUDE_SKILL_DIR}` 未解決で `/scripts/spike-stop.sh: not found` → marker 未書込 | skill frontmatter `hooks:` は公式サポート・active 中発火・自動 cleanup。hook command では `${CLAUDE_PLUGIN_ROOT}` が利用可 | **発火=GO／command 変数を `${CLAUDE_PLUGIN_ROOT}` に要修正・第2回で marker 書込を確認** |
| #3 | skill Bash の env 解決 | Bash tool call で `CLAUDE_PLUGIN_ROOT`/`CLAUDE_SKILL_DIR`=`<unset>`、`CLAUDE_CODE_SESSION_ID` のみ解決（`CLAUDE_SESSION_ID` 別名も `<unset>`） | `CLAUDE_PLUGIN_ROOT` は **hook 実行時のみ**／Bash tool call では未設定。`CLAUDE_SKILL_DIR` は **bash injection（`!`+backtick`）専用**で Bash tool call には来ない | **判明（仕様どおり）** |
| #4 | フルロード／budget／/goal | spike-orch・spike-sub ロード済（system reminder 一覧に出現）、spike-leaf は disable で非掲載、budget 破綻なし。/goal 非干渉は未テスト | — | おおむね GO |

### 第1回スパイクの設計上の取り違え（重要・第2回で是正）

`#3` の `CLAUDE_SKILL_DIR=<unset>` は **間違ったメカニズムをテストした**結果である。SKILL.md 内の ```` ```bash ```` フェンスブロックは **Bash ツール呼び出し**に変換され env は注入されない。`${CLAUDE_SKILL_DIR}` は **bash injection（`!`+backtick` 構文）専用**で、フェンスブロックでは解決しない（公式仕様）。つまり「`CLAUDE_SKILL_DIR` は実在しない」のではなく「**注入経路が違った**」。同様に `#2` の hook command は `${CLAUDE_SKILL_DIR}`（skill 文脈の injection 専用）ではなく `${CLAUDE_PLUGIN_ROOT}`（hook 実行時に解決）を使うべきだった。

### env / path 解決の確定マトリクス（§A の SoT・プラン §A を全面差し替え）

| 用途 | 解決手段 | env 依存 |
|---|---|---|
| 自スキル内 reference を **Read** | 相対リンク `./references/foo.md`（Claude が skill dir 基準で解決） | **不要**。現 rite-workflow が既にこの方式（line 36/40/44 等） |
| plugin-root 共有 reference を **Read** | 相対リンク `../../references/foo.md` | **不要** |
| plugin ファイルを **Bash tool call** で叩く（preflight 等） | `.rite-plugin-root` inline one-liner（既存機構） | env 不可・**機構を残す** |
| bundled script を **bash injection** で叩き出力注入 | `` !`${CLAUDE_SKILL_DIR}/scripts/foo.sh` `` | injection でのみ可（任意・補助） |
| **skill-frontmatter hook** の command | `bash ${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/foo.sh`（`bash ` 必須・既存 hooks.json 8件と同形） | hook 実行時のみ可 |

### プラン修正（§A/§C/§D を差し替え）

- **§A 差し替え**: 「`{plugin_root}` 手動解決を全廃 → `${CLAUDE_SKILL_DIR}`/`${CLAUDE_PLUGIN_ROOT}` 直接参照」は **Bash tool call では不可**。代わりに上記マトリクスを SoT とする。**Read 参照ロードは相対リンクで env 不要**（移行はむしろ簡素化）。Bash tool call の plugin file アクセスは `.rite-plugin-root` 機構を**維持**。`${CLAUDE_SKILL_DIR}` は bash injection 限定の補助手段。
- **§C 差し替え**: `plugin-path-resolution.md`(26参照) の **削除は撤回**。Bash tool call の path 解決に依然必須。ただし plugin-root references の **Read 参照は相対リンク化**して `${CLAUDE_PLUGIN_ROOT}` 依存を新規に作らない（line 201 の preflight one-liner 等の Bash 用途のみ残す）。
- **§D 差し替え**: skill-scoped hook の command は `${CLAUDE_SKILL_DIR}` ではなく **`bash ${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/foo.sh`** を使う（`bash ` プレフィックス込みが正準・`hooks.json` の既存8 hook 全てと同形）。**発火自体は実証済**。第1回・第2回（cached round-1）の `/scripts/spike-stop.sh: not found` は `${CLAUDE_SKILL_DIR}` が hook command で空展開された結果で、この是正の根拠。`Stop`→`Stop` 維持・`once:true` は skill では**公式未文書** → 当面これらに依存しない設計とし、必要時に第3回で実証する。

### 解決した未解決事項

- **orchestrator→sub-skill の呼び出し経路 = Skill ツール invoke**（sentinel+自然継続ではない）。spike #1 成功 + §B 遮断の両方が invoke 経路を裏付ける。→ §B frontmatter ポリシーを **lock**: orchestrator 到達スキルは `disable-model-invocation:true` 不可、narrow description で /goal 非干渉を担保。
- **`CLAUDE_CODE_SESSION_ID` は skill Bash tool call で解決する**（`CLAUDE_SESSION_ID` 別名は不可）。継続 hook の session 照合・state 参照は `CLAUDE_CODE_SESSION_ID` を正とする。

### 残課題（任意の第2回スパイクで closeout・load-bearing は §D のみ）

第1回は #2 の hook command path（`${CLAUDE_PLUGIN_ROOT}`）と #3 の injection 経路（`${CLAUDE_SKILL_DIR}`）を正しくテストしていない。両者は公式に「動く」とされるが skill 文脈の記述は最小限。**Read 参照ロードは相対リンクで確定済・Bash plugin file は既存機構で確定済**なので、唯一 load-bearing なのは **§D 継続 hook の path 解決**。第2回を実施する場合に備え spike-orch を下記へ修正済（round 2）:
- hook command を `${CLAUDE_PLUGIN_ROOT}/skills/spike-orch/scripts/spike-stop.sh` に変更（marker が実際に書かれ、`CLAUDE_PLUGIN_ROOT` が解決値で入るか）
- `${CLAUDE_SKILL_DIR}` を **bash injection（`!`+backtick`）** で観測（フェンスブロックとの対照）
- co-located reference を相対リンクで **Read** できるか（reference ロードの確定）
- `reviewers` スキルが `disable-model-invocation:true` の整合（review 経路が Skill ツール invoke でないこと）を確認 — agents/ 経由（Task ツール）なら §B と矛盾しない

## Phase 1 — 第2回（2026-06-30）

**前提（重要）**: 第2回 `/rite:spike-orch` は **cached round-1 の SKILL.md が走った**。証拠＝呼び出されたプロンプトが round-1 の4ステップ版（env を Bash フェンスで観測）だったのに、ディスク上の SKILL.md は round-2 の6ステップ版。**プラグインスキルはセッション開始時にキャッシュされ、`/clear` では再ロードされない**ことが実証された（round-2 編集が現セッションに反映されない）。→ **§D の marker 実書込観測は真の fresh セッション（plugin reload）が必須**。

| spike | 検証項目 | 第2回 実機結果 | 判定 |
|---|---|---|---|
| #3 | env（Bash フェンス＝Bash tool call） | `CLAUDE_SKILL_DIR`/`CLAUDE_PLUGIN_ROOT`=`<unset>`、`CLAUDE_CODE_SESSION_ID` のみ解決（第1回の追認） | 仕様どおり |
| #1 | spike-sub（user-invocable:false）呼出 | 成功・内部 Bash 実行・sentinel `[spike-sub:returned-to-caller:OK]` 受領 | **GO**（回帰確認） |
| §B | spike-leaf（disable-model-invocation:true）遮断 | "cannot be used with Skill tool due to disable-model-invocation" で遮断 | 前提維持 |
| #2 | skill-scoped Stop hook 発火 | 発火するが round-1 command `${CLAUDE_SKILL_DIR}/scripts/spike-stop.sh` の `${CLAUDE_SKILL_DIR}` が**空展開** → `/scripts/spike-stop.sh: not found` で **marker 未書込** | **command 是正で対処**（下記） |

### 第2回で確定した是正（適用済）

- **`${CLAUDE_SKILL_DIR}` は hook command で空に展開される**ことを実観測で確定（`/scripts/spike-stop.sh: not found` ＝ 先頭 `/` は空展開の証拠）。→ skill-scoped hook command の正準形は **`bash ${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/<x>.sh`**。`hooks.json` の既存8 hook 全てがこの `bash ${CLAUDE_PLUGIN_ROOT}/...` 形で本番稼働＝`${CLAUDE_PLUGIN_ROOT}` の hook 実行時解決は確立済み。
- **適用済の編集**: `spike-orch/SKILL.md` の hook command を `bash ${CLAUDE_PLUGIN_ROOT}/skills/spike-orch/scripts/spike-stop.sh` に修正。progress doc §A マトリクス・§D スケルトン・§D 差し替えを `bash ` 必須に統一。
- **残（fresh セッションでの最終確認のみ）**: 上記是正後に `/rite:spike-orch` を**新規セッション**で再実行し、`.spike-stop-marker.txt` に行が書かれ、その行の `CLAUDE_PLUGIN_ROOT=` が**解決値**で入ることを観測すれば §D の唯一の load-bearing 残課題が closeout。発火・呼出経路・遮断・env マトリクスは確定済なので、これは設計判断ではなく実書込の確認に限る。

## Phase 1 — 第3回（fresh reload・round-2 SKILL.md 実走, 2026-06-30）

**前提**: 真に fresh なセッション（plugin reload 済）で `/rite:spike-orch` を実行。今回は**ディスク上の round-2 SKILL.md（6ステップ版）が実走**した（第2回の cached round-1 問題が解消）。証拠＝届いたプロンプトが round-2 の6ステップ＋報告フォーマット。これにより §D の唯一の load-bearing 残課題（marker 実書込）を closeout。

### 観測結果（全7項目）

| 検証項目 | 第3回 実機結果 | 判定 |
|---|---|---|
| #3a CLAUDE_SKILL_DIR（bash injection `!`+backtick`） | `<unset>` | 仮説訂正（後述） |
| #3a CLAUDE_PLUGIN_ROOT（bash injection） | `<unset>` | 仮説訂正（後述） |
| #3b 同上（Bash tool call フェンス） | 両方 `<unset>`、`CLAUDE_CODE_SESSION_ID` のみ解決 | 仕様どおり（追認） |
| #5 co-located reference の Read | ✅ `./references/probe.md` を相対リンクで Read・sentinel `[spike-probe:read-ok]` 受領 | **GO** |
| #1 spike-sub（user-invocable:false）呼出 | ✅ 成功・sentinel `[spike-sub:returned-to-caller:OK]` 受領 | **GO**（回帰） |
| §B spike-leaf（disable-model-invocation:true）遮断 | ✅ "cannot be used with Skill tool due to disable-model-invocation" で遮断 | 前提維持 |
| #2 Stop hook marker | ✅ **fired**・marker 1行書込・`CLAUDE_PLUGIN_ROOT=…/plugins/rite`（解決）・`CLAUDE_SKILL_DIR=<unset>`・`stop_hook_active=false` | **§D closeout（GO）** |

marker 実値:

```
2026-06-29T15:21:00Z spike-orch Stop hook fired | session=816c30ea-… stop_hook_active=false CLAUDE_PLUGIN_ROOT=/home/akiyoshi/Projects/work/cc-rite-workflow/plugins/rite CLAUDE_SKILL_DIR=<unset>
```

### §D 継続 hook：load-bearing 残課題を closeout（GO）

- hook command `bash ${CLAUDE_PLUGIN_ROOT}/skills/spike-orch/scripts/spike-stop.sh` が **script を解決して実行**＋**hook 実行時 process env に `CLAUDE_PLUGIN_ROOT` が解決値で存在**を二重で確認。`stop_hook_active=false`（再入ループなし・1行のみ）。
- → skill-scoped Stop hook の正準形 `bash ${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/<x>.sh` を**最終 lock**。第1回（`${CLAUDE_SKILL_DIR}` 誤用）・第2回（cached round-1 で空展開実観測）からの是正が完結。

### 第1回「injection 経路」仮説の訂正（重要）

第1回の総括は「`#3` の `<unset>` は注入経路の取り違えで、bash injection（`!`+backtick`）なら `${CLAUDE_SKILL_DIR}` が解決するはず」と仮説立てた。**第3回の実機で injection も `<unset>` となり、この仮説は反証された**。実際に両 env を解決するのは **skill ロード時の markdown テンプレート置換**である:

- 生 SKILL.md 本文 L20 の bare `${CLAUDE_SKILL_DIR}` / `${CLAUDE_PLUGIN_ROOT}`、frontmatter hook command L15 の `${CLAUDE_PLUGIN_ROOT}` は、モデルに届いたロード済みテキストでは**絶対パスに置換済み**だった（"Base directory" ヘッダも同機構）。
- 一方 `` !`echo "${CLAUDE_SKILL_DIR:-<unset>}"` `` は `<unset>`。理由は (a) injection 実行 shell の env に両 var が無い + (b) `${VAR:-default}` 形は bare `${VAR}` テンプレート一致でないため置換もされない。
- caveat: **bare `${CLAUDE_SKILL_DIR}` を injection ブロック内に置いた場合**の挙動は未測定（`:-default` 形のみテスト）。移行設計は injection 解決に依存しないので追検証は不要。

### env / path 解決マトリクス（第3回で確定・§A SoT を上書き）

| 経路 | `CLAUDE_PLUGIN_ROOT` | `CLAUDE_SKILL_DIR` | `CLAUDE_CODE_SESSION_ID` |
|---|---|---|---|
| markdown テンプレート置換（本文・hook command 文字列の bare `${VAR}`） | ✅ 解決 | ✅ 解決 | — |
| bash injection `!`+backtick`（`${VAR:-default}` 形） | ❌ `<unset>` | ❌ `<unset>` | 未測定 |
| Bash tool call（フェンス実行） | ❌ `<unset>` | ❌ `<unset>` | ✅ 解決 |
| Stop hook 実行時 process env | ✅ 解決 | ❌ `<unset>` | ✅ 解決 |

実装上の制約（lock）:

- パス依存は ①Read 用途＝相対リンク（env 不要・最優先）②hook command＝`bash ${CLAUDE_PLUGIN_ROOT}/...`（テンプレート置換＋hook env の二重で解決）③Bash tool call の plugin file 叩き＝`.rite-plugin-root` 既存機構（env 不可）。
- hook 内では `CLAUDE_SKILL_DIR` 使用不可（process env に無い）。`CLAUDE_PLUGIN_ROOT` 一択。
- bash injection は env 解決に使わない。

### 後片付け（実施済）

- spike-orch / spike-sub / spike-leaf の3スキルと cwd の `.spike-stop-marker.txt` を削除済（いずれも未追跡だったため git 履歴に影響なし）。
- → Phase 1 スパイクは全項目 closeout。**Phase 2 へ無条件で進行可**。

## Phase 2 — 実行結果（PR lifecycle スキル化, 2026-06-30）

### 確定した変換レシピ（merge を基準実装に確立・全スキル共通）

`commands/pr/<X>.md` → `skills/<X>/SKILL.md` の機械的手順:

1. **`cp` でボディを byte-for-byte 保全** → 命名置換 sed → frontmatter 差し替え → パス修正。Write での retype は tuned bash を壊すので使わない（merge のみ初回 retype、以降 cp 方式）。
2. **frontmatter（§B ポリシー lock 済）**:
   - `run` = leaf user-only → `disable-model-invocation: true`（誰も呼ばない top orchestrator）
   - `open/iterate/ready/merge/cleanup` = orchestrator 到達 → **disable 不可**（model-invocable のまま）。narrow description のみで /goal 非干渉を担保（「汎用の〜ヘルパーではなく、その語では auto-activate しない」を明記）
   - `pr-create` = 純 sub-skill → `user-invocable: false`（menu 非表示・Skill ツール invoke は通る、spike #1 で実証）
   - 全スキルに `name:` / `argument-hint:` / `起動: /rite:<X> <args>` を付与
3. **命名置換 sed**（順序重要: pr:create を先に）:
   `s|rite:pr:create|rite:pr-create|g; s|rite:pr:|rite:|g; s|rite:issue:|rite:issue-|g; s|rite:wiki:|rite:wiki-|g; s|rite:skill:|rite:skill-|g; s|rite:template:|rite:template-|g`（`/` 有無両対応）。`/rite:resume` 等 top-level は不変。
4. **パス解決（第3回スパイク env マトリクス準拠）**:
   - `../../references/` `../../agents/` `../../skills/` `{plugin_root}`+`plugin-path-resolution.md` は **全て深さ不変**（`commands/pr/` も `skills/<X>/` も plugin-root から2階層）→ **無変更**。
   - 唯一の例外 = co-located から plugin-root へ移した `bash-trap-patterns.md`: `(./)references/bash-trap-patterns.md` → `../../references/bash-trap-patterns.md`。
   - co-located refs（`./references/<X>.md`）は所有スキル配下に COPY 済みなので形式不変。
5. **`$ARGUMENTS`/`$N` バインド**: Arguments 表 / Placeholder Legend に `$1`（= `{placeholder}`）を明記。本文の `{placeholder}` 記法は保持（Claude が引数から substitute）。
6. **ファイルパス言及の新構造化**: 本文プロース内の `commands/<g>/<x>.md` / bare `<g>/<x>.md` → `skills/<new-name>/SKILL.md`（未移行スキルへの forward-ref はプラン許容）。

### 確定した設計判断（Phase 2 固有）

- **旧 `commands/pr/` は Phase 6 まで温存**（COPY 方式）。移行は rite 不使用 = fresh セッションまでテスト不可のため、動作状態を壊さない安全策。重複は一時的（Phase 6 で commands/ 一括削除）。action スキルは `disable-model-invocation:true`（run）/ orchestrator 到達（budget 消費だが既存 command と同数オーダー）で budget 影響は限定的。
- **参照再配置（§C 適用 + 微修正）**: `bash-trap-patterns.md`(pr 5 + wiki cross-group) → **plugin-root**。`archive-procedures`→cleanup、`assessment-rules`/`fix-relaxation-rules`→fix、`change-intelligence`/`fact-check`/`internal-consistency`/`review-context-optimization`→review に co-locate（COPY）。`assessment-rules` は fix 所有（command 直接参照は fix のみ）だが review の `internal-consistency.md` が1リンク参照 → そのリンクのみ `../../fix/references/assessment-rules.md` のクロススキル相対に修正（self-containment より低リスク）。`anchor-naming-convention.md` は pr コマンド未参照（rite-workflow の simplification-charter のみ参照）→ **Phase 5 で rite-workflow へ co-locate** 予定、Phase 2 では触らない。
- **Stop hook の skill-scope 化は Phase 4 に延期**: Phase 2 で iterate/cleanup に skill-scoped Stop hook を追加すると global `stop-loop-continuation.sh` と**二重発火**する。spike で skill-scoped Stop hook の発火は実証済みなので、Phase 2 は本体のみ移行し継続は当面 global hook（phase enum ベース・コマンド名非依存）で維持。global→skill のアトミック移設を Phase 4 の global hook 剪定に集約。
- **sentinel 文字列は不変**: `[pr:created:N]` / `[pr:create-failed]` / `[review:mergeable]` / `[fix:pushed]` 等は emitter↔consumer 間の内部契約。`pr:`/`create:` は sentinel namespace でありユーザー向けコマンド名ではない。rename は emitter+consumer 同時変更が必要で別スコープ → Phase 2 では一切変更しない（grep ゲートは `rite:pr:` を見るので sentinel は非該当）。

### 移行済スキル（9/9・全て検証パス: 旧命名0・全リンク解決・frontmatter §B 準拠・YAML 健全）

| skill | 元 | 移行後行数 | frontmatter | references |
|---|---|---|---|---|
| merge | pr/merge.md | 135 | model-invocable | — |
| run | pr/run.md | 353 | `disable-model-invocation:true` | — |
| open | pr/open.md | 503 | model-invocable | — |
| iterate | pr/iterate.md | 221 | model-invocable | — |
| ready | pr/ready.md | 562 | model-invocable | — |
| cleanup | pr/cleanup.md | 731 | model-invocable | archive-procedures(1) |
| pr-create | pr/create.md | 994 | `user-invocable:false` | — |
| fix | pr/fix.md | 4040 | `user-invocable:false` | assessment-rules, fix-relaxation-rules(2) |
| review | pr/review.md | 4004 | `user-invocable:false` | change-intelligence, fact-check, internal-consistency, review-context-optimization, reviewer-prompt-generator, reviewer-prompt-verification(6) |

### giants の light 分解（方針 C 採用・実施結果）

- **review**: reviewer 指示テンプレート（Generator / Verification の 2 つの code-fence ブロック、計 ~150 行）を `references/reviewer-prompt-{generator,verification}.md` に抽出。**原本（rename 適用後）と byte 完全一致を diff 検証済み**（reviewer 挙動不変）。4154 → 4004 行。
- **review の他テンプレ候補は抽出せず（正しい判断）**: auto-issue テンプレートは bash heredoc（`cat <<'BODY_EOF'`）内に埋め込まれ、📜 レポートテンプレは Critic ステップロジックと織り込まれている。これらの抽出は bash/step ロジックの再構成を伴い、方針 C の「ステップ手順は SKILL.md に残す」原則に反する high-risk 操作のため **意図的に残置**。clean に取り出せる standalone テンプレートは reviewer プロンプトのみだった。
- **fix**: 大きな自己完結テンプレートが存在しない（📜 例 ~100 行は parse 説明と織込、完了報告は小さい heredoc）。バルクは irreducible なステップロジック。よって **verbatim 移行で確定**（強制抽出は避ける = C の原則どおり）。

### Phase 2 完全性ゲート（全パス・2026-06-30）

1. ✅ 旧コロン命名 `rite:(pr|issue|wiki|skill|template):` = **0 件**（全 9 スキル + 全 references）
2. ✅ bare colon コマンド略記（`pr:open` 等、sentinel `[pr:created]` 除く）= **0 件**
3. ✅ 旧 `commands/<g>/<x>.md` パス言及（`templates/pr/`・glob 例示 `commands/sub/foo.md` 除く）= **0 件**
4. ✅ markdown リンク全解決（forward-ref `../resume/SKILL.md`・`../wiki-{ingest,query}/SKILL.md` を除く）
5. ✅ frontmatter §B 準拠・YAML 健全（タブなし・block scalar 整形）・全タイトル `# /rite:<name>`
6. ✅ `bang-backtick-check.sh --all`（118 ファイル）= 0 findings
7. ✅ `hooks/tests/run-tests.sh` = **81/81 passed**（hooks/commands 未変更のため回帰なし）

### Phase 2 から後続フェーズへ持ち越す残務

- **forward-ref（Phase 3 で解決）**: open/iterate/review/fix が `../resume/SKILL.md`・`../wiki-ingest/SKILL.md`・`../wiki-query/SKILL.md` を参照。review が `../../commands/issue/references/fingerprint-cycling.md`（現位置・有効）を参照 → Phase 3 で issue 参照 relocate 時に skill パスへ更新。
- **Stop hook の skill-scope 化（Phase 4）**: iterate/cleanup 本体は移行済。global `stop-loop-continuation.sh` → skill-scoped へのアトミック移設は Phase 4 の global hook 剪定に集約（二重発火回避）。
- **旧 commands/pr/ 温存（Phase 6 で削除）**: 9 コマンド + commands/pr/references/（bash-trap 等は plugin-root/co-located に COPY 済みのため重複）。Phase 6 で commands/ 一括削除 + grep=0 最終ゲート。
- **anchor-naming-convention.md（Phase 5）**: pr コマンド未参照、rite-workflow の simplification-charter のみ参照 → Phase 5 で rite-workflow へ co-locate。
- **sentinel 文字列**: `[pr:created:N]` `[pr:create-failed]` 等は不変のまま（emitter↔consumer 契約）。将来 rename するなら別 Issue で emitter+consumer 同時に。

## 主要調査結果（Phase 0 で実測・SoT）

- **旧命名参照 計 1,113件**（`rite:pr:`708 / `rite:issue:`214 / `rite:wiki:`170 / `rite:skill:`15 / `rite:template:`6）。
  - ただし大半は**削除予定の command 自身**（pr/fix 66, pr/review 41 等）と **CHANGELOG 履歴**（書換禁止・grep=0 ゲートから除外）。
  - 実追従が要る残存ファイル: `docs/SPEC.md`(165), `README*.md`(各26), `skills/rite-workflow/SKILL.md`(25→一部除去済), `docs/CONFIGURATION.md`(20), `skills/rite-workflow/references/phase-mapping.md`(17), `skills/wiki/SKILL.md`(18) 等。
- **`flow-state.sh` の phase enum は動詞ベース**（`PHASE_ENUM_V3="init branch plan implement lint pr review fix ready ready_error cleanup ingest completed"`）→ **コマンド名非依存。enum 変更不要**。
- **`resume.md` の phase→step 対応表**（324-335行付近）が旧コマンド名を参照 → 機械的に新名へ置換（`/rite:pr:open`→`/rite:open` 等）。**worktree 再入場は issue 番号ベースでコマンド名非依存**。
- **SessionStart CRITICAL 出力**: `session-start.sh:607-616`（局在・silent 化容易）。
- **hooks/tests の旧命名 assert**: 約50件 / 約10ファイル（命名変更時に更新要）。
- **plugin-root 共有 reference の参照数**（多い順）: `plugin-path-resolution`(26・スキル化で `${CLAUDE_SKILL_DIR}`/`${CLAUDE_PLUGIN_ROOT}` に置換し**廃止**), `common-error-handling`(10), `wiki-patterns`(5), `severity-levels`(5), `projects-integration`(4), `issue-create-with-projects`(4), `gh-cli-patterns`(4), `box-display-width`(4), `review-result-schema`(3), `git-worktree-patterns`(3), `bottleneck-detection`(3) …
  - **デッド reference（参照0件）= 削除候補**: `sub-issue-link-handler`, `state-read-evolution`, `session-id-validation-contract`, `gh-cli-commands`, `bash-defensive-patterns`。
- **commands 配下 references/**: issue/(4) pr/(9) wiki/(2) = 計15。対応スキルへ co-locate。

## 命名マップ（プラン §1 の要約）

PR lifecycle（短縮）: open, iterate, review, fix, ready, merge, cleanup, run / pr-create（create 衝突回避）
issue 管理（接頭辞）: issue-create, issue-list, issue-update, issue-close, issue-edit, issue-implement
wiki: wiki-init, wiki-query, wiki-ingest, wiki-lint
meta: skill-suggest, template-reset
top-level: init, getting-started, workflow, investigate, learn, lint, resume

## 未解決の決定事項

### 第1回スパイク + 公式裏取りで確定（上「Phase 1 — 実行結果」参照）

- ~~orchestrator→sub-skill の呼び出し経路~~ → **Skill ツール invoke で確定**。§B ポリシー lock。
- ~~`CLAUDE_CODE_SESSION_ID` の skill Bash 可用性~~ → **解決する**で確定。
- ~~skill-scoped hooks のプラグイン実発火~~ → **発火する**で確定（command 変数を `${CLAUDE_PLUGIN_ROOT}` に直すのみ）。
- ~~`${CLAUDE_PLUGIN_ROOT}` の skill Bash 可用性~~ → **Bash tool call では不可・hook 実行時のみ可**で確定（§A マトリクス参照）。

### 残（任意の第2回スパイク or Phase 2 実装中に確定）

- ~~**§D 継続 hook の path 解決**~~ → **closeout（第3回 fresh reload, 2026-06-30）**: fresh セッションで marker が実書込され、行内 `CLAUDE_PLUGIN_ROOT=…/plugins/rite` が**解決値**で入ることを確認。hook command 正準形 `bash ${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/<x>.sh` を最終 lock。併せて第1回「bash injection なら `${CLAUDE_SKILL_DIR}` が解決する」仮説を**反証**（injection も `<unset>`、解決手段は markdown テンプレート置換）。
- **ネスト sub-skill 実行中の Stop hook 発火可否**（§D で書式確定済・挙動は最小ドキュメント）。
- **`reviewers`（disable-model-invocation:true）の整合**: review 経路が Skill ツール invoke でなく agents/ 経由（Task ツール）であることの確認。
- **継続機構の縮退度**（Stop hook skill-scoped 化で自律継続が当該スキル中のみに）。§E の session-start 降格タイミングと連動。
