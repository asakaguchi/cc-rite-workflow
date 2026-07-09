# Review SKILL Design Rationale

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md).
> 本ファイルは `skills/pr-review/SKILL.md` 本体から退避した**設計理由 (Why)** の受け皿。実行手順・分岐表・sentinel 表・
> エラー処理指示・出力テンプレートは SKILL.md 本体または [integrated-report-templates.md](integrated-report-templates.md)
> に残る。本体の該当箇所には `rationale: references/design-rationale.md#<anchor>` 形式のポインタがあり、逆引きできる。
> ここに書いてよいのは「なぜこの実装形なのか」「変更するなら何が壊れるか」の説明のみで、手順そのものを書いてはならない。

## argument-parsing-notes

ステップ 1.0 統合 bash block の設計理由。

- **bash 4+ compat guard**: `mapfile` builtin は bash 4.0 で導入されたため、bash 3.2 (macOS default) ではステップ 1.2.7 の `mapfile -t changed_file_paths < "$gh_files_stdout"` が `command not found` で silent 失敗する。guard で fail-fast させる。Source: GNU Bash 4.0 NEWS (https://tiswww.case.edu/php/chet/bash/NEWS)
- **config 読取を単一 awk に統合した理由 (C-2)**: `sed | awk | sed | sed | tr | tr` の 6 段 pipeline は pipefail 下で SIGPIPE rc=141 を起こし、fallback branch が config 値を silent に false へ上書きする latent regression を生む。単一 awk はファイルを直接読むため上流コマンドが存在せず、SIGPIPE 経路自体が消える。awk 終了コードは file IO / binary error 以外で 0 を返すため `if ! ...` で捕捉可能。Source: GNU bash manual — Pipelines / POSIX awk exit semantics

## doc-heavy-detection-notes

ステップ 1.2.7 Doc-Heavy PR Detection の設計理由。

- **変数名と config キー名の prefix 非対称**: lines 方式は変数 `doc_lines_ratio` / config `lines_ratio_threshold` で prefix 統一だが、count 方式は変数 `doc_files_count_ratio` / config `count_ratio_threshold` で prefix が異なる。config 側に "files_" を含めなかったのは、4 語の `files_count_ratio_threshold` より短い 3 語を優先したため。変数名側は計算対象 (file 数 vs 行数) を明示するため "files_count" を保持している。計算対象は疑似コードで明示されているので drift リスクは低い。
- **Self-only judgment (`all_files_excluded`) を明示フラグにする理由**: 「分子から除外、分母には含める」方式では rite plugin self-only PR でも数学的には doc_lines == 0 (= ratio 0) になり「ratio 未満」と区別不能になるため、明示的なフラグで補完する。疑似コード内の exclusion patterns の prefix `plugins/rite/` は bash 実装 (`[[ "$f" == plugins/rite/* ]]`) と同じ prefix で書く必要がある (汎用 repo で同名 dir を持つ場合の silent misclassification 防止)。anchor 参照 (`# === all_files_excluded bash impl ===`) は drift しやすいハードコード行番号を避けるための措置。
- **2 情報源の責務分離**: ratio 計算 (`doc_lines` / `doc_files_count` 等) は**ステップ 1.1 の `files` 配列** (context 保持データ) を再利用し、`gh pr view --json files` の再呼び出しは `all_files_excluded` 判定で必要な「path の bash 配列」抽出専用とする。ステップ 1.2.6 Note の「separate API call は不要」原則は ratio 計算に対する宣言であり矛盾しない。再呼び出しの正当化: コンテキスト保持データを bash 配列に再 hydration する仕組みは fragile (改行/特殊文字エスケープ + Claude context 変数が bash session に直接渡らない構造) で、silent failure リスク (未定義変数 → 空配列 → false positive) を排除できる。コストはネットワーク 1 往復のみ。
- **`case` パターンの glob**: bash の filename expansion ではなく case statement の pattern matching で評価され、POSIX 仕様上 `*` は `/` を含む任意文字列にマッチする。`commands/*.md` 1 行で `commands/foo.md` / `commands/sub/foo.md` / `commands/a/b/c/foo.md` をすべてカバーする (実機検証: `case "skills/sub/sub2/foo.md" in skills/*.md) MATCH ;; esac` → MATCH)。Source: POSIX shell pattern matching (IEEE Std 1003.1)。bash 4+ では `shopt -s globstar` 後に `**/*.md` glob も利用可能だが、互換性のため case 文形式を採用。
- **`doc_file_patterns` 疑似コード (`i18n/**/*.md, i18n/**/*.mdx`) と bash impl `case` (`i18n/*`) の意図的範囲差**: 前者は tech-writer Activation patterns との等価性を表現するため `.md` / `.mdx` 拡張子に限定する (2 ファイル等価性の系統 1 — internal-consistency.md の Cross-Reference 参照)。後者は rite plugin self-only 判定が目的のため、翻訳ファイル (`i18n/ja.yml` 等) も含めた全拡張子・任意階層を excluded に含める。両者は別の計算経路で使われており drift しない。
- **空配列 guard の背景**: ステップ 1.1 と 1.2.7 の files 配列の不整合 race (PR 削除 / PR が空になる / files 配列 shrink) のエッジケースで、retained flag が undefined のまま Determination block へ流れると `doc_heavy_pr_decision_summary` が意味不明な値 (NaN / undefined) になる。3 flag を明示 set してから skip すればステップ 5.4 の表示で「inconsistency 発生」として可視化される。
- **全経路で `[CONTEXT]` を対称 emit する理由**: skip 経路のみ emit する非対称設計だと、後続 phase (ステップ 2.2.1 / 5.1.3 / 5.4) が「`[CONTEXT]` 行が会話履歴に存在しない = 正常」という negative inference に依存し、Claude の context grep が前 session の `[CONTEXT] doc_heavy_pr=true` を誤拾いするリスクを生む。全経路対称 emit なら grep は常に最新行を decisive に拾える。
- **計算例**:
  - 例 1: `docs/foo.md (+50)` と `commands/bar.md (+50)` の PR → `doc_lines` = 50 (commands/ は除外)、`total_diff_lines` = 100 (両方含む)、ratio = 0.5 (< 0.6) → `doc_heavy_pr = false`
  - 例 2: `docs/foo.md (+80)` のみの PR → `doc_lines` = 80、`total_diff_lines` = 80、ratio = 1.0 → `doc_heavy_pr = true`

## code-block-scan-notes

ステップ 2.2.1 の fenced code block スキャン bash の設計理由。

- **pipefail を維持する理由**: 現行実装は pipeline を廃止し `diff_out=$(git diff ...)` 独立実行 + here-string 構成に移行したため、pipefail が直接必要な pipeline は存在しない。将来の pipeline 追加時の防御として維持している。
- **`printf | grep -m 1` ではなく here-string `<<<` を使う理由**: pipeline では printf が上流 (writer)、grep が下流 (reader) となり、`grep -m 1` の 1 件マッチ早期終了で上流の printf に SIGPIPE が届く経路が存在する。pipefail 有効時、`$diff_out` が pipe buffer (Linux デフォルト 64KB) を超えるサイズだと printf が rc=141 を返し、case 文の `*)` (IO error 扱い) で `__FAIL_SAFE_ADD__` sentinel が誤発火する (大きな diff の Doc-Heavy PR で silent false positive)。`<<<` は bash が入力を一時ファイル経由で渡すため SIGPIPE を受ける相手がおらず、grep の exit 0/1/2 をそのまま捕捉できる。
- **iteration_id を付与する理由**: 同一 session 内で同じ review が複数回実行されると `[CONTEXT] code_quality_coreviewer_add_reason=` 行が会話履歴に複数残り、後続 phase が「最新値」を決定論的に判別できない。`pr_number-{epoch_seconds}` suffix により「最大の iteration_id を持つ行が最新」と判定できる (M-7 修正。ステップ 7.2 / 7.7 の sentinel 規約と同型)。
- **`[CONTEXT]` 3 状態 emit の理由**: bash block 内で `:` no-op だけだと後続 phase が判定結果を機械的に読み取れない (会話文脈に何も残らない)。

## state-snapshot-notes

ステップ 4.0.A Pre-Review State Snapshot の設計理由。

- **detached HEAD edge case**: orchestrator が `git worktree add --detach` で起動された場合や reviewer ループ中の特殊な checkout で HEAD が detached になると `git branch --show-current` は空文字列を返す。空文字列のままステップ 5.0.A に渡すと verifier が `[ -z "$ORIGINAL_BRANCH" ]` で exit 2 (invalid args) になるため、`DETACHED:<short-hash>` sentinel に置換する。verifier 側で `DETACHED:*` は branch drift check を skip する経路に乗る。
- **md5sum portability**: Linux は `md5sum`、macOS は `shasum` を fallback として使う。両方とも stdout の先頭 token が hash であるため `awk '{print $1}'` で portable に取り出せる。
- **ステップ 5.0.A の placeholder 残留 gate**: `{orig_br}` が `{...}` 形状のまま渡されると verifier が non-empty 文字列として branch 比較し silent false-positive cascade を起こすため、形状検査で早期 reject する (ステップ 6.1.b と同 pattern)。

## verification-post-condition-notes

ステップ 5.1.1.1 Verification Result Table Presence check の設計理由。

- **設置の根拠**: ステップ 4.5.1 の verification テンプレートは `### 修正検証結果` の出力を義務付けているが、reviewer agent body が system prompt として与えられている現状では、reviewer がステップ 4.5 (full) の出力のみに集中してステップ 4.5.1 (verification) の出力を silent skip する経路が実証されている。テーブル欠落は「前回指摘の修正検証」の silent skip の兆候で、`finding_count == 0` と誤判定されて silent pass する経路が成立するため、契約違反を検出する post-condition で閉塞する。
- **分離の意図 (subagent resolution failure との関係)**: ステップ 5.1.1.1 の retry 機構は output format 異常 (verification table 欠落) のみを対象とし、`subagent resolution failure` とは独立した経路。この分離により、scoped subagent の解決不能という "インフラレベル" の障害と、output format の契約違反という "semantic レベル" の障害が混線することを防ぐ。resolution failure 時の terminal state は retry counter の数値ではなく classification 状態 (`error`) によって実現される (Judgment Matrix 行 3 への flow 分岐)。

## fingerprint-suppression-notes

ステップ 5.1.2.A Accepted Fingerprint Suppression の設計理由。

**Step 2 と Step 3 を統合した理由**: Claude Code Bash tool は呼び出し間で shell 変数を保持しないため、Step 3 (emit) を独立 bash block にすると `$fingerprint` / `$finding_id` / `$original_severity` が undefined になり emit が空値出力になる。match 検出 + 即時 emit を同一 invocation 内で完結させることで cross-call shell 変数破綻を構造的に回避する。重複 emit は per-finding loop の単一実行が暗黙に防止する。

## doc-heavy-post-condition-notes

ステップ 5.1.3 Doc-Heavy PR Mode Post-Condition Check の設計理由。

- **variant b を Step 1 判定式に含める理由**: tech-writer が `finding_count == 0` でも誤って variant b 文言 (`Findings below.`) を出力することがあり、判定を variant a / c のみで行うと「META 行が 1 つもない」と誤判定して false positive で `修正必要` 降格する。
- **inconclusive variant を判定式に含める理由**: `internal-consistency.md` の "Inconclusive 集計 と META 行への反映" は、Verification protocol の各 step で `target_not_found` / `extraction_failed` / `tool_failure` が発生した場合に META 行を `(a + inconclusive)` / `(b + inconclusive)` 形式へ切り替えることを reviewer に要求している。これらを判定式に含めないと、正しく inconclusive を報告した tech-writer を「META 行なし」と誤判定して二重 penalty が起き silent fall-through する。含めることで inconclusive 報告を正しく受け入れ、Step 4.5 で acknowledgement プロセスを発火できる。
- **literal substring match の設計選択**: カテゴリ名の空白/記号の差異 (`Order / Emphasis Consistency` 等の表記揺れ) を厳格に検出し、canonical form (`Order-Emphasis Consistency`) から逸脱した瞬間に発火する。「文書-実装整合性 mode の自己整合性」をステップ 5.1.3 自身が監視するための仕組み。

## step7-triage-redesign-notes

ステップ 7 の名称・推奨決定方式の再設計（自動 Issue 化 → スコープ外指摘のトリアージ）の設計理由。

- **3 つのバイアスの積み重ね**: 旧「自動 Issue 化」には (1) 起票をゴールとする命名、(2) `AskUserQuestion` の選択肢列挙で「別 Issue 作成」が先頭（本 tool の規約上、先頭 = 推奨と解釈されやすい）、(3) 推奨決定の指示不在（エージェント裁量）、の 3 バイアスが積み重なっていた。エージェントには「指摘を先送りすれば fix ループが早く収束する」という構造的な先延ばし動機があり、この 3 バイアスが揃うと保険的な follow-up Issue が増殖する。fix ループ側の別 Issue 化経路は既に「先延ばしの抜け穴」として廃止済み（`skills/iterate/SKILL.md`）であり、ステップ 7 だけが取り残されていた。
- **先延ばし禁止の設計原則**: 仮説的な将来リスクに先手を打つ Issue は大半が無駄に終わる。スコープ内の実指摘は本 PR で解決し（fix ループで強制済み）、スコープ外候補は「起票せず記録して終わり」をデフォルトにする方が、Issue の増殖を防ぎ実際に着手される確率を上げる。
- **推奨機械決定表を裁量の代わりに置く理由**: 「裁量で決めてよい」とすると上記の構造的動機により実質的に「別 Issue 作成」へ誘導される。Likelihood（Observed/Demonstrable vs Hypothetical）と Source（A/B）という機械的に判定可能な軸だけで推奨を決定することで、エージェントの意思が介在する余地を無くす。
- **Decision Log 記録を「追加」の経路とする理由**: fix ループの nit-noted 返信経路・acknowledged suppression（PR コメント / JSON ベースの再指摘抑制）は Decision Log 記録では代替されない。両者は別の目的（前者は次サイクルでの再指摘抑制、後者は仕様変更の記録）を持つため、置き換えではなく追加とした。
- **元 Issue が特定できない PR での「選択肢非表示」**: PR コメント記録という代替スキーマを新設すると、記録先が「Section 9」「作業メモリ」「PR コメント」の 3 種に増え「シンプルさを死守」原則に反する。本リポジトリはブランチ命名規則上ほぼ全 PR が issue 番号を含むため、この縮退経路の実発生頻度は低いと判断し、選択肢非表示（3 択化）で単純に倒した（対象 Issue の Decision Log D-04 参照）。

## phase7-gate-notes

ステップ 7.7 / 8.0.2 gate の設計理由。

- **Defensive layering の全体像**: (a) ステップ 4.5 reviewer template が 3-classification を要求 → (b) ステップ 5.1 collection で classification を extract (default fallback あり) → (c) ステップ 7.1 で candidates を構築 → (d) ステップ 7.2 で sentinel emit → (e) ステップ 7.7 で grep verify → (f) ステップ 8.0.2 で end-to-end gate continuity 参照。各層は個別に失敗しうるが、ステップ 7.7 は result emit 前の last-line-of-defense mechanical gate。ステップ 5/6 が abort-relevant findings を生成しても、ステップ 7.1 candidate extraction (recommendation_items) は独立しており ステップ 7.2 で user confirm が必須。
- **dual placement (7.7 + 8.0.2) の理由**: ステップ 7.7 はステップ 7.1 → 7.2 → 7.7 の sequence で 7.7 が呼ばれた場合に 7.2 sentinel emit を verify する (procedure 内部の integrity check)。ステップ 8.0.2 はステップ 7 entire procedure (7.1-7.7) が skip された場合の最終 fallback で、`candidate_count >= 1` という trigger 条件が満たされている時点で「ステップ 7 が走るはずだった」と判定できる (ステップ 7.7 自体が呼ばれていない silent skip 経路でも catch する)。ステップ 8.0.1 W Phase gate と完全に対称的で、result-emit boundary における defense-in-depth pattern を構成する。
