#!/usr/bin/env bash
# Verified Herdr Pi integration resolution for a fixed-fast preset launch.
#
# Sourced by bin/fm-spawn.sh before an opt-in fixed-fast Pi launch and by the
# focused test suite. The one contract lives here:
#
#   fm_herdr_pi_registration_extension <agent-dir>
#
# A fixed-fast preset Pi launch runs with --no-extensions so no discovered
# extension can register a later provider-request rewriter than the task
# control extension. On the herdr backend that also removes Herdr's own Pi
# integration from Pi's discovery, and without it the worker never reports its
# session or lifecycle state to Herdr: `agent get` never leaves agent_not_found
# and the pane cannot be classified as a live agent. The integration is safe to
# load beside the task extension because it only reports agent state; it must
# never carry a provider-request rewriter, the one hook through which a loaded
# extension can rewrite the request payload.
#
# The function proves all of that from the file the launch will actually load,
# never from a path name alone:
#   - the file exists at <agent-dir>/extensions/herdr-agent-state.ts and is a
#     regular file,
#   - its content carries Herdr's own management markers,
#   - it performs the agent-state registration RPC it exists for, and
#   - it registers no before_provider_request handler.
# It prints the resolved absolute path and returns 0 only when every check
# passes; otherwise it prints one reason line and returns 1. A missing or
# unverifiable integration must refuse the fixed-fast launch instead of
# producing an unobservable worker.
fm_herdr_pi_registration_extension() {  # <agent-dir>
  local agent_dir=$1
  local path="${agent_dir%/}/extensions/herdr-agent-state.ts"
  if [ ! -f "$path" ]; then
    printf '%s\n' "the Herdr Pi integration is not installed at $path"
    return 1
  fi
  if [ ! -r "$path" ]; then
    printf '%s\n' "the Herdr Pi integration at $path is not readable"
    return 1
  fi
  if ! grep -q 'installed by herdr' "$path"; then
    printf '%s\n' "the file at $path is not the Herdr-managed Pi integration (missing its installed-by-herdr marker)"
    return 1
  fi
  if ! grep -q 'HERDR_INTEGRATION_ID=pi' "$path"; then
    printf '%s\n' "the file at $path is not the Herdr Pi integration (missing HERDR_INTEGRATION_ID=pi)"
    return 1
  fi
  if ! grep -q 'pane\.report_agent' "$path"; then
    printf '%s\n' "the file at $path does not report agent state to Herdr (no pane.report_agent call)"
    return 1
  fi
  if grep -q 'before_provider_request' "$path"; then
    printf '%s\n' "the file at $path registers a provider-request rewriter, so it cannot be loaded beside the task fast control"
    return 1
  fi
  printf '%s\n' "$path"
}
