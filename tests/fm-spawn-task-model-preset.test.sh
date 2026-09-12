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

run_case() {
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5 log=$6
  : > "$log"
  FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --scout --preset chosen 2>&1
}

record=$(make_case pi pi-preset-task pi openai-codex/model-pi max false)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_pi "$FAKEBIN_DIR"
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pi-preset-task "$PROJ_DIR" "$DIR/launch.log") || fail "Pi preset spawn failed: $out"
launch=$(cat "$DIR/launch.log")
assert_contains "$launch" "--model 'openai-codex/model-pi' --thinking 'max'" "Pi launch settings"
cat > "$DIR/assert-pi-fast.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const callbacks = new Map();
const pi = {
  on(name, callback) {
    if (!callbacks.has(name)) callbacks.set(name, []);
    callbacks.get(name).push(callback);
  },
  appendEntry() {},
};
const extension = await import(pathToFileURL(process.argv[2]).href);
extension.default(pi);
const context = {
  model: { provider: "openai-codex", id: "model-pi" },
  thinkingLevel: "max",
  sessionManager: { getSessionId: () => "test-session", getSessionFile: () => null },
};
for (const callback of callbacks.get("session_start") || []) await callback({}, context);
const providerCallbacks = callbacks.get("before_provider_request") || [];
if (providerCallbacks.length !== 1) throw new Error(`expected one preset provider handler, got ${providerCallbacks.length}`);
const payload = await providerCallbacks[0]({
  model: { provider: "openai-codex", api: "openai-codex-responses" },
  payload: { service_tier: "priority", retained: true },
});
if (payload.service_tier !== "default" || payload.retained !== true) {
  throw new Error(`fast off did not rewrite only service_tier: ${JSON.stringify(payload)}`);
}
JS
node --no-warnings "$DIR/assert-pi-fast.mjs" "$HOME_DIR/state/pi-preset-task.pi-ext.ts" \
  || fail "generated Pi extension did not apply fast off at runtime"
[ ! -e "$HOME_DIR/user-home/.pi/agent/settings.json" ] || fail "Pi preset changed global settings"
[ "$(grep '^dispatch_fast=' "$HOME_DIR/state/pi-preset-task.meta")" = dispatch_fast=off ] || fail "Pi fast effective setting was not recorded"
[ "$(jq -s -r '.[0].selection.selected_candidate' "$HOME_DIR/data/dispatch-metrics.jsonl")" = candidate ] || fail "Pi launch provenance was not recorded"

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

record=$(make_case opencode-noauth opencode-noauth-task opencode vendor/model-open xhigh)
IFS='|' read -r DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$record
EOF
install_fake_opencode "$FAKEBIN_DIR"
# Remove the credential line while retaining the exact model/variant catalog.
perl -0pi -e 's/printf '\''%s\\n'\'' '\''Vendor api'\''/printf '\''%s\\n'\'' '\''Other api'\''/' "$FAKEBIN_DIR/opencode"
set +e
out=$(run_case "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" opencode-noauth-task "$PROJ_DIR" "$DIR/launch.log")
status=$?
set -e
[ "$status" -ne 0 ] || fail "OpenCode preset launched without a matching credential"
assert_contains "$out" "has no matching credential" "OpenCode credential refusal"
[ ! -s "$DIR/launch.log" ] || fail "credential refusal still delivered a launch"

echo "PASS: task/model preset settings reach Pi, Grok, Claude Code, and OpenCode without silent fallback"
