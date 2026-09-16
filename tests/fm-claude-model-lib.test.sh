#!/usr/bin/env bash
# tests/fm-claude-model-lib.test.sh - fixture tests for the Claude model-token
# evidence helper (bin/fm-claude-model-lib.sh).
#
# Claude Code documents the --model form in its own help text (an alias for the
# latest model, or a model's full name) but quotes only the tokens it
# enumerates, and it ships no authoritative installed model catalog. The helper
# proves a token only when the installed help's own --model option block quotes
# it exactly; a token quoted by a different option refuses, any other exact id
# refuses instead of accepting a plausible pattern, and it never probes the CLI
# with a prompt. These cases drive that verdict from help-text fixtures alone:
# no claude binary, no login, and no provider call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-model-lib.sh"

# Shaped like the real help output: options are indented two spaces, their
# descriptions continue on deeper-indented lines, and other options quote
# their own vocabulary in single quotes.
HELP="Options:
  --agent <agent>                       Agent for the current session. Overrides
                                        the 'agent' setting.
  --agents <json>                       JSON object defining custom agents (e.g.
                                        '{\"reviewer\": {\"description\": \"Reviews
                                        code\"}}')
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name (e.g.
                                        'claude-fable-5').
  -n, --name <name>                     Set a display name for this session
                                        (shown in the prompt box).

Commands:
  agents                                List configured agents
"

fm_claude_model_evidence "$HELP" opus \
  || fail "a help-documented alias was refused"
pass "a help-documented alias is proven"

fm_claude_model_evidence "$HELP" claude-fable-5 \
  || fail "a help-documented full model name was refused"
pass "a help-documented full model name is proven"

# The --agent option quotes 'agent' as its own setting name. That is not a
# model vocabulary, so a preset model token of 'agent' must refuse: only the
# --model option's own block proves a model.
reason=$(fm_claude_model_evidence "$HELP" agent 2>&1) \
  && fail "an exact token quoted only by another option was accepted"
assert_contains "$reason" "does not document model 'agent'" "foreign-option token refusal"
assert_contains "$reason" "--model option" "refusal names the --model evidence surface"
pass "a token quoted by another option is not a model"

# Drive the same bug the other way: a model token that another option quotes,
# while the --model block does not document it.
HELP_FOREIGN="Options:
  --agent <agent>                       Agent for the current session. Overrides
                                        the 'opus' setting.
  --model <model>                       Model for the current session.
  --no-chrome                           Disable Chrome integration.
"
reason=$(fm_claude_model_evidence "$HELP_FOREIGN" opus 2>&1) \
  && fail "a model token quoted only by another option was accepted"
assert_contains "$reason" "does not document model 'opus'" "model token from a foreign option refuses"
pass "a model token quoted outside the --model block refuses"

reason=$(fm_claude_model_evidence "$HELP" claude-opus-5 2>&1) \
  && fail "an exact id the help does not document was accepted"
assert_contains "$reason" "does not document model 'claude-opus-5'" "undocumented exact id refusal"
assert_contains "$reason" "cannot be proven" "refusal states the evidence gap"
pass "an undocumented exact model id refuses instead of guessing"

reason=$(fm_claude_model_evidence "$HELP" 'claude-opus-*' 2>&1) \
  && fail "a model pattern was accepted"
assert_contains "$reason" "not an exact model token" "pattern refusal"
pass "a model pattern is not an exact model token"

reason=$(fm_claude_model_evidence "" opus 2>&1) \
  && fail "an empty help text was treated as proof"
assert_contains "$reason" "does not document model 'opus'" "empty help refusal"
pass "an unreadable help surface proves nothing"

reason=$(fm_claude_model_evidence "$HELP" opusx 2>&1) \
  && fail "a token merely containing a documented alias was accepted"
assert_contains "$reason" "does not document model 'opusx'" "substring refusal"
pass "a token that merely contains a documented alias refuses"

# A help surface with no --model option at all cannot prove any token.
reason=$(fm_claude_model_evidence "Options:
  --no-chrome                           Disable Chrome integration.
" opus 2>&1) \
  && fail "a help surface without a --model option was treated as proof"
assert_contains "$reason" "does not document model 'opus'" "missing option refusal"
pass "a help surface without a --model option refuses"

# A short-alias spelling of the option is still the --model block.
HELP_SHORT="Options:
  -m, --model <model>                   Model for the current session (e.g.
                                        'opus').
  --no-chrome                           Disable Chrome integration.
"
fm_claude_model_evidence "$HELP_SHORT" opus \
  || fail "a short-alias --model option block did not prove its token"
pass "a short-alias --model option block is recognized"
