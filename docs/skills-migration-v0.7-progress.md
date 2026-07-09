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
| 3 | issue/wiki/meta/top-level スキル化 | **概ね完了** — 17/19 移行済（issue 6 + wiki 4 + meta 2 + top-level 5）。`investigate`・`workflow` は既存ルーター/knowledge スキルとの統合対象のためプラン §5 に従い Phase 5 へ繰延。完全性ゲート全パス（旧命名0・全リンク解決・bang-backtick 0・hooks/tests 81/81） |
| 4 | グローバル hook 剪定 & 棚卸し | **完了** — 棚卸し成果物作成済（下記「Phase 4 — 監査結果」）。坂口さん決定 = ①8 hook 全て global 維持（skill-scoping 撤回）②SessionStart CRITICAL を静かな1行へ降格。SessionStart 降格を実装・テスト更新し **81/81 green**。dead hook 削除（preflight-check / command-id ディスパッチ）は生きた呼び出し元 rite-workflow と同時の Phase 5 へ |
| 5 | orchestrator/knowledge 統合 | **完了** — investigate 統合（commands→skill, 広域 auto-activation 除去）・workflow 新スキル化・wiki ルーター解体削除・preflight-check 撤去・rite-workflow SKILL.md 命名/パス修正・reviewers 統合（review への cross-ref を skill パス化）・workflow-identity/anchor-naming 仕上げ。完全性ゲート全パス（Phase 5 範囲の旧命名 0・全リンク解決・bang-backtick 0/142・hooks/tests **80/80**）。残務は Phase 6（commands/ 一括削除・全リポジトリ旧命名スイープ） |
| 6 | 後片付け & リリース | **cleanup 完了 / release 残** — naming+path+bare-colon スイープ・既存 artifact 修正・scanner 7 件 commands→skills repoint（+ 連動 test 修正）・`commands/` 一括削除（42 file / -25,992 行）・完全性ゲート全パス（grep=0 / dangling 0 / 壊れリンク 0 / hooks 80/80・scripts/tests 73/73・hooks/scripts/tests 4/4・全 scanner --all rc=0）。version bump / CHANGELOG / `/release` は坂口さんの指示待ち（Phase 6b）|

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
| **leaf user-only**（他スキルから呼ばれない） | issue-create, issue-update, issue-close, issue-edit, wiki-init, wiki-query, skill-suggest, template-reset, getting-started, workflow, investigate, learn, resume | **`true`** | 既定 true | disable-model-invocation + narrow desc |
| **orchestrator 到達 & user-entry 兼用** | open, iterate, ready, merge, cleanup, lint, init, issue-list, **wiki-ingest, wiki-lint** | **`false`**（付けられない） | 既定 true（ユーザーも起動） | **narrow description のみ**（disable 不可） |
| **純 sub-skill**（user は直接起動しない） | review, fix, pr-create, issue-implement | **`false`** | **`false`**（メニュー非表示） | narrow desc + 非可視 |
| **knowledge content** | コーディング原則 / gh CLI パターン 等 | — | **`false`** | 背景知識 |

- `/rite:recover` は各所に出るが「ユーザーに `/rite:recover` を案内」する文字列であり programmatic 呼び出しではない → leaf 扱い（disable-model-invocation: true 可）。
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
- v0.7 では継続機構が skill-scoped Stop hook（iterate/cleanup）+ `/rite:recover` に移る予定。session-start 再注入は「中断検出 → /rite:recover 案内」の静かな1行に降格するのが筋だが、**その置換（skill-scoped 継続）が存在する Phase 2 以降でないと、降格＝compact 回復の劣化**になる。
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

### Addendum: §B lock の前提の誤り（後日判明・spike 記録自体は保持）

上記 §B lock は「spike-orch が自身の SKILL.md 本文の指示に従って Skill ツールを呼ぶ」経路のみを検証しており、「ユーザー自身が `/rite:xxx` と直接タイプした場合」は未検証だった。実際には Claude Code CLI 側で、ユーザーが明示的に入力したスラッシュコマンドとモデル自身が自律的に決定した Skill ツール呼び出しが**同一の Skill ツール経路**を通り、区別されない（upstream で複数回報告済みの既知の挙動: [anthropics/claude-code#43660](https://github.com/anthropics/claude-code/issues/43660) 等）。

この見落としにより、「leaf スキル（他スキルから呼ばれない）なら `disable-model-invocation:true` は安全」という誤った結論のもと、issue-create 等 14 件の user-invocable leaf スキルに `disable-model-invocation: true` を付与していた。何らかの要因（画像添付等）でネイティブなスラッシュコマンド dispatch と認識されないケースでは、モデル側の Skill ツールフォールバックが発生し、`disable-model-invocation` ガードにユーザー起動そのものが阻まれるバグを生んでいた。是正内容は別途 Issue で対応し、frontmatter ポリシーを「`disable-model-invocation` は user-invocable スキルには使用しない」へ変更した。

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
   `s|rite:pr:create|rite:pr-create|g; s|rite:pr:|rite:|g; s|rite:issue:|rite:issue-|g; s|rite:wiki:|rite:wiki-|g; s|rite:skill:|rite:skill-|g; s|rite:template:|rite:template-|g`（`/` 有無両対応）。`/rite:recover` 等 top-level は不変。
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

## Phase 3 — 実行結果（issue/wiki/meta/top-level スキル化, 2026-06-30）

### 着手前に発見した §B 分類の誤り（修正済み）

コールグラフ実測の結果、進捗ログ §B の旧分類に誤りを発見し修正:

- **`cleanup → wiki-ingest`**（`commands/pr/cleanup.md` 内 `Skill: rite:wiki:ingest` で programmatic 呼出）
- **`wiki-ingest → wiki-lint`**（`commands/wiki/ingest.md` 内 `skill: "rite:wiki:lint", args:"--auto"` で programmatic 呼出）

→ `wiki-ingest`・`wiki-lint` は orchestrator から Skill ツールで到達されるため `disable-model-invocation:true` 不可（spike §B で programmatic 呼出遮断を実証済）。両者を §B の **「orchestrator 到達 & user-entry 兼用」**（model-invocable）へ移動。`wiki-query`（hook `wiki-query-inject.sh` 直叩き＋案内のみ）・`wiki-init`（standalone）は programmatic 呼出なし → **leaf user-only のまま正**。

### Phase 3 の frontmatter 区分（確定）

| skill | 区分 | frontmatter |
|---|---|---|
| issue-create, issue-update, issue-close, issue-edit | leaf user-only | `disable-model-invocation: true` |
| wiki-init, wiki-query | leaf user-only | `disable-model-invocation: true` |
| skill-suggest, template-reset | leaf user-only | `disable-model-invocation: true` |
| getting-started, workflow, investigate, learn, resume | leaf user-only | `disable-model-invocation: true` |
| issue-list | orchestrator 到達（cleanup→） | model-invocable |
| wiki-ingest | orchestrator 到達（cleanup→） | model-invocable |
| wiki-lint | orchestrator 到達（wiki-ingest→） | model-invocable |
| init | orchestrator 到達（open→） | model-invocable |
| lint | orchestrator 到達（open/ready→） | model-invocable |
| issue-implement | 純 sub-skill（open→） | `user-invocable: false` |

### パス深さの2系統（Phase 2 レシピへの追補）

- **Group A（depth 2 = pr/ と同じ）**: `commands/{issue,wiki,skill,template}/<x>.md`。相対パス `../../references/` `../../templates/` `../../skills/` `{plugin_root}` は **深さ不変**（`skills/<X>/` も depth 2）。cross-group sibling 参照のみ新スキルパスへ更新。
- **Group B（depth 1）**: top-level `commands/<x>.md`（init, getting-started, workflow, investigate, learn, lint, resume）。`skills/<X>/SKILL.md`（depth 2）へ移すと相対が +1 階層 → `../references/`→`../../references/`、`../skills/`→`../../skills/`。`{plugin_root}`・`${CLAUDE_PLUGIN_ROOT}` は深さ不変。

### reference 再配置（§C 適用）

- issue group（issue-create 所有）へ co-locate: `complexity-gate`, `contract-section-mapping`, `fingerprint-cycling`, `slug-generation`。
- wiki group（wiki-lint 所有）へ co-locate: `bash-cross-boundary-state-transfer`, `broken-ref-resolution`。
- cross-ref 更新: `skills/pr-review/SKILL.md`（fingerprint-cycling forward-ref 解決）、`references/issue-create-with-projects.md`（prose path）、`templates/issue/default.md`（2 markdown link）。`simplification-charter.md` L73 は backtick の例示ファイル名のみ（リンクでない）→ 更新不要。

### investigate / workflow を Phase 5 へ繰り延べ（スコープ判断）

`investigate` と `workflow` は Phase 3 命名マップに含まれるが、いずれも**既存スキルとの統合対象**:

- `investigate`: 既存 `skills/investigate/SKILL.md`（広域 auto-activation ルーター）と名前衝突。
- `workflow`: プラン §4 が「状態検出・次アクション提案・コーディング原則は `rite-workflow` へ集約（`commands/workflow.md` と統合）」と規定 = 設計タスク。

プラン §5 Phase 5 が明示的に「investigate/wiki/reviewers のコマンド版とスキル版を統合」と割り当てているため、**両者は Phase 5 に回す**（既存ルーター/knowledge スキルの統合を 1 つの coherent な pass にまとめる）。**どのスキルも `../investigate/` `../workflow/` を参照していない**ため繰延による broken link は発生しない（forward-ref 棚卸しで確認）。`commands/investigate.md`・`commands/workflow.md` は温存。

### 移行済スキル（17・全ゲートパス）

| group | skills | frontmatter |
|---|---|---|
| issue | issue-create / issue-update / issue-close / issue-edit | `disable-model-invocation: true` |
| issue | issue-list | model-invocable（cleanup 到達） |
| issue | issue-implement | `user-invocable: false`（open→ sub-skill） |
| wiki | wiki-init / wiki-query | `disable-model-invocation: true` |
| wiki | wiki-ingest（cleanup→） / wiki-lint（wiki-ingest→） | model-invocable |
| meta | skill-suggest / template-reset | `disable-model-invocation: true` |
| top-level | getting-started / learn / resume | `disable-model-invocation: true` |
| top-level | init（open→） / lint（open,ready→） | model-invocable |

- 変換は Phase 2 レシピ準拠（cp byte 保全 → frontmatter swap → naming sed → bare path/colon 一掃 → depth 対応パス修正）。Group B（top-level depth 1）は `../references/`・`../skills/`・resume の `../hooks/scripts/` を +1 シフト。init の `{hooks_dir}/../hooks/`（runtime bash）と `.../cache/`（散文 ellipsis）はシフト対象外として保護。
- reference COPY: issue refs 4 → `skills/issue-create/references/`、wiki refs 2 → `skills/wiki-lint/references/`（旧 `commands/<g>/references/` は Phase 6 まで温存）。co-located ref は depth-invariant（commands/<g>/references/ も skills/<name>/references/ も plugin-root から深さ3）。

### Phase 3 完全性ゲート（全パス・2026-06-30）

1. ✅ 旧コロン命名 `rite:(pr|issue|wiki|skill|template):` = 0（17 skills + コピー refs）
2. ✅ bare colon 略記（`pr:open` `wiki:query` 等、sentinel `[pr:created]` 除く）= 0
3. ✅ bare 旧パス言及（`pr/X.md` `commands/<g>/<x>.md`、glob `commands/**` 除く）= 0
4. ✅ markdown リンク全解決（placeholder `pages/{domain}/{slug}.md` 例示・既存 `workflow-identity.md` 自己リンクを除く）。issue→wiki forward-ref（wiki-ingest/wiki-query）・各 orchestrator→resume forward-ref を全解消
5. ✅ frontmatter §B 準拠・YAML 健全（タブなし・block scalar 整形）・タイトル `# /rite:<name>`（issue-implement は sub-skill のため元 `# Implementation Guidance` 保持＝Phase 2 の pr-create と同様）
6. ✅ `bang-backtick-check.sh --all`（141 ファイル）= 0 findings
7. ✅ `hooks/tests/run-tests.sh` = 81/81 passed

### Phase 3 から後続フェーズへ持ち越す残務

- **investigate / workflow（Phase 5）**: 上記の通り既存 `skills/investigate/`・`rite-workflow` との統合として実施。`commands/investigate.md`・`commands/workflow.md` 温存。
- **既存ルーター skill 統合（Phase 5）**: `skills/wiki/`（wiki-* 4 分割で冗長化）・`skills/investigate/`・`skills/reviewers/` の重複解消。`skills/rite-workflow/references/workflow-identity.md` の自己リンク `../../skills/rite-workflow/...`（二重 skills/ で broken）も既存バグとして Phase 5 で是正。
- **旧 commands/（Phase 6 で削除）**: issue/ wiki/ skill/ template/ + 各 references、top-level *.md。Phase 6 で commands/ 一括削除 + grep=0 最終ゲート。

## Phase 4 — 監査結果（global hook 棚卸し, 2026-06-30）

**結論（重要）**: プラン §3 の前提「グローバル hook が `/goal` を汚染するからスキルスコープ化する」は監査でほぼ崩れた。8 個のグローバル hook はいずれも**既に自己局在化済み**（非 rite セッションでは fast no-op / handoff キー / IS_SUBAGENT ゲート）で、真の `/goal` コンテキスト汚染残渣は **SessionStart CRITICAL 出力ただ 1 つ**。プランの skill-scoping 3 件はいずれも「効果ほぼ無し or 破壊的」と判明した。

### hooks.json 登録 8 hook の棚卸し（KEEP / SCOPE / DELETE）

| hook (matcher) | script | 実態 | 自己局在化 | 判定 | 根拠 |
|---|---|---|---|---|---|
| PreCompact | pre-compact.sh | compact 前マーカー書込 | rite state 時のみ実働・冪等 | **KEEP global** | プラン据え置き合意 |
| PostCompact | post-compact.sh | compact 後回復マーカー | 同上 | **KEEP global** | プラン据え置き合意 |
| SessionStart | session-start.sh | 中断検出 + CRITICAL 注入 + reap + schema check | `ACTIVE!=true`→即 exit 0。CRITICAL は `ACTIVE=true && SOURCE∈{resume,compact}` のみ | **KEEP global / CRITICAL のみ降格** | reap/schema は維持必須。CRITICAL が唯一の汚染残渣 |
| SessionEnd | session-end.sh | orphan reap | rite state 時のみ・冪等 | **KEEP global** | プラン据え置き合意 |
| Stop | stop-loop-continuation.sh | review↔fix / wikichain 継続 | handoff キー・コマンド名非依存・handoff 不在で即 exit 0 (fail-open) | **KEEP global 推奨**（決定待ち） | 既に pending-handoff のみに局在。skill-scope 化は未検証のネスト発火依存で得るもの限定 |
| PreToolUse(Bash) | pre-tool-bash-guard.sh | gh/jq 普遍ガード + reviewer git 変更禁止 | Pattern1–3 は μs。Pattern4Z/4A–4G は `IS_SUBAGENT=1` ゲート（reviewer subagent 内のみ発火） | **KEEP global 推奨**（決定待ち） | reviewer ガードは subagent 内発火が必須＝global 登録が担保。review skill-scope へ移すと Task subagent へ伝播せず**ガードが壊れる** |
| PostToolUse(Bash) | post-tool-wm-sync.sh | phase 変化検出→Issue コメント同期 | 12 早期 exit。`FLOW_STATE` 不在/active≠true/phase 不変で即 exit 0 (`<1ms`) | **KEEP global 推奨**（決定待ち） | scoping は wall-time ほぼ削減せず脆さ増（out-of-band commit の phase 変化取りこぼし・completed/cleanup 防御喪失・新スキルごとの scope 列挙） |
| PostToolUse(Edit\|Write\|MultiEdit) | scripts/bang-backtick-edit-hook.sh | bang-backtick lint | 低衝突 | **KEEP global** | プラン据え置き合意 |

### dead hook 削除：参照ゼロは皆無 → 削除は Phase 5 へ

- **全 hook スクリプトに生きた参照が存在**（reference-dead = 0 件）。プラン §3 が名指しした dead 候補は実際には skill 側に呼び出し元がある:
  - `preflight-check.sh`（command-id ディスパッチ guard）: `skills/rite-workflow/SKILL.md` L199–209「Preflight Guard」+ `skills/rite-workflow/references/work-memory-format.md` L407 が `bash {plugin_root}/hooks/preflight-check.sh --command-id ...` で**生きた呼び出し**。`rite-workflow/SKILL.md` 自体に旧コロン命名（`/rite:pr:review` 等）が残存し **Phase 5 で統合予定**。
  - → **preflight-check.sh + command-id ディスパッチの削除は Phase 5（呼び出し元 rite-workflow の整理と同時アトミック）へ**。今 Phase 4 で消すと skill が壊れる。
- `references/session-id-validation-contract.md` も preflight-check.test.sh を参照（reference 棚卸しは Phase 5/6）。

### SessionStart CRITICAL 降格（§E の再評価・実行可能）

- §E は「降格は Stop の skill-scoped 継続が入った後」と結合させていたが、**再分析で非結合と判明**: post-compact 回復は **cross-turn**（セッション再起動後の再注入）、Stop 継続は **in-turn**（live turn 内の早期停止差し戻し）で別レイヤ。CRITICAL を「`/rite:recover` を案内する静かな 1 行」に降格しても cross-turn 回復は保たれる（`/rite:recover` が phase/next-action を再構築）。
- `session-start.sh` 構造確認済: `ACTIVE!=true`→exit 0 (L459)、`SOURCE∈{startup,clear}`→`_reset_active_state`（CRITICAL 非経由・ownership=other はスキップ）。CRITICAL (L606–616) は `ACTIVE=true && SOURCE∈{resume,compact}` でのみ到達。
- 降格は **hook 内の変更**（skill frontmatter でない）= **本セッションで session-start.test.sh により検証可能**（plugin caching の影響を受けない）。TC-012/013/014 + L243/L866 系 assert を新文言へ更新。
- L615 の `{plugin_root}` 言及（Claude 実行用 bash の 3-tier 手動解決プレースホルダ）は、降格で当該行ごと削除されるため `${CLAUDE_PLUGIN_ROOT}` 化問題は消滅（Bash tool call では `${CLAUDE_PLUGIN_ROOT}` は `<unset>`＝§A マトリクスより `{plugin_root}` 手動解決が正で、置換はむしろ誤り）。

### 検証可能性の境界（Phase 4 固有）

- **hook 側の変更（SessionStart 降格等）= 本セッションで検証可能**（`hooks/tests/` を直接実行できる。baseline 81/81 green 確認済）。
- **skill 側の変更（global hook → skill frontmatter への移設）= 本セッションで検証不可**（Phase 1 第2回の発見: プラグインスキルはセッション開始時キャッシュ・`/clear` で再ロードされない → fresh セッション必須）。これも skill-scoping を Phase 4 で急がない理由。

### 推奨する Phase 4 スコープ（プラン §3 からの是正）

1. **8 hook はすべて global 維持**（自己局在化済みのため scoping は効果無し or 破壊的）。
2. **SessionStart CRITICAL を静かな 1 行へ降格**（唯一の実取り効果・hook 内・検証可能）。
3. **preflight-check / command-id ディスパッチの削除は Phase 5 へ**（呼び出し元と同時）。
4. **棚卸し一覧（本節）を Phase 4 の成果物**とする。

→ プランの skill-scoping 撤回は承認済みプランの実質変更のため、実行前に坂口さんへ確認した（下記「Phase 4 — 実行結果」）。

## Phase 4 — 実行結果（2026-06-30）

### 坂口さんの決定（AskUserQuestion で確認）

- **Q1 hook scoping → 「global 維持」**: プラン §3 の skill-scope 化 3 件（Stop / pre-tool-bash-guard / post-tool-wm-sync）を**撤回**。8 hook すべて global のまま据え置き。根拠は上記「監査結果」の通り（自己局在化済み・bash-guard は subagent 伝播が切れ破壊的・Stop は未検証のネスト発火依存）。
- **Q2 SessionStart → 「静かな1行へ降格」**: CRITICAL 多行ブロックを `/rite:recover` 案内の静かな1行へ降格。

### 実装した変更（hook 内・本セッション検証済）

- **`hooks/session-start.sh`**: CRITICAL 多行 heredoc（旧 606–616）を 1 行 echo へ降格:
  - 新文言: `rite: 中断した rite workflow を検出しました (Issue #${ISSUE}, phase: ${PHASE})。再開するには /rite:recover を実行してください。`
  - 旧ブロックの coercive 指示（「IMPORTANT: First inform the user … Use bash {plugin_root}/…」）を除去 → `/goal` コンテキスト汚染を解消。
  - cross-turn 回復は保持（`/rite:recover` が phase/next_action/loop を再構築）。post-compact 回復（TC-012/013/014）は引き続き CRITICAL→notice 経路でフォールスルー。
  - 脆い `{plugin_root}` 言及は降格で当該行ごと消滅（§A マトリクスより Bash tool call で `${CLAUDE_PLUGIN_ROOT}` は `<unset>`＝置換は誤りだった）。
  - jq フィールド抽出を 4→2（issue_number + phase）に縮約し、orphan 化する next_action/loop_count を除去（unit-separator 区切り の empty-field 保全ロジックは維持）。
- **`hooks/tests/session-start.test.sh`**: 影響 7 ケースの assert を新文言へ更新（TC-006/008/011/012/013/014 + TC-per-session-detect-A）。説明コメント/echo の "CRITICAL" 表現も "interruption notice" へ整合。
- **検証**: `session-start.test.sh` 64/64、`run-tests.sh` **81/81 passed**。

### hooks.json は無変更

- 8 hook 登録すべて維持（PreCompact / PostCompact / SessionStart / SessionEnd / Stop / PreToolUse(Bash) / PostToolUse(Bash) / PostToolUse(Edit|Write|MultiEdit)）。skill frontmatter への hook 移設は行わない。

### dead hook の状況（削除は Phase 5/6 へ）

- **reference-dead な hook は 0 件**（全 hook に生きた参照あり）。プラン §3 の dead 候補は誤検出:
  - `preflight-check.sh` + command-id ディスパッチ: `skills/rite-workflow/SKILL.md`（L199–209 Preflight Guard）+ `skills/rite-workflow/references/work-memory-format.md`（L407）が生きた呼び出し元 → **Phase 5（rite-workflow 統合）で呼び出し元と同時削除**。
  - `workflow-incident-emit.sh`（プラン「旧 sentinel 監視」）: **既に撤去済**（hooks/ に不在）。
- SPEC.md は SessionStart CRITICAL 挙動を記述していない（Stop hook の note のみで、それは global 維持なので正確）→ Phase 4 由来の doc 更新は不要。

### Phase 4 から後続フェーズへ持ち越す残務

- **preflight-check.sh + command-id ディスパッチ削除（Phase 5）**: `rite-workflow/SKILL.md` の「Preflight Guard」節 + `work-memory-format.md` L407 の呼び出しを除去し、hook 本体 `preflight-check.sh` + `preflight-check.test.sh` + `references/session-id-validation-contract.md` の関連記述を同時に整理。
- **`rite-workflow/SKILL.md` の旧コロン命名（Phase 5）**: L207「/rite:lint, /rite:pr:review」・L222「/rite:pr:open/iterate/ready/merge」等が残存（Phase 3 完全性ゲートは移行済スキルのみ対象、rite-workflow は Phase 5 統合対象のため未着手）。
- **doc 一括更新（Phase 6）**: SPEC.md L1163 等の旧コロン命名（`/rite:pr:cleanup` 等）は Phase 6 の命名スイープへ。

## Phase 5 — 実行結果（orchestrator/knowledge 統合, 2026-06-30）

### 着手前の設計判断（坂口さんに AskUserQuestion で確認）

プラン §4「investigate/wiki/reviewers 統合（重複解消）」は具体策を定めていないため、2 点を確認し**いずれも推奨案で確定**:

- **wiki ルーター（`skills/wiki/SKILL.md`）の処遇 → 解体・削除**: wiki-* 4 スキル + lint と重複する旧コロン命名の広域 auto-activation ルーター。固有の troubleshooting/overview を wiki-ingest 配下 reference へ移設し削除。
- **preflight-check（compact 検出時に `/rite:recover` 以外をブロックする LLM 駆動ガード）の処遇 → 削除**: hooks.json 非登録、`rite-workflow` の指示で手動 bash 起動する脆い `{plugin_root}` 依存機構。Phase 4 監査が「dead ではない・決定は Phase 5」と保留した点。compact 回復は SessionStart 通知 + `/rite:recover`（cross-turn）に一本化。

### 実施した統合（6 タスク）

1. **investigate 統合**: `commands/investigate.md` の全 7 フェーズ手順を `skills/investigate/SKILL.md` に統合。frontmatter を `disable-model-invocation: true` + narrow desc 化し、**広域 Auto-Activation Keywords 節（「一覧」「全件」「使われ方」等の汚染源）を除去**。`references/investigation-protocol.md` の 5 リンクを `commands/investigate.md` → `skills/investigate/SKILL.md` へ更新（見出し不変のためアンカー維持）。
2. **workflow 新スキル**: `commands/workflow.md` → `skills/workflow/SKILL.md`（`/rite:workflow`, `disable-model-invocation: true`）。Group B（depth 1→2）で `box-display-width` 参照を +1 シフト。図/コマンド一覧の旧コロン命名を新命名へ（フロー図の box 幅は対象外注記あり）。
3. **wiki 解体・削除**: 固有の troubleshooting（raw が増えない/page が増えない/手動 ingest タイミング/growth-check alarm の読み方）+ 3 層アーキ概要を `skills/wiki-ingest/references/wiki-troubleshooting.md`（新命名）へ移設。wiki-ingest イントロにポインタ追加。唯一の参照元 `comment-best-practices.md` のジャーゴン whitelist L495 を `skills/wiki-ingest/`, `skills/wiki-query/` へ repoint。`skills/wiki/` を削除。
4. **preflight-check 削除**: `rite-workflow/SKILL.md` の「Preflight Guard」節 + `work-memory-format.md` の「Preflight Guard Contract (Phase C)」節を除去（SoT Access Pattern サブ節は preflight 無関係のため保持し `##` へ昇格）。`hooks/preflight-check.sh` + `hooks/tests/preflight-check.test.sh` を削除。`session-id-validation-contract.md` の Layer 1 依存テスト一覧から `preflight-check.test.sh` を除去。run-tests.sh は `*.test.sh` glob 探索のため改変不要。
5. **rite-workflow/SKILL.md 命名・パス修正**: 旧 `rite:` コロン命名（Suggested Actions 表・4 Command Architecture・sentinel 表・各所散文 計 30+）を命名 sed で新命名へ。bare colon 略記（`pr:open`/`wiki:ingest` 等）も targeted sed で変換（sentinel `[pr:created:N]`/`[pr:create-failed]` は `rite:` 接頭辞・bracket がないため非該当・全無傷を検証）。`commands/resume.md`→`skills/resume/SKILL.md`、`commands/issue/implement.md`→`skills/issue-implement/SKILL.md`（depth 補正 `../issue-implement/SKILL.md`）、`commands/pr/cleanup.md`+`commands/pr/references/`→skills 系へ。
6. **reviewers / workflow-identity / anchor-naming 仕上げ**:
   - **reviewers**: description の `/rite:pr:review` → `/rite:pr-review`。review への cross-ref（`commands/pr/review.md`・`commands/pr/references/internal-consistency.md`、markdown リンク + bare `review.md` 略記 計 15 箇所）を `skills/pr-review/SKILL.md`・`skills/pr-review/references/internal-consistency.md` へ統一（depth 不変・ステップ番号/アンカーは Phase 2 byte 保全により解決を検証）。reviewer の file-pattern glob `commands/**/*.md` は汎用パターンのため非対象。**review→reviewers は Skill invoke でなく `Read: skills/reviewers/SKILL.md`（ファイル Read）と確認** → `disable-model-invocation:true` は整合（Phase 1 残課題 closeout）。
   - **workflow-identity.md**: caller depth ガイダンス表（L161）を commands/ ベース → skills/ ベース（`../../skills/...` = skills/<name>/SKILL.md / `../../../skills/...` = skills/<name>/references/）へ。fenced 例（L167）の深さ依存パスを placeholder `<相対パス>` 化し自ファイル位置からの broken 表示を解消。
   - **anchor-naming-convention.md**: `commands/pr/references/` → `skills/rite-workflow/references/` へ co-locate（唯一の参照元 simplification-charter のみ）。両者を `./` 形式の sibling link に整理。

### Phase 5 完全性ゲート（全パス・2026-06-30）

対象 = Phase 5 で直接移行/整備したアーティファクト（investigate, workflow, rite-workflow/SKILL.md, reviewers, wiki-troubleshooting, investigation-protocol）:

1. ✅ 旧コロン命名 `rite:(pr|issue|wiki|skill|template):` = **0**
2. ✅ bare colon 略記（sentinel 除く）= **0**（`git fetch origin wiki:wiki` の refspec は false positive）
3. ✅ glob 以外の `commands/<g>/<x>.md` パス参照 = **0**（reviewer の `commands/**/*.md` glob は汎用パターン）
4. ✅ 相対 markdown リンク全解決（削除/移動先への dangling 0: skills/wiki/・preflight-check・旧 anchor-naming パスへの参照すべて 0）
5. ✅ frontmatter §B 準拠・YAML 健全（タブなし）・新規2スキルとも `disable-model-invocation: true`
6. ✅ `bang-backtick-check.sh --all`（142 ファイル）= **0 findings**
7. ✅ `hooks/tests/run-tests.sh` = **80/80 passed**（preflight-check.test.sh 削除で 81→80、回帰なし）

### Phase 5 から Phase 6 へ持ち越す残務

- **commands/ 一括削除**: 移行で orphan 化した `commands/investigate.md`・`commands/workflow.md` を含む `commands/` 全体 + commands/pr/references/ 残り。Phase 6 で削除 + 全リポジトリ grep=0 最終ゲート。
- **全リポジトリ旧命名スイープ（Phase 6）**: 構造統合は完了したが、**Phase 5 で直接編集していない rite-workflow references の旧命名は意図的に未着手**（broad sweep に集約）。具体: `workflow-identity.md` L96/L119/L170（`/rite:pr:cleanup`・`commands/issue/create.md`・`plugins/rite/commands/` 言及）、`phase-mapping.md`(17)、`session-detection.md` 等、および `anchor-naming-convention.md` の content（`commands/pr/fix.md:1118` 等の行番号 audit・`/rite:wiki:query`・「`plugins/rite/commands/` 配下」scope 記述）。SPEC.md(165)/README(各26)/CONFIGURATION.md(20) も同スイープ。
- **Phase 4 の未コミット変更**: `session-start.sh` + `session-start.test.sh`（CRITICAL 降格）は Phase 4 成果で本作業と同じ作業ツリーに未コミットのまま（コミットは坂口さんの指示待ち）。

## Phase 6 — 実行結果（後片付け cleanup, 2026-06-30）

### 坂口さんの決定（AskUserQuestion）

- **凍結境界 → 履歴4種を凍結**: `CHANGELOG*`（書換禁止）/ `docs/designs/*`（Status:実装完了の設計記録）/ `tests/regression/*`（明示 Retired）/ `REFACTOR-PROGRESS.md`（2026-06-11 中断の**別プロジェクト**）+ 本 progress doc を grep=0 から除外。`docs/tests/*` は現行検証用なので skills/ パスへスイープ。`.claude/settings.local.json` は untracked のため自動的に対象外。
- **到達点 → cleanup まで**: naming+path スイープ・`commands/` 削除・完全性ゲートまで。version bump / CHANGELOG / release は別ターン（鉄則どおりコミット/プッシュも指示待ち）。

### 実施した cleanup（5 系統）

1. **naming+path 決定論的 sed スイープ**（SWEEP 300 file 対象）: 旧コロン命名 `rite:(pr|issue|wiki|skill|template):` → フラット新命名、`commands/<g>/<x>.md` → `skills/<name>/SKILL.md`（co-located reference は新所在へ個別マップ）。117 file・689/689 対称置換。**パスは純テキスト置換で成立**（`commands/` と `skills/` は plugin-root 直下の兄弟 → `../../../` プレフィックス不変、末尾のみ置換）。
2. **bare-colon prose スイープ**: `pr:open`→`open` / `wiki:ingest`→`wiki-ingest` 等（verb 明示列挙で sentinel `[x:y]` 無傷・217 件保全を検証）。22 file。
3. **既存 artifact 修正**: Phase 5 sweep 由来の壊れパス `commands/skills/<name>/SKILL.md` → `skills/<name>/SKILL.md`（9 箇所。category-list `commands/skills/agents/i18n` は非該当）。
4. **scanner 7 件を commands→skills へ repoint（必然的後片付け）**: `commands/` 温存を Phase 6 までとした方針の帰結。commands/ 削除後に lint 基盤が空スキャン/ハードエラーになるのを回避。
   - **単独 base を skills へ**: `bash-heaviness-check` / `hardcoded-line-number-check`（`--all` で `commands_dir does not exist` エラーになっていた）/ `backlink-format-check` / `check-no-direct-gh-issue-create`。
   - **両 scan から死んだ commands/ を除去**: `bang-backtick-check`（scan_dirs 配列）/ `bang-backtick-edit-hook`（case arms）/ `orphan-reference-check`（find 述語）。
   - 連動 test を reseed（sandbox `commands/` → `skills/`）。汎用 sweep が write 先（`commands/pr/fix.md`→`skills/fix/SKILL.md`）を特定スキル名に変えたのに mkdir(dir) が未変換だった不整合を **distributed-fix-drift / doc-heavy / sh-cross-ref** で修正。`sh-cross-ref` は SKILL.md 命名で bare basename 解決が無効化されるため fixture を path 形へ全面更新（scanner 自体は実 tree で path 形を正しく解決・rc=0/0 findings を確認済）。`test-distributed` の `git show ${BASELINE_COMMIT=cec0140}:commands/pr/fix.md` は**歴史コミット時点のパス**なので revert（sweep が誤変換していた）。`finding-examples.md` の 1 件の hardcoded-line を backtick 退避。
5. **reviewer agent の機能的 grep 指示**（`commands/**/*.md` を grep せよ等）を skills/ へ更新。placeholder/hypothetical 例（`commands/foo.md`・`commands/<orchestrator>.md`・L111 scope-mismatch 例）は generic 例として残置。

### `commands/` 一括削除

- `git rm -r plugins/rite/commands/`（**42 tracked file・-25,992 行**）。28 コマンド + 各 references。
- untracked な runtime 残骸 `plugins/rite/commands/.rite-work-memory/issue-666.md`（gitignore 対象・私が作成したものでない）は削除せず残置 → 物理 dir のみ残るがリポジトリ非影響。

### Phase 6 完全性ゲート（全パス・2026-06-30、凍結4種 + untracked 除外）

1. ✅ G1 旧コロン命名 `rite:(pr|issue|wiki|skill|template):` = **0**（残 8 件は全て untracked `.claude/settings.local.json` のローカル権限エントリ＝コミット非対象）
2. ✅ G2 bare-colon 略記（sentinel 除く）= **0**
3. ✅ G3 dangling specific-file `commands/<g>/<x>.md` = **0**（残は SPEC migration anchor・`git show BASELINE:`・orphan motivation・state-read narrative 等の歴史参照のみ）
4. ✅ G4 壊れる markdown リンク `](...commands/...)` = **0**
5. ✅ G5 `commands/skills/` artifact = **0**
6. ✅ test: `hooks/tests/run-tests.sh` **80/80**・`hooks/scripts/tests/` 4/4 rc=0・`scripts/tests/run-all.sh` **73/73**
7. ✅ 全 scanner `--all`（commands/ 削除後の実 tree）= rc=0・findings=0（7 scanner とも skills/ を正しくスキャン）

### Phase 6b（release）へ持ち越す残務

- **version 0.7.0 バンプ（5 file）+ CHANGELOG（英/日）+ `/release`**（develop→main PR・タグ・GitHub Release）。坂口さんの指示待ち。
- ~~**ドキュメント構造 rewrite（6b doc）**~~ → **完了（2026-06-30）**: `CLAUDE.md` / `CONTRIBUTING.md` / `docs/SPEC.md` の ASCII アーキ図を skills/ 中心へ反転（commands/ ノード除去・skills/ を 30 スキルへ展開）。SPEC.md は併せて (a) `Command File Format` 節を `Skill File Format` へ統合し §B frontmatter ポリシー（disable-model-invocation / user-invocable）を明記、(b) 削除済み `preflight-check.sh` の専用節（hooks 節 + Features 節 + test 表行）を除去（compact 回復 = SessionStart notice + `/rite:recover` に一本化）、(c) lint scanner scope `commands/**` → `skills/**`、(d) prose（orchestrator commands → skills 等）を更新。全 3 ドキュメントで構造的 commands/ ノード 0・旧命名 0・fence 整合・dangling リンク 0 を検証。残る `commands/` 言及は migration anchor / `commands:` config key / generic「コマンド」/ `gh-cli-commands.md` filename のみ（意図的保持）。
- **未対応の既存 doc 不正確記述（移行と無関係・別途）**: `CONTRIBUTING.md` の「There is no Stop hook」注記は現状と矛盾（`stop-loop-continuation.sh` が hooks.json 登録済み）。本移行スコープ外のため未修正 → フォローアップ候補。
- **`.claude/settings.local.json`（ユーザーローカル・任意）**: stale な `Skill(rite:pr:create/review/ready)` 権限エントリ（→ `rite:pr-create`/`rite:pr-review`/`rite:ready`）。untracked のため未編集。必要なら `/config` 等で更新を案内。
- **残置した generic 例/歴史参照**: reviewer agent の placeholder `commands/foo.md` 等、SPEC/orphan-check の歴史アンカー、doc-heavy classifier の `commands/**/*.md` 除外 glob（drift-check で review/reviewers 同期・harmless）。いずれも dangling でなく意図的残置。

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
