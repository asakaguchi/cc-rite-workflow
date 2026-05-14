#!/bin/bash
# sentinel-visibility-rule.test.sh — Workflow Incident Sentinel Visibility Rule の構造保護
#
# 本 test は PR D で抽出した 3 references (workflow-incident-detection.md /
# workflow-incident-emit-pattern.md / fingerprint-cycling.md) と本体 start.md /
# start-execute.md / start-publish.md (PR F/G1 抽出後の 3-way split) 側の anchor
# reference が以下不変条件を満たすことを保証する:
#
# 1. workflow-incident-detection.md が Phase 5.4.4.1 Processing flow Step 1-7
#    と Phase 5.0 Step 6 (workflow_incident.enabled parser) を含む
# 2. workflow-incident-emit-pattern.md が sub-skill emit pattern bash literal
#    (`workflow-incident-emit.sh ... 2>/dev/null) || true`) と 4 orchestrator-direct
#    emit point (§A Phase 5.2 / §B Phase 5.3 / §C Phase 5.4.4 / §D Phase 5.5) を含む
# 3. fingerprint-cycling.md が Phase 5.4.1.0 Step 1-5 と Phase 5.4.3 Step 3.1
#    (Quality Signal 3 & 4) と 共通 4-option AskUserQuestion を含む
# 4. 本体 start.md 側に 3 references への anchor reference が存在し、orchestrator
#    が圧縮済み phase から正しい SoT に到達可能であること
# 5. 本体 start.md 側に Detection scope table (7 sentinel type) と When to execute
#    table (3 caller — PR G1 で start-publish 抽出後、5.0-5.2.1 / 5.3-5.4 / 5.5.0.1)
#    が残されていること (これらは本体 contract として保持)
# 6. start-publish.md 内の rite:pr:* Skill invocation contract が破壊されていないこと
#    (PR G1 で内部 routing が sub-skill 内に閉じた drift 防止)
#
# Run mode: 常時実行 (Charter assertion ではなく構造保護のため STRICT_CHARTER 不要)
# Exit code: 不変条件違反時に non-zero

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

START_MD="$REPO_ROOT/plugins/rite/commands/issue/start.md"
# PR F (#902) extracted Phase 5.0-5.2.1 (incl. §A Phase 5.2 `[lint:aborted]` anchor reference)
# into start-execute.md. PR G1 (#903) extracted Phase 5.3/5.4 (incl. §B Phase 5.3 `[pr:create-failed]`
# / §C Phase 5.4.4 `[fix:error]` anchor references) into start-publish.md. PR G2 (#904) extracted
# Phase 5.5-Termination (incl. §D Phase 5.5 `[ready:error]` anchor reference) into start-finalize.md.
# The anchor ownership is:
#   §A → start-execute.md
#   §B / §C → start-publish.md
#   §D → start-finalize.md (Phase 5.5 moved to start-finalize.md in PR G2)
#   `## 不変条件` → start.md (本体 contract retains generic reference to emit-pattern.md#不変条件)
# Anchor drift check scans the owner file per anchor.
START_EXECUTE_MD="$REPO_ROOT/plugins/rite/commands/issue/start-execute.md"
START_PUBLISH_MD="$REPO_ROOT/plugins/rite/commands/issue/start-publish.md"
START_FINALIZE_MD="$REPO_ROOT/plugins/rite/commands/issue/start-finalize.md"
REF_DETECTION="$REPO_ROOT/plugins/rite/commands/issue/references/workflow-incident-detection.md"
REF_EMIT="$REPO_ROOT/plugins/rite/commands/issue/references/workflow-incident-emit-pattern.md"
REF_FINGERPRINT="$REPO_ROOT/plugins/rite/commands/issue/references/fingerprint-cycling.md"

echo "=== Sentinel Visibility Rule — PR D 抽出構造の保護 ==="
echo "start.md:            $START_MD"
echo "detection ref:       $REF_DETECTION"
echo "emit-pattern ref:    $REF_EMIT"
echo "fingerprint ref:     $REF_FINGERPRINT"
echo ""

# === 1. workflow-incident-detection.md の必須コンテンツ ===
echo "--- 1. workflow-incident-detection.md ---"

assert_grep "detection: Phase 5.0 Step 6 parser section heading" \
  "$REF_DETECTION" \
  '^## Phase 5.0 Step 6 — `workflow_incident.enabled` parser'

assert_grep "detection: sed -n section-range parser literal" \
  "$REF_DETECTION" \
  '^workflow_incident_enabled=\$\(sed -n .*workflow_incident:'

assert_grep "detection: case-insensitive normalization (yes/no/1/0 variants)" \
  "$REF_DETECTION" \
  '^[[:space:]]+true\|yes\|1\)[[:space:]]+workflow_incident_enabled="true" ;;'

assert_grep "detection: Phase 5.4.4.1 main section heading" \
  "$REF_DETECTION" \
  '^## Phase 5.4.4.1 — Workflow Incident Detection'

# Processing flow Step 1-7 が各 step heading として存在する
for step in "Step 1 — Sentinel detection" \
            "Step 2 — Parse sentinel fields" \
            "Step 3 — Duplicate suppression" \
            "Step 4 — User confirmation via .AskUserQuestion" \
            "Step 5 — Branch on user choice" \
            "Step 6 — Create Issue via common script" \
            "Step 7 — Mark processed"; do
  assert_grep "detection: $step heading" \
    "$REF_DETECTION" \
    "^### $step"
done

assert_grep "detection: Non-blocking guarantee invariant" \
  "$REF_DETECTION" \
  '^### Non-blocking guarantee'

assert_grep "detection: Default-on behavior invariant" \
  "$REF_DETECTION" \
  '^### Default-on behavior'

# === 2. workflow-incident-emit-pattern.md の必須コンテンツ ===
echo ""
echo "--- 2. workflow-incident-emit-pattern.md ---"

assert_grep "emit: sub-skill emit canonical bash literal" \
  "$REF_EMIT" \
  'sentinel_line=\$\(bash \{plugin_root\}/hooks/workflow-incident-emit.sh'

assert_grep 'emit: non-blocking "|| true" guard pattern' \
  "$REF_EMIT" \
  'pr_number\} 2>/dev/null\) \|\| true'

# F-c2-3 (cycle 2): `|| true` 行末 only を grep して prose 参照を除外する。
# 旧 `grep -oE -- '\|\| true'` は markdown 解説文 (`「|| true」 は必須` 等) もカウントしていた。
# bash literal の `|| true` は行末で必ず終わるため `\|\| true$` で限定する。
# 期待値: sub-skill emit pattern (1) + §A (1) + §B (2) + §C (1) + §D (2) = **7 個** (>= 6 で許容範囲)
ortho_or_true_count=$({ grep -E -- '\|\| true$' "$REF_EMIT" || true; } | wc -l | tr -d ' ')
if [ "$ortho_or_true_count" -ge 6 ]; then
  pass "emit: orchestrator-direct '|| true' guard count >= 6 EOL-only (actual=$ortho_or_true_count, prose excluded)"
else
  fail "emit: orchestrator-direct '|| true' guard count >= 6 EOL-only (actual=$ortho_or_true_count, expected >=6). §A-§D 範囲内の bash guard が削除された可能性"
fi

assert_grep "emit: §A Phase 5.2 lint:aborted emit point" \
  "$REF_EMIT" \
  '^### §A — Phase 5.2 .\[lint:aborted\]'

# F-05 fix: §A 内に canonical bash literal が存在することを section-scoped で確認
# §A section 範囲 (^### §A から次の ^### までの前) を awk で抽出し、type=manual_fallback_adopted を含むかを判定
section_a=$(awk '/^### §A/,/^### §B/' "$REF_EMIT" 2>/dev/null)
if echo "$section_a" | grep -q '\--type manual_fallback_adopted'; then
  pass "emit: §A section body contains 'manual_fallback_adopted' type literal"
else
  fail "emit: §A section body lacks 'manual_fallback_adopted' type literal. heading 後の bash 本体が空または削除"
fi

assert_grep "emit: §B Phase 5.3 pr:create-failed emit point" \
  "$REF_EMIT" \
  '^### §B — Phase 5.3 .\[pr:create-failed\]'

section_b=$(awk '/^### §B/,/^### §C/' "$REF_EMIT" 2>/dev/null)
if echo "$section_b" | grep -q '\--type skill_load_failure'; then
  pass "emit: §B section body contains 'skill_load_failure' type literal"
else
  fail "emit: §B section body lacks 'skill_load_failure' type literal"
fi

assert_grep "emit: §C Phase 5.4.4 fix:error emit point" \
  "$REF_EMIT" \
  '^### §C — Phase 5.4.4 .\[fix:error\]'

section_c=$(awk '/^### §C/,/^### §D/' "$REF_EMIT" 2>/dev/null)
if echo "$section_c" | grep -q '\--type manual_fallback_adopted'; then
  pass "emit: §C section body contains 'manual_fallback_adopted' type literal"
else
  fail "emit: §C section body lacks 'manual_fallback_adopted' type literal"
fi

assert_grep "emit: §D Phase 5.5 ready:error emit point" \
  "$REF_EMIT" \
  '^### §D — Phase 5.5 .\[ready:error\]'

# §D は次の `^## ` heading (5 caller mapping) までを範囲とする
section_d=$(awk '/^### §D/,/^## /' "$REF_EMIT" 2>/dev/null)
if echo "$section_d" | grep -q '\--type skill_load_failure'; then
  pass "emit: §D section body contains 'skill_load_failure' type literal"
else
  fail "emit: §D section body lacks 'skill_load_failure' type literal"
fi

assert_grep "emit: 5 caller mapping table" \
  "$REF_EMIT" \
  '^## 5 caller × invocation point マッピング'

# 5 caller それぞれが table 内に出現
for caller in "Phase 5.2 \(lint\)" \
              "Phase 5.3 \(pr:create\)" \
              "Phase 5.4.3 \(pr:review\)" \
              "Phase 5.4.6 \(pr:fix\)" \
              "Phase 5.5.0.1 \(pr:ready\)"; do
  assert_grep "emit: caller table contains \"$caller\"" \
    "$REF_EMIT" \
    "$caller"
done

# === 3. fingerprint-cycling.md の必須コンテンツ ===
echo ""
echo "--- 3. fingerprint-cycling.md ---"

assert_grep "fingerprint: §1 Phase 5.4.1.0 main section" \
  "$REF_FINGERPRINT" \
  '^## §1 — Phase 5.4.1.0 Fingerprint Cycling Detection'

# Step 1-5 が各 step heading として存在する
for step in "Step 1 — Fetch 2 most recent review comments" \
            "Step 2 — Extract findings & compute fingerprints" \
            "Step 3 — Compare fingerprint sets" \
            "Step 4 — Escalate via AskUserQuestion" \
            "Step 5 — Proceed to review invocation"; do
  assert_grep "fingerprint: $step heading" \
    "$REF_FINGERPRINT" \
    "^### $step"
done

assert_grep "fingerprint: fingerprint = sha1(...) specification" \
  "$REF_FINGERPRINT" \
  '^fingerprint = sha1\( normalize\(file_path\)'

assert_grep "fingerprint: portable SHA-1 helper (sha1sum/shasum/python3 fallback)" \
  "$REF_FINGERPRINT" \
  '^sha1_portable\(\)'

assert_grep "fingerprint: §2 Phase 5.4.3 Step 3.1 Quality Signal 3 & 4" \
  "$REF_FINGERPRINT" \
  '^## §2 — Phase 5.4.3 Step 3.1 Quality Signal 3 & 4 Detection'

assert_grep 'fingerprint: §3 common 4-option AskUserQuestion heading' \
  "$REF_FINGERPRINT" \
  '^## §3 — 共通 4-option .?AskUserQuestion'

assert_grep "fingerprint: §4 split bash for 別 Issue として切り出す" \
  "$REF_FINGERPRINT" \
  '^## §4 — Split bash for .別 Issue として切り出す'

# F-c2-2 (cycle 2): §3 section 内には 4-option を行頭 `|` で含む **table が 2 つ** 存在する:
#   (1) "| Option | Action |" header 配下の 4-option AskUserQuestion contract table (line 157-163)
#   (2) "| Selection | Next |" header 配下の "Branching after user selection" table (line 165-171)
# 旧 `awk '/^## §3/,/^## §4/'` + `grep '^\| {option}'` は両 table から match するため、
# (1) を完全削除しても (2) の Branching table が残れば test PASS する false negative があった。
# 修正: Option/Action header を起点に `^$` (空行) までを scope として抽出し、4-option contract table のみを検証する。
section_3_options=$(awk '/^\| Option \| Action \|/,/^$/' "$REF_FINGERPRINT" 2>/dev/null)
for option in "本 PR 内で再試行" \
              "別 Issue として切り出す" \
              "PR を取り下げる" \
              "手動レビューへエスカレーション"; do
  if echo "$section_3_options" | grep -qE "^\| ${option}"; then
    pass "fingerprint: §3 Option/Action table row contains \"${option}\" (option-table-scoped)"
  else
    fail "fingerprint: §3 Option/Action table row missing \"${option}\". 4-option contract が削除された可能性 (Branching table とは別)"
  fi
done

# F-01 drift guard: workflow-incident-detection.md に sub-skill emit canonical bash literal が
# 再混入していないことを確認。SoT 二重定義を構造的に block する。
assert_not_grep "detection: no duplicate sub-skill emit canonical literal (drift guard for F-01)" \
  "$REF_DETECTION" \
  'sentinel_line=\$\(bash \{plugin_root\}/hooks/workflow-incident-emit.sh'

# === 4. start.md 本体側 anchor reference の存在 ===
echo ""
echo "--- 4. start.md 本体 anchor reference ---"

assert_grep "start: anchor to workflow-incident-detection.md" \
  "$START_MD" \
  '\(\./references/workflow-incident-detection\.md'

assert_grep "start: anchor to workflow-incident-emit-pattern.md" \
  "$START_MD" \
  '\(\./references/workflow-incident-emit-pattern\.md'

assert_grep "start: anchor to fingerprint-cycling.md" \
  "$START_MD" \
  '\(\./references/fingerprint-cycling\.md'

# === 5. start.md 本体に保持されるべき contract structures ===
echo ""
echo "--- 5. start.md 本体 contract structures ---"

# Detection scope 7-type table 行が本体に残されている (本体 contract)
for sentinel_type in "skill_load_failure" \
                     "hook_abnormal_exit" \
                     "manual_fallback_adopted" \
                     "wiki_ingest_skipped" \
                     "wiki_ingest_failed" \
                     "wiki_ingest_push_failed" \
                     "gitignore_drift"; do
  assert_grep "start: Detection scope table contains \`$sentinel_type\`" \
    "$START_MD" \
    "\`$sentinel_type\`"
done

# When to execute 3-caller table 行が本体に残されている
# PR F #951 F-05 fix: Phase 5.2 (lint) row が Mandatory After 5.0-5.2.1 統合により
# 「Phase 5.0-5.2.1 (execute) | Mandatory After 5.0-5.2.1 — Step 2」へ変更された。
# PR G1 #903 fix: Phase 5.3 / 5.4.3 / 5.4.6 rows が start-publish sub-skill 抽出により
# 「Phase 5.3-5.4 (publish) | Mandatory After 5.3-5.4」へ統合された。internal pr:create /
# pr:review / pr:fix 呼出は start-publish 内に閉じ、orchestrator 視点では 3 boundary。
# PR G2 #904 fix: Phase 5.5.0.1 (pr:ready) row が start-finalize sub-skill 抽出により
# 「Phase 5.5-Termination (finalize) | Mandatory After 5.5-Termination」へ変更。
assert_grep "start: When to execute table — Phase 5.0-5.2.1 execute row" \
  "$START_MD" \
  'Phase 5\.0-5\.2\.1 \(execute\).*Mandatory After 5\.0-5\.2\.1'

assert_grep "start: When to execute table — Phase 5.3-5.4 publish row" \
  "$START_MD" \
  'Phase 5\.3-5\.4 \(publish\).*Mandatory After 5\.3-5\.4'

assert_grep "start: When to execute table — Phase 5.5-Termination finalize row" \
  "$START_MD" \
  'Phase 5\.5-Termination \(finalize\).*Mandatory After 5\.5-Termination'

# Skip condition + Invariants が本体に残されている (本体 contract)
assert_grep "start: Skip condition retained" \
  "$START_MD" \
  '\*\*Skip condition\*\*: If `workflow_incident\.enabled: false`'

assert_grep "start: Invariants statement retained (non-blocking)" \
  "$START_MD" \
  'workflow MUST NOT halt'

# === 5.5. start-publish.md 内の rite:pr:* Skill invocation contract ===
# PR G1 で Phase 5.3-5.4 が start-publish.md sub-skill 内に閉じたため、
# start.md からは「Phase 5.4.3 (pr:review) / 5.4.6 (pr:fix) row」の assert が削除された。
# 代わりに「start-publish.md 内に rite:pr:create / rite:pr:review / rite:pr:fix の Skill invocation が
# 必ず存在する」ことを pin することで、内部 Skill 呼出が誤削除される drift を検出する。
echo ""
echo "--- 5.5. start-publish.md 内の rite:pr:* Skill invocation contract (PR G1) ---"

assert_grep "start-publish: rite:pr:create skill invocation retained" \
  "$START_PUBLISH_MD" \
  'skill: "rite:pr:create"'

assert_grep "start-publish: rite:pr:review skill invocation retained" \
  "$START_PUBLISH_MD" \
  'skill: "rite:pr:review"'

assert_grep "start-publish: rite:pr:fix skill invocation retained" \
  "$START_PUBLISH_MD" \
  'skill: "rite:pr:fix"'

# start-execute.md drift guard: inline workflow-incident-emit.sh literal が再混入しないこと
# (Issue #954 L-1: 3 sub-skill 間で ownership 契約の structural integrity を均一化する)
assert_not_grep "start-execute: no inline 'workflow-incident-emit.sh' bash literal (drift guard)" \
  "$START_EXECUTE_MD" \
  'bash \{plugin_root\}/hooks/workflow-incident-emit.sh'

# start-publish.md drift guard: inline workflow-incident-emit.sh literal が再混入しないこと
# (Issue #954 L-1: 3 sub-skill 間で ownership 契約の structural integrity を均一化する)
assert_not_grep "start-publish: no inline 'workflow-incident-emit.sh' bash literal (drift guard)" \
  "$START_PUBLISH_MD" \
  'bash \{plugin_root\}/hooks/workflow-incident-emit.sh'

# === 5.6. start-finalize.md 内の rite:pr:ready / rite:issue:close Skill invocation contract (PR G2) ===
# PR G2 で Phase 5.5/5.7 が start-finalize.md sub-skill 内に閉じたため、
# start.md からは「Phase 5.5 (pr:ready) row」「5.7.2 (rite:issue:close)」の assert が削除された。
# 代わりに「start-finalize.md 内に rite:pr:ready / rite:issue:close の Skill invocation が
# 必ず存在する」ことを pin することで、内部 Skill 呼出が誤削除される drift を検出する。
echo ""
echo "--- 5.6. start-finalize.md 内の rite:pr:ready / rite:issue:close Skill invocation contract (PR G2) ---"

assert_grep "start-finalize: rite:pr:ready skill invocation retained" \
  "$START_FINALIZE_MD" \
  'skill: "rite:pr:ready"'

assert_grep "start-finalize: rite:issue:close skill invocation retained" \
  "$START_FINALIZE_MD" \
  'skill: "rite:issue:close"'

# start-finalize.md drift guard: inline workflow-incident-emit.sh literal が再混入しないこと
assert_not_grep "start-finalize: no inline 'workflow-incident-emit.sh' bash literal (drift guard)" \
  "$START_FINALIZE_MD" \
  'bash \{plugin_root\}/hooks/workflow-incident-emit.sh'

# start-finalize.md sentinel HTML-comment form の直接 pin (Issue #954 L-2)
# verify-terminal-output.sh Check 3.5 + verify-terminal-output.test.sh fixture 経由で
# 間接的に検証されているが、本 Section 5.6 に直接 pin assert を追加することで、
# Skill invocation pin と同じ section 内で workflow terminal sentinel の structural integrity を一望できる。
assert_grep "start-finalize: <!-- [start:finalize:completed] --> sentinel HTML-comment form retained" \
  "$START_FINALIZE_MD" \
  '<!-- \[start:finalize:completed\] -->'

assert_grep "start-finalize: <!-- [start:finalize:aborted] --> sentinel HTML-comment form retained" \
  "$START_FINALIZE_MD" \
  '<!-- \[start:finalize:aborted\] -->'

# === 6. start.md drift guard — inline emit literal must NOT reappear (#937) ===
echo ""
echo "--- 6. start.md drift guard (#937: inline emit literal block) ---"

# F-#937 drift guard: orchestrator-direct emit canonical bash literal が start.md に再混入していないことを確認。
# Issue #937 で start.md L743/949/955/1221/1247/1253 の 6 箇所 inline emit literal を
# references/workflow-incident-emit-pattern.md §A-§D anchor 参照に圧縮した。
# 将来の編集で `bash {plugin_root}/hooks/workflow-incident-emit.sh ...` literal が start.md
# 本体に再混入すると SoT 1:1 分離契約が破れるため、ここで構造的に block する。
assert_not_grep "start: no inline 'workflow-incident-emit.sh' bash literal (drift guard for #937)" \
  "$START_MD" \
  'bash \{plugin_root\}/hooks/workflow-incident-emit.sh'

# 上記 assert_not_grep の補強: 旧 inline emit literal に含まれていた具体的 details 文字列が
# start.md に再混入していないかを pin する。drift guard target は **start.md 本体** (= grep scope の $START_MD)
# であり、references/workflow-incident-emit-pattern.md の説明 prose や bash literal は対象外。
#
# 旧 inline literal は計 6 種類の details 文字列を含んでいた (compression **前** の start.md
# L743 / L949 / L955 / L1221 / L1247 / L1253、compression commit d436e6b9 で削除済み)。
# 現 start.md (post-compression、cycle 2 終了時点) では L742 / 944 / 1207 / 1232 が anchor reference
# 行となっており、上記旧行番号は git history (`git log -p plugins/rite/commands/issue/start.md`) で
# 確認可能。Issue #937 cycle 1 で 4 種を pin、cycle 2 で §C / §D anchor reference の prose を
# 抽象化した結果、cycle 1 で exclusion していた `rite:pr:fix error fallback` も start.md から
# 消えた (現 start.md prose には 6 種すべての literal なし。canonical SoT としては
# `references/workflow-incident-emit-pattern.md` §A-§D 配下の bash literal に保持されている)。
# 本 test は cycle 2 終了時点の状態に基づき 6 種すべてを pin する (grep scope = $START_MD のみ)。
#
# 検証コマンド (Phase 1.2.0 Priority 0 grep と同形式で、$START_MD に当該 literal が存在しないことを
# 機械的に確認できる):
#   grep -F 'rite:lint aborted by user'             plugins/rite/commands/issue/start.md → 0 hits
#   grep -F 'rite:pr:create returned create-failed' plugins/rite/commands/issue/start.md → 0 hits
#   grep -F 'rite:pr:create manual fallback'        plugins/rite/commands/issue/start.md → 0 hits
#   grep -F 'rite:pr:fix error fallback'            plugins/rite/commands/issue/start.md → 0 hits
#   grep -F 'rite:pr:ready returned error'          plugins/rite/commands/issue/start.md → 0 hits
#   grep -F 'rite:pr:ready manual fallback'         plugins/rite/commands/issue/start.md → 0 hits
#
# 将来 §C / §D anchor reference に `details=...` example が再導入された場合、本 test の対応 pin が
# 誤発火する。その際は (a) example を anchor reference 経由で参照に置換するか、(b) 該当 ghost literal を
# exclusion に戻す (理由を明記) かを judgment する。
for ghost_literal in "rite:lint aborted by user" \
                     "rite:pr:create returned create-failed" \
                     "rite:pr:create manual fallback" \
                     "rite:pr:fix error fallback" \
                     "rite:pr:ready returned error" \
                     "rite:pr:ready manual fallback"; do
  assert_not_grep "start: no ghost literal '$ghost_literal' (drift guard for #937)" \
    "$START_MD" \
    "$ghost_literal"
done

# === 7. start.md anchor 整合性検証 (Issue #948 cycle 1 HIGH F-#937-1 対応) ===
echo ""
echo "--- 7. start.md → emit-pattern.md anchor 整合性 (github-slugger 互換性) ---"

# 背景: PR #948 cycle 1 で `#b--phase-53-pr-create-failed` (誤) を `#b--phase-53-prcreate-failed` (正)
# に修正した。github-slugger v2 の仕様により、heading 内の `:` は **ハイフン置換なしで削除** される。
# したがって `[pr:create-failed]` は `prcreate-failed` (連結) になり、`pr-create-failed` (ハイフン区切り) ではない。
# 同種の drift を将来検出するため、本 test は (heading, expected_anchor) のペアを pin する。
#
# **検証戦略**: github-slugger を bash 上で実装するのは複雑で fragile (`§`, `—`, fullwidth, etc.
# 多数の Unicode normalization rule がある)。代わりに以下 2 点を独立に assert する:
#   (a) emit-pattern.md に各 heading が literal で存在する
#   (b) start.md に対応する anchor reference が存在する
# これにより node.js 不在環境でも動作し、anchor slug の drift (heading 更新時に anchor 未更新等)
# を検出できる。anchor slug 自体の正確性は cycle 1 の手動検証 + reviewer による github-slugger 実証で担保。

# (heading exact text, expected anchor in start.md) のペア定義
# anchor 値は github-slugger v2 で実証済み (PR #948 cycle 1/2 verification 参照)。
# pair format: "{heading_literal}|{expected_anchor}"
#
# §A-§D は本 PR で追加された h3 emit point anchor (4 個)、`## 不変条件` は cycle 1 修正で
# response-text-inclusion 要件の anchor target として start.md L742/944/1207/1232 から 4 回参照される
# h2 anchor。同一 PR diff で導入され同じ drift risk を持つため anchor_pairs に含める
# (cycle 2 code-quality MEDIUM 指摘対応)。
# PR F #951 cycle 1 F-07 fix: per-pair owner enforcement.
# 旧実装は START_MD/START_EXECUTE_MD の OR 条件で anchor 存在を判定しており、
# PR F の refactor scope (§A は start-execute.md, §B-§D + 不変条件 は start.md) という
# ownership 契約を強制していなかった。§A を誤って start.md に書戻したり §B を
# start-execute.md に複製しても test PASS する false negative があった。
# anchor_pairs に owner column (3rd field) を追加し per-pair で grep 対象を切替える。
# format: "{heading_literal}|{expected_anchor}|{owner: start|start-execute}"
#
# Note: `#不変条件` anchor は start-execute.md §A note からも legitimately 参照される
# (§A canonical literal が response-text-inclusion 不変条件を参照するため、複数 owner 経由で
# 引用可能)。本 test の ownership 契約は **必ず owner file に anchor が存在すること** を
# 強制するもので、non-owner file への追加参照は drift とは扱わない (§A note のような正規路を
# 妨げないため)。
anchor_pairs=(
  '### §A — Phase 5.2 `[lint:aborted]`|a--phase-52-lintaborted|start-execute'
  '### §B — Phase 5.3 `[pr:create-failed]`|b--phase-53-prcreate-failed|start-publish'
  '### §C — Phase 5.4.4 `[fix:error]`|c--phase-544-fixerror|start-publish'
  '### §D — Phase 5.5 `[ready:error]`|d--phase-55-readyerror|start-finalize'
  '## 不変条件|不変条件|start'
)

for pair in "${anchor_pairs[@]}"; do
  heading="${pair%%|*}"
  rest="${pair#*|}"
  anchor="${rest%%|*}"
  owner="${rest##*|}"

  # (a) emit-pattern.md に heading が literal で存在
  # heading は backtick / brackets / em-dash を含むため `grep -F` (fixed string) を使う
  if grep -qF -- "$heading" "$REF_EMIT"; then
    pass "anchor: emit-pattern.md contains heading: $heading"
  else
    fail "anchor: emit-pattern.md MISSING heading literal: $heading (heading が書き換えられた可能性)"
  fi

  # (b) owner file に対応 anchor が存在することを検証 (PR F/G1/G2 #902/#903/#904 ownership 契約):
  #   - §A → start-execute.md
  #   - §B / §C → start-publish.md
  #   - §D → start-finalize.md
  #   - `## 不変条件` → start.md (本体 contract 内 generic reference)
  case "$owner" in
    start)
      owner_file="$START_MD"
      owner_label="start.md"
      ;;
    start-execute)
      owner_file="$START_EXECUTE_MD"
      owner_label="start-execute.md"
      ;;
    start-publish)
      owner_file="$START_PUBLISH_MD"
      owner_label="start-publish.md"
      ;;
    start-finalize)
      owner_file="$START_FINALIZE_MD"
      owner_label="start-finalize.md"
      ;;
    *)
      fail "anchor: unknown owner '$owner' in anchor_pairs (must be 'start', 'start-execute', 'start-publish', or 'start-finalize')"
      continue
      ;;
  esac

  if grep -qF -- "workflow-incident-emit-pattern.md#${anchor}" "$owner_file"; then
    pass "anchor: ${owner_label} references anchor #${anchor} (per ownership contract)"
  else
    fail "anchor: ${owner_label} MISSING anchor reference workflow-incident-emit-pattern.md#${anchor} (anchor drift の可能性 — heading を更新したら anchor も更新すること、または PR F ownership 契約を確認)"
  fi
done

# === Summary ===
if ! print_summary "$(basename "$0")" \
  "PR D で抽出した 3 references の構造が破壊されています。圧縮を巻き戻して reference 内容を確認してください。"; then
  exit 1
fi
