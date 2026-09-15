#!/usr/bin/env bash
# Opt-in live guard for the exact Pi reasoning probe against the REAL installed
# @earendil-works/pi-coding-agent package (no stubs). It declares synthetic
# local models with different thinkingLevelMap shapes and proves the production
# probe accepts a mapped level, refuses an unmapped one, and refuses an unknown
# model. No provider call leaves the machine: the synthetic provider carries a
# placeholder key and is never contacted, and catalog resolution stays local.
#
# Run after every Pi upgrade and before trusting refreshed per-harness evidence
# (docs/verification/runtime-backends.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_REASONING_LIVE_E2E npm jq node
export NODE_NO_WARNINGS=1

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  fail "Pi package absent: the live reasoning guard needs @earendil-works/pi-coding-agent installed (FM_PI_PACKAGE_DIR to override)"
fi
PI_VERSION=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')

TMP_ROOT=$(fm_test_tmproot fm-pi-reasoning-probe-live)
trap 'rm -rf "$TMP_ROOT"' EXIT
agentdir="$TMP_ROOT/agent"
mkdir -p "$agentdir"
cat > "$agentdir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-fake": {
      "baseUrl": "http://127.0.0.1:9/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        {
          "id": "fm-live-deep",
          "name": "fm live deep",
          "contextWindow": 8192,
          "maxTokens": 512,
          "reasoning": true,
          "thinkingLevelMap": {
            "minimal": "minimal",
            "low": "low",
            "medium": "medium",
            "high": "high",
            "xhigh": "xhigh",
            "max": "max"
          }
        },
        {
          "id": "fm-live-shallow",
          "name": "fm live shallow",
          "contextWindow": 8192,
          "maxTokens": 512,
          "reasoning": true,
          "thinkingLevelMap": { "low": "low", "high": "high" }
        }
      ]
    }
  }
}
JSON

probe="$ROOT/bin/fm-pi-reasoning-probe.mjs"

out=$(node "$probe" --package-dir "$PI_PACKAGE_DIR" --agent-dir "$agentdir" \
  --model fm-live-fake/fm-live-deep --effort max 2>&1) || fail "the probe refused a mapped level: $out"
[ "$out" = "supported=off,minimal,low,medium,high,xhigh,max" ] \
  || fail "the real Pi SDK reported an unexpected supported-level list: $out"

out=$(node "$probe" --package-dir "$PI_PACKAGE_DIR" --agent-dir "$agentdir" \
  --model fm-live-fake/fm-live-shallow --effort max 2>&1)
status=$?
[ "$status" -eq 3 ] || fail "the probe did not refuse an unmapped level (exit $status): $out"
case "$out" in
  *"does not support thinking level 'max'"*) ;;
  *) fail "the unmapped-level refusal did not name the level: $out" ;;
esac

out=$(node "$probe" --package-dir "$PI_PACKAGE_DIR" --agent-dir "$agentdir" \
  --model fm-live-fake/fm-live-absent --effort high 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "the probe did not refuse an unknown model (exit $status): $out"

pass "real Pi SDK $PI_VERSION resolves exact thinking levels: a mapped level passes, an unmapped level and an unknown model refuse"
