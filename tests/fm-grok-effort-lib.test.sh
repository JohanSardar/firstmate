#!/usr/bin/env bash
# tests/fm-grok-effort-lib.test.sh - fixture tests for the Grok per-model
# reasoning-effort evidence helper (bin/fm-grok-effort-lib.sh).
#
# The helper decides whether the installed CLI's own fetched model catalog
# proves a requested effort for the selected model, because installed Grok
# advertises a different reasoning-effort menu per model (1.0.30: grok-4.6
# advertises xhigh, grok-4.5 does not) and `grok models` lists only ids. These
# cases drive that verdict from catalog fixtures alone: no grok binary, no
# login, and no provider call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-grok-effort-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-grok-effort-lib)
trap 'rm -rf "$TMP_ROOT"' EXIT

CATALOG="$TMP_ROOT/models_cache.json"

write_catalog() {  # <version> <models-json>
  cat > "$CATALOG" <<JSON
{"fetched_at":"2026-01-01T00:00:00Z","grok_version":"$1","auth_method":"session","origin":"https://example.invalid/v1/models","models":$2}
JSON
}

write_catalog 1.0.30 '{"grok-4.6":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"xhigh"},{"value":"high"},{"value":"medium"},{"value":"low"}]}},"grok-4.5":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"high"},{"value":"medium"},{"value":"low"}]}}}'

fm_grok_effort_evidence "$CATALOG" 'grok 1.0.30 (deadbeef) [stable]' grok-4.6 xhigh \
  || fail "an advertised per-model level was refused"
pass "an advertised per-model effort is proven"

reason=$(fm_grok_effort_evidence "$CATALOG" 'grok 1.0.30 (deadbeef) [stable]' grok-4.5 xhigh 2>&1) \
  && fail "a level the selected model does not advertise was accepted"
[ "$reason" = "model grok-4.5 does not advertise reasoning effort 'xhigh' (advertised: high,medium,low)" ] \
  || fail "the refusal did not quote the model's own menu: $reason"
pass "a level the selected model does not advertise refuses with its menu"

reason=$(fm_grok_effort_evidence "$CATALOG" 'grok 1.0.30 (deadbeef) [stable]' grok-4.6 max 2>&1) \
  && fail "an unsupported level above the shared vocabulary was accepted"
assert_contains "$reason" "does not advertise reasoning effort 'max'" "unsupported upper level refusal"
pass "an unsupported upper level refuses instead of mapping to another provider"

reason=$(fm_grok_effort_evidence "$CATALOG" 'grok 1.0.31 (deadbeef) [stable]' grok-4.6 xhigh 2>&1) \
  && fail "a catalog written by a different grok version was trusted"
assert_contains "$reason" "written by grok 1.0.30, not the running grok 1.0.31" "version-stamp refusal"
pass "a catalog from a different grok version proves nothing"

reason=$(fm_grok_effort_evidence "$CATALOG" 'grok 1.0.30 (deadbeef) [stable]' grok-unknown xhigh 2>&1) \
  && fail "a model without a catalog entry was accepted"
assert_contains "$reason" "has no entry for model grok-unknown" "missing model entry refusal"
pass "a model without a catalog entry refuses"

reason=$(fm_grok_effort_evidence "$TMP_ROOT/absent.json" 'grok 1.0.30' grok-4.6 xhigh 2>&1) \
  && fail "a missing catalog was treated as proof"
assert_contains "$reason" "no fetched Grok model catalog" "missing catalog refusal"
pass "a missing fetched catalog refuses rather than guessing a global effort range"

printf '%s\n' '{not json' > "$CATALOG"
reason=$(fm_grok_effort_evidence "$CATALOG" 'grok 1.0.30' grok-4.6 xhigh 2>&1) \
  && fail "an unreadable catalog was treated as proof"
assert_contains "$reason" "is unreadable" "unreadable catalog refusal"
pass "an unreadable catalog refuses"

write_catalog 1.0.30 '{"grok-4.6":{"info":{"reasoning_effort":"high"}}}'
reason=$(fm_grok_effort_evidence "$CATALOG" 'grok 1.0.30' grok-4.6 high 2>&1) \
  && fail "a model without an advertised menu was trusted from its default alone"
assert_contains "$reason" "advertised: none" "menu-less model refusal"
pass "a model without an advertised effort menu refuses"

echo "PASS: Grok effort is proven per selected model from the installed CLI's own catalog"
