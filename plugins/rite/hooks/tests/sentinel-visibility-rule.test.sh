#!/bin/bash
# sentinel-visibility-rule.test.sh — Workflow Incident Sentinel Visibility Rule の構造保護
#
# 本 test は PR D で抽出した 3 references (workflow-incident-detection.md /
# workflow-incident-emit-pattern.md / fingerprint-cycling.md) と本体 start.md
# 側の anchor reference が以下不変条件を満たすことを保証する:
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
#    table (5 caller) が残されていること (これらは本体 contract として保持)
#
# Run mode: 常時実行 (Charter assertion ではなく構造保護のため STRICT_CHARTER 不要)
# Exit code: 不変条件違反時に non-zero

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

START_MD="$REPO_ROOT/plugins/rite/commands/issue/start.md"
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

assert_grep "emit: §A Phase 5.2 lint:aborted emit point" \
  "$REF_EMIT" \
  '^### §A — Phase 5.2 .\[lint:aborted\]'

assert_grep "emit: §B Phase 5.3 pr:create-failed emit point" \
  "$REF_EMIT" \
  '^### §B — Phase 5.3 .\[pr:create-failed\]'

assert_grep "emit: §C Phase 5.4.4 fix:error emit point" \
  "$REF_EMIT" \
  '^### §C — Phase 5.4.4 .\[fix:error\]'

assert_grep "emit: §D Phase 5.5 ready:error emit point" \
  "$REF_EMIT" \
  '^### §D — Phase 5.5 .\[ready:error\]'

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

# 4-option AskUserQuestion の 4 選択肢すべてが存在する
for option in "本 PR 内で再試行" \
              "別 Issue として切り出す" \
              "PR を取り下げる" \
              "手動レビューへエスカレーション"; do
  assert_grep "fingerprint: 4-option contains \"$option\"" \
    "$REF_FINGERPRINT" \
    "$option"
done

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

# When to execute 5-caller table 行が本体に残されている
assert_grep "start: When to execute table — Phase 5.2 lint row" \
  "$START_MD" \
  'Phase 5\.2 \(lint\).*Mandatory After 5\.2'

assert_grep "start: When to execute table — Phase 5.3 pr:create row" \
  "$START_MD" \
  'Phase 5\.3 \(pr:create\).*Mandatory After 5\.3'

assert_grep "start: When to execute table — Phase 5.4.3 pr:review row" \
  "$START_MD" \
  'Phase 5\.4\.3 \(pr:review\).*After Review'

assert_grep "start: When to execute table — Phase 5.4.6 pr:fix row" \
  "$START_MD" \
  'Phase 5\.4\.6 \(pr:fix\).*After Fix'

assert_grep "start: When to execute table — Phase 5.5.0.1 pr:ready row" \
  "$START_MD" \
  'Phase 5\.5\.0\.1 \(pr:ready\).*Mandatory After 5\.5'

# Skip condition + Invariants が本体に残されている (本体 contract)
assert_grep "start: Skip condition retained" \
  "$START_MD" \
  '\*\*Skip condition\*\*: If `workflow_incident\.enabled: false`'

assert_grep "start: Invariants statement retained (non-blocking)" \
  "$START_MD" \
  'workflow MUST NOT halt'

# === Summary ===
if ! print_summary "$(basename "$0")" \
  "PR D で抽出した 3 references の構造が破壊されています。圧縮を巻き戻して reference 内容を確認してください。"; then
  exit 1
fi
