#!/usr/bin/env bash
# Structured, conservative metrics for opt-in task/model preset runs.
#
# Internal lifecycle calls:
#   fm-dispatch-metrics.sh launch <meta-path> <choice-path>
#   fm-dispatch-metrics.sh finish <meta-path> <choice-path> <outcome>
#
# Later observations:
#   fm-dispatch-metrics.sh observe <task-id> [--model-used <provider/model>]
#     [--effort-used <level>] [--fast-server-verified on|off|unknown]
#     [--quality passed|bug-found|bug-escaped|unknown]
#     [--usage '<json object with kind>'] [--basis <source>]
#     [--quota-fraction <0..1> --monthly-price-usd <n> --reset-days <n>]
#
# Records append to data/dispatch-metrics.jsonl. Subscription cost is always an
# estimate, never billing: a weekly estimate is emitted only when all inputs are
# supplied and reset-days is exactly 7. Missing observations stay unknown, never
# zero. Prices, usage, and account details belong only in this gitignored ledger.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
LEDGER=$DATA/dispatch-metrics.jsonl
NODE=${NODE:-node}

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

command -v "$NODE" >/dev/null 2>&1 || die "node is required for dispatch metrics"
mkdir -p "$DATA"
command=${1:-}
case "$command" in
  launch)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    exec "$NODE" "$SCRIPT_DIR/fm-dispatch-metrics.mjs" launch \
      --meta "$2" --choice "$3" --ledger "$LEDGER"
    ;;
  finish)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    exec "$NODE" "$SCRIPT_DIR/fm-dispatch-metrics.mjs" finish \
      --meta "$2" --choice "$3" --ledger "$LEDGER" --outcome "$4"
    ;;
  observe)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    task=$2
    shift 2
    exec "$NODE" "$SCRIPT_DIR/fm-dispatch-metrics.mjs" observe \
      --ledger "$LEDGER" --task "$task" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
