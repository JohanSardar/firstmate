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
META
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" launch "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" || fail "launch metric failed"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" finish "$metrics_dir/state/metric-task.meta" "$metrics_dir/state/metric-task.dispatch-choice.json" landed || fail "finish metric failed"
ledger="$metrics_dir/data/dispatch-metrics.jsonl"
[ "$(jq -s 'map(select(.event=="launch-prepared")) | length' "$ledger")" -eq 1 ] || fail "launch event missing"
[ "$(jq -s 'map(select(.event=="finish")) | length' "$ledger")" -eq 1 ] || fail "finish event missing"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].quality.status' "$ledger")" = unknown ] || fail "missing quality was not kept unknown"
[ "$(jq -s -r 'map(select(.event=="finish"))[0].cost.billing_basis' "$ledger")" = estimate-not-invoice ] || fail "cost was not labeled as an estimate"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.fast' "$ledger")" = null ] || fail "requested fast was claimed as effective"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.fast_basis' "$ledger")" = requested-not-wire-verified ] || fail "fast basis was not requested-only"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --model-used vendor/model-runtime --effort-used high --fast-server-verified off --quality bug-found --quota-fraction 0.1 --monthly-price-usd 80 --reset-days 7 || fail "observation metric failed"
[ "$(jq -s -r 'map(select(.event=="observation"))[0].cost.weekly_usd' "$ledger")" = 2 ] || fail "weekly estimate formula is wrong"
FM_DATA_OVERRIDE="$metrics_dir/data" "$METRICS" observe metric-task --quota-fraction 0.1 --monthly-price-usd 80 --reset-days 30 || fail "monthly-period observation failed"
[ "$(jq -s -r 'map(select(.event=="observation"))[1].cost.status' "$ledger")" = unknown ] || fail "incompatible reset period was presented as weekly cost"

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
META
}
session_a=aaaaaaaa-1111-2222-3333-444444444444
session_b=bbbbbbbb-1111-2222-3333-444444444444
write_relaunch_meta s1 "$session_a"
FM_DATA_OVERRIDE="$relaunch_dir/data" "$METRICS" launch \
  "$relaunch_dir/state/relaunch-task.meta" "$relaunch_dir/state/relaunch-task.dispatch-choice.json" || fail "first incarnation launch metric failed"
write_relaunch_meta s2 "$session_b"
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
write_relaunch_meta s3 "$session_b"
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
META
}
cross_claude=cccccccc-1111-2222-3333-444444444444
cross_grok=dddddddd-1111-2222-3333-444444444444
write_cross_meta claude opus s1 "$cross_claude"
FM_DATA_OVERRIDE="$cross_dir/data" "$METRICS" launch \
  "$cross_dir/state/cross-task.meta" "$cross_dir/state/cross-task.dispatch-choice.json" || fail "claude incarnation launch metric failed"
write_cross_meta grok grok-4.6 s2 "$cross_grok"
FM_DATA_OVERRIDE="$cross_dir/data" "$METRICS" launch \
  "$cross_dir/state/cross-task.meta" "$cross_dir/state/cross-task.dispatch-choice.json" || fail "grok incarnation launch metric failed"
# The claude incarnation has a complete local transcript; the grok incarnation
# has none. Reporting only the claude total would look complete but be partial.
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":30,"output_tokens_details":{"thinking_tokens":7},"speed":"standard","service_tier":"priority"},"content":[{"type":"text"}]}}\n' \
  > "$cross_dir/config/projects/worktree/$cross_claude.jsonl"
# Finish on the claude incarnation, whose transcript is complete.
write_cross_meta claude opus s3 "$cross_claude"
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
META
}
same_a=aaaaaaaa-1111-2222-3333-444444444401
same_b=bbbbbbbb-1111-2222-3333-444444444402
write_same_meta s1 "$same_a"
FM_DATA_OVERRIDE="$same_dir/data" "$METRICS" launch "$same_dir/state/same-task.meta" "$same_dir/state/same-task.dispatch-choice.json" || fail "same-harness first launch metric failed"
write_same_meta s2 "$same_b"
FM_DATA_OVERRIDE="$same_dir/data" "$METRICS" launch "$same_dir/state/same-task.meta" "$same_dir/state/same-task.dispatch-choice.json" || fail "same-harness second launch metric failed"
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":30},"content":[{"type":"text"}]}}\n' > "$same_dir/config/projects/worktree/$same_a.jsonl"
printf '{"type":"assistant","effort":"medium","message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text"}]}}\n' > "$same_dir/config/projects/worktree/$same_b.jsonl"
write_same_meta s3 "$same_b"
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
META
{
  printf '%s\n' '{"schema_version":1,"event":"launch-prepared","event_id":"launch:sessionless-task:s1","task_id":"sessionless-task","spawn_gen":"s1","effective":{"harness":"pi"}}'
  printf '%s\n' '{"schema_version":1,"event":"launch-prepared","event_id":"launch:sessionless-task:s2","task_id":"sessionless-task","spawn_gen":"s2","effective":{"harness":"opencode"}}'
} > "$sessionless_dir/data/dispatch-metrics.jsonl"
FM_DATA_OVERRIDE="$sessionless_dir/data" "$METRICS" finish \
  "$sessionless_dir/state/sessionless-task.meta" "$sessionless_dir/state/sessionless-task.dispatch-choice.json" landed || fail "sessionless cross-harness finish failed"
sessionless_observed=$(jq -c -s 'map(select(.event=="finish"))[0] | {status: .runtime_observed.status, partial: .runtime_observed.partial, harnesses: [.runtime_observed.sessions[].harness], reason: .runtime_observed.reason}' "$sessionless_dir/data/dispatch-metrics.jsonl")
case "$sessionless_observed" in *'"status":"unknown"'*'"partial":true'*'"pi"'*'"opencode"'*'cross-harness'*) ;; *) fail "sessionless prior incarnations were dropped from the cross-harness guard: $sessionless_observed" ;; esac

echo "PASS: task/model presets are deterministic, weighted, explicit on unavailability, and conservatively measured"
