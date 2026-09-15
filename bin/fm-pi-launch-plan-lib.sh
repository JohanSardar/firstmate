#!/usr/bin/env bash
# Pure decision owner for Pi's per-worker fast guarantee.
#
# Sourced by bin/fm-spawn.sh before an opt-in preset launch and by the focused
# test suite. The one contract lives here:
#
#   fm_pi_fast_plan_guarantees <task-extension> <registration-extension|-> [plan-arg...]
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
#     extension can load implicitly and register a later handler,
#   - loads exactly one task extension with -e/--extension as the last explicit
#     extension, so its handler is registered last and its payload wins, and
#   - names no other extension except, when the backend requires it, the single
#     verified registration-only integration before that task extension.
# The caller supplies the plan that the launcher will actually deliver; a plan
# that cannot prove both conditions is refused rather than trusted, because
# assuming an unproven load order is exactly the silent override this contract
# exists to prevent.
#
# The registration extension argument is the path the caller already resolved
# and verified as registration-only (identity markers plus no
# before_provider_request registration - bin/fm-herdr-pi-registration-lib.sh
# owns that proof). It is "-" when no extra extension is required. This helper
# still checks the plan it is given: a declared registration extension that is
# missing from the plan, or any other extension before the task extension,
# refuses, so the launcher cannot drop the backend's integration while still
# claiming the fast guarantee.
#
# Refusal reasons (stdout, return 1):
#   missing --no-extensions
#   no explicit extension list
#   task extension is not the last extension
#   extension option without a value
#   the required registration extension is missing from the plan
#   an unverified extension precedes the task extension
fm_pi_fast_plan_guarantees() {  # <task-extension> <registration-extension|-> <plan-arg>...
  local task_extension=$1 registration_extension=$2
  shift 2
  local no_extensions=0 extensions=0 last_extension='' preceding_ok=1 registration_seen=0
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
        # Every extension already loaded must be the one verified
        # registration-only integration the caller declared.
        if [ "$extensions" -gt 0 ]; then
          if [ "$registration_extension" = '-' ] || [ "$last_extension" != "$registration_extension" ]; then
            preceding_ok=0
          fi
        fi
        extensions=$((extensions + 1))
        last_extension=$1
        [ "$last_extension" != "$registration_extension" ] || registration_seen=1
        shift
        ;;
      --extension=*)
        if [ "$extensions" -gt 0 ]; then
          if [ "$registration_extension" = '-' ] || [ "$last_extension" != "$registration_extension" ]; then
            preceding_ok=0
          fi
        fi
        extensions=$((extensions + 1))
        last_extension=${1#--extension=}
        [ "$last_extension" != "$registration_extension" ] || registration_seen=1
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
  [ "$preceding_ok" -eq 1 ] || {
    printf '%s\n' 'an unverified extension precedes the task extension'
    return 1
  }
  if [ "$registration_extension" != '-' ] && [ "$registration_seen" -eq 0 ]; then
    printf '%s\n' 'the required registration extension is missing from the plan'
    return 1
  fi
  return 0
}
