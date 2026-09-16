#!/usr/bin/env bash
# Behavior tests for opt-in task/model preset selection and comparison records.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PRESET="$ROOT/bin/fm-task-model-preset.sh"
METRICS="$ROOT/bin/fm-dispatch-metrics.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-model-preset)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "$3: missing '$2' in '$1'" ;; esac
}

make_config() {
  local path=$1
  cat > "$path" <<'JSON'
{"schema_version":1,"seed":"synthetic-test-seed","presets":{"fixed-example":{"mode":"fixed","candidate":{"id":"fixed","harness":"pi","model":"vendor/model-fixed","effort":"high","fast":false}},"weighted-example":{"mode":"weighted","candidates":[{"id":"primary","weight":0.4,"harness":"grok","model":"model-primary","effort":"xhigh"},{"id":"alternative-a","weight":0.35,"harness":"claude","model":"opus","effort":"medium"},{"id":"alternative-b","weight":0.25,"harness":"opencode","model":"vendor/model-alternative","effort":"xhigh"}]}}}
JSON
}

case_dir="$TMP_ROOT/basic"
mkdir -p "$case_dir/state"
make_config "$case_dir/config.json"
FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" validate "$case_dir/config.json" || fail "valid preset config was rejected"
fixed=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select fixed-task fixed-example "$case_dir/config.json") || fail "fixed selection failed"
[ "$(printf '%s' "$fixed" | jq -r '.mode + ":" + .selected.id')" = fixed:fixed ] || fail "fixed selection chose the wrong candidate"
[ "$(printf '%s' "$fixed" | jq -r '.selected.fast')" = false ] || fail "explicit fast=false was lost"

cat > "$case_dir/literal-default.json" <<'JSON'
{"schema_version":1,"presets":{"default":{"mode":"fixed","candidate":{"id":"literal-default","harness":"claude","model":"opus","effort":"medium"}}}}
JSON
literal_default=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select literal-default-task default "$case_dir/literal-default.json") \
  || fail "a preset literally named default was not selectable"
[ "$(printf '%s' "$literal_default" | jq -r '.preset + ":" + .selected.id')" = default:literal-default ] \
  || fail "literal default preset was treated as an alias"
jq '. + {default:"fixed-example"}' "$case_dir/config.json" > "$case_dir/removed-alias.json"
set +e
legacy_alias_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" validate "$case_dir/removed-alias.json" 2>&1)
legacy_alias_rc=$?
set -e
[ "$legacy_alias_rc" -ne 0 ] || fail "removed root default alias still passed validation"
assert_contains "$legacy_alias_out" "unknown field 'default'" "root default alias validation"

first=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select retry-task weighted-example "$case_dir/config.json") || fail "weighted selection failed"
first_id=$(printf '%s' "$first" | jq -r '.selected.id')
first_digest=$(printf '%s' "$first" | jq -r '.config_sha256')
jq '.seed="changed-seed"' "$case_dir/config.json" > "$case_dir/changed.json"
second=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select retry-task weighted-example "$case_dir/changed.json") || fail "retry did not reuse its choice"
[ "$(printf '%s' "$second" | jq -r '.selected.id')" = "$first_id" ] || fail "retry resampled a different candidate"
[ "$(printf '%s' "$second" | jq -r '.config_sha256')" = "$first_digest" ] || fail "retry replaced the original config provenance"

availability_choice=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select availability-task weighted-example "$case_dir/config.json") \
  || fail "availability setup selection failed"
availability_id=$(printf '%s' "$availability_choice" | jq -r '.selected.id')
availability_harness=$(printf '%s' "$availability_choice" | jq -r '.selected.harness')
availability_model=$(printf '%s' "$availability_choice" | jq -r '.selected.model')
cp "$case_dir/state/availability-task.dispatch-choice.json" "$case_dir/availability-choice-before.json"
jq --arg id "$availability_id" --arg harness "$availability_harness" --arg model "$availability_model" '
  .presets["weighted-example"].candidates |= map(
    if .id == $id and .harness == $harness and .model == $model
    then . + {available:false, unavailable_reason:"approval was withdrawn"}
    else . end
  )
' "$case_dir/config.json" > "$case_dir/now-unavailable.json"
set +e
availability_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select availability-task weighted-example "$case_dir/now-unavailable.json" 2>&1)
availability_rc=$?
set -e
[ "$availability_rc" -eq 2 ] || fail "a reused choice newly marked unavailable did not exit 2"
assert_contains "$availability_out" "approval was withdrawn" "current availability refusal"
cmp -s "$case_dir/availability-choice-before.json" "$case_dir/state/availability-task.dispatch-choice.json" \
  || fail "availability refusal rewrote or resampled the durable choice"

counts_primary=0
counts_a=0
counts_b=0
i=1
while [ "$i" -le 80 ]; do
  selected=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select "sample-$i" weighted-example "$case_dir/config.json" | jq -r '.selected.id') || fail "sample $i failed"
  case "$selected" in
    primary) counts_primary=$((counts_primary + 1)) ;;
    alternative-a) counts_a=$((counts_a + 1)) ;;
    alternative-b) counts_b=$((counts_b + 1)) ;;
    *) fail "unknown weighted candidate $selected" ;;
  esac
  i=$((i + 1))
done
[ "$counts_primary" -ge 18 ] && [ "$counts_primary" -le 48 ] || fail "primary weight was not reflected ($counts_primary/80)"
[ "$counts_a" -ge 14 ] && [ "$counts_a" -le 44 ] || fail "alternative-a did not receive regular samples ($counts_a/80)"
[ "$counts_b" -ge 8 ] && [ "$counts_b" -le 32 ] || fail "alternative-b did not receive regular samples ($counts_b/80)"

mkdir -p "$case_dir/concurrent-state"
FM_STATE_OVERRIDE="$case_dir/concurrent-state" "$PRESET" select race-task weighted-example "$case_dir/config.json" > "$case_dir/race-a.json" &
race_a=$!
FM_STATE_OVERRIDE="$case_dir/concurrent-state" "$PRESET" select race-task weighted-example "$case_dir/config.json" > "$case_dir/race-b.json" &
race_b=$!
wait "$race_a" || fail "first concurrent selector failed"
wait "$race_b" || fail "second concurrent selector failed"
cmp -s "$case_dir/race-a.json" "$case_dir/race-b.json" || fail "concurrent selectors did not reuse one durable choice"
choice_links=$(stat -f '%l' "$case_dir/concurrent-state/race-task.dispatch-choice.json" 2>/dev/null \
  || stat -c '%h' "$case_dir/concurrent-state/race-task.dispatch-choice.json")
[ "$choice_links" = 1 ] || fail "durable choice did not settle to one link"
ln "$case_dir/concurrent-state/race-task.dispatch-choice.json" "$case_dir/concurrent-state/.race-task.dispatch-choice.json.99999.0"
FM_STATE_OVERRIDE="$case_dir/concurrent-state" "$PRESET" select race-task weighted-example "$case_dir/config.json" > "$case_dir/race-c.json" \
  || fail "a leftover publication link blocked reuse of the durable choice"
cmp -s "$case_dir/race-a.json" "$case_dir/race-c.json" || fail "retry beside a leftover publication link did not reuse the durable choice"

cat > "$case_dir/unavailable.json" <<'JSON'
{"schema_version":1,"presets":{"blocked":{"mode":"fixed","candidate":{"id":"disabled-product","harness":"opencode","model":"vendor/model-disabled","effort":"xhigh","available":false,"unavailable_reason":"product approval is pending"}}}}
JSON
set +e
unavailable_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" select unavailable-task blocked "$case_dir/unavailable.json" 2>&1)
unavailable_rc=$?
set -e
[ "$unavailable_rc" -eq 2 ] || fail "sampled unavailable candidate did not exit 2 (got $unavailable_rc)"
assert_contains "$unavailable_out" "sampled unavailable candidate 'disabled-product'" "unavailable selection"
[ "$(jq -r '.selected.id' "$case_dir/state/unavailable-task.dispatch-choice.json")" = disabled-product ] || fail "unavailable sample provenance was not retained"

cat > "$case_dir/invalid.json" <<'JSON'
{"schema_version":1,"presets":{"bad":{"mode":"fixed","candidate":{"id":"bad","harness":"grok","model":"grok-example","effort":"xhigh","fast":true}}}}
JSON
set +e
invalid_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" validate "$case_dir/invalid.json" 2>&1)
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || fail "non-Pi fast setting passed validation"
assert_contains "$invalid_out" "fast is supported only for pi and pi-signed" "fast validation"

cat > "$case_dir/invalid-opencode-effort.json" <<'JSON'
{"schema_version":1,"presets":{"bad":{"mode":"fixed","candidate":{"id":"bad","harness":"opencode","model":"vendor/model","effort":"minimal"}}}}
JSON
set +e
invalid_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" validate "$case_dir/invalid-opencode-effort.json" 2>&1)
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || fail "OpenCode effort outside the relaunch-safe vocabulary passed validation"
assert_contains "$invalid_out" "effort 'minimal' is unsupported for opencode" "OpenCode effort validation"

cat > "$case_dir/invalid-grok-max.json" <<'JSON'
{"schema_version":1,"presets":{"bad":{"mode":"fixed","candidate":{"id":"bad","harness":"grok","model":"grok-example","effort":"max"}}}}
JSON
set +e
invalid_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" validate "$case_dir/invalid-grok-max.json" 2>&1)
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || fail "grok max passed validation"
assert_contains "$invalid_out" "effort 'max' is unsupported for grok" "grok max rejection"

metrics_dir="$TMP_ROOT/metrics"
mkdir -p "$metrics_dir/data" "$metrics_dir/state"
make_config "$metrics_dir/config.json"
choice=$(FM_STATE_OVERRIDE="$metrics_dir/state" "$PRESET" select metric-task fixed-example "$metrics_dir/config.json") || fail "metrics choice failed"
printf '%s\n' "$choice" > "$metrics_dir/state/metric-task.dispatch-choice.json"
cat > "$metrics_dir/state/metric-task.meta" <<'META'
harness=pi
kind=ship
model=vendor/model-fixed
effort=high
spawn_gen=s1
dispatch_preset=fixed-example
dispatch_fast=off
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_tool_version=pi-test
dispatch_validation_basis=validated-launch-control
dispatch_generation=metric-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" launch "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" || fail "launch metric failed"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" landed || fail "finish metric failed"
ledger="$metrics_dir/data/dispatch-metrics.jsonl"
[ "$(jq -s 'map(select(.event=="launch-prepared")) | length' "$ledger")" -eq 1 ] || fail "launch event missing"
[ "$(jq -s 'map(select(.event=="finish")) | length' "$ledger")" -eq 1 ] || fail "finish event missing"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].quality.status' "$ledger")" = unknown ] || fail "missing quality was not kept unknown"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].quality.defect_attribution.origin' "$ledger")" = unknown ] || fail "a finish without defect evidence did not stay conservatively unknown"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].quality.defect_attribution.evidence | length' "$ledger")" -eq 0 ] || fail "a finish without defect evidence invented evidence"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].cost.billing_basis' "$ledger")" = estimate-not-invoice ] || fail "cost was not labeled as an estimate"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.fast' "$ledger")" = null ] || fail "requested fast was claimed as effective"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.fast_basis' "$ledger")" = requested-not-wire-verified ] || fail "fast basis was not requested-only"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.basis' "$ledger")" = validated-launch-control ] || fail "the launcher's recorded validation basis was not carried into the ledger"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].totals.status' "$ledger")" = complete ] || fail "explicit launch totals were not complete"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --model-used vendor/model-runtime --effort-used high --fast-server-verified off --quality bug-found --quota-fraction 0.1 --monthly-price-usd 80 --reset-days 7 || fail "observation metric failed"
[ "$(jq -s -r 'map(select(.event=="observation"))[0].cost.weekly_usd' "$ledger")" = 2 ] || fail "weekly estimate formula is wrong"
[ "$(jq -s -r 'map(select(.event=="observation"))[0].quality.defect_origin' "$ledger")" = unknown ] || fail "a bare bug-found status implied a defect origin"
[ "$(jq -s -r 'map(select(.event=="observation"))[0].quality.defect_origin_explicit' "$ledger")" = false ] || fail "an unsupplied defect origin was recorded as explicit"
# The observation is stamped with the task generation so a later finish event
# can scope the evidence to its own task lifetime; with no explicit
# --generation the ledger's latest launch-prepared record supplies it.
[ "$(jq -s -r 'map(select(.event=="observation"))[0].generation' "$ledger")" = metric-generation ] || fail "an observation was not stamped with the task generation"
[ "$(jq -s -r 'map(select(.event=="observation"))[0].generation_basis' "$ledger")" = latest-recorded-launch ] || fail "the derived generation basis was not recorded"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --quota-fraction 0.1 --monthly-price-usd 80 --reset-days 30 || fail "monthly-period observation failed"
[ "$(jq -s -r 'map(select(.event=="observation"))[1].cost.status' "$ledger")" = unknown ] || fail "incompatible reset period was presented as weekly cost"

# A defect origin is evidence from an operator observation, never inferred from
# a quality status. Explicit origins are recorded with their basis and only a
# single agreed origin is attributed by the finish event.
set +e
defect_bad_quality=$(FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --quality passed --defect-origin pre-existing-code 2>&1)
defect_bad_quality_rc=$?
set -e
[ "$defect_bad_quality_rc" -ne 0 ] || fail "a defect origin was accepted on a passed quality status"
assert_contains "$defect_bad_quality" "--defect-origin applies only to a bug-found or bug-escaped quality observation" "defect-origin quality scope"
set +e
defect_bad_origin=$(FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --quality bug-found --defect-origin flaky-implementation 2>&1)
defect_bad_origin_rc=$?
set -e
[ "$defect_bad_origin_rc" -ne 0 ] || fail "an unknown defect origin value was accepted"
assert_contains "$defect_bad_origin" "--defect-origin must be" "defect-origin vocabulary"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --quality bug-found --defect-origin original-implementation-worker --basis "reproduced from the original change" || fail "explicit defect-origin observation failed"
[ "$(jq -s -r 'map(select(.event=="observation"))[2].quality.defect_origin' "$ledger")" = original-implementation-worker ] || fail "an explicit defect origin was not recorded"
[ "$(jq -s -r 'map(select(.event=="observation"))[2].quality.defect_origin_basis' "$ledger")" = "reproduced from the original change" ] || fail "the defect-origin evidence was not recorded"
sed 's/^spawn_gen=s1$/spawn_gen=s2/' "$metrics_dir/state/metric-task.meta" > "$metrics_dir/state/metric-task.meta.tmp"
mv "$metrics_dir/state/metric-task.meta.tmp" "$metrics_dir/state/metric-task.meta"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" landed || fail "defect attribution finish failed"
# The bare bug-found observation above recorded no origin, so the task-level
# attribution must stay unknown even though another defect carries a known
# origin: one defect without a proven cause makes the mixed claim unprovable,
# and the basis names the evidence instead of silently dropping it.
[ "$(jq -s -r 'map(select(.event=="finish"))[1].quality.defect_attribution.origin' "$ledger")" = unknown ] || fail "an implicit unknown-origin defect was hidden behind a known origin"
[ "$(jq -s -r 'map(select(.event=="finish"))[1].quality.defect_attribution.evidence | length' "$ledger")" -eq 2 ] || fail "every recorded observation was not kept as evidence"
[ "$(jq -s -r 'map(select(.event=="finish"))[1].quality.defect_attribution.basis | test("no proven origin")' "$ledger")" = true ] || fail "the mixed-attribution basis did not explain the unknown component"
# An explicitly unattributed defect keeps the same conservative result.
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --quality bug-escaped --defect-origin unknown --basis "the failing change could not be isolated" || fail "explicit unknown defect-origin observation failed"
sed 's/^spawn_gen=s2$/spawn_gen=s3/' "$metrics_dir/state/metric-task.meta" > "$metrics_dir/state/metric-task.meta.tmp"
mv "$metrics_dir/state/metric-task.meta.tmp" "$metrics_dir/state/metric-task.meta"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" landed || fail "mixed defect attribution finish failed"
[ "$(jq -s -r 'map(select(.event=="finish"))[2].quality.defect_attribution.origin' "$ledger")" = unknown ] || fail "an explicitly unattributed defect was hidden behind another origin"
[ "$(jq -s -r 'map(select(.event=="finish"))[2].quality.defect_attribution.basis | test("no proven origin")' "$ledger")" = true ] || fail "the explicitly unknown-attribution reason was not recorded"

# A generation whose recorded defects all carry exactly one known origin is the
# only case where the finish event may name that origin. A defect observation
# from another generation, or one carrying no generation token, is preserved as
# unscoped evidence and can never be inherited by this lifetime.
scoped_choice=$(FM_STATE_OVERRIDE="$metrics_dir/state" "$PRESET" select scoped-defect-task fixed-example "$metrics_dir/config.json") || fail "scoped defect choice failed"
printf '%s\n' "$scoped_choice" > "$metrics_dir/state/scoped-defect-task.dispatch-choice.json"
cat > "$metrics_dir/state/scoped-defect-task.meta" <<'META'
harness=pi
kind=ship
model=vendor/model-fixed
effort=high
spawn_gen=sd1
dispatch_preset=fixed-example
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_generation=scoped-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" launch "$metrics_dir/state/scoped-defect-task.meta" "$metrics_dir/state/scoped-defect-task.dispatch-choice.json" || fail "scoped defect launch failed"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe scoped-defect-task --quality bug-found --defect-origin validation-correction --basis "the validation fix introduced it" || fail "scoped defect observation failed"
scoped_event=$(jq -s -r 'map(select(.event=="observation" and .task_id=="scoped-defect-task"))[0].event_id' "$ledger")
scoped_stamp=$(jq -s -r 'map(select(.event=="observation" and .task_id=="scoped-defect-task"))[0].generation' "$ledger")
[ "$scoped_stamp" = scoped-generation ] || fail "the scoped observation did not inherit the current generation ($scoped_stamp)"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/scoped-defect-task.meta" "$metrics_dir/state/scoped-defect-task.dispatch-choice.json" landed || fail "scoped defect finish failed"
scoped_origin=$(jq -s -r 'map(select(.event=="finish" and .task_id=="scoped-defect-task"))[0].quality.defect_attribution.origin' "$ledger")
[ "$scoped_origin" = validation-correction ] || fail "a single agreed known defect origin was not attributed ($scoped_origin)"
# Reusing the task id for a new lifetime must not inherit the previous
# generation's attributed defect or a legacy observation that carries no
# generation token; both stay visible as unscoped evidence.
printf '%s\n' \
  '{"event":"observation","event_id":"obs-legacy-defect","task_id":"scoped-defect-task","quality":{"status":"bug-found","defect_origin":"pre-existing-code","defect_origin_explicit":true}}' \
  >> "$ledger"
printf '%s\n' \
  '{"event":"observation","event_id":"obs-foreign-generation","task_id":"scoped-defect-task","generation":"other-generation","quality":{"status":"bug-found","defect_origin":"original-implementation-worker"}}' \
  >> "$ledger"
scoped_choice2=$(FM_STATE_OVERRIDE="$metrics_dir/state" "$PRESET" select scoped-defect-task fixed-example "$metrics_dir/config.json") || fail "second scoped choice failed"
printf '%s\n' "$scoped_choice2" > "$metrics_dir/state/scoped-defect-task.dispatch-choice.json"
sed 's/^dispatch_generation=scoped-generation$/dispatch_generation=second-generation/; s/^spawn_gen=sd1$/spawn_gen=sd2/' \
  "$metrics_dir/state/scoped-defect-task.meta" > "$metrics_dir/state/scoped-defect-task.meta.tmp"
mv "$metrics_dir/state/scoped-defect-task.meta.tmp" "$metrics_dir/state/scoped-defect-task.meta"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" launch "$metrics_dir/state/scoped-defect-task.meta" "$metrics_dir/state/scoped-defect-task.dispatch-choice.json" || fail "second scoped launch failed"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/scoped-defect-task.meta" "$metrics_dir/state/scoped-defect-task.dispatch-choice.json" landed || fail "second scoped finish failed"
scoped_reuse_origin=$(jq -s -r 'map(select(.event=="finish" and .task_id=="scoped-defect-task"))[1].quality.defect_attribution.origin' "$ledger")
scoped_reuse_evidence=$(jq -s -r 'map(select(.event=="finish" and .task_id=="scoped-defect-task"))[1].quality.defect_attribution.evidence | length' "$ledger")
scoped_reuse_unscoped=$(jq -s -r 'map(select(.event=="finish" and .task_id=="scoped-defect-task"))[1].quality.defect_attribution.unscoped_evidence | length' "$ledger")
scoped_reuse_scoped=$(jq -s -r --arg id "$scoped_event" 'map(select(.event=="finish" and .task_id=="scoped-defect-task"))[1].quality.defect_attribution.unscoped_evidence | map(select(.event_id==$id)) | length' "$ledger")
scoped_reuse_basis=$(jq -s -r 'map(select(.event=="finish" and .task_id=="scoped-defect-task"))[1].quality.defect_attribution.basis' "$ledger")
[ "$scoped_reuse_origin" = unknown ] || fail "a reused task id inherited a prior generation's defect origin"
[ "$scoped_reuse_evidence" -eq 0 ] || fail "a reused task id inherited prior-generation defect evidence"
[ "$scoped_reuse_unscoped" -eq 3 ] || fail "the unscoped defect observations were not preserved as evidence"
[ "$scoped_reuse_scoped" -eq 1 ] || fail "the previous generation's observation was not listed as unscoped evidence"
assert_contains "$scoped_reuse_basis" "3 defect observation(s) from another generation or without a generation token were not inherited" "unscoped defect evidence basis"
# An explicit --generation wins over the ledger's latest launch and records its
# own basis, so an operator appending an observation for a known lifetime is
# never silently restamped with a newer one.
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe scoped-defect-task --generation pinned-generation --quality bug-found --defect-origin pre-existing-code || fail "explicit-generation observation failed"
pinned_stamp=$(jq -s -r 'map(select(.event=="observation" and .task_id=="scoped-defect-task"))[-1] | .generation + ":" + .generation_basis' "$ledger")
[ "$pinned_stamp" = "pinned-generation:explicit" ] || fail "an explicit generation was not honored ($pinned_stamp)"

# The finish command records whether the cleanup discarded the local copy under
# explicit authorization, as a separate axis from the delivery outcome: a
# delivery classified landed (or unknown) is not turned into a discard claim,
# and a value that is neither true nor false is refused.
sed 's/^spawn_gen=s3$/spawn_gen=s4/' "$metrics_dir/state/metric-task.meta" > "$metrics_dir/state/metric-task.meta.tmp"
mv "$metrics_dir/state/metric-task.meta.tmp" "$metrics_dir/state/metric-task.meta"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" unknown true || fail "discard-authorized finish failed"
[ "$(jq -s -r 'map(select(.event=="finish" and .task_id=="metric-task"))[3].cleanup.discard_authorized' "$ledger")" = true ] || fail "the authorized local discard was not recorded"
[ "$(jq -s -r 'map(select(.event=="finish" and .task_id=="metric-task"))[3].delivery_outcome' "$ledger")" = unknown ] || fail "the authorized discard replaced the classified delivery outcome"
set +e
discard_bad=$(FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" landed maybe 2>&1)
discard_bad_rc=$?
set -e
[ "$discard_bad_rc" -eq 2 ] || fail "an invalid discard-authorized value was accepted"
assert_contains "$discard_bad" "discard-authorized" "discard-authorized usage refusal"

# A quality observation that records no defect is never attribution evidence:
# a passed result or a generic unknown quality must neither add defect evidence
# nor force an unknown-defect verdict, while an actual defect record keeps its
# own explicit origin. These records are hand-written observations representing
# integration producers the way the typed ledger accepts them.
defect_scope_dir="$TMP_ROOT/defect-scope"
mkdir -p "$defect_scope_dir/data" "$defect_scope_dir/state"
printf '%s\n' '{"schema_version":1,"presets":{"fixed":{"mode":"fixed","candidate":{"id":"candidate","harness":"pi","model":"openai-codex/model","effort":"high"}}}}' > "$defect_scope_dir/config.json"
write_defect_scope_meta() {  # <task> <spawn-gen>
  cat > "$defect_scope_dir/state/$1.meta" <<META
harness=pi
kind=ship
model=openai-codex/model
effort=high
spawn_gen=$2
dispatch_preset=fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_generation=defect-scope-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
}
defect_choice=$(FM_STATE_OVERRIDE="$defect_scope_dir/state" "$PRESET" select mixed-defect-task fixed "$defect_scope_dir/config.json") || fail "mixed defect-scope choice failed"
printf '%s\n' "$defect_choice" > "$defect_scope_dir/state/mixed-defect-task.dispatch-choice.json"
write_defect_scope_meta mixed-defect-task s1
scope_ledger="$defect_scope_dir/data/dispatch-metrics.jsonl"
printf '%s\n' \
  '{"event":"observation","event_id":"obs-passed","task_id":"mixed-defect-task","generation":"defect-scope-generation","quality":{"status":"passed","basis":"tests passed","defect_origin":"unknown","defect_origin_explicit":false,"defect_origin_basis":"no defect origin evidence was supplied with this observation"}}' \
  '{"event":"observation","event_id":"obs-unknown","task_id":"mixed-defect-task","generation":"defect-scope-generation","quality":{"status":"unknown","basis":"quality not assessed","defect_origin":"unknown","defect_origin_explicit":true,"defect_origin_basis":"operator left the call open"}}' \
  '{"event":"observation","event_id":"obs-bug","task_id":"mixed-defect-task","generation":"defect-scope-generation","quality":{"status":"bug-found","basis":"reproduced defect","defect_origin":"validation-correction","defect_origin_explicit":true,"defect_origin_basis":"the validation fix introduced it"}}' \
  >> "$scope_ledger"
FM_DATA_OVERRIDE="$defect_scope_dir/data" "$METRICS" finish "$defect_scope_dir/state/mixed-defect-task.meta" "$defect_scope_dir/state/mixed-defect-task.dispatch-choice.json" landed || fail "mixed defect-scope finish failed"
mixed_scope=$(jq -c -s 'map(select(.event=="finish" and .task_id=="mixed-defect-task"))[0].quality.defect_attribution | {origin, evidence: [.evidence[].event_id], basis}' "$scope_ledger")
[ "$mixed_scope" = '{"origin":"validation-correction","evidence":["obs-bug"],"basis":"recorded by defect-origin observation(s) obs-bug"}' ] \
  || fail "non-defect observations polluted defect attribution: $mixed_scope"

# With no defect observation at all, passed and unknown records create no
# attribution result: the finish event stays conservatively unattributed with
# empty evidence instead of claiming a defect whose origin was unknown.
passed_choice=$(FM_STATE_OVERRIDE="$defect_scope_dir/state" "$PRESET" select passed-only-task fixed "$defect_scope_dir/config.json") || fail "passed-only defect-scope choice failed"
printf '%s\n' "$passed_choice" > "$defect_scope_dir/state/passed-only-task.dispatch-choice.json"
write_defect_scope_meta passed-only-task s2
printf '%s\n' \
  '{"event":"observation","event_id":"obs-passed-only","task_id":"passed-only-task","generation":"defect-scope-generation","quality":{"status":"passed","basis":"tests passed","defect_origin":"unknown","defect_origin_explicit":false,"defect_origin_basis":"no defect origin evidence was supplied with this observation"}}' \
  '{"event":"observation","event_id":"obs-unknown-only","task_id":"passed-only-task","generation":"defect-scope-generation","quality":{"status":"unknown","basis":"quality not assessed","defect_origin":"unknown","defect_origin_explicit":true,"defect_origin_basis":"operator left the call open"}}' \
  >> "$scope_ledger"
FM_DATA_OVERRIDE="$defect_scope_dir/data" "$METRICS" finish "$defect_scope_dir/state/passed-only-task.meta" "$defect_scope_dir/state/passed-only-task.dispatch-choice.json" landed || fail "passed-only defect-scope finish failed"
passed_scope=$(jq -c -s 'map(select(.event=="finish" and .task_id=="passed-only-task"))[0].quality.defect_attribution | {origin, evidence: (.evidence | length), basis}' "$scope_ledger")
[ "$passed_scope" = '{"origin":"unknown","evidence":0,"basis":"no defect origin was observed for this task generation"}' ] \
  || fail "non-defect observations created an unknown-defect attribution: $passed_scope"

# A defect observation whose origin field is absent entirely (a legacy or
# foreign producer record) is still an actual defect: it is preserved in
# evidence with an explicit null origin_recorded, and it conservatively blocks
# a more specific attribution even though a known-origin record exists.
absent_choice=$(FM_STATE_OVERRIDE="$defect_scope_dir/state" "$PRESET" select absent-origin-task fixed "$defect_scope_dir/config.json") || fail "absent-origin defect-scope choice failed"
printf '%s\n' "$absent_choice" > "$defect_scope_dir/state/absent-origin-task.dispatch-choice.json"
write_defect_scope_meta absent-origin-task s3
printf '%s\n' \
  '{"event":"observation","event_id":"obs-absent-origin","task_id":"absent-origin-task","generation":"defect-scope-generation","quality":{"status":"bug-found","basis":"reproduced defect with no recorded cause"}}' \
  '{"event":"observation","event_id":"obs-known-later","task_id":"absent-origin-task","generation":"defect-scope-generation","quality":{"status":"bug-found","basis":"reproduced defect","defect_origin":"validation-correction","defect_origin_explicit":true,"defect_origin_basis":"the validation fix introduced it"}}' \
  >> "$scope_ledger"
FM_DATA_OVERRIDE="$defect_scope_dir/data" "$METRICS" finish "$defect_scope_dir/state/absent-origin-task.meta" "$defect_scope_dir/state/absent-origin-task.dispatch-choice.json" landed || fail "absent-origin defect-scope finish failed"
absent_scope=$(jq -c -s 'map(select(.event=="finish" and .task_id=="absent-origin-task"))[0].quality.defect_attribution | {origin, evidence: [.evidence[] | {id: .event_id, origin, recorded: .origin_recorded}], basis}' "$scope_ledger")
[ "$absent_scope" = '{"origin":"unknown","evidence":[{"id":"obs-absent-origin","origin":"unknown","recorded":null},{"id":"obs-known-later","origin":"validation-correction","recorded":"validation-correction"}],"basis":"at least one recorded defect had no proven origin (obs-absent-origin)"}' ] \
  || fail "an absent defect origin did not conservatively block attribution: $absent_scope"

# A finish record with no generation token (a legacy record written before
# generation stamping) cannot scope any observation to its lifetime, so it must
# not attribute a defect: the recorded defects stay listed as unscoped evidence
# with the reason rather than being dropped or silently inherited.
legacy_choice=$(FM_STATE_OVERRIDE="$defect_scope_dir/state" "$PRESET" select legacy-finish-task fixed "$defect_scope_dir/config.json") || fail "legacy-finish defect-scope choice failed"
printf '%s\n' "$legacy_choice" > "$defect_scope_dir/state/legacy-finish-task.dispatch-choice.json"
cat > "$defect_scope_dir/state/legacy-finish-task.meta" <<'META'
harness=pi
kind=ship
model=openai-codex/model
effort=high
spawn_gen=s4
dispatch_preset=fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
printf '%s\n' \
  '{"event":"observation","event_id":"obs-legacy-generationless","task_id":"legacy-finish-task","generation":"defect-scope-generation","quality":{"status":"bug-found","defect_origin":"validation-correction","defect_origin_explicit":true}}' \
  >> "$scope_ledger"
FM_DATA_OVERRIDE="$defect_scope_dir/data" "$METRICS" finish "$defect_scope_dir/state/legacy-finish-task.meta" "$defect_scope_dir/state/legacy-finish-task.dispatch-choice.json" landed || fail "legacy-finish defect-scope finish failed"
legacy_scope=$(jq -c -s 'map(select(.event=="finish" and .task_id=="legacy-finish-task"))[0].quality.defect_attribution | {origin, evidence: (.evidence | length), unscoped: [.unscoped_evidence[].event_id], basis}' "$scope_ledger")
[ "$legacy_scope" = '{"origin":"unknown","evidence":0,"unscoped":["obs-legacy-generationless"],"basis":"the finish record carries no generation token, so recorded defects cannot be scoped to this task lifetime"}' ] \
  || fail "a generationless finish record did not keep defect evidence unscoped: $legacy_scope"

claude_dir="$TMP_ROOT/claude"
mkdir -p "$claude_dir/data" "$claude_dir/state" "$claude_dir/config/projects/worktree"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$claude_dir/config.json"
choice=$(FM_STATE_OVERRIDE="$claude_dir/state" "$PRESET" select claude-task claude-fixed "$claude_dir/config.json") || fail "Claude choice failed"
printf '%s\n' "$choice" > "$claude_dir/state/claude-task.dispatch-choice.json"
write_claude_meta() {
  cat > "$claude_dir/state/claude-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=$1
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=$2
dispatch_generation=claude-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
}
# Claude Code writes one transcript line per assistant content block; every
# block of one response repeats the same message.id and the same usage. Agent
# tool subagents write their own transcripts under <session>/subagents/, and
# each of those mirrors the spawning message into the subagent file, so the
# usage must be deduplicated across the main transcript and every subagent file.
subagents_dir="$claude_dir/config/projects/worktree/11111111-2222-3333-4444-555555555555/subagents"
mkdir -p "$subagents_dir"
transcript="$claude_dir/config/projects/worktree/11111111-2222-3333-4444-555555555555.jsonl"
usage_a='{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":30,"output_tokens_details":{"thinking_tokens":7},"speed":"standard","service_tier":"priority"}'
usage_b='{"input_tokens":20,"cache_read_input_tokens":200,"cache_creation_input_tokens":0,"output_tokens":50,"output_tokens_details":{"thinking_tokens":0},"speed":"fast"}'
usage_c='{"input_tokens":5,"cache_read_input_tokens":50,"cache_creation_input_tokens":1,"output_tokens":6,"output_tokens_details":{"thinking_tokens":2}}'
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  for block in thinking text tool_use; do
    printf '{"type":"assistant","effort":"medium","message":{"id":"msg_a","model":"claude-opus-5","usage":%s,"content":[{"type":"%s"}]}}\n' "$usage_a" "$block"
  done
  printf '{"type":"assistant","effort":"medium","message":{"id":"msg_b","model":"claude-opus-5","usage":%s,"content":[{"type":"text"}]}}\n' "$usage_b"
  # Some Claude versions inline sidechain records in the main transcript; the
  # mirrored spawning message must not be counted twice or override the main
  # worker's model.
  printf '{"type":"assistant","isSidechain":true,"agentId":"abc","message":{"id":"msg_a","model":"claude-haiku-4","usage":%s,"content":[{"type":"tool_use"}]}}\n' "$usage_a"
} > "$transcript"
{
  printf '{"type":"assistant","isSidechain":true,"agentId":"abc","message":{"id":"msg_a","model":"claude-opus-5","usage":%s,"content":[{"type":"tool_use"}]}}\n' "$usage_a"
  printf '{"type":"assistant","isSidechain":true,"agentId":"abc","message":{"id":"msg_c","model":"claude-haiku-4","usage":%s,"content":[{"type":"text"}]}}\n' "$usage_c"
} > "$subagents_dir/agent-one.jsonl"
write_claude_meta s1 11111111-2222-3333-4444-555555555555
CLAUDE_CONFIG_DIR="$claude_dir/config" FM_DATA_OVERRIDE="$claude_dir/data" "$METRICS" finish \
  "$claude_dir/state/claude-task.meta" "$claude_dir/state/claude-task.dispatch-choice.json" landed || fail "Claude finish metric failed"
claude_ledger="$claude_dir/data/dispatch-metrics.jsonl"
observed=$(jq -c -s 'map(select(.event=="finish"))[0].runtime_observed | {model_used, effort_used, speed, service_tier, subagents: .subagent_transcripts, usage: (.usage | {status, responses, subagent_responses, subagent_transcripts, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, thinking_tokens})}' "$claude_ledger")
[ "$observed" = '{"model_used":"claude-opus-5","effort_used":"medium","speed":"fast","service_tier":"priority","subagents":1,"usage":{"status":"recorded-local","responses":3,"subagent_responses":1,"subagent_transcripts":1,"input_tokens":35,"cache_read_tokens":350,"cache_creation_tokens":6,"output_tokens":86,"thinking_tokens":9}}' ] \
  || fail "Claude transcript usage was not deduplicated across subagent transcripts: $observed"

# A usage line without a stable message id cannot be deduplicated, so the
# usage observation stays unknown instead of recording a possibly inflated sum.
printf '{"type":"assistant","message":{"model":"claude-opus-5","usage":%s,"content":[{"type":"text"}]}}\n' "$usage_b" >> "$transcript"
write_claude_meta s2 11111111-2222-3333-4444-555555555555
CLAUDE_CONFIG_DIR="$claude_dir/config" FM_DATA_OVERRIDE="$claude_dir/data" "$METRICS" finish \
  "$claude_dir/state/claude-task.meta" "$claude_dir/state/claude-task.dispatch-choice.json" landed || fail "Claude unidentified finish metric failed"
observed=$(jq -c -s 'map(select(.event=="finish"))[1] | {status: .runtime_observed.status, model: .runtime_observed.model_used, usage: .usage.status}' "$claude_ledger")
[ "$observed" = '{"status":"observed","model":"claude-opus-5","usage":"unknown"}' ] \
  || fail "Claude usage without message identity was not kept unknown: $observed"

# A missing Claude transcript keeps the observation unknown with its own
# precise reason and an explicit unknown usage block, never a bare reason.
write_claude_meta s3 99999999-9999-9999-9999-999999999999
CLAUDE_CONFIG_DIR="$claude_dir/config" FM_DATA_OVERRIDE="$claude_dir/data" "$METRICS" finish \
  "$claude_dir/state/claude-task.meta" "$claude_dir/state/claude-task.dispatch-choice.json" landed || fail "Claude missing-transcript finish metric failed"
claude_missing=$(jq -c -s 'map(select(.event=="finish"))[2] | {status: .runtime_observed.status, usage: .usage.status, reason: .usage.reason}' "$claude_ledger")
[ "$claude_missing" = '{"status":"unknown","usage":"unknown","reason":"expected one Claude transcript, found 0"}' ] \
  || fail "a missing Claude transcript did not carry its precise unknown usage block: $claude_missing"

# A transcript that exists but carries no attributable assistant line returns
# null usage. The observation and the finish event's usage block must name that
# cause instead of the generic "no observation was supplied" fallback.
session_noline=77777777-1111-2222-3333-444444444444
transcript_noline="$claude_dir/config/projects/worktree/$session_noline.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}' > "$transcript_noline"
write_claude_meta s4 "$session_noline"
CLAUDE_CONFIG_DIR="$claude_dir/config" FM_DATA_OVERRIDE="$claude_dir/data" "$METRICS" finish \
  "$claude_dir/state/claude-task.meta" "$claude_dir/state/claude-task.dispatch-choice.json" landed || fail "Claude no-assistant-line finish metric failed"
claude_noline=$(jq -c -s 'map(select(.event=="finish"))[3] | {status: .runtime_observed.status, reason: .runtime_observed.reason, usage_status: .usage.status, usage_reason: .usage.reason}' "$claude_ledger")
case "$claude_noline" in
  *'"status":"unknown"'*'"reason":"no attributable assistant line'*'"usage_status":"unknown"'*'"usage_reason":"no attributable assistant line'*) ;;
  *) fail "a Claude transcript without an attributable assistant line did not carry the precise per-incarnation reason: $claude_noline" ;;
esac
case "$claude_noline" in
  *"no task-attributable provider usage observation was supplied"*) fail "an empty Claude transcript fell back to the generic usage reason: $claude_noline" ;;
esac
pass "a Claude transcript without an assistant line names the precise null-usage cause"

# An existing but unreadable transcript also returns null usage; the reason
# must name the unreadable path rather than the generic fallback.
session_unreadable=88888888-1111-2222-3333-444444444444
transcript_unreadable="$claude_dir/config/projects/worktree/$session_unreadable.jsonl"
printf '%s\n' '{"type":"assistant","message":{"id":"msg_x","model":"claude-opus-5","usage":{"input_tokens":1}}}' > "$transcript_unreadable"
chmod 000 "$transcript_unreadable"
write_claude_meta s5 "$session_unreadable"
CLAUDE_CONFIG_DIR="$claude_dir/config" FM_DATA_OVERRIDE="$claude_dir/data" "$METRICS" finish \
  "$claude_dir/state/claude-task.meta" "$claude_dir/state/claude-task.dispatch-choice.json" landed || fail "Claude unreadable-transcript finish metric failed"
claude_unreadable=$(jq -c -s 'map(select(.event=="finish"))[4] | {status: .runtime_observed.status, reason: .runtime_observed.reason, usage_status: .usage.status, usage_reason: .usage.reason}' "$claude_ledger")
case "$claude_unreadable" in
  *'"status":"unknown"'*"$transcript_unreadable"*'"usage_status":"unknown"'*"$transcript_unreadable"*) ;;
  *) fail "an unreadable Claude transcript did not name the unreadable path as its null-usage cause: $claude_unreadable" ;;
esac
case "$claude_unreadable" in
  *"no task-attributable provider usage observation was supplied"*) fail "an unreadable Claude transcript fell back to the generic usage reason: $claude_unreadable" ;;
esac
chmod 600 "$transcript_unreadable"
pass "an unreadable Claude transcript names the unreadable path as its null-usage cause"

# A relaunch re-mints the runtime session id and records a second
# launch-prepared event. The finish event must aggregate every recorded
# incarnation instead of counting only the last one, and it must stay unknown
# when any incarnation's local record is unavailable.
relaunch_dir="$TMP_ROOT/claude-relaunch"
mkdir -p "$relaunch_dir/data" "$relaunch_dir/state" "$relaunch_dir/config/projects/worktree"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$relaunch_dir/config.json"
relaunch_choice=$(FM_STATE_OVERRIDE="$relaunch_dir/state" "$PRESET" select relaunch-task claude-fixed "$relaunch_dir/config.json") || fail "relaunch choice failed"
printf '%s\n' "$relaunch_choice" > "$relaunch_dir/state/relaunch-task.dispatch-choice.json"
write_relaunch_meta() {
  cat > "$relaunch_dir/state/relaunch-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=$1
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=$2
dispatch_generation=relaunch-generation
dispatch_launch_kind=$3
dispatch_choice_reused=1
META
}
session_a=aaaaaaaa-1111-2222-3333-444444444444
session_b=bbbbbbbb-1111-2222-3333-444444444444
write_relaunch_meta s1 "$session_a" spawn
FM_DATA_OVERRIDE="$relaunch_dir/data" "$METRICS" launch \
  "$relaunch_dir/state/relaunch-task.meta" "$relaunch_dir/state/relaunch-task.dispatch-choice.json" || fail "first incarnation launch metric failed"
write_relaunch_meta s2 "$session_b" relaunch
FM_DATA_OVERRIDE="$relaunch_dir/data" "$METRICS" launch \
  "$relaunch_dir/state/relaunch-task.meta" "$relaunch_dir/state/relaunch-task.dispatch-choice.json" || fail "second incarnation launch metric failed"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '{"type":"assistant","effort":"medium","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":30,"output_tokens_details":{"thinking_tokens":7},"speed":"standard","service_tier":"priority"},"content":[{"type":"text"}]}}\n'
  printf '{"type":"assistant","effort":"medium","message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":20,"cache_read_input_tokens":200,"cache_creation_input_tokens":0,"output_tokens":50,"output_tokens_details":{"thinking_tokens":0},"speed":"fast"},"content":[{"type":"text"}]}}\n'
} > "$relaunch_dir/config/projects/worktree/$session_a.jsonl"
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_c","model":"claude-opus-5","usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":4,"output_tokens_details":{"thinking_tokens":5},"speed":"fast","service_tier":"default"},"content":[{"type":"text"}]}}\n' > "$relaunch_dir/config/projects/worktree/$session_b.jsonl"
CLAUDE_CONFIG_DIR="$relaunch_dir/config" FM_DATA_OVERRIDE="$relaunch_dir/data" "$METRICS" finish \
  "$relaunch_dir/state/relaunch-task.meta" "$relaunch_dir/state/relaunch-task.dispatch-choice.json" landed || fail "relaunch finish metric failed"
relaunch_ledger="$relaunch_dir/data/dispatch-metrics.jsonl"
aggregated=$(jq -c -s 'map(select(.event=="finish"))[0].runtime_observed | {status, sessions, model_used, effort_used, speed, service_tier, usage: (.usage | {status, responses, incarnations, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, thinking_tokens})}' "$relaunch_ledger")
[ "$aggregated" = "{\"status\":\"observed\",\"sessions\":[\"$session_a\",\"$session_b\"],\"model_used\":\"claude-opus-5\",\"effort_used\":\"medium\",\"speed\":\"fast\",\"service_tier\":\"default\",\"usage\":{\"status\":\"recorded-local\",\"responses\":3,\"incarnations\":2,\"input_tokens\":31,\"cache_read_tokens\":302,\"cache_creation_tokens\":8,\"output_tokens\":84,\"thinking_tokens\":12}}" ] \
  || fail "relaunch usage was not aggregated across both incarnations: $aggregated"

# Drop the latest incarnation's transcript: the finish event must not present a
# partial sum as a recorded observation.
rm -f "$relaunch_dir/config/projects/worktree/$session_b.jsonl"
write_relaunch_meta s3 "$session_b" relaunch
CLAUDE_CONFIG_DIR="$relaunch_dir/config" FM_DATA_OVERRIDE="$relaunch_dir/data" "$METRICS" finish \
  "$relaunch_dir/state/relaunch-task.meta" "$relaunch_dir/state/relaunch-task.dispatch-choice.json" landed || fail "relaunch partial finish metric failed"
partial=$(jq -c -s 'map(select(.event=="finish"))[1] | {status: .runtime_observed.status, sessions: .runtime_observed.sessions, usage: .usage.status, reason: .runtime_observed.usage.reason}' "$relaunch_ledger")
case "$partial" in *'"status":"unknown"'*) ;; *) fail "incomplete relaunch observation was not unknown: $partial" ;; esac
case "$partial" in *"$session_b"*) ;; *) fail "incomplete relaunch observation did not name the unavailable incarnation: $partial" ;; esac

# A relaunch can change harness, leaving launch-ledger incarnations from more
# than one harness. Local session stores are not a compatible unit across them,
# so the finish event must not drop the foreign incarnation and present one
# harness's total as the task's complete usage: it reports the observation
# unknown with the reason instead.
cross_dir="$TMP_ROOT/cross-harness"
mkdir -p "$cross_dir/data" "$cross_dir/state" "$cross_dir/config/projects/worktree"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$cross_dir/config.json"
cross_choice=$(FM_STATE_OVERRIDE="$cross_dir/state" "$PRESET" select cross-task claude-fixed "$cross_dir/config.json") || fail "cross-harness choice failed"
printf '%s\n' "$cross_choice" > "$cross_dir/state/cross-task.dispatch-choice.json"
write_cross_meta() {  # <harness> <model> <spawn-gen> <runtime-session>
  cat > "$cross_dir/state/cross-task.meta" <<META
harness=$1
kind=ship
model=$2
effort=medium
spawn_gen=$3
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=$4
dispatch_generation=cross-generation
dispatch_launch_kind=$5
dispatch_choice_reused=1
META
}
cross_claude=cccccccc-1111-2222-3333-444444444444
cross_grok=dddddddd-1111-2222-3333-444444444444
write_cross_meta claude opus s1 "$cross_claude" spawn
FM_DATA_OVERRIDE="$cross_dir/data" "$METRICS" launch \
  "$cross_dir/state/cross-task.meta" "$cross_dir/state/cross-task.dispatch-choice.json" || fail "claude incarnation launch metric failed"
write_cross_meta grok grok-4.6 s2 "$cross_grok" relaunch
FM_DATA_OVERRIDE="$cross_dir/data" "$METRICS" launch \
  "$cross_dir/state/cross-task.meta" "$cross_dir/state/cross-task.dispatch-choice.json" || fail "grok incarnation launch metric failed"
# The claude incarnation has a complete local transcript; the grok incarnation
# has none. Reporting only the claude total would look complete but be partial.
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":30,"output_tokens_details":{"thinking_tokens":7},"speed":"standard","service_tier":"priority"},"content":[{"type":"text"}]}}\n' \
  > "$cross_dir/config/projects/worktree/$cross_claude.jsonl"
# Finish on the claude incarnation, whose transcript is complete.
write_cross_meta claude opus s3 "$cross_claude" relaunch
CLAUDE_CONFIG_DIR="$cross_dir/config" FM_DATA_OVERRIDE="$cross_dir/data" "$METRICS" finish \
  "$cross_dir/state/cross-task.meta" "$cross_dir/state/cross-task.dispatch-choice.json" landed || fail "cross-harness finish metric failed"
cross_ledger="$cross_dir/data/dispatch-metrics.jsonl"
cross_observed=$(jq -c -s 'map(select(.event=="finish"))[0] | {status: .runtime_observed.status, partial: .runtime_observed.partial, model: .runtime_observed.model_used, usage: .usage.status, sessions: [.runtime_observed.sessions[].session_id], reason: .runtime_observed.reason}' "$cross_ledger")
case "$cross_observed" in *'"status":"unknown"'*) ;; *) fail "cross-harness usage was presented as a complete observation: $cross_observed" ;; esac
case "$cross_observed" in *'"partial":true'*) ;; *) fail "cross-harness usage was not marked partial: $cross_observed" ;; esac
case "$cross_observed" in *'"usage":"unknown"'*) ;; *) fail "cross-harness usage was not kept unknown: $cross_observed" ;; esac
case "$cross_observed" in *'"model":null'*) ;; *) fail "cross-harness finish attributed a model from one harness: $cross_observed" ;; esac
case "$cross_observed" in *"$cross_claude"*"$cross_grok"*) ;; *) fail "cross-harness finish did not name both incarnations: $cross_observed" ;; esac
case "$cross_observed" in *"cross-harness"*) ;; *) fail "cross-harness finish did not state the reason: $cross_observed" ;; esac

# A single-harness incarnation set still aggregates exactly as before, so the
# guard above does not disable ordinary relaunch aggregation.
same_dir="$TMP_ROOT/same-harness-regression"
mkdir -p "$same_dir/data" "$same_dir/state" "$same_dir/config/projects/worktree"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$same_dir/config.json"
same_choice=$(FM_STATE_OVERRIDE="$same_dir/state" "$PRESET" select same-task claude-fixed "$same_dir/config.json") || fail "same-harness choice failed"
printf '%s\n' "$same_choice" > "$same_dir/state/same-task.dispatch-choice.json"
write_same_meta() {  # <spawn-gen> <runtime-session>
  cat > "$same_dir/state/same-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=$1
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=$2
dispatch_generation=same-generation
dispatch_launch_kind=$3
dispatch_choice_reused=$4
META
}
same_a=aaaaaaaa-1111-2222-3333-444444444401
same_b=bbbbbbbb-1111-2222-3333-444444444402
write_same_meta s1 "$same_a" spawn 0
FM_DATA_OVERRIDE="$same_dir/data" "$METRICS" launch "$same_dir/state/same-task.meta" "$same_dir/state/same-task.dispatch-choice.json" || fail "same-harness first launch metric failed"
write_same_meta s2 "$same_b" relaunch 1
FM_DATA_OVERRIDE="$same_dir/data" "$METRICS" launch "$same_dir/state/same-task.meta" "$same_dir/state/same-task.dispatch-choice.json" || fail "same-harness second launch metric failed"
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":30},"content":[{"type":"text"}]}}\n' > "$same_dir/config/projects/worktree/$same_a.jsonl"
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text"}]}}\n' > "$same_dir/config/projects/worktree/$same_b.jsonl"
write_same_meta s3 "$same_b" relaunch 1
CLAUDE_CONFIG_DIR="$same_dir/config" FM_DATA_OVERRIDE="$same_dir/data" "$METRICS" finish \
  "$same_dir/state/same-task.meta" "$same_dir/state/same-task.dispatch-choice.json" landed || fail "same-harness finish metric failed"
same_observed=$(jq -c -s 'map(select(.event=="finish"))[0] | {status: .runtime_observed.status, usage: .usage.status, incarnations: .runtime_observed.usage.incarnations, responses: .runtime_observed.usage.responses, input: .runtime_observed.usage.input_tokens, output: .runtime_observed.usage.output_tokens}' "$same_dir/data/dispatch-metrics.jsonl")
[ "$same_observed" = '{"status":"observed","usage":"recorded-local","incarnations":2,"responses":2,"input":11,"output":32}' ] \
  || fail "same-harness relaunch aggregation regressed: $same_observed"

# Grok writes its authoritative local token totals to usage.json beside the
# session summary; the finish event must collect them instead of leaving usage
# unknown, and an incarnation without that file stays unknown rather than zero.
grok_dir="$TMP_ROOT/grok-usage"
mkdir -p "$grok_dir/data" "$grok_dir/state" "$grok_dir/grokhome/sessions/%2Ftmp%2Fgrok-wt/01a0-grok"
printf '%s\n' '{"schema_version":1,"presets":{"grok-fixed":{"mode":"fixed","candidate":{"id":"grok","harness":"grok","model":"grok-4.6","effort":"xhigh"}}}}' > "$grok_dir/config.json"
grok_choice=$(FM_STATE_OVERRIDE="$grok_dir/state" "$PRESET" select grok-task grok-fixed "$grok_dir/config.json") || fail "Grok choice failed"
printf '%s\n' "$grok_choice" > "$grok_dir/state/grok-task.dispatch-choice.json"
write_grok_meta() {
  cat > "$grok_dir/state/grok-task.meta" <<META
harness=grok
kind=ship
model=grok-4.6
effort=xhigh
spawn_gen=$1
worktree=/tmp/grok-wt
dispatch_preset=grok-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=01a0-grok
dispatch_generation=grok-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
}
write_grok_meta s1
cat > "$grok_dir/grokhome/sessions/%2Ftmp%2Fgrok-wt/01a0-grok/summary.json" <<'JSON'
{"info":{"id":"01a0-grok","cwd":"/tmp/grok-wt"},"current_model_id":"grok-4.6","reasoning_effort":"xhigh","num_messages":2}
JSON
cat > "$grok_dir/grokhome/sessions/%2Ftmp%2Fgrok-wt/01a0-grok/usage.json" <<'JSON'
{"sessionId":"01a0-grok","session":{"inputTokens":1000,"outputTokens":50,"cachedReadTokens":400,"cacheCreationTokens":25,"reasoningTokens":9,"totalTokens":1050,"modelCalls":3,"primaryModelId":"grok-4.6"},"turns":[]}
JSON
GROK_HOME="$grok_dir/grokhome" FM_DATA_OVERRIDE="$grok_dir/data" "$METRICS" launch \
  "$grok_dir/state/grok-task.meta" "$grok_dir/state/grok-task.dispatch-choice.json" || fail "Grok launch metric failed"
GROK_HOME="$grok_dir/grokhome" FM_DATA_OVERRIDE="$grok_dir/data" "$METRICS" finish \
  "$grok_dir/state/grok-task.meta" "$grok_dir/state/grok-task.dispatch-choice.json" landed || fail "Grok finish metric failed"
grok_observed=$(jq -c -s 'map(select(.event=="finish"))[0].runtime_observed | {status, model_used, effort_used, usage: (.usage | {status, responses, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, thinking_tokens})}' "$grok_dir/data/dispatch-metrics.jsonl")
[ "$grok_observed" = '{"status":"observed","model_used":"grok-4.6","effort_used":"xhigh","usage":{"status":"recorded-local","responses":3,"input_tokens":1000,"cache_read_tokens":400,"cache_creation_tokens":25,"output_tokens":50,"thinking_tokens":9}}' ] \
  || fail "Grok usage.json was not collected: $grok_observed"
rm -f "$grok_dir/grokhome/sessions/%2Ftmp%2Fgrok-wt/01a0-grok/usage.json"
write_grok_meta s2
GROK_HOME="$grok_dir/grokhome" FM_DATA_OVERRIDE="$grok_dir/data" "$METRICS" finish \
  "$grok_dir/state/grok-task.meta" "$grok_dir/state/grok-task.dispatch-choice.json" landed || fail "Grok partial finish metric failed"
grok_partial=$(jq -c -s 'map(select(.event=="finish"))[1] | {status: .runtime_observed.status, usage: .usage.status, reason: .runtime_observed.usage.reason}' "$grok_dir/data/dispatch-metrics.jsonl")
case "$grok_partial" in *'"usage":"unknown"'*'no local Grok usage.json'*) ;; *) fail "a missing Grok usage.json was not kept unknown: $grok_partial" ;; esac

# A Grok relaunch aggregates every recorded incarnation, and when any one of
# them lacks its local usage record the whole observation stays unknown with
# that incarnation's own precise reason and an explicit unknown usage block.
grok_relaunch="$TMP_ROOT/grok-relaunch"
mkdir -p "$grok_relaunch/data" "$grok_relaunch/state" "$grok_relaunch/grokhome/sessions/%2Ftmp%2Fgrok-relaunch-wt/01a0-grok-a" "$grok_relaunch/grokhome/sessions/%2Ftmp%2Fgrok-relaunch-wt/01a0-grok-b"
printf '%s\n' '{"schema_version":1,"presets":{"grok-fixed":{"mode":"fixed","candidate":{"id":"grok","harness":"grok","model":"grok-4.6","effort":"xhigh"}}}}' > "$grok_relaunch/config.json"
grok_relaunch_choice=$(FM_STATE_OVERRIDE="$grok_relaunch/state" "$PRESET" select grok-relaunch-task grok-fixed "$grok_relaunch/config.json") || fail "Grok relaunch choice failed"
printf '%s\n' "$grok_relaunch_choice" > "$grok_relaunch/state/grok-relaunch-task.dispatch-choice.json"
write_grok_relaunch_meta() {  # <spawn-gen> <session> <kind>
  cat > "$grok_relaunch/state/grok-relaunch-task.meta" <<META
harness=grok
kind=ship
model=grok-4.6
effort=xhigh
spawn_gen=$1
worktree=/tmp/grok-relaunch-wt
dispatch_preset=grok-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=$2
dispatch_generation=grok-relaunch-generation
dispatch_launch_kind=$3
dispatch_choice_reused=1
META
}
cat > "$grok_relaunch/grokhome/sessions/%2Ftmp%2Fgrok-relaunch-wt/01a0-grok-a/summary.json" <<'JSON'
{"info":{"id":"01a0-grok-a"},"current_model_id":"grok-4.6","reasoning_effort":"xhigh"}
JSON
cat > "$grok_relaunch/grokhome/sessions/%2Ftmp%2Fgrok-relaunch-wt/01a0-grok-a/usage.json" <<'JSON'
{"sessionId":"01a0-grok-a","session":{"inputTokens":100,"outputTokens":10,"cachedReadTokens":5,"cacheCreationTokens":1,"reasoningTokens":2,"modelCalls":1},"turns":[]}
JSON
cat > "$grok_relaunch/grokhome/sessions/%2Ftmp%2Fgrok-relaunch-wt/01a0-grok-b/summary.json" <<'JSON'
{"info":{"id":"01a0-grok-b"},"current_model_id":"grok-4.6","reasoning_effort":"xhigh"}
JSON
write_grok_relaunch_meta s1 01a0-grok-a spawn
GROK_HOME="$grok_relaunch/grokhome" FM_DATA_OVERRIDE="$grok_relaunch/data" "$METRICS" launch \
  "$grok_relaunch/state/grok-relaunch-task.meta" "$grok_relaunch/state/grok-relaunch-task.dispatch-choice.json" || fail "Grok relaunch first launch metric failed"
write_grok_relaunch_meta s2 01a0-grok-b relaunch
GROK_HOME="$grok_relaunch/grokhome" FM_DATA_OVERRIDE="$grok_relaunch/data" "$METRICS" launch \
  "$grok_relaunch/state/grok-relaunch-task.meta" "$grok_relaunch/state/grok-relaunch-task.dispatch-choice.json" || fail "Grok relaunch second launch metric failed"
GROK_HOME="$grok_relaunch/grokhome" FM_DATA_OVERRIDE="$grok_relaunch/data" "$METRICS" finish \
  "$grok_relaunch/state/grok-relaunch-task.meta" "$grok_relaunch/state/grok-relaunch-task.dispatch-choice.json" landed || fail "Grok relaunch finish metric failed"
grok_relaunch_observed=$(jq -c -s 'map(select(.event=="finish"))[0] | {status: .runtime_observed.status, partial: .runtime_observed.partial, sessions: [.runtime_observed.sessions[].session_id], usage: .usage.status, reason: .usage.reason}' "$grok_relaunch/data/dispatch-metrics.jsonl")
case "$grok_relaunch_observed" in
  *'"status":"unknown"'*'"partial":true'*'01a0-grok-a'*'01a0-grok-b'*'"usage":"unknown"'*'no local Grok usage.json'*) ;;
  *) fail "a partial Grok relaunch did not keep both incarnations and the precise cause: $grok_relaunch_observed" ;;
esac

# Pi records the richest local usage split in its own session JSONL files. The
# finish event attributes them to this task by worktree path and launch window,
# so sessions from another directory or from before the task started stay out.
pi_dir="$TMP_ROOT/pi-usage"
mkdir -p "$pi_dir/data" "$pi_dir/state" "$pi_dir/wt" "$pi_dir/piagent/sessions/--one--" "$pi_dir/piagent/sessions/--two--"
printf '%s\n' '{"schema_version":1,"presets":{"pi-fixed":{"mode":"fixed","candidate":{"id":"pi","harness":"pi","model":"openai-codex/model-pi","effort":"max"}}}}' > "$pi_dir/config.json"
pi_choice=$(FM_STATE_OVERRIDE="$pi_dir/state" "$PRESET" select pi-task pi-fixed "$pi_dir/config.json") || fail "Pi choice failed"
printf '%s\n' "$pi_choice" > "$pi_dir/state/pi-task.dispatch-choice.json"
cat > "$pi_dir/state/pi-task.meta" <<META
harness=pi
kind=ship
model=openai-codex/model-pi
effort=max
spawn_gen=s1
worktree=$pi_dir/wt
dispatch_preset=pi-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1767225600
dispatch_generation=pi-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
{
  printf '{"type":"session","version":3,"id":"pi-main","timestamp":"2026-01-01T00:00:10.000Z","cwd":"%s"}\n' "$pi_dir/wt"
  printf '%s\n' '{"type":"thinking_level_change","id":"t1","parentId":null,"timestamp":"2026-01-01T00:00:11.000Z","thinkingLevel":"max"}'
  printf '%s\n' '{"type":"message","id":"m1","parentId":"t1","timestamp":"2026-01-01T00:00:12.000Z","message":{"role":"assistant","provider":"openai-codex","model":"model-pi","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":5,"reasoning":7,"totalTokens":162},"stopReason":"toolUse"}}'
  printf '%s\n' '{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:00:13.000Z","message":{"role":"assistant","provider":"openai-codex","model":"model-pi","usage":{"input":10,"output":2,"cacheRead":3,"cacheWrite":0,"reasoning":1,"totalTokens":16},"stopReason":"stop"}}'
} > "$pi_dir/piagent/sessions/--one--/2026-01-01T00-00-10-000Z_pi-main.jsonl"
{
  printf '%s\n' '{"type":"session","version":3,"id":"pi-other","timestamp":"2026-01-01T00:00:10.000Z","cwd":"/tmp/somewhere-else"}'
  printf '%s\n' '{"type":"message","id":"else1","parentId":null,"timestamp":"2026-01-01T00:00:12.000Z","message":{"role":"assistant","provider":"openai-codex","model":"model-pi","usage":{"input":9999,"output":9999,"cacheRead":0,"cacheWrite":0,"reasoning":0},"stopReason":"stop"}}'
} > "$pi_dir/piagent/sessions/--two--/2026-01-01T00-00-10-000Z_pi-other.jsonl"
{
  printf '{"type":"session","version":3,"id":"pi-old","timestamp":"2020-01-01T00:00:10.000Z","cwd":"%s"}\n' "$pi_dir/wt"
  printf '%s\n' '{"type":"message","id":"old1","parentId":null,"timestamp":"2020-01-01T00:00:12.000Z","message":{"role":"assistant","provider":"openai-codex","model":"model-pi","usage":{"input":5000,"output":5000},"stopReason":"stop"}}'
} > "$pi_dir/piagent/sessions/--one--/2020-01-01T00-00-10-000Z_pi-old.jsonl"
# A reused worktree slot must not pull in whatever ran immediately before this
# generation: a session that began one tenth of a second before the recorded
# dispatch start is already the previous occupant's, so there is deliberately
# no pre-launch allowance around the boundary.
{
  printf '{"type":"session","version":3,"id":"pi-skew","timestamp":"2025-12-31T23:59:59.900Z","cwd":"%s"}\n' "$pi_dir/wt"
  printf '%s\n' '{"type":"message","id":"skew1","parentId":null,"timestamp":"2025-12-31T23:59:59.900Z","message":{"role":"assistant","provider":"openai-codex","model":"model-pi","usage":{"input":7000,"output":7000},"stopReason":"stop"}}'
} > "$pi_dir/piagent/sessions/--two--/2025-12-31T23-59-59-900Z_pi-skew.jsonl"
PI_CODING_AGENT_DIR="$pi_dir/piagent" FM_DATA_OVERRIDE="$pi_dir/data" "$METRICS" launch \
  "$pi_dir/state/pi-task.meta" "$pi_dir/state/pi-task.dispatch-choice.json" || fail "Pi launch metric failed"
PI_CODING_AGENT_DIR="$pi_dir/piagent" FM_DATA_OVERRIDE="$pi_dir/data" "$METRICS" finish \
  "$pi_dir/state/pi-task.meta" "$pi_dir/state/pi-task.dispatch-choice.json" landed || fail "Pi finish metric failed"
pi_observed=$(jq -c -s 'map(select(.event=="finish"))[0].runtime_observed | {status, model_used, effort_used, sessions, usage: (.usage | {status, responses, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, thinking_tokens})}' "$pi_dir/data/dispatch-metrics.jsonl")
[ "$pi_observed" = '{"status":"observed","model_used":"openai-codex/model-pi","effort_used":"max","sessions":["pi-main"],"usage":{"status":"recorded-local","responses":2,"input_tokens":110,"cache_read_tokens":33,"cache_creation_tokens":5,"output_tokens":22,"thinking_tokens":8}}' ] \
  || fail "Pi session usage was not collected or was attributed outside the task window: $pi_observed"

# A matched Pi session with no measurable turn cannot be proven zero.
printf '{"type":"session","version":3,"id":"pi-empty","timestamp":"2026-01-01T00:01:10.000Z","cwd":"%s"}\n' "$pi_dir/wt" \
  > "$pi_dir/piagent/sessions/--two--/2026-01-01T00-01-10-000Z_pi-empty.jsonl"
sed 's/^spawn_gen=s1$/spawn_gen=s2/' "$pi_dir/state/pi-task.meta" > "$pi_dir/state/pi-task.meta.tmp"
mv "$pi_dir/state/pi-task.meta.tmp" "$pi_dir/state/pi-task.meta"
PI_CODING_AGENT_DIR="$pi_dir/piagent" FM_DATA_OVERRIDE="$pi_dir/data" "$METRICS" finish \
  "$pi_dir/state/pi-task.meta" "$pi_dir/state/pi-task.dispatch-choice.json" landed || fail "Pi partial finish metric failed"
pi_partial=$(jq -c -s 'map(select(.event=="finish"))[1] | {status: .runtime_observed.status, partial: .runtime_observed.partial, usage: .usage.status, reason: .runtime_observed.usage.reason}' "$pi_dir/data/dispatch-metrics.jsonl")
case "$pi_partial" in *'"status":"unknown"'*'"partial":true'*'without measurable usage'*) ;; *) fail "a Pi session without measurable usage was presented as recorded: $pi_partial" ;; esac

# OpenCode keeps its authoritative session/message store in sqlite. The finish
# event attributes sessions by resolved directory and launch window, counts the
# child (subagent) session totals separately, and records the exact variant the
# session ran.
oc_dir="$TMP_ROOT/opencode-usage"
mkdir -p "$oc_dir/data" "$oc_dir/state" "$oc_dir/wt" "$oc_dir/xdg/opencode" "$oc_dir/xdgjson/opencode/storage/session/proj" "$oc_dir/xdgjson/opencode/storage/message/ses_json"
printf '%s\n' '{"schema_version":1,"presets":{"oc-fixed":{"mode":"fixed","candidate":{"id":"oc","harness":"opencode","model":"vendor/model-open","effort":"xhigh"}}}}' > "$oc_dir/config.json"
oc_choice=$(FM_STATE_OVERRIDE="$oc_dir/state" "$PRESET" select oc-task oc-fixed "$oc_dir/config.json") || fail "OpenCode choice failed"
printf '%s\n' "$oc_choice" > "$oc_dir/state/oc-task.dispatch-choice.json"
cat > "$oc_dir/state/oc-task.meta" <<META
harness=opencode
kind=ship
model=vendor/model-open
effort=xhigh
spawn_gen=s1
worktree=$oc_dir/wt
dispatch_preset=oc-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1767225600
dispatch_generation=oc-generation
dispatch_launch_kind=spawn
dispatch_choice_reused=0
META
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  cat > "$oc_dir/make-store.cjs" <<'JS'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2]);
db.exec(`create table session (id text primary key, directory text not null, time_created integer not null, model text,
  tokens_input integer default 0 not null, tokens_output integer default 0 not null, tokens_reasoning integer default 0 not null,
  tokens_cache_read integer default 0 not null, tokens_cache_write integer default 0 not null);
create table message (id text primary key, session_id text not null, time_created integer not null, data text not null);`);
const insertSession = db.prepare("insert into session (id,directory,time_created,model,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write) values (?,?,?,?,?,?,?,?,?)");
const model = JSON.stringify({ id: "model-open", providerID: "vendor", variant: "xhigh" });
insertSession.run("ses_parent", process.argv[3], 1767225601000, model, 100, 20, 7, 30, 5);
insertSession.run("ses_child", process.argv[3], 1767225602000, model, 10, 2, 1, 3, 0);
insertSession.run("ses_old", process.argv[3], 1, model, 5000, 5000, 5000, 0, 0);
const insertMessage = db.prepare("insert into message (id,session_id,time_created,data) values (?,?,?,?)");
insertMessage.run("msg_1", "ses_parent", 1767225603000, JSON.stringify({ role: "assistant" }));
insertMessage.run("msg_2", "ses_parent", 1767225604000, JSON.stringify({ role: "user" }));
insertMessage.run("msg_3", "ses_child", 1767225605000, JSON.stringify({ role: "assistant" }));
db.close();
JS
  node "$oc_dir/make-store.cjs" "$oc_dir/xdg/opencode/opencode.db" "$oc_dir/wt"
  XDG_DATA_HOME="$oc_dir/xdg" FM_DATA_OVERRIDE="$oc_dir/data" "$METRICS" launch \
    "$oc_dir/state/oc-task.meta" "$oc_dir/state/oc-task.dispatch-choice.json" || fail "OpenCode sqlite launch metric failed"
  XDG_DATA_HOME="$oc_dir/xdg" FM_DATA_OVERRIDE="$oc_dir/data" "$METRICS" finish \
    "$oc_dir/state/oc-task.meta" "$oc_dir/state/oc-task.dispatch-choice.json" landed || fail "OpenCode sqlite finish metric failed"
  oc_observed=$(jq -c -s 'map(select(.event=="finish"))[0].runtime_observed | {status, model_used, effort_used, sessions, usage: (.usage | {status, responses, sessions, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, thinking_tokens})}' "$oc_dir/data/dispatch-metrics.jsonl")
  [ "$oc_observed" = '{"status":"observed","model_used":"vendor/model-open","effort_used":"xhigh","sessions":["ses_parent","ses_child"],"usage":{"status":"recorded-local","responses":2,"sessions":2,"input_tokens":110,"cache_read_tokens":33,"cache_creation_tokens":5,"output_tokens":22,"thinking_tokens":8}}' ] \
    || fail "OpenCode sqlite usage was not collected: $oc_observed"
fi
# Older OpenCode versions keep the same sessions as JSON storage instead of sqlite.
printf '{"id":"ses_json","directory":"%s","time":{"created":1767225601000},"model":{"providerID":"vendor","id":"model-open","variant":"high"}}\n' "$oc_dir/wt" \
  > "$oc_dir/xdgjson/opencode/storage/session/proj/ses_json.json"
printf '%s\n' '{"role":"assistant","tokens":{"input":40,"output":4,"reasoning":1,"cache":{"read":8,"write":2}}}' \
  > "$oc_dir/xdgjson/opencode/storage/message/ses_json/msg_json.json"
sed 's/^spawn_gen=s1$/spawn_gen=s2/' "$oc_dir/state/oc-task.meta" > "$oc_dir/state/oc-task.meta.tmp"
mv "$oc_dir/state/oc-task.meta.tmp" "$oc_dir/state/oc-task.meta"
XDG_DATA_HOME="$oc_dir/xdgjson" FM_DATA_OVERRIDE="$oc_dir/data" "$METRICS" finish \
  "$oc_dir/state/oc-task.meta" "$oc_dir/state/oc-task.dispatch-choice.json" landed || fail "OpenCode json finish metric failed"
oc_json=$(jq -c -s 'map(select(.event=="finish"))[-1].runtime_observed | {status, model_used, effort_used, usage: (.usage | {status, responses, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, thinking_tokens})}' "$oc_dir/data/dispatch-metrics.jsonl")
case "$oc_json" in *'vendor/model-open'*'"status":"recorded-local"'*'"responses":1'*) ;; *) fail "OpenCode JSON storage usage was not collected: $oc_json" ;; esac

# A tool switch whose prior incarnations are sessionless (Pi, OpenCode) must
# still be visible to the cross-harness guard instead of dropping their usage.
sessionless_dir="$TMP_ROOT/sessionless-cross"
mkdir -p "$sessionless_dir/data" "$sessionless_dir/state"
printf '%s\n' '{"schema_version":1,"presets":{"oc-fixed":{"mode":"fixed","candidate":{"id":"oc","harness":"opencode","model":"vendor/model-open","effort":"xhigh"}}}}' > "$sessionless_dir/config.json"
sessionless_choice=$(FM_STATE_OVERRIDE="$sessionless_dir/state" "$PRESET" select sessionless-task oc-fixed "$sessionless_dir/config.json") || fail "sessionless choice failed"
printf '%s\n' "$sessionless_choice" > "$sessionless_dir/state/sessionless-task.dispatch-choice.json"
cat > "$sessionless_dir/state/sessionless-task.meta" <<META
harness=opencode
kind=ship
model=vendor/model-open
effort=xhigh
spawn_gen=s2
worktree=$sessionless_dir/wt
dispatch_preset=oc-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1767225600
dispatch_generation=sessionless-generation
dispatch_launch_kind=relaunch
dispatch_choice_reused=1
META
{
  printf '%s\n' '{"schema_version":1,"event":"launch-prepared","event_id":"launch:sessionless-task:s1","task_id":"sessionless-task","spawn_gen":"s1","generation":"sessionless-generation","started_at":"2026-01-01T00:00:00Z","launch_kind":"spawn","selection_reused":false,"effective":{"harness":"pi"}}'
  printf '%s\n' '{"schema_version":1,"event":"launch-prepared","event_id":"launch:sessionless-task:s2","task_id":"sessionless-task","spawn_gen":"s2","generation":"sessionless-generation","started_at":"2026-01-01T00:00:00Z","launch_kind":"relaunch","selection_reused":true,"effective":{"harness":"opencode"}}'
} > "$sessionless_dir/data/dispatch-metrics.jsonl"
FM_DATA_OVERRIDE="$sessionless_dir/data" "$METRICS" finish \
  "$sessionless_dir/state/sessionless-task.meta" "$sessionless_dir/state/sessionless-task.dispatch-choice.json" landed || fail "sessionless cross-harness finish failed"
sessionless_observed=$(jq -c -s 'map(select(.event=="finish"))[0] | {status: .runtime_observed.status, partial: .runtime_observed.partial, harnesses: [.runtime_observed.sessions[].harness], reason: .runtime_observed.reason}' "$sessionless_dir/data/dispatch-metrics.jsonl")
case "$sessionless_observed" in *'"status":"unknown"'*'"partial":true'*'"pi"'*'"opencode"'*'cross-harness'*) ;; *) fail "sessionless prior incarnations were dropped from the cross-harness guard: $sessionless_observed" ;; esac

# Reusing a task id after teardown must not absorb the previous task's
# incarnations from the append-only ledger. The generation token scopes both
# the session aggregation and the explicit totals to the current lifetime: a
# relaunch preserves the token and a fresh task spawn mints a new one, so even
# an identical launch origin cannot confuse the two.
generation_dir="$TMP_ROOT/generation-scope"
mkdir -p "$generation_dir/data" "$generation_dir/state" "$generation_dir/config/projects/worktree"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$generation_dir/config.json"
generation_choice=$(FM_STATE_OVERRIDE="$generation_dir/state" "$PRESET" select generation-task claude-fixed "$generation_dir/config.json") || fail "generation choice failed"
printf '%s\n' "$generation_choice" > "$generation_dir/state/generation-task.dispatch-choice.json"
cat > "$generation_dir/state/generation-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=s2
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_runtime_session=current-session
dispatch_launch_kind=spawn
dispatch_choice_reused=0
dispatch_generation=current-generation
META
{
  printf '%s\n' '{"schema_version":1,"event":"launch-prepared","event_id":"launch:generation-task:old","task_id":"generation-task","spawn_gen":"old","generation":"old-generation","started_at":"2026-01-01T00:00:00Z","effective":{"harness":"claude"},"runtime_session":"old-session"}'
  printf '%s\n' '{"schema_version":1,"event":"finish","event_id":"finish:generation-task:old","task_id":"generation-task","spawn_gen":"old","generation":"old-generation","started_at":"2026-01-01T00:00:00Z","totals":{"launches":1,"relaunches":0,"retries":0},"delivery_outcome":"landed"}'
} > "$generation_dir/data/dispatch-metrics.jsonl"
FM_DATA_OVERRIDE="$generation_dir/data" "$METRICS" launch \
  "$generation_dir/state/generation-task.meta" "$generation_dir/state/generation-task.dispatch-choice.json" || fail "generation launch metric failed"
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_gen","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":3},"content":[{"type":"text"}]}}\n' \
  > "$generation_dir/config/projects/worktree/current-session.jsonl"
# A transcript for the previous generation's session exists too: the scoping,
# not the file's absence, is what must keep it out of this task's totals.
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_old","model":"claude-opus-5","usage":{"input_tokens":9000,"output_tokens":9000},"content":[{"type":"text"}]}}\n' \
  > "$generation_dir/config/projects/worktree/old-session.jsonl"
CLAUDE_CONFIG_DIR="$generation_dir/config" FM_DATA_OVERRIDE="$generation_dir/data" "$METRICS" finish \
  "$generation_dir/state/generation-task.meta" "$generation_dir/state/generation-task.dispatch-choice.json" landed || fail "generation finish metric failed"
generation_observed=$(jq -c -s 'map(select(.event=="finish"))[-1] | {session: .runtime_observed.session_id, totals: .totals, input: .runtime_observed.usage.input_tokens}' "$generation_dir/data/dispatch-metrics.jsonl")
[ "$generation_observed" = '{"session":"current-session","totals":{"status":"complete","launches":1,"relaunches":0,"retries":0},"input":7}' ] \
  || fail "a reused task id absorbed a prior generation's incarnations: $generation_observed"

# The final metrics event persists explicit launch, relaunch, and retry totals
# scoped to the same generation, so a reader never has to infer them from
# session or subagent counts.
totals_dir="$TMP_ROOT/launch-totals"
mkdir -p "$totals_dir/data" "$totals_dir/state"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$totals_dir/config.json"
totals_choice=$(FM_STATE_OVERRIDE="$totals_dir/state" "$PRESET" select totals-task claude-fixed "$totals_dir/config.json") || fail "totals choice failed"
printf '%s\n' "$totals_choice" > "$totals_dir/state/totals-task.dispatch-choice.json"
write_totals_meta() {  # <spawn-gen> <kind> <reused>
  cat > "$totals_dir/state/totals-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=$1
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_launch_kind=$2
dispatch_choice_reused=$3
dispatch_generation=totals-generation
META
}
write_totals_meta s1 spawn 0
FM_DATA_OVERRIDE="$totals_dir/data" "$METRICS" launch "$totals_dir/state/totals-task.meta" "$totals_dir/state/totals-task.dispatch-choice.json" || fail "spawn launch metric failed"
write_totals_meta s2 relaunch 1
FM_DATA_OVERRIDE="$totals_dir/data" "$METRICS" launch "$totals_dir/state/totals-task.meta" "$totals_dir/state/totals-task.dispatch-choice.json" || fail "relaunch launch metric failed"
write_totals_meta s3 spawn 1
FM_DATA_OVERRIDE="$totals_dir/data" "$METRICS" launch "$totals_dir/state/totals-task.meta" "$totals_dir/state/totals-task.dispatch-choice.json" || fail "retry launch metric failed"
kinds=$(jq -c -s '[.[] | select(.event=="launch-prepared") | {kind: .launch_kind, reused: .selection_reused}]' "$totals_dir/data/dispatch-metrics.jsonl")
[ "$kinds" = '[{"kind":"spawn","reused":false},{"kind":"relaunch","reused":true},{"kind":"spawn","reused":true}]' ] \
  || fail "launch kinds and selection reuse were not recorded: $kinds"
FM_DATA_OVERRIDE="$totals_dir/data" "$METRICS" finish "$totals_dir/state/totals-task.meta" "$totals_dir/state/totals-task.dispatch-choice.json" landed || fail "totals finish metric failed"
totals_seen=$(jq -c -s 'map(select(.event=="finish"))[0].totals' "$totals_dir/data/dispatch-metrics.jsonl")
[ "$totals_seen" = '{"status":"complete","launches":3,"relaunches":1,"retries":1}' ] \
  || fail "explicit launch/relaunch/retry totals were wrong: $totals_seen"

# The generation token and the explicit launch-kind/reuse fields never shipped
# in another format, so a task or launch record missing them reports
# incomplete evidence instead of an inferred generation, position, or reuse.
incomplete_dir="$TMP_ROOT/incomplete-scope"
mkdir -p "$incomplete_dir/data" "$incomplete_dir/state"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$incomplete_dir/config.json"
incomplete_choice=$(FM_STATE_OVERRIDE="$incomplete_dir/state" "$PRESET" select incomplete-task claude-fixed "$incomplete_dir/config.json") || fail "incomplete choice failed"
printf '%s\n' "$incomplete_choice" > "$incomplete_dir/state/incomplete-task.dispatch-choice.json"
cat > "$incomplete_dir/state/incomplete-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=s1
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
META
FM_DATA_OVERRIDE="$incomplete_dir/data" "$METRICS" finish "$incomplete_dir/state/incomplete-task.meta" "$incomplete_dir/state/incomplete-task.dispatch-choice.json" landed || fail "missing-generation finish metric failed"
incomplete_seen=$(jq -c -s 'map(select(.event=="finish"))[0] | {generation, totals: .totals, runtime: {status: .runtime_observed.status, partial: .runtime_observed.partial, usage: .usage.status, reason: .usage.reason}}' "$incomplete_dir/data/dispatch-metrics.jsonl")
case "$incomplete_seen" in
  *'"generation":null'*'"status":"incomplete"'*'"launches":null'*'no generation token'*'"usage":"unknown"'*) ;;
  *) fail "a missing generation was not reported as incomplete evidence: $incomplete_seen" ;;
esac
# A launch record without the explicit kind/reuse fields makes the totals
# incomplete inside an otherwise scoped generation.
kindless_dir="$TMP_ROOT/kindless"
mkdir -p "$kindless_dir/data" "$kindless_dir/state"
printf '%s\n' '{"schema_version":1,"presets":{"claude-fixed":{"mode":"fixed","candidate":{"id":"opus","harness":"claude","model":"opus","effort":"medium"}}}}' > "$kindless_dir/config.json"
kindless_choice=$(FM_STATE_OVERRIDE="$kindless_dir/state" "$PRESET" select kindless-task claude-fixed "$kindless_dir/config.json") || fail "kindless choice failed"
printf '%s\n' "$kindless_choice" > "$kindless_dir/state/kindless-task.dispatch-choice.json"
cat > "$kindless_dir/state/kindless-task.meta" <<META
harness=claude
kind=ship
model=opus
effort=medium
spawn_gen=s1
dispatch_preset=claude-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1
dispatch_generation=kindless-generation
META
FM_DATA_OVERRIDE="$kindless_dir/data" "$METRICS" launch "$kindless_dir/state/kindless-task.meta" "$kindless_dir/state/kindless-task.dispatch-choice.json" || fail "kindless launch metric failed"
FM_DATA_OVERRIDE="$kindless_dir/data" "$METRICS" finish "$kindless_dir/state/kindless-task.meta" "$kindless_dir/state/kindless-task.dispatch-choice.json" landed || fail "kindless finish metric failed"
kindless_seen=$(jq -c -s 'map(select(.event=="finish"))[0].totals' "$kindless_dir/data/dispatch-metrics.jsonl")
case "$kindless_seen" in
  *'"status":"incomplete"'*'"relaunches":null'*'"retries":null'*'without an explicit launch kind or selection reuse'*) ;;
  *) fail "a launch record without explicit kind/reuse did not report incomplete totals: $kindless_seen" ;;
esac

# The live extension runtime observation and the local-store collector observe
# the same incarnation, so the merge keeps the collector's completeness status,
# partial flag, reason, and measured effort while preserving the live fields the
# collector cannot know, and a disagreement is recorded instead of hidden.
merge_dir="$TMP_ROOT/runtime-merge"
mkdir -p "$merge_dir/data" "$merge_dir/state" "$merge_dir/wt" "$merge_dir/piagent/sessions/--one--" "$merge_dir/piagent/sessions/--two--"
printf '%s\n' '{"schema_version":1,"presets":{"pi-fixed":{"mode":"fixed","candidate":{"id":"pi","harness":"pi","model":"openai-codex/model-pi","effort":"max"}}}}' > "$merge_dir/config.json"
merge_choice=$(FM_STATE_OVERRIDE="$merge_dir/state" "$PRESET" select merge-task pi-fixed "$merge_dir/config.json") || fail "merge choice failed"
printf '%s\n' "$merge_choice" > "$merge_dir/state/merge-task.dispatch-choice.json"
write_merge_meta() {  # <spawn-gen>
  cat > "$merge_dir/state/merge-task.meta" <<META
harness=pi
kind=ship
model=openai-codex/model-pi
effort=max
spawn_gen=$1
worktree=$merge_dir/wt
dispatch_preset=pi-fixed
dispatch_started_at=2026-01-01T00:00:00Z
dispatch_started_epoch=1767225600
dispatch_launch_kind=spawn
dispatch_choice_reused=0
dispatch_generation=merge-generation
META
}
write_merge_meta s1
cat > "$merge_dir/state/merge-task.dispatch-runtime.json" <<'JSON'
{"schema_version":1,"task_id":"merge-task","preset":"pi-fixed","session_id":"pi-live","model_used":"openai-codex/model-pi","effort_used":"xhigh","fast_requested":false,"fast_server_verified":false}
JSON
{
  printf '{"type":"session","version":3,"id":"pi-live","timestamp":"2026-01-01T00:00:10.000Z","cwd":"%s"}\n' "$merge_dir/wt"
  printf '%s\n' '{"type":"thinking_level_change","id":"t1","parentId":null,"timestamp":"2026-01-01T00:00:11.000Z","thinkingLevel":"max"}'
  printf '%s\n' '{"type":"message","id":"m1","parentId":"t1","timestamp":"2026-01-01T00:00:12.000Z","message":{"role":"assistant","provider":"openai-codex","model":"model-pi","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":5,"reasoning":7,"totalTokens":162},"stopReason":"stop"}}'
} > "$merge_dir/piagent/sessions/--one--/2026-01-01T00-00-10-000Z_pi-live.jsonl"
PI_CODING_AGENT_DIR="$merge_dir/piagent" FM_DATA_OVERRIDE="$merge_dir/data" "$METRICS" launch \
  "$merge_dir/state/merge-task.meta" "$merge_dir/state/merge-task.dispatch-choice.json" || fail "merge launch metric failed"
PI_CODING_AGENT_DIR="$merge_dir/piagent" FM_DATA_OVERRIDE="$merge_dir/data" "$METRICS" finish \
  "$merge_dir/state/merge-task.meta" "$merge_dir/state/merge-task.dispatch-choice.json" landed || fail "merge finish metric failed"
merged=$(jq -c -s 'map(select(.event=="finish"))[0].runtime_observed | {status, model_used, effort_used, fast_requested, usage: .usage.status, conflicts}' "$merge_dir/data/dispatch-metrics.jsonl")
[ "$merged" = '{"status":"observed","model_used":"openai-codex/model-pi","effort_used":"max","fast_requested":false,"usage":"recorded-local","conflicts":[{"field":"effort_used","live":"xhigh","observed":"max"}]}' ] \
  || fail "the runtime observation merge dropped collector authority or hid a conflict: $merged"
# An unmeasurable session keeps the whole observation unknown and partial while
# the live record's own fields survive the merge.
printf '{"type":"session","version":3,"id":"pi-empty","timestamp":"2026-01-01T00:01:10.000Z","cwd":"%s"}\n' "$merge_dir/wt" \
  > "$merge_dir/piagent/sessions/--two--/2026-01-01T00-01-10-000Z_pi-empty.jsonl"
write_merge_meta s2
PI_CODING_AGENT_DIR="$merge_dir/piagent" FM_DATA_OVERRIDE="$merge_dir/data" "$METRICS" finish \
  "$merge_dir/state/merge-task.meta" "$merge_dir/state/merge-task.dispatch-choice.json" landed || fail "partial merge finish metric failed"
merged_partial=$(jq -c -s 'map(select(.event=="finish"))[1].runtime_observed | {status, partial, effort_used, fast_requested, usage: .usage.status, reason}' "$merge_dir/data/dispatch-metrics.jsonl")
case "$merged_partial" in
  *'"status":"unknown"'*'"partial":true'*'"effort_used":"max"'*'"fast_requested":false'*'"usage":"unknown"'*'without measurable usage'*) ;;
  *) fail "a partial collector result was not preserved through the merge: $merged_partial" ;;
esac

# Usage output is the selector's documentation contract: it ends with the last
# sentence of the header comment and must not leak shell code after it.
usage_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" --help) || fail "--help exited non-zero"
assert_contains "$usage_out" "fm-task-model-preset.sh select <task-id> <preset-name>" "usage text"
[ "$(printf '%s\n' "$usage_out" | tail -n 1)" = "remain in the weighted draw and stop a sampled launch explicitly." ] \
  || fail "usage output leaked past the header comment: $(printf '%s\n' "$usage_out" | tail -n 1)"

echo "PASS: task/model presets are deterministic, weighted, explicit on unavailability, and conservatively measured"
