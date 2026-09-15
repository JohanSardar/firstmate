#!/usr/bin/env bash
# tests/fm-herdr-pi-registration.test.sh - fixture tests for the verified Herdr
# Pi registration integration resolver (bin/fm-herdr-pi-registration-lib.sh).
#
# The resolver is the single owner of what may be loaded beside the fixed-fast
# task extension on the herdr backend. These cases drive its verdict with
# fixture files only: a marked registration-only integration passes, and a
# missing file, a foreign file, a file that cannot report agent state, and a
# file that registers a provider-request rewriter all refuse with a precise
# reason.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-pi-registration-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-pi-registration)
trap 'rm -rf "$TMP_ROOT"' EXIT

agent_dir="$TMP_ROOT/agent"
mkdir -p "$agent_dir/extensions"
integration="$agent_dir/extensions/herdr-agent-state.ts"

write_integration() {  # <body>
  cat > "$integration" <<EOF
// installed by herdr
// managed by herdr; reinstalling or updating the integration overwrites this file.
// HERDR_INTEGRATION_ID=pi
// HERDR_INTEGRATION_VERSION=8
export default function (pi) {
$1
}
EOF
}

write_integration '  pi.on("session_start", () => socketWrite({ method: "pane.report_agent", pane_id: paneId }));'

if out=$(fm_herdr_pi_registration_extension "$agent_dir"); then
  [ "$out" = "$integration" ] || fail "the resolved integration path was '$out', expected '$integration'"
else
  fail "the marked registration-only integration was refused: $out"
fi
pass "a marked Herdr integration that reports agent state resolves to its absolute path"

# A trailing slash on the agent dir must resolve to the same file.
out=$(fm_herdr_pi_registration_extension "$agent_dir/") \
  || fail "a trailing slash on the agent dir was not accepted"
[ "$out" = "$integration" ] || fail "the trailing-slash resolution returned '$out'"
pass "a trailing slash on the agent dir still resolves the integration"

expect_refusal() {  # <expected-reason> <agent-dir>
  local expected=$1 dir=$2 reason
  reason=$(fm_herdr_pi_registration_extension "$dir" 2>&1) && fail "refusal expected ($expected) but the resolver accepted $dir"
  [ "$reason" = "$expected" ] || fail "refusal reason mismatch: expected '$expected', got '$reason'"
}

missing_dir="$TMP_ROOT/missing"
expect_refusal "the Herdr Pi integration is not installed at $missing_dir/extensions/herdr-agent-state.ts" "$missing_dir"
pass "a missing integration refuses with its resolved path"

write_integration '  pi.on("session_start", () => socketWrite({ method: "pane.report_agent", pane_id: paneId }));'
printf '%s\n%s\n' '// something else' 'export default function () {}' > "$integration"
expect_refusal "the file at $integration is not the Herdr-managed Pi integration (missing its installed-by-herdr marker)" "$agent_dir"
pass "a foreign extension file refuses instead of being loaded"

write_integration '  pi.on("session_start", () => socketWrite({ method: "pane.report_agent", pane_id: paneId }));'
sed 's#// HERDR_INTEGRATION_ID=pi#// other integration#' "$integration" > "$integration.tmp"
mv "$integration.tmp" "$integration"
expect_refusal "the file at $integration is not the Herdr Pi integration (missing HERDR_INTEGRATION_ID=pi)" "$agent_dir"
pass "a file without Herdr's Pi integration identity refuses"

write_integration '  pi.on("session_start", () => {});'
expect_refusal "the file at $integration does not report agent state to Herdr (no pane.report_agent call)" "$agent_dir"
pass "a marked file that cannot report agent state refuses"

write_integration '  pi.on("session_start", () => socketWrite({ method: "pane.report_agent", pane_id: paneId }));
  pi.on("before_provider_request", (event) => ({ ...event.payload, service_tier: "priority" }));'
expect_refusal "the file at $integration registers a provider-request rewriter, so it cannot be loaded beside the task fast control" "$agent_dir"
pass "a registration file that could rewrite the provider request refuses"

echo "PASS: only a verified registration-only Herdr integration may join the fixed-fast launch plan"
