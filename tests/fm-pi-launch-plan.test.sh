#!/usr/bin/env bash
# tests/fm-pi-launch-plan.test.sh - fixture tests for the pure resolved-Pi
# launch-plan fast guarantee (bin/fm-pi-launch-plan-lib.sh).
#
# The helper is the single owner of the decision, so these cases drive its
# verdict with argument fixtures alone: no filesystem, no project, no settings,
# and no live Pi. The proving branch exists for a launcher that resolves a plan
# with --no-extensions and the task extension last; every other plan refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-pi-launch-plan-lib.sh"

TASK_EXT='/state/task.pi-ext.ts'

# --- proving plans (return 0, no output) -------------------------------------

if out=$(fm_pi_fast_plan_guarantees "$TASK_EXT" --no-extensions -e /ext/a.ts -e "$TASK_EXT" --model m); then
  [ -z "$out" ] || fail "a proving plan printed output: $out"
else
  fail "a plan with --no-extensions and the task extension last was refused: $out"
fi
pass "a plan proving --no-extensions with the task extension last is guaranteed"

fm_pi_fast_plan_guarantees "$TASK_EXT" --model m --no-extensions --extension /ext/a.ts --extension "$TASK_EXT" \
  || fail "the --extension long form was not accepted"
pass "the --extension long form is honored"

fm_pi_fast_plan_guarantees "$TASK_EXT" --no-extensions "--extension=$TASK_EXT" \
  || fail "the --extension= form was not accepted"
pass "the --extension= form is honored"

# The flag is order-independent, but the extension order is exactly the contract.
fm_pi_fast_plan_guarantees "$TASK_EXT" -e /ext/a.ts --no-extensions -e "$TASK_EXT" -e /ext/b.ts --no-extensions \
  >/dev/null 2>&1 && fail "a later extension after the task extension was wrongly guaranteed"
pass "a plan whose later extension shadows the task extension is refused"

# --- refusing plans (return 1 with one reason line) --------------------------

expect_refusal() {  # <expected-reason> <args...>
  local expected=$1 reason status
  shift
  reason=$(fm_pi_fast_plan_guarantees "$@" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "refusal expected ($expected) but the plan was guaranteed"
  [ "$reason" = "$expected" ] || fail "refusal reason mismatch: expected '$expected', got '$reason'"
}

expect_refusal 'missing --no-extensions' "$TASK_EXT" -e /ext/a.ts -e "$TASK_EXT"
pass "a plan without --no-extensions refuses"

expect_refusal 'no explicit extension list' "$TASK_EXT" --no-extensions
pass "a plan with no explicit extensions refuses"

expect_refusal 'task extension is not the last extension' "$TASK_EXT" --no-extensions -e "$TASK_EXT" -e /ext/later.ts
pass "a plan whose task extension is not last refuses"

expect_refusal 'task extension is not the last extension' "$TASK_EXT" --no-extensions -e /ext/a.ts
pass "a plan that never loads the task extension refuses"

expect_refusal 'task extension is not the last extension' "$TASK_EXT" --no-extensions --extension /state/./task.pi-ext.ts
pass "a path spelling that differs from the delivered task extension refuses"

expect_refusal 'extension option without a value' "$TASK_EXT" --no-extensions -e
pass "a dangling extension option refuses instead of passing it through"

echo "PASS: the resolved Pi launch plan is the only fast authority"
