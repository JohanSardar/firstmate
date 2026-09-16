#!/usr/bin/env bash
# Claude model-token evidence for opt-in preset launches.
#
# Sourced by bin/fm-spawn.sh before an opt-in preset Claude launch and by the
# focused test suite.
#
# Claude Code's own `--help` is the installed CLI's token-free launch
# documentation: it states that --model accepts an alias for the latest model
# (e.g. 'fable', 'opus', or 'sonnet') or a model's full name (e.g.
# 'claude-fable-5') and quotes the tokens it documents. It is the only
# authoritative token-free evidence available: Claude Code ships no installed
# model catalog, and user config/cache values (session history, cached
# client-data slots) are evidence of past use, never of launchability.
#
#   fm_claude_model_evidence <help-text> <model>
#
# Proves the token only when the installed help's own --model option block
# quotes it exactly. Only that option's block counts: a single-quoted token
# another option documents (for example --agent's 'agent' setting name) is not
# a model. A plausible-looking pattern is never accepted in its place, and no
# prompt or print invocation is ever made to discover a model list. Prints
# nothing and returns 0 when the token is documented; otherwise prints one
# reason line and returns 1, and the caller refuses the launch.
fm_claude_model_evidence() {  # <help-text> <model>
  local help_text=$1 model=$2 vocabulary
  case "$model" in
    '' | *[!A-Za-z0-9._:/+-]*)
      printf '%s\n' "Claude model '$model' is not an exact model token"
      return 1
      ;;
  esac
  # The --model option's block is its option line plus the indented
  # continuation lines under it; a following option line (`  -`), an unindented
  # section header, or a blank line ends the block. A help surface whose
  # --model block cannot be located yields no vocabulary and therefore refuses.
  vocabulary=$(printf '%s\n' "$help_text" | awk '
    /^[[:space:]]*--model([[:space:]<,]|$)/ || /^[[:space:]]*-[^[:space:]], --model([[:space:]<,]|$)/ { in_model = 1; print; next }
    in_model && /^  -/ { exit }
    in_model && /^[A-Za-z][A-Za-z ]*:$/ { exit }
    in_model && /^[[:space:]]*$/ { exit }
    in_model { print }
  ')
  case "$vocabulary" in
    *"'$model'"*) return 0 ;;
  esac
  printf '%s\n' "the installed Claude Code help's --model option does not document model '$model', and no authoritative token-free catalog enumerates it, so its launchability cannot be proven"
  return 1
}
