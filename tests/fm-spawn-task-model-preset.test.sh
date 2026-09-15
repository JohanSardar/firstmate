#!/usr/bin/env bash
# Launch-shape tests for opt-in task/model presets across supported adapters.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-task-model-preset)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "$3: missing '$2'" ;; esac
}

make_case() {
  local name=$1 id=$2 harness=$3 model=$4 effort=$5 fast=${6:-omit}
  local dir="$TMP_ROOT/$name" home="$TMP_ROOT/$name/home" proj="$TMP_ROOT/$name/project" wt="$TMP_ROOT/$name/wt" fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  mkdir -p "$home/user-home/.pi/agent"
  printf '%s\n' '{"openai-codex":{"type":"oauth"}}' > "$home/user-home/.pi/agent/auth.json"
  printf '%s\n' '{"providers":{"openai-codex":{"models":[{"id":"model-pi","name":"model pi","reasoning":true,"thinkingLevelMap":{"low":"low","medium":"medium","high":"high","xhigh":"xhigh","max":"max"}}]}}}' \
    > "$home/user-home/.pi/agent/models.json"
  if [ "$fast" = omit ]; then
    fast_json=
  else
    fast_json=",\"fast\":$fast"
  fi
  cat > "$home/config/task-model-presets.json" <<JSON
{"schema_version":1,"presets":{"chosen":{"mode":"fixed","candidate":{"id":"candidate","harness":"$harness","model":"$model","effort":"$effort"$fast_json}}}}
JSON
  printf '%s\n' "$dir|$home|$proj|$wt|$fakebin"
}

install_fake_pi() {
  local fakebin=$1
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' 'Options: --tui-mode <mode>' ;;
  --version) printf '%s\n' 'pi 9.9.9-test' ;;
  --list-models)
    printf '%s\n' 'provider      model       context  max-out  thinking  images'
    printf '%s\n' 'openai-codex  model-pi    100K     10K      yes       no'
    ;;
esac
SH
  chmod +x "$fakebin/pi"
}

# A fixture stand-in for the installed Pi package: the reasoning probe imports
# the same ModelRuntime/ModelRegistry surface the real package exposes and reads
# the synthetic model catalog this suite writes per case.
install_fake_pi_package() {
  local package=$1
  mkdir -p "$package/dist" "$package/node_modules/@earendil-works/pi-ai/dist"
  cat > "$package/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","version":"9.9.9-test","type":"module"}
JSON
  cat > "$package/dist/index.js" <<'JS'
import { readFileSync } from "node:fs";
function loadModels(modelsPath) {
  try {
    const config = JSON.parse(readFileSync(modelsPath, "utf8"));
    const models = [];
    for (const [provider, entry] of Object.entries(config.providers ?? {})) {
      for (const model of entry.models ?? []) models.push({ provider, ...model });
    }
    return models;
  } catch {
    return [];
  }
}
export class ModelRuntime {
  static async create({ modelsPath }) {
    return { modelsPath, models: loadModels(modelsPath) };
  }
}
export class ModelRegistry {
  constructor(runtime) { this.runtime = runtime; }
  async refresh() { this.runtime.models = loadModels(this.runtime.modelsPath); }
  find(provider, id) {
    return this.runtime.models.find((model) => model.provider === provider && model.id === id) ?? null;
  }
}
JS
  cat > "$package/node_modules/@earendil-works/pi-ai/dist/compat.js" <<'JS'
// Pi's own supported-level rule: xhigh and max exist only when the model's
// thinkingLevelMap defines them, and a null map entry disables a level.
export function getSupportedThinkingLevels(model) {
  if (!model.reasoning) return ["off"];
  return ["off", "minimal", "low", "medium", "high", "xhigh", "max"].filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}
JS
}

install_fake_grok() {
  local fakebin=$1
  cat > "$fakebin/grok" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf '%s\n' 'You are logged in with example.invalid.' '' 'Available models:' '  * grok-default (default)' '  - grok-example' ;;
  --version) printf '%s\n' 'grok 9.9.9-test' ;;
esac
SH
  chmod +x "$fakebin/grok"
}

# Synthetic stand-in for the CLI's own fetched model catalog. The real grok
# writes <GROK_HOME>/models_cache.json from its authenticated models endpoint
# and stamps it with the fetching version; the launch validation proves the
# requested effort against that per-model menu.
write_fake_grok_catalog() {  # <home> <version> <models-json>
  local home=$1 version=$2 models=$3
  mkdir -p "$home/user-home/.grok"
  cat > "$home/user-home/.grok/models_cache.json" <<JSON
{"fetched_at":"2026-01-01T00:00:00Z","grok_version":"$version","auth_method":"session","origin":"https://example.invalid/v1/models","models":$models}
JSON
}

install_fake_claude() {
  local fakebin=$1
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' "--model <model> aliases: 'fable', 'opus', or 'sonnet'" '--effort <level> low medium high xhigh max'
elif [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true}'
elif [ "${1:-}" = --version ]; then
  printf '%s\n' 'claude 9.9.9-test'
fi
SH
  chmod +x "$fakebin/claude"
}

install_fake_opencode() {
  local fakebin=$1
  cat > "$fakebin/opencode" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ] && [ "${3:-}" = --verbose ]; then
  printf '%s\n' 'vendor/model-open' '{' '  "variants": {' '    "xhigh": {"reasoningEffort":"xhigh"}' '  }' '}'
elif [ "${1:-}" = models ]; then
  printf '%s\n' 'vendor/model-open'
elif [ "${1:-}" = providers ] && [ "${2:-}" = list ]; then
  printf '%s\n' 'Vendor api'
elif [ "${1:-}" = --version ]; then
  printf '%s\n' 'opencode 9.9.9-test'
fi
SH
  chmod +x "$fakebin/opencode"
}

PI_PACKAGE="$TMP_ROOT/pi-package"
install_fake_pi_package "$PI_PACKAGE"
export FM_PI_PACKAGE_DIR="$PI_PACKAGE"

run_case() {
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5 log=$6
  : > "$log"
  FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --scout --preset chosen 2>&1
}

record=$(make_case pi pi-preset-task pi openai-codex/model-pi max)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-preset-task "$PROJ_DIR" "$DIR/launch.log") || fail "Pi preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
assert_contains "$launch" "--model 'openai-codex/model-pi' --thinking 'max'" "Pi launch settings"
# A preset without a fixed fast value keeps Pi's ordinary discovery and the
# same single -e shape every other launch uses: the ordered --no-extensions
# plan is reserved for the case where a fast value must be guaranteed.
case "$launch" in
  *"--no-extensions"*) fail "a preset without fixed fast disabled Pi extension discovery: $launch" ;;
esac
assert_contains "$launch" "-e '$HOME_DIR/state/pi-preset-task.pi-ext.ts'" "ordinary preset keeps the task extension"
# The generated Pi extension registers the provider-request hook exactly once
# when the file loads, never per session_start, so a re-fired session start
# cannot stack duplicate handlers.
cat > "$DIR/assert-pi-extension.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const callbacks = new Map();
const pi = {
  on(name, callback) {
    if (!callbacks.has(name)) callbacks.set(name, []);
    callbacks.get(name).push(callback);
  },
};
const extension = await import(pathToFileURL(process.argv[2]).href);
extension.default(pi);
if ((callbacks.get("before_provider_request") || []).length !== 0) {
  throw new Error("a preset without fast registered a provider-request handler");
}
const context = {
  model: { provider: "openai-codex", id: "model-pi", api: "openai-codex-responses" },
  thinkingLevel: "max",
  sessionManager: { getSessionId: () => "test-session" },
};
const sessionStarts = callbacks.get("session_start") || [];
if (sessionStarts.length !== 1) throw new Error(`expected one session_start handler, got ${sessionStarts.length}`);
await sessionStarts[0]({ type: "session_start" }, context);
await sessionStarts[0]({ type: "session_start" }, context);
if ((callbacks.get("before_provider_request") || []).length !== 0) {
  throw new Error("session_start stacked a provider-request handler");
}
JS
node --no-warnings "$DIR/assert-pi-extension.mjs" "$HOME_DIR/state/pi-preset-task.pi-ext.ts" \
  || fail "generated Pi extension registered a provider hook for a preset without fast"
runtime="$HOME_DIR/state/pi-preset-task.dispatch-runtime.json"
[ "$(jq -r '.model_used + " " + .effort_used' "$runtime")" = "openai-codex/model-pi max" ] \
  || fail "Pi runtime observation was not recorded"
[ ! -e "$HOME_DIR/user-home/.pi/agent/settings.json" ] || fail "Pi preset changed global settings"
[ "$(jq -s -r '.[0].effective.effort' "$HOME_DIR/data/dispatch-metrics.jsonl")" = max ] || fail "validated Pi effort was not recorded effective"
[ "$(jq -s -r '.[0].selection.selected_candidate' "$HOME_DIR/data/dispatch-metrics.jsonl")" = candidate ] || fail "Pi launch provenance was not recorded"
[ "$(jq -s -r '.[0].launch_kind' "$HOME_DIR/data/dispatch-metrics.jsonl")" = spawn ] || fail "a fresh preset spawn did not record its launch kind"
[ "$(jq -s -r '.[0].selection_reused' "$HOME_DIR/data/dispatch-metrics.jsonl")" = false ] || fail "a fresh preset spawn claimed to reuse a sample"
[ -n "$(grep '^dispatch_generation=' "$HOME_DIR/state/pi-preset-task.meta" | cut -d= -f2)" ] \
  || fail "a fresh preset spawn did not record a generation token"
[ -n "$(jq -s -r '.[0].generation' "$HOME_DIR/data/dispatch-metrics.jsonl")" ] \
  || fail "the launch event did not record the generation token"

# A retry that finds an already-sampled durable choice records the reuse
# explicitly, so the final metrics event can total retries without inferring
# them from session or subagent counts.
record=$(make_case retry-choice retry-choice-task pi openai-codex/model-pi max)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-task-model-preset.sh" select retry-choice-task chosen "$HOME_DIR/config/task-model-presets.json" >/dev/null \
  || fail "pre-sampling the durable choice for the retry failed"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" retry-choice-task "$PROJ_DIR" "$DIR/launch.log") \
  || fail "retry preset spawn failed: $out"
[ "$(grep '^dispatch_choice_reused=' "$HOME_DIR/state/retry-choice-task.meta" | cut -d= -f2)" = 1 ] \
  || fail "a spawn that reused a sampled choice did not record it"
[ "$(jq -s -r '.[0].selection_reused' "$HOME_DIR/data/dispatch-metrics.jsonl")" = true ] \
  || fail "the launch event did not record the reused sample"
[ "$(jq -s -r '.[0].launch_kind' "$HOME_DIR/data/dispatch-metrics.jsonl")" = spawn ] \
  || fail "the retry launch kind was not recorded"

# A level the model does not map (here max) must refuse before launch: Pi would
# otherwise clamp it silently to a lower level while the ledger claimed max.
record=$(make_case pi-unsupported-level pi-unsupported-task pi openai-codex/model-pi max)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
printf '%s\n' '{"providers":{"openai-codex":{"models":[{"id":"model-pi","name":"model pi","reasoning":true,"thinkingLevelMap":{"low":"low","high":"high","xhigh":"xhigh"}}]}}}' \
  > "$HOME_DIR/user-home/.pi/agent/models.json"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-unsupported-task "$PROJ_DIR" "$DIR/launch.log") \
  && fail "a Pi preset launched a thinking level the model does not support"
assert_contains "$out" "does not support thinking level 'max'" "unsupported Pi level refusal"
assert_contains "$out" "supported: off,minimal,low,medium,high,xhigh" "unsupported Pi level supported list"
[ ! -s "$DIR/launch.log" ] || fail "unsupported Pi level refusal still delivered a launch"

# A missing installed package cannot prove any exact level, so the launch
# refuses instead of trusting the --list-models reasoning column.
record=$(make_case pi-no-package pi-no-package-task pi openai-codex/model-pi max)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
out=$(FM_PI_PACKAGE_DIR="$DIR/absent-pi-package" run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-no-package-task "$PROJ_DIR" "$DIR/launch.log") \
  && fail "a Pi preset launched without a verifiable exact reasoning surface"
assert_contains "$out" "could not verify exact Pi reasoning support" "missing-package reasoning refusal"
assert_contains "$out" "installed Pi package not found" "missing-package probe detail"
[ ! -s "$DIR/launch.log" ] || fail "missing-package refusal still delivered a launch"

# A fixed fast value is guaranteed only through the deterministic preset plan:
# the launch disables discovery and names the task extension last, so the
# generated provider-request handler is the final request rewriter. The launch
# must deliver exactly that plan, and the ledger still records fast as
# requested-only, never wire-verified.
record=$(make_case pi-fast pi-fast-task pi openai-codex/model-pi max true)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-fast-task "$PROJ_DIR" "$DIR/launch.log") \
  || fail "Pi fast preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
assert_contains "$launch" "--no-extensions" "fast preset launch disables discovery"
case "$launch" in
  *"'--no-extensions' '-e' '"$HOME_DIR/state/pi-fast-task.pi-ext.ts"'"*) ;;
  *) fail "the fast preset launch did not deliver --no-extensions before the task extension: $launch" ;;
esac
fast_extension="'-e' '$HOME_DIR/state/pi-fast-task.pi-ext.ts'"
after_extension=${launch#*"$fast_extension"}
case "$after_extension" in
  *"'-e' "*) fail "a later extension followed the task extension in the fast launch: $launch" ;;
esac
cat > "$DIR/assert-pi-fast-extension.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const callbacks = new Map();
const pi = {
  on(name, callback) {
    if (!callbacks.has(name)) callbacks.set(name, []);
    callbacks.get(name).push(callback);
  },
};
const extension = await import(pathToFileURL(process.argv[2]).href);
extension.default(pi);
const handlers = callbacks.get("before_provider_request") || [];
if (handlers.length !== 1) throw new Error(`expected one provider-request handler, got ${handlers.length}`);
const rewritten = handlers[0]({ payload: { model: "gpt-5" } }, { model: { provider: "openai-codex", api: "openai-codex-responses" } });
if (rewritten.service_tier !== "priority") throw new Error(`fast request did not set priority: ${JSON.stringify(rewritten)}`);
const untouched = handlers[0]({ payload: { model: "other" } }, { model: { provider: "anthropic", api: "anthropic-messages" } });
if (untouched !== undefined) throw new Error("fast request rewrote a non-codex provider payload");
JS
node --no-warnings "$DIR/assert-pi-fast-extension.mjs" "$HOME_DIR/state/pi-fast-task.pi-ext.ts" \
  || fail "the delivered fast task extension did not register its provider-request handler"
metrics="$HOME_DIR/data/dispatch-metrics.jsonl"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.fast' "$metrics")" = null ] \
  || fail "a requested fast value was claimed as effective"
[ "$(jq -s -r 'map(select(.event=="launch-prepared"))[0].effective.fast_basis' "$metrics")" = requested-not-wire-verified ] \
  || fail "the fast value was not recorded as requested-only"

# The pure plan helper still owns the refusal fixture: a plan that appends a
# later rewriter after the task extension refuses before launch
# (tests/fm-pi-launch-plan.test.sh), and a preset launch whose resolved plan
# cannot prove the ordering is refused by the same call.

record=$(make_case grok grok-preset-task grok grok-example xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_grok "$FAKEBIN_DIR"
write_fake_grok_catalog "$HOME_DIR" 9.9.9-test '{"grok-example":{"info":{"supports_reasoning_effort":true,"reasoning_effort":"high","reasoning_efforts":[{"id":"xhigh","value":"xhigh"},{"id":"high","value":"high"},{"id":"medium","value":"medium"},{"id":"low","value":"low"}]}}}'
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" grok-preset-task "$PROJ_DIR" "$DIR/launch.log") || fail "Grok preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
assert_contains "$launch" "--session-id '" "Grok session identity"
assert_contains "$launch" "--model 'grok-example' --reasoning-effort 'xhigh'" "Grok xhigh launch setting"

# The advertised effort menu varies by model, so a level the selected model
# does not advertise refuses before launch rather than being recorded as
# validated control (installed 1.0.30: grok-4.6 advertises xhigh, grok-4.5 does
# not).
record=$(make_case grok-effort-refused grok-effort-task grok grok-example xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_grok "$FAKEBIN_DIR"
write_fake_grok_catalog "$HOME_DIR" 9.9.9-test '{"grok-example":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"id":"high","value":"high"},{"id":"medium","value":"medium"},{"id":"low","value":"low"}]}}}'
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" grok-effort-task "$PROJ_DIR" "$DIR/launch.log") \
  && fail "a Grok preset launched an effort the selected model does not advertise"
assert_contains "$out" "does not advertise reasoning effort 'xhigh'" "Grok per-model effort refusal"
assert_contains "$out" "advertised: high,medium,low" "Grok advertised effort menu"
[ ! -s "$DIR/launch.log" ] || fail "the Grok effort refusal still delivered a launch"

# Without the CLI's own fetched catalog nothing proves the pair, so the launch
# refuses instead of falling back to a guessed global effort range.
record=$(make_case grok-no-catalog grok-no-catalog-task grok grok-example xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_grok "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" grok-no-catalog-task "$PROJ_DIR" "$DIR/launch.log") \
  && fail "a Grok preset launched without the catalog that proves its effort"
assert_contains "$out" "no fetched Grok model catalog" "Grok missing-catalog refusal"
[ ! -s "$DIR/launch.log" ] || fail "the Grok missing-catalog refusal still delivered a launch"

record=$(make_case claude claude-preset-task claude opus medium)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_claude "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" claude-preset-task "$PROJ_DIR" "$DIR/launch.log") || fail "Claude preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
assert_contains "$launch" "--session-id '" "Claude session identity"
assert_contains "$launch" "--model 'opus' --effort 'medium'" "Claude launch settings"

record=$(make_case opencode opencode-preset-task opencode vendor/model-open xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_opencode "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" opencode-preset-task "$PROJ_DIR" "$DIR/launch.log") || fail "OpenCode preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
# The installed `opencode run` subcommand is one-shot, so the preset must launch
# the long-lived TUI with a per-launch agent carrying the exact model/variant.
case "$launch" in
  *"opencode run "*) fail "OpenCode preset launched the one-shot run subcommand: $launch" ;;
esac
assert_contains "$launch" "opencode --agent 'fm-preset-opencode-preset-task' --model 'vendor/model-open' --prompt" "OpenCode persistent TUI launch"
case "$launch" in
  *'--auto'*) fail "OpenCode preset launch added the redundant --auto approval flag: $launch" ;;
esac
oc_config=$(printf '%s\n' "$launch" | sed -n "s/^.*OPENCODE_CONFIG_CONTENT='\([^']*\)'.*$/\1/p" | head -1)
[ -n "$oc_config" ] || fail "OpenCode preset launch did not carry an OPENCODE_CONFIG_CONTENT"
[ "$(printf '%s' "$oc_config" | jq -r '.permission["*"]')" = allow ] \
  || fail "OpenCode preset config lost its permission posture"
[ "$(printf '%s' "$oc_config" | jq -r '.agent["fm-preset-opencode-preset-task"].mode')" = primary ] \
  || fail "OpenCode preset agent is not a primary agent"
[ "$(printf '%s' "$oc_config" | jq -r '.agent["fm-preset-opencode-preset-task"].model')" = vendor/model-open ] \
  || fail "OpenCode preset agent lost the exact model"
[ "$(printf '%s' "$oc_config" | jq -r '.agent["fm-preset-opencode-preset-task"].variant')" = xhigh ] \
  || fail "OpenCode preset agent lost the exact variant"
cat > "$DIR/assert-opencode-runtime.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const plugin = await import(pathToFileURL(process.argv[2]).href);
const hooks = await plugin.FmBusyState({});
const updated = (sessionID, modelID) => hooks.event({ event: { type: "message.updated", properties: {
  info: { id: `msg_${sessionID}`, sessionID, role: "assistant", providerID: "vendor", modelID },
} } });
await hooks.event({ event: { type: "message.updated", properties: { info: { id: "msg_user", sessionID: "ses_main", role: "user" } } } });
await updated("ses_main", "model-open");
await updated("ses_child", "model-cheap");
JS
node --no-warnings "$DIR/assert-opencode-runtime.mjs" "$WT_DIR/.opencode/plugins/fm-busy-state.js" \
  || fail "generated OpenCode plugin could not be driven"
runtime="$HOME_DIR/state/opencode-preset-task.dispatch-runtime.json"
[ "$(jq -r '.session_id + " " + .model_used + " " + (.effort_used | tostring)' "$runtime")" = "ses_main vendor/model-open null" ] \
  || fail "OpenCode runtime record was not scoped to the main task session: $(cat "$runtime")"

record=$(make_case opencode-noauth opencode-noauth-task opencode vendor/model-open xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_opencode "$FAKEBIN_DIR"
# Remove the credential line while retaining the exact model/variant catalog.
perl -0pi -e 's/printf '\''%s\\n'\'' '\''Vendor api'\''/printf '\''%s\\n'\'' '\''Other api'\''/' "$FAKEBIN_DIR/opencode"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" opencode-noauth-task "$PROJ_DIR" "$DIR/launch.log") \
  && fail "OpenCode preset launched without a matching credential"
assert_contains "$out" "has no matching credential" "OpenCode credential refusal"
[ ! -s "$DIR/launch.log" ] || fail "credential refusal still delivered a launch"

# A harness switch on a preset task used to replay the sampled model/effort and
# the Pi-only fast value onto the replacement harness, and it only refused after
# the old agent had already been stopped. --preflight is the same profile
# resolution the launch runs, on the pre-stop side: a different harness resets
# the sampled axes (and drops the Pi-only fast request), an explicit override is
# preserved and validated, and nothing durable changes either way.
record=$(make_case pi-switch pi-switch-task pi openai-codex/model-pi max true)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
install_fake_grok "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-switch-task "$PROJ_DIR" "$DIR/launch.log") \
  || fail "Pi fast preset spawn for relaunch failed: $out"
meta_before=$(cat "$HOME_DIR/state/pi-switch-task.meta")
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-switch-task --relaunch --harness grok --preflight 2>&1) \
  || fail "harness-switch preflight did not resolve the default replacement profile: $out"
assert_contains "$out" "profile-validated harness=grok model=default effort=default" "harness-switch preflight profile"
[ "$(cat "$HOME_DIR/state/pi-switch-task.meta")" = "$meta_before" ] || fail "preflight rewrote the task record"
# The same harness keeps the sampled candidate and still validates it.
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-switch-task --relaunch --harness pi --preflight 2>&1) \
  || fail "same-harness preflight did not validate the sampled profile: $out"
assert_contains "$out" "profile-validated harness=pi model=openai-codex/model-pi effort=max" "same-harness preflight profile"
# An explicit override survives a harness switch and is validated against the
# target harness's own catalog.
write_fake_grok_catalog "$HOME_DIR" 9.9.9-test '{"grok-example":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"id":"xhigh","value":"xhigh"},{"id":"high","value":"high"}]}}}'
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-switch-task --relaunch --harness grok --model grok-example --effort xhigh --preflight 2>&1) \
  || fail "preflight refused an explicit override the target harness advertises: $out"
assert_contains "$out" "profile-validated harness=grok model=grok-example effort=xhigh" "explicit override preflight profile"
if out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-switch-task --relaunch --harness grok --model grok-absent --effort xhigh --preflight 2>&1); then
  fail "preflight accepted an explicit model the target harness does not advertise"
fi
assert_contains "$out" "which is not in 'grok models'" "explicit override refusal detail"
[ "$(cat "$HOME_DIR/state/pi-switch-task.meta")" = "$meta_before" ] || fail "a refused preflight rewrote the task record"

# A switch that names only a model must resolve the target tool's own default
# effort/variant instead of validating the literal string 'default': Pi skips
# the exact-level probe for an unrequested level, and OpenCode accepts the
# model without requiring a variant or writing one into the agent record.
record=$(make_case model-only-switch model-only-switch-task grok grok-example xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_grok "$FAKEBIN_DIR"
write_fake_grok_catalog "$HOME_DIR" 9.9.9-test '{"grok-example":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"id":"xhigh","value":"xhigh"},{"id":"high","value":"high"}]}}}'
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" model-only-switch-task "$PROJ_DIR" "$DIR/launch.log") \
  || fail "Grok preset spawn for the model-only switch failed: $out"
install_fake_pi "$FAKEBIN_DIR"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" model-only-switch-task --relaunch --harness pi --model openai-codex/model-pi --preflight 2>&1) \
  || fail "a Pi switch with an explicit model and no effort must resolve Pi's default level: $out"
assert_contains "$out" "profile-validated harness=pi model=openai-codex/model-pi effort=default" "Pi model-only preflight profile"
install_fake_opencode "$FAKEBIN_DIR"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" model-only-switch-task --relaunch --harness opencode --model vendor/model-open --preflight 2>&1) \
  || fail "an OpenCode switch with an explicit model and no variant must resolve OpenCode's default variant: $out"
assert_contains "$out" "profile-validated harness=opencode model=vendor/model-open effort=default opencode-agent=fm-preset-model-only-switch-task" "OpenCode model-only preflight profile"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" model-only-switch-task --relaunch --harness opencode --preflight 2>&1) \
  || fail "an OpenCode switch with no axes must resolve the ordinary default configuration: $out"
assert_contains "$out" "profile-validated harness=opencode model=default effort=default opencode-agent=ordinary" "OpenCode default preflight profile"
# An explicitly requested effort without the model it belongs to cannot be
# proven against any per-model menu, so it must stop clearly instead of being
# written into a launch control the model may not support.
if out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" model-only-switch-task --relaunch --harness pi --effort high --preflight 2>&1); then
  fail "a Pi switch with an effort but no model was accepted"
fi
assert_contains "$out" "requested Pi effort 'high' without an explicit model" "Pi effort-without-model refusal"
if out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" model-only-switch-task --relaunch --harness opencode --effort high --preflight 2>&1); then
  fail "an OpenCode switch with a variant but no model was accepted"
fi
assert_contains "$out" "requested OpenCode effort 'high' without an explicit model" "OpenCode variant-without-model refusal"

# --preflight is relaunch-only; a fresh spawn must not silently accept it.
if out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" preflight-fresh "$PROJ_DIR" --scout --preflight 2>&1); then
  fail "--preflight was accepted without --relaunch"
fi
assert_contains "$out" "--preflight applies only to --relaunch" "--preflight scope refusal"

echo "PASS: task/model preset launch controls stay exact across Pi, Grok, Claude Code, and OpenCode"
