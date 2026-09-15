#!/usr/bin/env bash
# tests/fm-claude-model-lib.test.sh - fixture tests for the Claude model-token
# evidence helper (bin/fm-claude-model-lib.sh).
#
# Claude Code documents the --model form in its own help text (an alias for the
# latest model, or a model's full name) but quotes only the tokens it
# enumerates, and it ships no authoritative installed model catalog. The helper
# proves a token only when the installed help quotes it exactly; any other exact
# id refuses instead of accepting a plausible pattern, and it never probes the
# CLI with a prompt. These cases drive that verdict from help-text fixtures
# alone: no claude binary, no login, and no provider call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-model-lib.sh"

HELP="--model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name (e.g.
                                        'claude-fable-5')."

fm_claude_model_evidence "$HELP" opus \
  || fail "a help-documented alias was refused"
pass "a help-documented alias is proven"

fm_claude_model_evidence "$HELP" claude-fable-5 \
  || fail "a help-documented full model name was refused"
pass "a help-documented full model name is proven"

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
