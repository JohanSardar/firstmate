# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4 and model variants re-verified on 2026-09-12 using 1.18.28; the persistent preset launch shape was re-verified on 2026-09-15 using 1.18.30.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | `--model <provider/model>`. |
| Effort flag | None on the ordinary interactive `opencode --prompt` launch. An opt-in task/model preset launches the same long-lived TUI with a per-launch agent whose `variant` carries the requested level, after verifying that level in that exact model's verbose variant table. `opencode run` is a one-shot batch command and is never the preset worker shape (its `--interactive` flag starts no persistent worker on 1.18.x). |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers and add `--verbose` for model-specific variants. |
| Trust dialog | None. |

Preset selection also requires a matching `opencode providers list` credential and never substitutes a similarly named contributor-free or API-billed product.
An opt-in preset delivers `OPENCODE_CONFIG_CONTENT` with `permission` plus a per-launch primary agent carrying the exact `model` and `variant`, and launches `opencode --agent <name> --auto --prompt <brief>`; OpenCode resolves an agent-configured variant ahead of the model default, so the persistent TUI runs the sampled pair.
`tests/fm-opencode-preset-agent-live-e2e.test.sh` proves that resolution against the real installed CLI (token-free).
The task-local plugin records the model and variant OpenCode reports for later comparison, from `message.updated` assistant messages of the first session that produced one (the worker's main session); a subagent child session's messages are ignored, and `AssistantMessage` carries no variant, so the observed effort stays null.
OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.
