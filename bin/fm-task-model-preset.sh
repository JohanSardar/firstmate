#!/usr/bin/env bash
# Opt-in task-to-model preset selector.
#
# Usage:
#   fm-task-model-preset.sh validate [<config-path>]
#   fm-task-model-preset.sh select <task-id> <preset-name|default> [<config-path>]
#
# The default config is $FM_CONFIG_OVERRIDE/task-model-presets.json, otherwise
# $FM_HOME/config/task-model-presets.json. Selection is deterministic for the
# config seed + preset + task id. The complete sampled choice is published to
# state/<task-id>.dispatch-choice.json before it is returned. A retry reuses
# that record even when the config changed, so retries never produce duplicate
# samples or silently fall through to another candidate. Unavailable candidates
# remain in the weighted draw and stop a sampled launch explicitly.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
NODE=${NODE:-node}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

command -v "$NODE" >/dev/null 2>&1 || die "node is required for task/model preset selection"
command=${1:-}
case "$command" in
  validate)
    [ "$#" -le 2 ] || { usage >&2; exit 2; }
    config=${2:-$CONFIG/task-model-presets.json}
    exec "$NODE" "$SCRIPT_DIR/fm-task-model-preset.mjs" validate --config "$config"
    ;;
  select)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
    task=$2
    preset=$3
    config=${4:-$CONFIG/task-model-presets.json}
    exec "$NODE" "$SCRIPT_DIR/fm-task-model-preset.mjs" select \
      --config "$config" --state-dir "$STATE" --task "$task" --preset "$preset"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
