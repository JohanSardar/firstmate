#!/usr/bin/env bash
# Pure decision owner for Pi's per-worker fast guarantee.
#
# Sourced by bin/fm-spawn.sh before an opt-in preset launch and by the focused
# test suite. The one contract lives here:
#
#   fm_pi_fast_plan_guarantees <task-extension> [plan-arg...]
#
# It decides, from an already-resolved ordered launch plan, whether a fixed
# per-worker service_tier request can be guaranteed. It is pure: it never reads
# the filesystem, environment, settings, discovered extensions, or project
# paths, and it writes nothing except a one-line refusal reason on stdout when
# the plan cannot prove the guarantee.
#
# Pi runs before_provider_request handlers in extension load order and the last
# registered handler owns the final payload. A fixed fast value is therefore
# guaranteed only when the resolved plan:
#   - carries --no-extensions, so no discovered user, project, or package
#     extension can load implicitly and register a later handler, and
#   - loads the task extension with -e/--extension as the last explicit
#     extension, so its handler is registered last and its payload wins.
# The caller supplies the plan that the launcher will actually deliver; a plan
# that cannot prove both conditions is refused rather than trusted, because
# assuming an unproven load order is exactly the silent override this contract
# exists to prevent.
#
# Refusal reasons (stdout, return 1):
#   missing --no-extensions
#   no explicit extension list
#   task extension is not the last extension
#   extension option without a value
fm_pi_fast_plan_guarantees() {  # <task-extension> <plan-arg>...
  local task_extension=$1
  shift
  local no_extensions=0 extensions=0 last_extension=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-extensions)
        no_extensions=1
        shift
        ;;
      -e|--extension)
        shift
        if [ "$#" -eq 0 ]; then
          printf '%s\n' 'extension option without a value'
          return 1
        fi
        extensions=$((extensions + 1))
        last_extension=$1
        shift
        ;;
      --extension=*)
        extensions=$((extensions + 1))
        last_extension=${1#--extension=}
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  [ "$no_extensions" -eq 1 ] || {
    printf '%s\n' 'missing --no-extensions'
    return 1
  }
  [ "$extensions" -gt 0 ] || {
    printf '%s\n' 'no explicit extension list'
    return 1
  }
  [ "$last_extension" = "$task_extension" ] || {
    printf '%s\n' 'task extension is not the last extension'
    return 1
  }
  return 0
}
