#!/usr/bin/env bash
# Behavior tests for opt-in task/model preset validation and deterministic selection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PRESET="$ROOT/bin/fm-task-model-preset.sh"
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

# Usage output is the selector's documentation contract: it ends with the last
# sentence of the header comment and must not leak shell code after it.
usage_out=$(FM_STATE_OVERRIDE="$case_dir/state" "$PRESET" --help) || fail "--help exited non-zero"
assert_contains "$usage_out" "fm-task-model-preset.sh select <task-id> <preset-name>" "usage text"
[ "$(printf '%s\n' "$usage_out" | tail -n 1)" = "remain in the weighted draw and stop a sampled launch explicitly." ] \
  || fail "usage output leaked past the header comment: $(printf '%s\n' "$usage_out" | tail -n 1)"

echo "PASS: task/model presets are deterministic, weighted, explicit on unavailability, and retry-stable"
