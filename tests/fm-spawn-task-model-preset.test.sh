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

# The resolved launch plan is the only fast authority. This spawn delivers its
# task extension with -e but no --no-extensions, so a fixed fast value cannot be
# proven to survive a later discovered handler and is refused before launch.
record=$(make_case pi-fast pi-fast-task pi openai-codex/model-pi max false)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-fast-task "$PROJ_DIR" "$DIR/launch.log") \
  && fail "a fixed fast preset launched without a plan that proves the task extension wins"
assert_contains "$out" "cannot guarantee it (missing --no-extensions)" "fast plan refusal reason"
assert_contains "$out" "refusing to launch with a fast value it cannot prove" "fast plan refusal wording"
[ ! -s "$DIR/launch.log" ] || fail "fast plan refusal still delivered a launch"

record=$(make_case grok grok-preset-task grok grok-example xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_grok "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" grok-preset-task "$PROJ_DIR" "$DIR/launch.log") || fail "Grok preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
assert_contains "$launch" "--session-id '" "Grok session identity"
assert_contains "$launch" "--model 'grok-example' --reasoning-effort 'xhigh'" "Grok xhigh launch setting"

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
assert_contains "$launch" "opencode run --interactive --auto --model 'vendor/model-open' --variant 'xhigh'" "OpenCode variant launch"
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

echo "PASS: task/model preset launch controls stay exact across Pi, Grok, Claude Code, and OpenCode"
