#!/usr/bin/env bash
# Opt-in guard for the persistent OpenCode preset launch shape: the per-launch
# agent configuration fm-spawn delivers must resolve inside the REAL installed
# CLI with the exact sampled model and variant. Token-free and offline; no model
# call is made, only OpenCode's own config resolution runs.
#
# The earlier preset shape used `opencode run --interactive`, which is a
# one-shot batch command whose --interactive flag starts no persistent worker on
# 1.18.x. This guard pins the replacement: an agent carrying `model` and
# `variant`, resolved by `opencode debug agent` exactly as the TUI resolves it.
#
# Run after every OpenCode upgrade and before trusting refreshed per-harness
# evidence (docs/verification/runtime-backends.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OPENCODE_PRESET_AGENT_LIVE_E2E opencode jq node

TMP_ROOT=$(fm_test_tmproot fm-opencode-preset-agent-live)
trap 'rm -rf "$TMP_ROOT"' EXIT
VERSION=$(opencode --version 2>&1 | head -n 1)
AGENT=fm-preset-live-e2e

# Discover one model that the installed catalog advertises with at least one
# variant, preferring the cheap DeepSeek Flash entry when it is present. The
# guard never assumes a specific product is installed.
opencode models --verbose > "$TMP_ROOT/models.txt" 2>/dev/null || {
  fail "opencode models --verbose failed; cannot discover a model/variant pair"
}
cat > "$TMP_ROOT/discover.cjs" <<'JS'
const fs = require("node:fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const lines = text.split("\n");
let best = null;
let index = 0;
while (index < lines.length) {
  index += 1;
  while (index < lines.length && lines[index].trim() !== "{") index += 1;
  if (index >= lines.length) break;
  let depth = 0;
  const block = [];
  for (; index < lines.length; index += 1) {
    const line = lines[index];
    block.push(line);
    for (const character of line) {
      if (character === "{") depth += 1;
      else if (character === "}") depth -= 1;
    }
    if (depth === 0) { index += 1; break; }
  }
  let parsed;
  try { parsed = JSON.parse(block.join("\n")); } catch { continue; }
  const variants = Object.keys(parsed.variants ?? {});
  if (!parsed.providerID || !parsed.id || variants.length === 0) continue;
  const candidate = { model: `${parsed.providerID}/${parsed.id}`, variant: variants[0] };
  if (best === null) best = candidate;
  if (candidate.model === "deepseek/deepseek-flash") { best = candidate; break; }
}
if (best) process.stdout.write(`${best.model} ${best.variant}\n`);
JS
discovered=$(node "$TMP_ROOT/discover.cjs" "$TMP_ROOT/models.txt") || {
  fail "could not scan the installed model catalog for a model with variants"
}
[ -n "$discovered" ] || fail "the installed model catalog advertises no model with variants"
model=${discovered%% *}
variant=${discovered#* }
case "$model" in */*) ;; *) fail "discovered model '$model' is not an exact provider/model id" ;; esac

config=$(jq -cn --arg agent "$AGENT" --arg model "$model" --arg variant "$variant" \
  '{permission:{"*":"allow"},agent:{($agent):{mode:"primary",model:$model,variant:$variant}}}') \
  || fail "could not build the preset agent configuration"
OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_CONFIG_CONTENT="$config" \
  opencode debug agent "$AGENT" > "$TMP_ROOT/resolved.txt" 2>&1 \
  || fail "OpenCode $VERSION could not resolve the preset agent configuration"

cat > "$TMP_ROOT/verify.cjs" <<'JS'
const fs = require("node:fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const start = text.indexOf("{");
if (start < 0) { console.error("no JSON object in the resolved agent output"); process.exit(1); }
let depth = 0;
let end = -1;
for (let index = start; index < text.length; index += 1) {
  const character = text[index];
  if (character === "{") depth += 1;
  else if (character === "}") {
    depth -= 1;
    if (depth === 0) { end = index + 1; break; }
  }
}
if (end < 0) { console.error("unterminated JSON object in the resolved agent output"); process.exit(1); }
let resolved;
try { resolved = JSON.parse(text.slice(start, end)); } catch (error) {
  console.error(`cannot parse the resolved agent output: ${error.message}`);
  process.exit(1);
}
const expectedModel = process.argv[3];
const expectedVariant = process.argv[4];
const actualModel = `${resolved.model?.providerID}/${resolved.model?.modelID}`;
if (actualModel !== expectedModel) {
  console.error(`resolved model ${actualModel} != ${expectedModel}`);
  process.exit(1);
}
if (resolved.variant !== expectedVariant) {
  console.error(`resolved variant ${resolved.variant} != ${expectedVariant}`);
  process.exit(1);
}
JS
node "$TMP_ROOT/verify.cjs" "$TMP_ROOT/resolved.txt" "$model" "$variant" \
  || fail "the resolved preset agent did not carry the exact model/variant"

pass "OpenCode $VERSION resolves the persistent preset agent with exact $model variant $variant"
