# Edge Cases — `/rite:issue:create` Workflow

> **SoT scope**: `/rite:issue:create` workflow の short-input handling 仕様。`create.md` ステップ 1.3 (入力から What/Why/Where 抽出) が consumer。

## EDGE-4: Short Input Handling

`create.md` ステップ 1.3 の extraction を実行する前に input 長をチェックする。

**Step 1**: Detect short input

User input (Skill argument の `args`) を whitespace stripping した後の Unicode 文字数を数える。10 文字未満は short input として扱う。

例: "Fix" (3 chars), "Bug" (3 chars), "Update" (6 chars), "リファクタ" (5 chars), "修正" (2 chars)

**Step 2**: Request supplementary information via AskUserQuestion

Language template は `create.md` ステップ 1.2 言語設定 (`rite-config.yml` の `language: ja | en | auto`、`auto` は CJK 検出) に従う。

**Japanese** (`ja` または `auto` で CJK 検出):
```
質問: 入力が短すぎるため、もう少し詳しく教えてください。何を達成したいですか？

オプション:
- 詳細を入力する
- 既存の Issue を参照する（Issue 番号を入力）
```

**English** (`en` または `auto` で non-CJK):
```
Question: The input is too short. Could you provide more details? What do you want to achieve?

Options:
- Provide details
- Reference an existing Issue (enter Issue number)
```

**Step 3**: Process the user's selection

| Selection | Action |
|-----------|--------|
| **詳細を入力する** / **Provide details** | 補足入力を新たな user input として ステップ 1.3 の extraction を再開 |
| **既存の Issue を参照する** / **Reference an existing Issue** | Step 3a へ |

**Step 3a**: Reference an existing Issue

1. Issue 番号を AskUserQuestion (free-text input) で受け取る
2. `gh issue view {issue_number} --json number,title,state,body --jq '{number,title,state}'` で存在検証
3. Issue が存在しない (404) → エラー表示し再入力を促す
4. Issue が CLOSED → 言語別オプション提示: "参考として新規 Issue 作成" / "Issue 番号を再入力"。参考選択なら `gh issue view {issue_number} --json body --jq '.body'` で body を取得し context として使用
5. Issue が OPEN → 言語別オプション提示: "context として新規 Issue 作成" / "この Issue で /rite:pr:open を実行 (create 中止)"。start 選択なら create を終了して `参照先の Issue に対して /rite:pr:open #{issue_number} を実行してください。` (英語は equivalent) を出力
