# リファクタリング進捗まとめ（中断時点の引き継ぎ）

> 作成: 2026-06-11 / Phase 4 作業途中で中断。tool call の malformed 多発のため一旦停止。

## 全体像

cc-rite-workflow を Phase 1〜6 に分けてリファクタリング（機能削除・統合・圧縮）するプロジェクト。
全 PR は **stacked PR**（merge-base が `b904cbca`、全 phase 共通の stale base）。
各 phase は前 phase の上に 1 commit ずつ積まれている。順次マージが必要。

```
phase-3 ⊂ phase-4 ⊂ phase-5 ⊂ phase-6
```

## 完了済み

| Phase | 状態 |
|-------|------|
| Phase 1 (D-1,2,8,11) | ✅ develop にマージ済み |
| Phase 2 (D-7) | ✅ develop にマージ済み |
| Phase 3 (D-4,5,6,9) | ✅ **本セッションで rebase→review→fix→merge→cleanup 完遂** |

### Phase 3 で得た重要な教訓
- **stale base 問題**: PR 公式 diff（three-dot）は Phase 1/2 を巻き込み肥大化する。`git rebase --onto develop <前phase-tip>` で当該 phase 固有 commit のみ develop に乗せ直すと clean になる。
- **3-way merge 検証の必要性**: `git diff develop branch`（two-dot）は squash 実効差分ではない。`git merge-tree --write-tree develop HEAD` で 3-way 検証すること（Phase 3 で two-dot 誤読により false positive を出した教訓）。
- Phase 3 の follow-up（design doc / hook コメントの sprint dangling）を起票済み。Phase 6 の SPEC/design 同期で回収可能。

## 作業中（Phase 4）

**Phase 4 PR** `refactor(phase-4): reviewer 二重管理を解消し agents/ に一本化 (D-3)`
内容: `skills/reviewers/{type}.md` 13 ファイルを `agents/{type}-reviewer.md` に verbatim 統合・削除。checklist 注入を user→system prompt 化。

### 現在の branch 状態（refactor/phase-4-reviewer-consolidation）
develop の上に 3 commits（**全て push 済み**、Phase 4 PR に反映済み）:
```
5d3ce30c fix(phase-4): review.md の dangling 参照を除去        ← 最新（push 済みか要確認 ※下記）
51203a3b fix(phase-4): verbatim 統合を完成 — 参照表追補等       ← push 済み
45ab2bf2 refactor: reviewer の二重管理を解消し agents/ に一本化   ← rebase 済み・push 済み
```

> ⚠️ **要確認**: `5d3ce30c`（review.md dangling fix）は **commit は成功したが push したか不確実**（中断直前の出力が表示バグで読めなかった）。再開時にまず `git status` で `ahead of origin` を確認し、未 push なら `git push --force-with-lease origin refactor/phase-4-reviewer-consolidation` する。

### Phase 4 でやったこと
1. **rebase**: `git rebase --onto develop bcbb36c3 refactor/phase-4-reviewer-consolidation` で stale base 解消（conflict は `skills/reviewers/tech-writer.md` の modify/delete 1 件のみ → 削除採用）。3-way squash CLEAN 確認済み。
2. **1 回目レビュー（prompt-engineer）**: 要修正 6 件
   - CRITICAL: tech-writer-reviewer.md の Phase 3 fix（action lines→body）取りこぼし
   - HIGH×2: 7 reviewer の参照表脱落（verbatim 不成立）/ devops Activation scoping 脱落
   - MEDIUM×2 + LOW-MEDIUM: 3-source→2-source 移行の取りこぼし
3. **fix 1（commit 51203a3b）**: 上記 6 件を subagent 委譲で修正。7 reviewer に参照表を verbatim 追補、devops scoping 追補、tech-writer action-line fix、lint.md/review.md の 3→2、internal-consistency.md の bare 参照修正。
4. **2 回目レビュー（prompt-engineer）**: 前回 5 件は解消確認。新たに **MEDIUM 3 件**（review.md が旧ステップ4.1/4.2 削除で stranded した dangling 参照: line 908 / 1529 / 表3行）を検出。
5. **fix 2（commit 5d3ce30c）**: review.md の dangling 5 箇所を subagent 委譲で除去。`grep` で 0 件確認済み。

## Phase 4 の残タスク（再開時）

1. **5d3ce30c の push 確認**（上記 ⚠️）
2. **3 回目レビュー**（収束確認）— fix 2 が新たな問題を生んでいないか prompt-engineer で再検証。可能なら tech-writer / code-quality も起動して全体像を確認（1・2 回目は prompt-engineer のみ。malformed 多発で残り 2 reviewer 未起動）
3. 収束したら **merge**（`gh pr merge 1418 --squash --delete-branch=false`）
4. **cleanup**（develop に switch・pull、branch 削除、state クリーン。Phase 3 と同手順）

### Phase 4 で残っている既知の follow-up（scope 外と判定済み）
- `hooks/scripts/distributed-fix-drift-check.sh:43` が存在しないパス `plugins/rite/agents/tech-writer.md`（正: `tech-writer-reviewer.md`）を参照。**develop で pre-existing**（本 PR 非変更）のため scope 外 → 別 Issue 推奨。
- `skills/rite-workflow/references/comment-best-practices.md:457` の prose 参照 `tech-writer.md` も pre-existing → 別 Issue 推奨。
- `_reviewer-base.md` の link 表示テキスト `tech-writer.md`（リンク target は修正済み、表示のみズレ）→ 任意。

## 未着手（Phase 5・6）

各々 develop の上に 1 commit、stale base（要 rebase）。

| Phase | 内容 | 固有 commit |
|-------|------|------------|
| Phase 5 (D-8,10) | 安全圧縮（lint.md / getting-started.md / review.md、pinned format 不可触） | 17d00ee3 |
| Phase 6 (D-12) | SPEC/CONFIGURATION 最終同期 + dangling scan | 6cb8e8f9 |

### Phase 5/6 の進め方（Phase 3/4 と同じパターン）
各 phase で:
1. `git rebase --onto develop <前phase-tip> <branch>`
   - Phase 5: `git rebase --onto develop e6afca1a refactor/phase-5-file-compression`（※ Phase 4 マージ後は前phase-tip がマージで変わるため、実際は **Phase 4 マージ後の develop に対して** rebase。前phase-tip は phase-5 固有 commit の親 = 17d00ee3^ を指定）
   - Phase 6: 同様に Phase 5 マージ後の develop へ
2. conflict 解決 → `git merge-tree` で 3-way CLEAN 確認
3. `git push --force-with-lease`
4. `/rite:pr:review`（3 reviewer 並列）
5. fix（subagent 委譲が有効）→ commit → push
6. 再レビューで収束確認
7. `gh pr merge --squash` → cleanup
8. develop pull → 次 phase

> ⚠️ **stacked rebase の前phase-tip 指定に注意**: Phase 4 を rebase した時の `bcbb36c3` は「phase-3 の元 feature tip」だった。Phase 5 では「phase-4 の元 feature tip = `e6afca1a`」を `--onto develop` の base に指定する（develop にマージされた squash commit ではなく、**branch の元 stacked 履歴上の親**を指す点に注意）。`git log --oneline <前phase固有commit>^1` で親を確認してから rebase すること。

### Phase 6 の特記
- SPEC dangling 除去は Phase 3 の rebase で一部すでに develop 側に反映済みの可能性 → 実効差分が縮小、no-op conflict がありうる。
- follow-up（design doc / hook の sprint dangling）が Phase 6 で回収されるか確認。

## 全 Phase 完了後の最終検証（予定）

develop に Phase 4-6 が入った後:
```bash
bash plugins/rite/hooks/tests/run-tests.sh                              # 期待 68/68
bash plugins/rite/hooks/scripts/orphan-reference-check.sh --all         # orphans=0
bash plugins/rite/hooks/scripts/distributed-fix-drift-check.sh --all
bash plugins/rite/hooks/scripts/review-schema-version-check.sh
bash plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh --all
```
+ `/rite:lint` + 削除機能の残骸 grep（notification/sprint/recall/tdd/contextual + reviewer skills）+ follow-up（sprint dangling）状態確認 + develop の commit 履歴確認。

## このセッションの問題点（申し送り）

- **tool call の malformed が頻発**（Phase 4 着手以降）。コマンド自体は実行されるが、応答に付随する tool call の parse が時々失敗する。原因は harness 側と推測。**対策**: 1 応答 1 tool call、出力はシンプルに、長いナレーションを避ける。大規模 edit は subagent 委譲が有効（malformed を回避できた）。
- **bash 出力の表示崩れ**: `git status`/`reflog` 等で出力が重複・混入することがある。`> /tmp/xxx.txt 2>&1 && cat` で file 経由にすると比較的安定。
- **reviewer は prompt-engineer のみ実施**: Phase 4 は malformed 多発で tech-writer/code-quality を並列起動できていない。再開時に余裕があれば 3 reviewer で再確認推奨。

## ドッグフーディング注意（CLAUDE.md より）
- このリポジトリは rite workflow 自体を rite workflow で開発。`commands/`/`skills/`/`agents/` の変更は次回呼び出しから反映。Phase 4 は **reviewer 定義そのものを変更**するため、マージ後は `/rite:pr:review` の reviewer 挙動が変わる（checklist が system prompt 化）。Phase 5/6 のレビューは新 reviewer 構成で実行される。
