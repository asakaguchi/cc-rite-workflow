# AI Coding Principles Reference

A collection of principles to avoid common failure patterns in AI coding agents.
Structured for rite workflow based on Andrej Karpathy's "Issues with AI Coding".
The `knowledge_routing` principle additionally draws on t-wada's four quadrants of where knowledge lives: code = How, test code = What, commit log = Why, code comments = Why not.

## Principle List

| Principle ID | Principle Name | Applicable Phase |
|-------------|---------------|-----------------|
| `assumption_surfacing` | Surface Assumptions | Phase 3, 5.1 |
| `confusion_management` | Manage Confusion/Contradictions | Phase 1, 3 |
| `push_back_when_warranted` | Push Back When Warranted | PR Review |
| `simplicity_enforcement` | Enforce Simplicity | Phase 5.1 |
| `scope_discipline` | Scope Discipline | Phase 5.1 |
| `dead_code_hygiene` | Dead Code Hygiene | Phase 5.1 |
| `inline_planning` | Present Plan Before Implementation | Phase 3 |
| `issue_accountability` | Accountability for Discovered Issues | All Phases |
| `no_unnecessary_fallback` | No Unnecessary Fallback | Phase 5.1, PR Review |
| `reference_discovery` | Discover Reference Implementations | Phase 3 |
| `question_self_check` | Self-Check Before Asking | All Phases |
| `documentation_consistency` | Sync Documentation with Specification Changes | Phase 5.1 |
| `knowledge_routing` | Route Knowledge to Its Durable Medium | Phase 5.1, PR Review |

---

## Principle Details

### assumption_surfacing (Surface Assumptions)

**Summary**: Surface assumptions explicitly and confirm before proceeding.

**Failure Patterns**:
- Implementing ambiguous requirements based on own interpretation
- Guessing user intent and going off track
- Proceeding with "probably this" assumptions

**Rules**:
1. When requirements are ambiguous, state interpretation explicitly before implementing
2. When multiple interpretations are possible, present the options
3. Confirm important design decisions in advance

**Where to Apply**:
- Phase 3 (Implementation Plan): State assumptions when creating plans
- Phase 5.1 (Implementation): Record decisions made during implementation

**Example**:
```text
この Issue の「認証機能の追加」について、以下の解釈で進めます:
- 方式: JWT トークン認証
- スコープ: API エンドポイントのみ
- 既存機能への影響: 認証ミドルウェアを追加

この解釈で進めてよいですか？
```

---

### confusion_management (Manage Confusion/Contradictions)

**Summary**: Stop and confirm when contradictions or unknowns are detected.

**Failure Patterns**:
- Implementing contradictory instructions by choosing one side
- Ignoring unknowns and proceeding with guesses
- Swallowing errors and continuing

**Rules**:
1. Report contradictions immediately upon detection
2. Do not proceed with implementation until resolved
3. Clarify ambiguities before moving forward

**Where to Apply**:
- Phase 1 (Issue Quality Check): Stop when contradictions are detected
- Phase 3 (Implementation Plan): Identify unknowns

**Example**:
```text
Issue の内容に矛盾があります:
- 「パフォーマンスを最優先」と記載
- 一方で「すべてのエラーを詳細ログ出力」も要求

これらは相反する可能性があります。どちらを優先しますか？
```

---

### push_back_when_warranted (Push Back When Warranted)

**Summary**: Push back when problems are found.

**Failure Patterns**:
- Following obviously problematic designs without objection
- Not pointing out security risks
- Silently accepting technical debt

**Rules**:
1. Always point out security risks
2. Suggest alternatives for anti-patterns
3. Clearly communicate technical concerns

**Where to Apply**:
- PR Review: Flagging problematic implementations

**Example**:
```text
この実装にはセキュリティ上の懸念があります:
- SQL クエリに直接ユーザー入力を使用（SQLインジェクションリスク）

代替案: プリペアドステートメントを使用
```

---

### simplicity_enforcement (Enforce Simplicity)

**Summary**: Avoid excessive complexity.

**Failure Patterns**:
- Adding unnecessary abstraction layers
- Creating unused extension points
- Over-applying design patterns

**Rules**:
1. YAGNI (You Aren't Gonna Need It) principle
2. Question more than 3 levels of indirection
3. Avoid "for the future" implementations

**Where to Apply**:
- Phase 5.1 (Implementation): Simplicity check during coding

**Checklist**:
- [ ] Is this abstraction needed right now?
- [ ] Is this design pattern excessive?
- [ ] Is there a simpler solution?

---

### scope_discipline (Scope Discipline)

**Summary**: Only change what was requested.

**Failure Patterns**:
- Opportunistic refactoring
- "Improving" unrelated files
- Adding features outside scope

**Rules**:
1. Only change what is described in the Issue
2. Propose out-of-scope improvements as separate Issues
3. Resist the temptation of "while I'm at it"

**Where to Apply**:
- Phase 5.1 (Implementation): Restricting change scope

**Example**:
```text
実装中に以下の改善点を発見しました:
- utils.ts の関数名が不適切

これは今回のスコープ外のため、別 Issue として登録しますか？
```

---

### dead_code_hygiene (Dead Code Hygiene)

**Summary**: Identify dead code explicitly and confirm removal.

**Failure Patterns**:
- Leaving unused code
- Commenting out code as "insurance"
- Keeping meaningless backward-compatibility code

**Rules**:
1. Report unused code as removal candidates
2. Delete rather than comment out
3. Confirm before deletion

**Where to Apply**:
- Phase 5.1 (Implementation): Check for dead code after refactoring

**Example**:
```text
リファクタリング後、以下のコードが未使用になりました:
- `oldHandler()` 関数
- `legacyConfig` 変数

これらを削除してよいですか？
```

---

### inline_planning (Present Plan Before Implementation)

**Summary**: Present plan before implementing and get confirmation.

**Failure Patterns**:
- Starting implementation without a plan
- Implementing parts without seeing the whole picture
- Frequent rework due to lack of planning

**Rules**:
1. State plan explicitly before implementing
2. List target files in advance
3. Get approval before starting implementation

**Where to Apply**:
- Phase 3 (Implementation Plan): Present implementation plan upfront

**Example**:
```text
## 実装計画

### 変更対象ファイル
- src/auth.ts: 認証ロジックの追加
- src/middleware.ts: 認証ミドルウェアの追加

### 参考実装
| 参考ファイル | 参考理由 |
|-------------|---------|
| src/session.ts | 同様の認証状態管理パターンを踏襲 |

### 実装ステップ
1. 認証ロジックの実装
2. ミドルウェアの統合
3. テストの追加

### 受入基準マッピング
- AC1 → step 1
- AC2 → step 2

### 注意点
- 既存セッション管理との整合性に注意

この計画で進めますか？
```

**Note**: This example mirrors the actual plan template. See [`skills/open/SKILL.md`](../../../skills/open/SKILL.md) ステップ 3.3 (実装計画生成) for the canonical template definition.

---

### issue_accountability (Accountability for Discovered Issues)

**Summary**: Always address discovered issues; never dismiss as "out of scope".

**Failure Patterns**:
- Ignoring issues as "not my change"
- Skipping action as "existing problem"
- Dismissing problems as "out of scope"
- Completing without addressing items as "outside current scope"

**Rules**:
1. Always take some action on discovered problems/issues
2. "Not my change" or "existing problem" is not a valid reason to ignore
3. If outside the current Issue scope, **always create a separate Issue** to track it
4. When creating separate Issues, add to Projects with appropriate labels

**Where to Apply**:
- All phases: Immediate action when problems are discovered
- lint/test execution: Create Issues for out-of-scope errors
- PR Review: Genuine response to review comments
- Before PR creation: Check for unaddressed issues

**Example**:
```text
lint で以下の警告を検出しました:
- src/utils.ts:42 - 未使用の変数 'oldConfig'

この警告は今回の変更範囲外ですが、発見した問題には対応が必要です。

対応:
- 別 Issue #XXX を作成しました
- ラベル: lint, tech-debt
- Status: Todo
```

**Prohibited judgments**:
```text
❌ 「これは私の変更とは関係ない既存の問題です」
❌ 「このディレクトリは今回の修正対象外です」
❌ 「このエラーは無視して進めます」
```

**Correct responses**:
```text
✅ 「範囲外の問題を検出しました。別 Issue として登録します」
✅ 「既存のエラーですが、Issue #XXX として追跡します」
✅ 「対象外の警告を Issue 化しました: #YYY」
```

---

### no_unnecessary_fallback (No Unnecessary Fallback)

**Summary**: Don't add fallbacks that hide failure causes. Distinguish "expected absence" from "unexpected failure".

**Failure Patterns**:
- Silent fallback to a default value when the operation should have succeeded
- Multi-level fallback chains where scope silently changes at each level
- catch-all that swallows errors and continues as if nothing happened
- Fallback that makes bugs "go away" instead of surfacing them

**Rules**:
1. **"Expected absence"** (config not set, optional feature disabled) → Fallback is OK, but always with a visible warning
2. **"Unexpected failure"** (API error, file not found when it should exist) → Error, not fallback
3. **Visibility criterion**: Can the user see what happened and why? If the fallback hides the cause, it's unnecessary
4. Prefer failing loudly over degrading silently — bugs caught early are cheaper to fix

**Where to Apply**:
- Phase 5.1 (Implementation): Check for unnecessary fallbacks in new code
- PR Review: Flag fallback chains that hide root causes

**Example**:
```text
❌ Bad: Silent multi-level fallback
git symbolic-ref ... || git remote show origin ... || echo "main"
→ Silently falls to "main", hiding the real problem (misconfigured remote)

✅ Good: Explicit error with guidance
git symbolic-ref ... || {
 echo "エラー: デフォルトブランチを検出できません"
 echo "rite-config.yml で branch.base を設定してください"
 exit 1
}

❌ Bad: Scope silently changes
git diff origin/develop...HEAD || git diff HEAD || lint entire project
→ User thinks they're linting changed files, but actually linting everything

✅ Good: Fail and explain
git diff origin/develop...HEAD || git diff develop...HEAD || {
 echo "エラー: 変更ファイルを特定できません"
 echo "明示的にパスを指定してください: /rite:lint <path>"
 exit 1
}
```

**Judgment guide**:

| Situation | Correct Response | Reason |
|-----------|-----------------|--------|
| Config value not set | Fallback with warning | Expected absence — user chose not to set it |
| API call fails | Error | Unexpected failure — something is wrong |
| File not found (should exist) | Error | Unexpected failure — indicates a bug or misconfiguration |
| Optional feature unavailable | Skip with notice | Expected absence — feature is optional |
| Network error during branch detection | Error | Unexpected failure — don't guess the branch name |

---

### reference_discovery (Discover Reference Implementations)

**Summary**: Discover existing reference implementations in the same directory/pattern as change targets.

**Failure Patterns**:
- Implementing without checking existing conventions in the same directory
- Creating inconsistent coding styles across similar files
- Ignoring established patterns in neighbor files

**Rules**:
1. Before implementing, search for files in the same directory with the same extension
2. Identify naming patterns (e.g., `*-handler.ts` → other `*-handler.ts` files)
3. Check for corresponding test/implementation file pairs
4. Record discovered references in the implementation plan
5. Follow the structure and conventions of reference files during implementation

**Where to Apply**:
- Phase 3 (Implementation Plan): Discover references during plan generation

**Discovery Methods**:

| Method | Pattern | Example |
|--------|---------|---------|
| Same directory | Same extension files in target directory | `skills/issue-create/references/*.md` |
| Name pattern | Files matching `*-{suffix}.{ext}` | `*-handler.ts`, `*-service.ts` |
| Test correspondence | Test file ↔ implementation file | `foo.ts` ↔ `foo.test.ts` |

**Example**:
```text
## 参考実装

| 参考ファイル | 参考理由 |
|-------------|---------|
| skills/issue-create/SKILL.md | 同ディレクトリの既存コマンド定義 |
| skills/issue-edit/SKILL.md | 類似の Issue 操作コマンド |

### 参考にすべきパターン
- Phase 番号のフォーマット: `### 3.1`, `### 3.2` 形式
- フロントマター: `description` フィールドは日本語
- セクション構成: Module reference → Steps → Notes
```

**When No References Found**:
```text
参考実装: なし（新規ディレクトリまたは初めてのファイルパターン）
→ プロジェクト全体の慣習に従ってください
```

---

### documentation_consistency (Sync Documentation with Specification Changes)

**Summary**: When an implementation changes user-visible specification (commands, config keys, file paths, public API, workflow phases, hook names, etc.), update related documentation in the same PR. Detect drift before commit, not at PR review time.

**Failure Patterns**:
- Renaming a command or config key in code without updating README / docs / CLAUDE.md
- Adding a new workflow phase to `skills/open/SKILL.md` / `skills/iterate/SKILL.md` 等 without updating the corresponding skill / reference docs
- Removing a feature from code while marketing copy in README still describes it
- Deferring documentation drift to a separate "follow-up" Issue that never gets done
- Relying on the tech-writer reviewer at PR review time to catch drift, causing avoidable review round-trips

**Rules**:
1. Before committing, identify user-facing identifiers introduced/changed/removed by the diff
2. Search the entire repository (`*.md`, `README*`, `CLAUDE.md`, `docs/`, `plugins/rite/**/*.md`) for those identifiers
3. Update stale documentation in the **same branch** as the implementation — never defer
4. Do **not** ask the user for permission via `AskUserQuestion`; documentation sync is mandatory when drift is detected
5. Do **not** create a separate Issue for the drift (this contradicts the same-PR rule and `issue_accountability` for in-scope work)
6. Skip when the diff is internals-only, documentation-only, or test-only

**Where to Apply**:
- Phase 5.1 (Implementation): Run as the dedicated `5.1.0.7 Documentation Impact Investigation` step before `5.1.1` commit
- This complements (does not replace) the tech-writer reviewer at PR review time

**Example**:

```text
実装で /rite:issue-resume コマンドを /rite:recover にリネームした

ドキュメント影響調査:
- Grep "/rite:issue-resume" → README.md L142, docs/getting-started.md L88, plugins/rite/skills/setup/SKILL.md L23
- 全 3 ファイルを Edit ツールで /rite:recover に更新
- 同じブランチでステージし、実装と同じコミットに含める
```

**Anti-pattern**:

```text
❌ 「ドキュメント追従は別 Issue として後で対応します」
❌ 「README の記述が古いですが、レビュアーが指摘してくれるはずです」
❌ AskUserQuestion: 「README を更新しますか？」
```

---

### question_self_check (Self-Check Before Asking)

**Summary**: Self-check whether the question is truly necessary before asking.

**Details**: See the `question_self_check` section in [common-principles.md](./common-principles.md).

**Where to Apply**:
- All phases: Before asking any question or requesting confirmation

---

### knowledge_routing (Route Knowledge to Its Durable Medium)

**Summary**: Every implementation produces four kinds of knowledge, and each has one medium where it survives. The medium's properties — lifespan, visibility, verifiability — decide the routing. Knowledge placed in the wrong medium rots, goes unread, or becomes a lie. For an LLM agent whose session memory vanishes, these four channels are the only persistent memory, so routing them correctly is a first-class discipline. Each channel's detailed rules live in its own SoT; this principle only routes.

**Four Channels**:

| Knowledge | Medium | Why this medium |
|-----------|--------|-----------------|
| How (current behavior) | The code itself (naming, structure) | Code is executed, so it is always true — it cannot drift from the running reality |
| What (specification, behavior) | Test code (test name + assertion) | Tests are executable specification — the name states What, the assertion proves it |
| Why (motive at change time) | Commit message body | The commit is the immutable record of the context at the moment of change |
| Why not (rejected alternative) — and the Why that must stay beside the code (hidden constraint, invariant, workaround) | Code comments | The comment is the only document that stays in the same place as the code it guards |

**Failure Patterns**:
- A comment describes How the code works (comment rot — the comment lies as soon as the code changes; promote it to naming instead)
- A comment narrates the change history / motive (journal comment — that belongs in the commit message)
- A commit body records only What changed, with no Why (the rationale is lost at the next read)
- A rejected alternative lives only in the commit, leaving no trace on the code side (a future reader "improves" the code straight back into the rejected shape)
- A test name describes How (an implementation detail), so it becomes a lie the moment the implementation changes

**Routing flowchart** (when unsure where to record a finding):
- Current behavior of the code → let the code say it (naming, structure)
- Specification or behavior → a test, with the test name written as a specification sentence
- Motive / choice / rejected alternative → if a future reader would be tempted to rewrite the code back to the naive shape, a comment (Why not); otherwise the commit message
- Hidden constraint / invariant / workaround → a comment (Why)

**Rules**:
1. Route each kind of knowledge to its one channel; do not record the same knowledge in two channels.
2. Defer each channel's detailed rules to its SoT — do not duplicate them here: comments → [comment-best-practices.md](./comment-best-practices.md), tests → [test-reviewer.md](../../../agents/test-reviewer.md). For commits, record the "why" in the commit message body (free-form prose).
3. Transport misplaced knowledge to its correct medium rather than leaving it: change history found in a comment → move it to the commit; How found in a comment → promote it to naming and delete the comment.

**Where to Apply**:
- Phase 5.1 (Implementation): Route each finding to its channel while coding
- PR Review: Flag misplaced knowledge with this principle's ID as the rationale

---

## Markdown Authoring Conventions

> **Note**: このセクションは Markdown 記述規約であり、上記の `## Principle List` テーブルに登録されているコード規約 (AI Coding Principles) とは別軸のため、独立セクションとして配置している。`## Related` からも参照される。

These conventions apply to authoring Markdown files loaded by the Claude Code Skill loader. Certain inline-code patterns may interact with the loader's bash interpretation path and cause prose to be executed as shell commands.

**Applicable file paths** (Skill loader 経路にある全カテゴリ):

- `plugins/rite/skills/**/*.md`
- `plugins/rite/agents/**/*.md`
- `plugins/rite/references/**/*.md`
- `plugins/rite/templates/**/*.md`

### bash negation operator inline code convention

**Summary**: When referencing the bash negation operator in Markdown inline code, never let a bare bang character (U+0021) sit immediately before the closing backtick of an inline code span. Always include a command, argument, or ellipsis token after the bang.

**Failure pattern** (observed incident): The file `skills/fix/SKILL.md` once contained 5 occurrences of bang-backtick adjacency (a bang character placed directly next to the closing backtick of an inline code span, with no intervening whitespace or token). The Skill loader mis-executed surrounding documentation text as shell commands at runtime — a silent failure that was only caught through careful diffing. Replacing each occurrence with the trailing-token form (`if ! cmd` / `if ! ...`) resolved the failure.

> **Note on mechanism**: The exact trigger (bash history expansion vs. the Skill loader's internal quoting/parsing processing) is **not fully characterized**. Empirically, bang-backtick adjacency is known to trigger failures in some files and contexts but long-standing occurrences exist in other files (e.g., `plugins/rite/references/gh-cli-patterns.md`) without reported Skill-load failures. See the `gh-cli-patterns.md` "Shell Escaping Notes" section for related unresolved areas. Treat this rule as a **defensive convention grounded in the observed incident above**, not as a statement of a fully understood mechanism.

**NG / OK examples** (the NG example is inside a fenced `text` block per Rule 3 below so it does not itself violate the convention):

```text
NG pattern (demonstration — do not write this in prose):
 backtick + bang + closing backtick (bang-backtick adjacency, no trailing token)

OK patterns:
 `if ! cmd`
 `if ! ...`
 `if ! command -v foo`
```

**Rules**:
1. Do not write bang-backtick adjacency in Markdown prose (outside fenced code blocks) in any file loaded by the Skill loader.
2. Always include a trailing token: use `if ! cmd` (specific command) or `if ! ...` (ellipsis placeholder) instead.
3. When the NG pattern must itself be quoted for documentation, enclose it in a fenced code block tagged `text`. Fenced blocks are not subject to inline-code parsing by the loader.

**Application scope** (silent retroactive sweep 回避): 本 convention は**新規編集時に目視で発見したもののみ**を対象とする。既存ファイルへの retroactive 一括書き換えは行わない — 長期間存在する既存箇所で Skill ロード失敗が観測されておらず、真のトリガ条件が未だ empirically 特定されていないため、一括書き換えは不要な変更を広範に生むリスクがある。真のトリガ条件の dry-run 実証調査は別 Issue で追跡する。

---

### operational bash block heaviness convention

**Summary**: command / reference 本文の operational bash ブロックは軽量に保つ — **1 ブロック 1 目的・<= 25 行を目安**とし、python inline (`python3 -c`)・入れ子 `$()`・複数 heredoc を 1 ブロックに密集させない。tmpfile や中間変数を process 境界を跨いで渡す必要がある場合は、1 本の Bash invocation に詰め込まず `hooks/` または `scripts/` の helper script へ切り出す。

**Failure pattern** (observed incident): 過去に複数のコマンド本文 (`pr/ready.md` / `pr/fix.md` / `pr/pr-review.md` 等) が 40〜360 行規模の operational bash ブロックを抱えており、各々「⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること」と注記した上で `python3 -c` heredoc・多引数 `jq -n`・入れ子 `$()`・`trap` + `mktemp` を密集させていた。Claude のツール呼び出し解析がこの巨大ブロックで malform し、**エラーすら出さず無言でターンが終了（停止）する**事象が `/rite:ready` 実行中および scout 1 行で計 3 回以上観測された。ブロックを phase ごとに分割する／重いロジックを helper script へ切り出して本文を数行の呼び出しにする、のいずれかで停止は解消した。

**Rules**:
1. 1 ブロック = 1 目的。operational bash ブロックは <= 25 行を目安とする。
2. command 本文 bash に `python3 -c` heredoc を埋め込まない。テキスト変換は helper (`*.py` を `*.sh` wrapper 経由で呼ぶ) に移す — 先例: `issue-comment-wm-update.py` / `issue-comment-wm-sync.sh`。
3. 入れ子 `$()` (`$(cmd "$(jq -n ...)")` 等) を避ける。pipe (`jq -n ... | cmd`) もしくは stdin / tmpfile を読む helper を優先する。
4. 1 ブロック内の複数 heredoc を避ける。file body が必要なら Write tool で tmpfile に書き出し、helper には `--content-file <tmp>` / `--body-file <tmp>` で渡す。
5. 値を process 境界を跨いで渡す必要があるときは helper へ切り出す (work-memory / state 系は `hooks/`、issue / projects 系は `scripts/`)。その際**既存のワークフロー契約 (sentinel emit / non-blocking / trap cleanup) を verbatim で引き継ぐ**こと。
6. `gh {pr,issue} create` の `--title` に長文 / 特殊文字（全角記号・`≠`・括弧・コロン等）の literal を**インライン展開しない**。title を **Write tool** でファイル化して bash で変数に読み込む（`pr_title=$(cat title.txt)` → `--title "$pr_title"`）か、helper の `--arg title` 経由で渡す。`gh` に `--title-file` は無い（body の `--body-file` と非対称）ため「変数経由」が canonical。先例: `skills/pr-create/SKILL.md` の pr_title.txt 変数経由パターン / `skills/issue-create/SKILL.md` の decompose path（`gh {pr,issue} create` のインライン特殊文字 title が malformed tool-call の dominant trigger だった）。

**Precedents**: `projects-status-update.sh` / `local-wm-update.sh` / `issue-body-safe-update.sh` / `issue-comment-wm-sync.sh` / `create-issue-with-projects.sh` — 重い操作を positional-JSON または stdin 入力 + tmpfile body file で helper に委譲済の前例。

**Where to Apply**:
- `plugins/rite/skills/**/*.md` の operational bash ブロックを新規記述 / 編集するとき。

**Mechanical enforcement**: 上記 Rules は `/rite:lint` Phase 3.5 (`hooks/scripts/bash-heaviness-check.sh`) が `plugins/rite/skills/**/*.md` を走査して非ブロッキング warning として機械的に surface する (`[lint:success]` は不変)。各 bash ブロックを 4 つの heaviness シグナル (+ standalone 検出 `inline-gh-create-title`) で評価し、これは Rules と対応する:

| シグナル | 判定 | 対応 Rule |
|---------|------|----------|
| `python-inline` | `python3 -c` / python heredoc を含む | Rule 2 |
| `nested-cmdsub` | 入れ子 `$( … $( … )`（同一行） | Rule 3 |
| `multi-heredoc` | heredoc が 2 つ以上 | Rule 4 |
| `long-block` | ブロック本文が >= 25 行 | Rule 1 |
| `inline-gh-create-title` | `gh {pr,issue} create` 行に literal な `--title "…"` を inline（`--title "$var"` は対象外） | Rule 6 |

**2 シグナル以上**該当したブロックのみ flag する (single signal — 単発の helper 呼び出し + 1 個の JSON heredoc、または 1 個の長文テンプレート heredoc — は誤検知を避けるため flag しない)。heredoc 本文はデータ扱いで python-inline / nested-cmdsub の評価対象外。意図的・レビュー済の重いブロックは行内 `drift-check-ignore` marker で除外できる。既存の重いブロックの helper 切り出しは段階的 cleanup であり、本 guard は awareness のための warning に留める。

**例外: `inline-gh-create-title` は単独でも flag する**。これは複数シグナルの密集（heaviness）ではなく、単一行でも malform を誘発する高確度の独立パターンのため、2-signal モデルとは別に扱う。example / template の title は plain ` ``` ` fence（` ```bash ` 以外は走査対象外）や heredoc 本文（データ扱い）に置くことで誤検知を避ける。`drift-check-ignore` marker による除外は他シグナルと同様に効く。

---

## Phase Checklists

### All Phases (Common)

- [ ] `issue_accountability`: Are any discovered problems being ignored?
- [ ] `question_self_check`: Did you self-check before asking? (Is the answer already in the request? Is it obvious?)

### Phase 3 (Implementation Plan)

- [ ] `assumption_surfacing`: Are assumptions stated explicitly?
- [ ] `confusion_management`: Are there contradictions or unknowns?
- [ ] `inline_planning`: Is the plan presented?
- [ ] `reference_discovery`: Are reference implementations identified?

### Phase 5.1 (Implementation)

- [ ] `simplicity_enforcement`: Is there excessive complexity?
- [ ] `scope_discipline`: Are there out-of-scope changes?
- [ ] `dead_code_hygiene`: Is dead code being left behind?
- [ ] `no_unnecessary_fallback`: Are there fallbacks that hide failure causes?
- [ ] `issue_accountability`: Are any discovered problems being ignored?
- [ ] `documentation_consistency`: Has related documentation been updated for any user-visible spec changes?
- [ ] `knowledge_routing`: Is each finding routed to its durable medium (How → code, What → tests, Why → commit, Why not → comments)?

### PR Review

- [ ] `push_back_when_warranted`: Are problems being flagged?
- [ ] `simplicity_enforcement`: Is there excessive complexity?
- [ ] `scope_discipline`: Are there out-of-scope changes?
- [ ] `no_unnecessary_fallback`: Are there fallbacks that hide failure causes?
- [ ] `issue_accountability`: Are review comments being addressed genuinely?
- [ ] `knowledge_routing`: Is any knowledge in the wrong medium (How in a comment, change history in a comment, Why missing from the commit body, a test name describing How)?

### Before PR Creation

- [ ] `issue_accountability`: Are there unaddressed problems or review comments?
- [ ] `issue_accountability`: Are out-of-scope problems tracked as separate Issues?

**Reference**: The `/rite:pr-create` Phase 2.5 ([create.md](../../../skills/pr-create/SKILL.md), "2.5 Unaddressed Issues Check" section) implements the unaddressed issues check.

---

## Related

- [SKILL.md](../SKILL.md) - Principle summary
- [Phase Mapping](./phase-mapping.md) - Phase details
- [PR Open Workflow](../../../skills/open/SKILL.md) - Issue → branch → 実装 → lint → draft PR
- [PR Create Command](../../../skills/pr-create/SKILL.md) - Unaddressed issues check before PR creation (Phase 2.5)
- [PR Review](../../../skills/pr-review/SKILL.md) - Multi-reviewer PR review workflow
- [Markdown Authoring Conventions](#markdown-authoring-conventions) - Skill loader に load される Markdown ファイルの記述規約 (bash negation operator inline code convention / operational bash block heaviness convention)
- [gh-cli-patterns.md](../../../references/gh-cli-patterns.md) - Related bang character (U+0021) handling in bash command contexts (Shell Escaping Notes)
- [graphql-helpers.md](../../../references/graphql-helpers.md) - Related bang character handling in GraphQL query / jq contexts (History Expansion and Special Character Prevention)
- [gh-cli-error-catalog.md](../../../references/gh-cli-error-catalog.md) - Related bang character handling error catalog (Category 6)
