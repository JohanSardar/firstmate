#!/usr/bin/env node
// Internal structured-ledger owner for bin/fm-dispatch-metrics.sh.

import { closeSync, existsSync, fsyncSync, lstatSync, openSync, readFileSync, readSync, readdirSync, realpathSync, writeSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

function fail(message, code = 1) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(code);
}
function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) fail(`unexpected argument '${token}'`);
    const key = token.slice(2);
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) fail(`${token} needs a value`);
    args[key] = argv[i + 1];
    i += 1;
  }
  return args;
}
function meta(path) {
  const result = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const at = line.indexOf("=");
    if (at > 0) result[line.slice(0, at)] = line.slice(at + 1);
  }
  return result;
}
function readJson(path, label) {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    if (!object(value)) fail(`${label} must contain a JSON object`);
    return value;
  } catch (error) {
    fail(`cannot read ${label} ${path}: ${error.message}`);
  }
}
function ledgerHas(ledger, eventID) {
  if (!existsSync(ledger)) return false;
  for (const line of readFileSync(ledger, "utf8").split("\n")) {
    if (!line) continue;
    try {
      if (JSON.parse(line).event_id === eventID) return true;
    } catch {
      fail(`dispatch metrics ledger ${ledger} contains malformed JSON`);
    }
  }
  return false;
}
function append(ledger, event) {
  if (existsSync(ledger)) {
    const stat = lstatSync(ledger);
    if (!stat.isFile() || stat.nlink !== 1) fail(`dispatch metrics ledger ${ledger} must be a single-link regular file`);
  }
  if (ledgerHas(ledger, event.event_id)) return;
  const line = Buffer.from(`${JSON.stringify(event)}\n`);
  const fd = openSync(ledger, "a", 0o600);
  let written;
  try {
    written = writeSync(fd, line, 0, line.length);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  if (written !== line.length) fail(`dispatch metrics ledger ${ledger} accepted only ${written} of ${line.length} bytes`);
}
function numeric(value, name, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < min || number > max) fail(`${name} must be a number from ${min} through ${max}`);
  return number;
}
function nowISO() { return new Date().toISOString(); }
function findNamed(root, name, depth = 3) {
  if (!root || !existsSync(root) || depth < 0) return [];
  const found = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isFile() && entry.name === name) found.push(path);
    else if (entry.isDirectory()) found.push(...findNamed(path, name, depth - 1));
  }
  return found;
}
// Every launch-prepared record for this task in its current generation, oldest
// first. The generation token is the only scoping evidence. A task record with
// no generation token, or any same-task launch record with none, cannot be
// proven to belong to this task lifetime, so the scope reports incomplete
// evidence instead of being inferred from another field such as the launch
// origin.
function readRecordedLaunches(ledger, taskID, generation) {
  if (typeof generation !== "string" || !generation) {
    return {
      status: "incomplete",
      launches: [],
      reason: "the task record carries no generation token, so this task lifetime's recorded launches cannot be identified",
    };
  }
  if (!existsSync(ledger)) return { status: "complete", launches: [], reason: null };
  const launches = [];
  let unscoped = 0;
  for (const line of readFileSync(ledger, "utf8").split("\n")) {
    if (!line) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      fail(`dispatch metrics ledger ${ledger} contains malformed JSON`);
    }
    if (event.event !== "launch-prepared" || event.task_id !== taskID) continue;
    if (typeof event.generation !== "string" || !event.generation) {
      unscoped += 1;
      continue;
    }
    if (event.generation !== generation) continue;
    launches.push(event);
  }
  if (unscoped > 0) {
    return {
      status: "incomplete",
      launches,
      reason: `${unscoped} launch record(s) for this task carry no generation token, so complete incarnation scoping cannot be proven`,
    };
  }
  return { status: "complete", launches, reason: null };
}
// The generation token one observation belongs to: explicit when the operator
// supplies it, otherwise the most recent launch-prepared record for the task,
// which is the task lifetime the durable ledger was last told about. A ledger
// whose latest launch carries no token yields null rather than a guess, and the
// recorded basis says which of the two produced the token.
function observationGeneration(ledger, taskID, requested) {
  if (typeof requested === "string") {
    if (!requested) fail("--generation must be a non-empty task generation token");
    return { generation: requested, basis: "explicit" };
  }
  let latest = null;
  if (existsSync(ledger)) {
    for (const line of readFileSync(ledger, "utf8").split("\n")) {
      if (!line) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        fail(`dispatch metrics ledger ${ledger} contains malformed JSON`);
      }
      if (event.event !== "launch-prepared" || event.task_id !== taskID) continue;
      latest = event;
    }
  }
  const generation = typeof latest?.generation === "string" && latest.generation ? latest.generation : null;
  return { generation, basis: generation === null ? "no-generation-token" : "latest-recorded-launch" };
}
// Every runtime session those launches recorded, oldest first, deduplicated by
// harness+session. A relaunch re-mints the session id (Claude and Grok refuse a
// reused id), so the finish event aggregates every incarnation the ledger
// recorded rather than counting only the last one. Sessionless incarnations are
// kept too: a Pi or OpenCode launch records no runtime session, and dropping
// them would let a tool switch hide prior usage instead of reporting it unknown.
function recordedSessions(launches) {
  const sessions = [];
  for (const event of launches) {
    const harness = event.effective?.harness ?? null;
    const session = typeof event.runtime_session === "string" && event.runtime_session ? event.runtime_session : null;
    if (sessions.some((entry) => entry.session === session && entry.harness === harness)) continue;
    sessions.push({ session, harness });
  }
  return sessions;
}
// Explicit launch totals for the finish event, derived from the same ledger
// records. A launch is one delivered incarnation; a relaunch is a launch that
// replaced a running agent; a retry is a fresh spawn that reused an
// already-sampled durable choice instead of making a new draw. The launch kind
// and the reuse fact must be recorded explicitly: a record missing either one
// makes the totals incomplete evidence instead of being inferred from position
// or another field.
function launchTotals(launches, scopingReason) {
  if (scopingReason) {
    return { status: "incomplete", launches: null, relaunches: null, retries: null, reason: scopingReason };
  }
  const missing = launches.filter((event) => (event.launch_kind !== "spawn" && event.launch_kind !== "relaunch") || typeof event.selection_reused !== "boolean");
  if (missing.length > 0) {
    return {
      status: "incomplete",
      launches: launches.length,
      relaunches: null,
      retries: null,
      reason: `launch incarnation(s) without an explicit launch kind or selection reuse: ${missing.map((event) => event.spawn_gen || event.event_id || "unknown").join(",")}`,
    };
  }
  let relaunches = 0;
  let retries = 0;
  for (const event of launches) {
    if (event.launch_kind === "relaunch") relaunches += 1;
    else if (event.selection_reused === true) retries += 1;
  }
  return { status: "complete", launches: launches.length, relaunches, retries };
}
// One Claude transcript's usage, including the Agent-tool subagent transcripts
// that live beside the main session file. Every assistant message is counted
// once per stable message id across the main transcript and every subagent
// file: Claude mirrors the spawning Agent message into each subagent transcript,
// so deduplicating within only one file would double count it. A usage-bearing
// record without a stable id, or an unreadable transcript, keeps the whole
// incarnation unknown rather than presenting a partial sum as recorded.
function collectClaudeSession(session) {
  const root = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "projects");
  const matches = findNamed(root, `${session}.jsonl`, 3);
  if (matches.length !== 1) {
    const reason = `expected one Claude transcript, found ${matches.length}`;
    return {
      session_id: session,
      status: "unknown",
      reason,
      usage: { status: "unknown", kind: "tokens", reason },
    };
  }
  const mainPath = matches[0];
  let model = null;
  let effort = null;
  let speed = null;
  let serviceTier = null;
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  const counted = new Set();
  let unidentified = false;
  let unreadable = null;
  let subagentTranscripts = 0;
  let subagentResponses = 0;
  const readAssistantMessages = (path, { main = false } = {}) => {
    let lines;
    try {
      lines = readFileSync(path, "utf8").split("\n");
    } catch (error) {
      unreadable = `${path}: ${error.message}`;
      return 0;
    }
    let countedHere = 0;
    for (const line of lines) {
      if (!line) continue;
      let item;
      try { item = JSON.parse(line); } catch { continue; }
      if (item.type !== "assistant" || !object(item.message)) continue;
      if (main && item.isSidechain !== true) {
        model = item.message.model || model;
        effort = item.effort || effort;
      }
      const usage = item.message.usage;
      if (!object(usage)) continue;
      const messageID = item.message.id;
      if (typeof messageID !== "string" || !messageID) {
        unidentified = true;
        continue;
      }
      if (counted.has(messageID)) continue;
      counted.add(messageID);
      countedHere += 1;
      totals.input_tokens += Number(usage.input_tokens) || 0;
      totals.cache_read_tokens += Number(usage.cache_read_input_tokens) || 0;
      totals.cache_creation_tokens += Number(usage.cache_creation_input_tokens) || 0;
      totals.output_tokens += Number(usage.output_tokens) || 0;
      totals.thinking_tokens += Number(usage.output_tokens_details?.thinking_tokens) || 0;
      if (main) {
        speed = usage.speed || speed;
        serviceTier = usage.service_tier || serviceTier;
      }
    }
    return countedHere;
  };
  const responses = readAssistantMessages(mainPath, { main: true });
  const subagentDir = join(dirname(mainPath), session, "subagents");
  if (existsSync(subagentDir)) {
    let entries;
    try {
      entries = readdirSync(subagentDir, { withFileTypes: true });
    } catch (error) {
      unreadable = `${subagentDir}: ${error.message}`;
      entries = [];
    }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      subagentTranscripts += 1;
      subagentResponses += readAssistantMessages(join(subagentDir, entry.name));
    }
  }
  return {
    session_id: session,
    status: model ? "observed" : "unknown",
    basis: "local-claude-transcript",
    model_used: model,
    effort_used: effort,
    speed,
    service_tier: serviceTier,
    subagent_transcripts: subagentTranscripts,
    usage: !model ? null : unreadable || unidentified
      ? { status: "unknown", kind: "tokens", reason: unreadable ?? "transcript usage without a stable assistant message id cannot be deduplicated" }
      : { status: "recorded-local", kind: "tokens", responses: responses + subagentResponses, subagent_responses: subagentResponses, subagent_transcripts: subagentTranscripts, ...totals, completeness: "not-proven-for-aborted-turns" },
  };
}
// A multi-incarnation observation is complete only when every incarnation has
// its own complete local record. The reason names each missing incarnation
// with that collector's own precise cause instead of a generic replacement,
// and the block always carries an unknown usage section so a consumer never
// has to guess why usage is unavailable.
function incompleteRuntime(basis, observations, latest) {
  const missing = observations.filter((entry) => entry.status !== "observed" || entry.usage?.status !== "recorded-local");
  const detail = missing
    .map((entry) => `${entry.session_id ?? "unknown-session"} (${entry.usage?.reason ?? entry.reason ?? "no complete local record"})`)
    .join("; ");
  const reason = `relaunch incarnation(s) without a complete local record: ${detail}`;
  return {
    status: "unknown",
    basis,
    session_id: latest?.session_id ?? null,
    sessions: observations.map((entry) => ({ session_id: entry.session_id, status: entry.usage?.status ?? entry.status })),
    model_used: latest?.model_used ?? null,
    effort_used: latest?.effort_used ?? null,
    partial: true,
    reason,
    usage: { status: "unknown", kind: "tokens", partial: true, reason },
  };
}
function collectClaude(sessions) {
  const observations = sessions.map(collectClaudeSession);
  if (observations.length === 1) return observations[0];
  const latest = observations[observations.length - 1];
  if (observations.some((entry) => entry.status !== "observed" || entry.usage?.status !== "recorded-local")) {
    return incompleteRuntime("local-claude-transcript", observations, latest);
  }
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  let responses = 0;
  let subagentResponses = 0;
  let subagentTranscripts = 0;
  for (const entry of observations) {
    responses += entry.usage.responses;
    subagentResponses += entry.usage.subagent_responses ?? 0;
    subagentTranscripts += entry.usage.subagent_transcripts ?? 0;
    for (const key of Object.keys(totals)) totals[key] += entry.usage[key] ?? 0;
  }
  return {
    status: "observed",
    basis: "local-claude-transcript",
    session_id: latest.session_id,
    sessions: observations.map((entry) => entry.session_id),
    model_used: latest.model_used,
    effort_used: latest.effort_used,
    speed: latest.speed,
    service_tier: latest.service_tier,
    usage: {
      status: "recorded-local",
      kind: "tokens",
      responses,
      subagent_responses: subagentResponses,
      subagent_transcripts: subagentTranscripts,
      ...totals,
      incarnations: observations.length,
      completeness: "not-proven-for-aborted-turns",
    },
  };
}
function collectGrokSession(session) {
  const root = join(process.env.GROK_HOME || join(homedir(), ".grok"), "sessions");
  const matches = findNamed(root, "summary.json", 3).filter((path) => path.split("/").includes(session));
  if (matches.length !== 1) {
    const reason = `expected one Grok session summary, found ${matches.length}`;
    return {
      session_id: session,
      status: "unknown",
      basis: "local-grok-session-summary",
      reason,
      usage: { status: "unknown", kind: "tokens", reason },
    };
  }
  const summary = readJson(matches[0], "Grok session summary");
  const observation = {
    session_id: session,
    status: summary.current_model_id ? "observed" : "unknown",
    basis: "local-grok-session-summary",
    model_used: summary.current_model_id || null,
    effort_used: summary.reasoning_effort || null,
  };
  // Grok writes its authoritative per-session token totals to usage.json next
  // to summary.json. The totals are local observations, not a provider invoice;
  // a missing or incomplete file stays unknown instead of reporting zero.
  const usagePath = join(dirname(matches[0]), "usage.json");
  if (!existsSync(usagePath)) {
    observation.usage = { status: "unknown", kind: "tokens", reason: "no local Grok usage.json for this session" };
    return observation;
  }
  let usage;
  try {
    usage = JSON.parse(readFileSync(usagePath, "utf8"));
  } catch (error) {
    observation.usage = { status: "unknown", kind: "tokens", reason: `cannot read Grok usage.json: ${error.message}` };
    return observation;
  }
  const block = object(usage) && object(usage.session) ? usage.session : null;
  const count = (value) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null);
  const tokens = block ? {
    input_tokens: count(block.inputTokens),
    output_tokens: count(block.outputTokens),
    cache_read_tokens: count(block.cachedReadTokens),
    cache_creation_tokens: count(block.cacheCreationTokens),
    thinking_tokens: count(block.reasoningTokens),
  } : null;
  if (!tokens || Object.values(tokens).some((value) => value === null)) {
    observation.usage = { status: "unknown", kind: "tokens", reason: "Grok usage.json did not report a complete local token block" };
    return observation;
  }
  observation.usage = {
    status: "recorded-local",
    kind: "tokens",
    responses: count(block.modelCalls) ?? 0,
    ...tokens,
    completeness: "not-proven-for-aborted-turns",
  };
  if (object(block.modelUsage)) observation.models_used = Object.keys(block.modelUsage);
  return observation;
}
function collectGrok(sessions) {
  const observations = sessions.map(collectGrokSession);
  if (observations.length === 1) return observations[0];
  const latest = observations[observations.length - 1];
  if (observations.some((entry) => entry.status !== "observed" || entry.usage?.status !== "recorded-local")) {
    return incompleteRuntime("local-grok-session-summary", observations, latest);
  }
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  let responses = 0;
  for (const entry of observations) {
    responses += entry.usage.responses ?? 0;
    for (const key of Object.keys(totals)) totals[key] += entry.usage[key] ?? 0;
  }
  return {
    status: "observed",
    basis: "local-grok-session-summary",
    session_id: latest.session_id,
    sessions: observations.map((entry) => entry.session_id),
    model_used: latest.model_used,
    effort_used: latest.effort_used,
    usage: {
      status: "recorded-local",
      kind: "tokens",
      responses,
      ...totals,
      incarnations: observations.length,
      completeness: "not-proven-for-aborted-turns",
    },
  };
}
function resolvedPathsEqual(left, right) {
  if (!left || !right) return false;
  if (left === right) return true;
  let resolvedLeft = left;
  let resolvedRight = right;
  try { resolvedLeft = realpathSync(left); } catch { /* keep the recorded spelling */ }
  try { resolvedRight = realpathSync(right); } catch { /* keep the recorded spelling */ }
  return resolvedLeft === resolvedRight;
}
function taskStartedEpoch(fields) {
  const value = Number(fields.dispatch_started_epoch);
  return Number.isFinite(value) && value > 0 ? value : null;
}
// A session is task-attributable only when it began at or after this task's
// recorded dispatch start. Without the bound, a reused worktree path could
// pull a previous task's sessions into this task's totals. There is
// deliberately no pre-launch allowance: a session that started before this
// generation's dispatch belongs to whatever ran in the slot before it, and the
// launch timestamp is recorded before the worker is ever delivered.
function withinTaskWindow(startedEpoch, startMillis) {
  if (startedEpoch === null || !Number.isFinite(startMillis)) return true;
  return startMillis / 1000 >= startedEpoch;
}
// Reading a session header should not cost a full transcript read: a Pi session
// JSONL grows with every turn, and the sessions scan only needs line one.
function readFirstLine(path, maxBytes = 65536) {
  const descriptor = openSync(path, "r");
  try {
    const buffer = Buffer.alloc(maxBytes);
    const read = readSync(descriptor, buffer, 0, maxBytes, 0);
    const text = buffer.subarray(0, read).toString("utf8");
    const newline = text.indexOf("\n");
    return newline >= 0 ? text.slice(0, newline) : text;
  } finally {
    closeSync(descriptor);
  }
}
function usageUnknown(basis, reason) {
  return {
    status: "unknown",
    basis,
    session_id: null,
    sessions: [],
    model_used: null,
    effort_used: null,
    reason,
    usage: { status: "unknown", kind: "tokens", reason },
  };
}
function unusableObservation(basis, entries, latest, reason) {
  return {
    status: "unknown",
    basis,
    session_id: latest?.session_id ?? null,
    sessions: entries,
    model_used: latest?.model_used ?? null,
    effort_used: latest?.effort_used ?? null,
    partial: true,
    reason,
    usage: { status: "unknown", kind: "tokens", partial: true, reason },
  };
}
// The finish event's observation when the launch ledger itself cannot be
// scoped to one task lifetime. Nothing is collected from a scope that cannot
// be proven, and the unknown usage block carries the scoping reason.
function incompleteScopedRuntime(reason) {
  return {
    status: "unknown",
    basis: "local-launch-ledger",
    session_id: null,
    sessions: [],
    model_used: null,
    effort_used: null,
    partial: true,
    reason,
    usage: { status: "unknown", kind: "tokens", partial: true, reason },
  };
}
// Pi keeps one JSONL per session under the agent dir's sessions/ tree; the
// header records the session cwd, so sessions are attributed to this task's
// worktree by resolved path and then bounded by the launch window. Every
// assistant message carries the provider's own token split (input, output,
// cache read/write, reasoning), which is the richest local usage evidence Pi
// offers. An unreadable file, an id-less usage record, or a matched session
// with no measurable turn keeps the whole observation unknown rather than
// presenting a partial sum as complete.
function collectPiTaskUsage(worktree, startedEpoch) {
  const basis = "local-pi-sessions";
  if (!worktree) return usageUnknown(basis, "task metadata records no worktree, so Pi session evidence cannot be attributed");
  const root = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "sessions");
  if (!existsSync(root)) return usageUnknown(basis, `no Pi sessions directory at ${root}`);
  const files = [];
  try {
    for (const directory of readdirSync(root, { withFileTypes: true })) {
      if (!directory.isDirectory()) continue;
      const directoryPath = join(root, directory.name);
      for (const entry of readdirSync(directoryPath, { withFileTypes: true })) {
        if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
        const path = join(directoryPath, entry.name);
        let header;
        try {
          header = JSON.parse(readFirstLine(path));
        } catch {
          continue;
        }
        if (!object(header) || header.type !== "session" || !header.cwd) continue;
        if (!resolvedPathsEqual(header.cwd, worktree)) continue;
        if (!withinTaskWindow(startedEpoch, header.timestamp ? Date.parse(header.timestamp) : NaN)) continue;
        files.push({ path, session_id: header.id ?? null, timestamp: header.timestamp ?? null });
      }
    }
  } catch (error) {
    return usageUnknown(basis, `cannot scan Pi sessions at ${root}: ${error.message}`);
  }
  if (files.length === 0) return usageUnknown(basis, "no Pi session record for this task's worktree was found");
  // Chronological order matters: the observation's model/effort must come from
  // the latest incarnation, not whichever directory readdir happened to visit.
  files.sort((left, right) => {
    const leftTime = left.timestamp ? Date.parse(left.timestamp) : NaN;
    const rightTime = right.timestamp ? Date.parse(right.timestamp) : NaN;
    if (Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime !== rightTime) return leftTime - rightTime;
    return left.path.localeCompare(right.path);
  });
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  const counted = new Set();
  const emptySessions = [];
  const sessions = [];
  let responses = 0;
  let unidentified = false;
  let unreadable = null;
  let model = null;
  let effort = null;
  for (const file of files) {
    const label = file.session_id ?? file.path;
    sessions.push(label);
    let lines;
    try {
      lines = readFileSync(file.path, "utf8").split("\n");
    } catch (error) {
      unreadable = `${file.path}: ${error.message}`;
      continue;
    }
    let sessionResponses = 0;
    for (const line of lines) {
      if (!line) continue;
      let item;
      try { item = JSON.parse(line); } catch { continue; }
      if (item.type === "thinking_level_change") {
        if (typeof item.thinkingLevel === "string" && item.thinkingLevel) effort = item.thinkingLevel;
        continue;
      }
      if (item.type !== "message" || !object(item.message) || item.message.role !== "assistant") continue;
      const usage = item.message.usage;
      if (!object(usage)) continue;
      const recordID = typeof item.id === "string" && item.id ? item.id : null;
      if (!recordID) {
        unidentified = true;
        continue;
      }
      if (counted.has(recordID)) continue;
      counted.add(recordID);
      sessionResponses += 1;
      responses += 1;
      totals.input_tokens += Number(usage.input) || 0;
      totals.cache_read_tokens += Number(usage.cacheRead) || 0;
      totals.cache_creation_tokens += Number(usage.cacheWrite) || 0;
      totals.output_tokens += Number(usage.output) || 0;
      totals.thinking_tokens += Number(usage.reasoning) || 0;
      if (item.message.provider && item.message.model) model = `${item.message.provider}/${item.message.model}`;
    }
    if (sessionResponses === 0) emptySessions.push(label);
  }
  const latest = { session_id: files[files.length - 1]?.session_id ?? null, model_used: model, effort_used: effort };
  if (unreadable || unidentified || emptySessions.length > 0) {
    const reason = unreadable
      ?? (emptySessions.length > 0
        ? `Pi session(s) without measurable usage: ${emptySessions.join(",")}`
        : "a Pi session had a usage record without a stable message id");
    return unusableObservation(basis, sessions.map((session_id) => ({ session_id, status: "unknown" })), latest, reason);
  }
  return {
    status: "observed",
    basis,
    session_id: latest.session_id,
    sessions,
    model_used: model,
    effort_used: effort,
    usage: {
      status: "recorded-local",
      kind: "tokens",
      responses,
      ...totals,
      sessions: files.length,
      completeness: "not-proven-for-aborted-turns",
    },
  };
}
// OpenCode 1.18.x writes its session/message store to sqlite; older versions
// keep the JSON storage tree. Both are read directly, never through the CLI:
// sessions are attributed by their recorded directory and bounded by the
// launch window, and the same token split is summed across the parent and its
// child (subagent) sessions, whose rows are separate and therefore not double
// counted.
function opencodeDataDir() {
  const base = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(base, "opencode");
}
function opencodeDatabasePath() {
  const dataDir = opencodeDataDir();
  const configured = process.env.OPENCODE_DB;
  if (!configured) return join(dataDir, "opencode.db");
  if (configured === ":memory:") return null;
  return configured.startsWith("/") ? configured : join(dataDir, configured);
}
function collectOpencodeSqlite(dbPath, worktree, startedEpoch) {
  const basis = "local-opencode-sessions";
  let DatabaseSync;
  try {
    ({ DatabaseSync } = createRequire(import.meta.url)("node:sqlite"));
  } catch (error) {
    return usageUnknown(basis, `this node runtime cannot read OpenCode's sqlite store: ${error.message}`);
  }
  if (typeof DatabaseSync !== "function") return usageUnknown(basis, "this node runtime exposes no node:sqlite DatabaseSync");
  let database;
  try {
    database = new DatabaseSync(dbPath, { readOnly: true });
  } catch (error) {
    return usageUnknown(basis, `cannot open OpenCode store ${dbPath}: ${error.message}`);
  }
  try {
    let rows;
    let messageCounts;
    try {
      rows = database.prepare("select id, directory, time_created, model, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write from session").all();
      messageCounts = database.prepare("select session_id, count(*) as count from message where json_extract(data, '$.role') = 'assistant' group by session_id").all();
    } catch (error) {
      return usageUnknown(basis, `cannot read OpenCode sessions from ${dbPath}: ${error.message}`);
    }
    const matched = rows.filter((row) => resolvedPathsEqual(row.directory, worktree) && withinTaskWindow(startedEpoch, Number(row.time_created)));
    if (matched.length === 0) return usageUnknown(basis, "no OpenCode session for this task's worktree was found");
    matched.sort((left, right) => Number(left.time_created) - Number(right.time_created));
    const counts = new Map(messageCounts.map((row) => [row.session_id, Number(row.count) || 0]));
    let responses = 0;
    const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
    for (const row of matched) {
      responses += counts.get(row.id) ?? 0;
      totals.input_tokens += Number(row.tokens_input) || 0;
      totals.cache_read_tokens += Number(row.tokens_cache_read) || 0;
      totals.cache_creation_tokens += Number(row.tokens_cache_write) || 0;
      totals.output_tokens += Number(row.tokens_output) || 0;
      totals.thinking_tokens += Number(row.tokens_reasoning) || 0;
    }
    const latest = matched[matched.length - 1];
    let modelUsed = null;
    let effortUsed = null;
    try {
      const model = JSON.parse(latest.model);
      if (model && model.providerID && model.id) modelUsed = `${model.providerID}/${model.id}`;
      if (typeof model?.variant === "string" && model.variant && model.variant !== "default") effortUsed = model.variant;
    } catch { /* an unreadable model record stays unknown */ }
    return {
      status: "observed",
      basis,
      session_id: latest.id,
      sessions: matched.map((row) => row.id),
      model_used: modelUsed,
      effort_used: effortUsed,
      usage: {
        status: "recorded-local",
        kind: "tokens",
        responses,
        ...totals,
        sessions: matched.length,
        completeness: "not-proven-for-aborted-turns",
      },
    };
  } finally {
    try { database.close(); } catch { /* already closed */ }
  }
}
function collectOpencodeJsonStorage(storage, worktree, startedEpoch) {
  const basis = "local-opencode-storage";
  const sessionRoot = join(storage, "session");
  const messageRoot = join(storage, "message");
  if (!existsSync(sessionRoot)) return usageUnknown(basis, `no OpenCode session records at ${sessionRoot}`);
  const matched = [];
  try {
    for (const project of readdirSync(sessionRoot, { withFileTypes: true })) {
      if (!project.isDirectory()) continue;
      for (const entry of readdirSync(join(sessionRoot, project.name), { withFileTypes: true })) {
        if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
        let record;
        try {
          record = JSON.parse(readFileSync(join(sessionRoot, project.name, entry.name), "utf8"));
        } catch {
          continue;
        }
        if (!object(record) || !record.directory) continue;
        if (!resolvedPathsEqual(record.directory, worktree)) continue;
        if (!withinTaskWindow(startedEpoch, Number(record.time?.created))) continue;
        matched.push(record);
      }
    }
  } catch (error) {
    return usageUnknown(basis, `cannot scan OpenCode session storage: ${error.message}`);
  }
  if (matched.length === 0) return usageUnknown(basis, "no OpenCode session for this task's worktree was found");
  matched.sort((left, right) => Number(left.time?.created ?? 0) - Number(right.time?.created ?? 0));
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  let responses = 0;
  let unreadable = null;
  for (const record of matched) {
    const directory = join(messageRoot, record.id);
    if (!existsSync(directory)) {
      unreadable = `no OpenCode message records for session ${record.id}`;
      continue;
    }
    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      unreadable = `${directory}: ${error.message}`;
      continue;
    }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
      let message;
      try {
        message = JSON.parse(readFileSync(join(directory, entry.name), "utf8"));
      } catch (error) {
        unreadable = `${join(directory, entry.name)}: ${error.message}`;
        continue;
      }
      if (!object(message) || message.role !== "assistant" || !object(message.tokens)) continue;
      responses += 1;
      totals.input_tokens += Number(message.tokens.input) || 0;
      totals.cache_read_tokens += Number(message.tokens.cache?.read) || 0;
      totals.cache_creation_tokens += Number(message.tokens.cache?.write) || 0;
      totals.output_tokens += Number(message.tokens.output) || 0;
      totals.thinking_tokens += Number(message.tokens.reasoning) || 0;
    }
  }
  const latest = matched[matched.length - 1];
  if (unreadable) {
    return unusableObservation(basis, matched.map((record) => ({ session_id: record.id, status: "unknown" })), { session_id: latest.id }, unreadable);
  }
  const modelUsed = latest.model?.providerID && latest.model?.id ? `${latest.model.providerID}/${latest.model.id}` : null;
  const effortUsed = typeof latest.model?.variant === "string" && latest.model.variant && latest.model.variant !== "default" ? latest.model.variant : null;
  return {
    status: "observed",
    basis,
    session_id: latest.id,
    sessions: matched.map((record) => record.id),
    model_used: modelUsed,
    effort_used: effortUsed,
    usage: {
      status: "recorded-local",
      kind: "tokens",
      responses,
      ...totals,
      sessions: matched.length,
      completeness: "not-proven-for-aborted-turns",
    },
  };
}
function collectOpencodeTaskUsage(worktree, startedEpoch) {
  const dbPath = opencodeDatabasePath();
  if (dbPath && existsSync(dbPath)) return collectOpencodeSqlite(dbPath, worktree, startedEpoch);
  const storage = join(opencodeDataDir(), "storage");
  if (existsSync(storage)) return collectOpencodeJsonStorage(storage, worktree, startedEpoch);
  return usageUnknown("local-opencode-sessions", `no OpenCode session store at ${opencodeDataDir()}`);
}
function usageHarnessFamily(harness) {
  // pi and pi-signed are the same runtime and the same local session store, so a
  // switch between those identities is not a cross-harness move for usage.
  return harness === "pi-signed" ? "pi" : harness;
}
// The live extension/plugin snapshot and the local-store collector observe the
// same incarnation from different angles, so neither may silently erase the
// other's limits. The collector owns completeness, usage, and the effort it
// measured from the session store; the live record keeps the values only it can
// know (fast request state, observation time) and fills a field the collector
// could not bind. A model or effort disagreement is recorded rather than
// hidden, while the collector's measured value stays the reported one.
function mergeRuntimeObservation(runtime, collected) {
  const merged = {
    ...runtime,
    ...collected,
    usage_basis: collected.basis ?? runtime.usage_basis ?? null,
    fast_requested: runtime.fast_requested ?? null,
    fast_server_verified: runtime.fast_server_verified ?? false,
  };
  merged.session_id = collected.session_id ?? runtime.session_id ?? null;
  if (merged.usage === undefined) merged.usage = runtime.usage;
  const conflicts = [];
  for (const field of ["model_used", "effort_used"]) {
    const live = runtime[field] ?? null;
    const observed = collected[field] ?? null;
    if (live && observed && live !== observed) conflicts.push({ field, live, observed });
    // The collector's measured value is authoritative when it has one; the
    // live snapshot fills only what the collector could not bind.
    merged[field] = observed ?? live;
  }
  if (conflicts.length > 0) merged.conflicts = conflicts;
  return merged;
}
function collectRuntime(choicePath, fields, recordedSessions) {
  const runtimePath = choicePath.replace(/\.dispatch-choice\.json$/, ".dispatch-runtime.json");
  const runtime = existsSync(runtimePath) ? readJson(runtimePath, "dispatch runtime observation") : null;
  const family = usageHarnessFamily(fields.harness);
  // A relaunch may change harness, and a local transcript or session summary
  // from one harness is not a compatible unit with another's. Dropping the
  // foreign incarnations would present one harness's total as the task's
  // complete usage, so nothing is filtered: the observation stays unknown with
  // the reason, and only a single-harness incarnation set is aggregated.
  // Sessionless incarnations count here too, or a Pi/OpenCode tool switch could
  // hide the prior harness's usage from this guard.
  const foreignHarnesses = [...new Set(recordedSessions
    .filter((entry) => entry.harness !== null && usageHarnessFamily(entry.harness) !== family)
    .map((entry) => entry.harness))];
  if (foreignHarnesses.length > 0) {
    const reason = `recorded launch incarnation(s) ran on ${foreignHarnesses.join(", ")} while this launch runs on ${fields.harness}; complete cross-harness usage aggregation is not proven`;
    return {
      status: "unknown",
      basis: "local-launch-ledger",
      session_id: null,
      sessions: recordedSessions.map((entry) => ({ session_id: entry.session, harness: entry.harness })),
      model_used: null,
      effort_used: null,
      partial: true,
      reason,
      usage: { status: "unknown", kind: "tokens", partial: true, reason },
    };
  }
  const startedEpoch = taskStartedEpoch(fields);
  const worktree = fields.worktree || null;
  let collected = null;
  if (family === "claude" || family === "grok") {
    const ordered = [];
    for (const entry of recordedSessions) {
      if (entry.session && !ordered.includes(entry.session)) ordered.push(entry.session);
    }
    if (fields.dispatch_runtime_session && !ordered.includes(fields.dispatch_runtime_session)) {
      ordered.push(fields.dispatch_runtime_session);
    }
    const sessionless = recordedSessions.filter((entry) => entry.session === null).length;
    if (ordered.length > 0) {
      const observed = family === "claude" ? collectClaude(ordered) : collectGrok(ordered);
      collected = sessionless > 0
        ? unusableObservation(observed.basis ?? `local-${family}-transcript`, observed.sessions?.map((session_id) => ({ session_id, status: "unknown" })) ?? [], observed, `${sessionless} launch incarnation(s) recorded no runtime session, so their usage cannot be bound`)
        : observed;
    } else if (sessionless > 0) {
      collected = usageUnknown(`local-${family}-transcript`, `${sessionless} launch incarnation(s) recorded no runtime session, so their usage cannot be bound`);
    }
  } else if (family === "pi") {
    if (recordedSessions.length > 0) collected = collectPiTaskUsage(worktree, startedEpoch);
  } else if (family === "opencode") {
    if (recordedSessions.length > 0) collected = collectOpencodeTaskUsage(worktree, startedEpoch);
  }
  if (runtime) {
    if (!collected) {
      // The live observation exists but no local collector could attribute
      // usage to this incarnation; report that as an explicit unknown usage
      // block instead of returning a record with no usage section at all.
      return mergeRuntimeObservation(runtime, usageUnknown("local-launch-ledger", "no local session collector could attribute usage to this task generation"));
    }
    return mergeRuntimeObservation(runtime, collected);
  }
  if (!collected) return usageUnknown("local-launch-ledger", "no launch incarnation was recorded for this task generation, so no local usage can be attributed");
  return collected;
}
// The defect origins a quality observation may attribute a recorded defect to.
// The set is deliberately exhaustive and conservative: a defect that cannot be
// attributed from evidence stays unknown rather than defaulting to the worker
// that happened to be running.
const DEFECT_ORIGINS = new Set(["original-implementation-worker", "validation-correction", "pre-existing-code", "unknown"]);
// Only a quality observation that records an actual defect is attribution
// evidence. A passed result or a generic unknown quality says nothing about a
// defect, so it can neither add evidence nor force an unknown-origin verdict;
// a defect that cannot be attributed stays unknown on its own defect record,
// never defaulted to the worker that happened to be running.
const DEFECT_QUALITY_STATUSES = new Set(["bug-found", "bug-escaped"]);
// The finish event's defect attribution, scoped to the task generation.
// Observations are scoped by their recorded generation token: an observation
// from another generation, or one carrying no token at all (legacy evidence
// written before observation events were stamped), is preserved as unscoped
// evidence but can never be inherited by this generation, so a reused task id
// does not absorb an earlier task lifetime's defects. Within the generation,
// only observations that actually record a defect are evidence, and any such
// defect whose origin is absent or unknown blocks a specific attribution
// whether or not the unknown was explicit: one defect without a proven cause
// makes the task-level claim unprovable. Disagreeing known origins stay
// unknown rather than being resolved by the most common one.
function defectAttribution(ledger, taskID, generation) {
  const evidence = [];
  const unscoped = [];
  if (existsSync(ledger)) {
    for (const line of readFileSync(ledger, "utf8").split("\n")) {
      if (!line) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        fail(`dispatch metrics ledger ${ledger} contains malformed JSON`);
      }
      if (event.event !== "observation" || event.task_id !== taskID || !object(event.quality)) continue;
      if (!DEFECT_QUALITY_STATUSES.has(event.quality.status)) continue;
      const recorded = event.quality.defect_origin;
      const known = typeof recorded === "string" && DEFECT_ORIGINS.has(recorded);
      const entry = {
        origin: known ? recorded : "unknown",
        // The raw value is kept so an absent or unrecognized origin is
        // distinguishable from an explicitly recorded "unknown".
        origin_recorded: known ? recorded : null,
        explicit: event.quality.defect_origin_explicit === true,
        status: event.quality.status ?? null,
        basis: event.quality.defect_origin_basis ?? event.quality.basis ?? null,
        event_id: event.event_id ?? null,
        generation: typeof event.generation === "string" && event.generation ? event.generation : null,
      };
      if (generation && entry.generation === generation) evidence.push(entry);
      else unscoped.push(entry);
    }
  }
  const attribution = (origin, basis) => ({ origin, basis, generation: generation ?? null, evidence, unscoped_evidence: unscoped });
  if (!generation) {
    return attribution("unknown", "the finish record carries no generation token, so recorded defects cannot be scoped to this task lifetime");
  }
  const unknownOrigin = evidence.filter((entry) => entry.origin === "unknown");
  if (unknownOrigin.length > 0) {
    return attribution("unknown", `at least one recorded defect had no proven origin (${unknownOrigin.map((entry) => entry.event_id ?? "unknown").join(", ")})`);
  }
  if (evidence.length === 0) {
    return attribution("unknown", unscoped.length > 0
      ? `no defect origin was observed for this task generation; ${unscoped.length} defect observation(s) from another generation or without a generation token were not inherited`
      : "no defect origin was observed for this task generation");
  }
  const origins = [...new Set(evidence.map((entry) => entry.origin))];
  if (origins.length !== 1) {
    return attribution("unknown", `recorded defect origins disagree (${origins.join(", ")})`);
  }
  return attribution(origins[0], `recorded by defect-origin observation(s) ${evidence.map((entry) => entry.event_id).join(", ")}`);
}
function launchSettings(record, fields) {
  const requested = record.selected;
  const requestedFast = Object.hasOwn(requested, "fast") ? requested.fast : null;
  return {
    requested: {
      harness: requested.harness,
      model: requested.model,
      effort: requested.effort,
      fast: requestedFast,
    },
    effective: {
      harness: fields.harness,
      model: fields.model === "default" ? null : fields.model,
      effort: fields.effort === "default" ? null : fields.effort,
      // A requested fast value is never claimed as the effective wire value,
      // because the launch plan proves only which handler registers last, not
      // what the provider did with the payload; server_verified stays false
      // until response evidence exists.
      fast: null,
      fast_basis: requestedFast === null ? null : "requested-not-wire-verified",
      // The recorded basis is the launcher's own evidence of what it proved.
      // A missing field is unknown, never an assumption that the axes were
      // validated.
      basis: fields.dispatch_validation_basis || "unknown",
      server_verified: false,
      tool_version: fields.dispatch_tool_version || null,
    },
  };
}

const [command, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
if (command === "launch" || command === "finish") {
  for (const key of ["meta", "choice", "ledger"]) if (!args[key]) fail(`${command} needs --${key}`);
  const fields = meta(args.meta);
  const record = readJson(args.choice, "dispatch choice");
  const spawnGen = fields.spawn_gen || "unknown";
  const eventID = `${command}:${record.task_id}:${spawnGen}`;
  const settings = launchSettings(record, fields);
  if (command === "launch") {
    append(args.ledger, {
      schema_version: 1,
      event: "launch-prepared",
      event_id: eventID,
      recorded_at: nowISO(),
      task_id: record.task_id,
      spawn_gen: spawnGen,
      kind: fields.kind || null,
      preset: record.preset,
      selection: {
        mode: record.mode,
        algorithm: record.algorithm,
        config_sha256: record.config_sha256,
        sample_sha256: record.sample_sha256,
        bucket: record.bucket,
        total_weight_units: record.total_weight_units,
        candidates: record.candidates,
        selected_candidate: record.selected.id,
      },
      ...settings,
      started_at: fields.dispatch_started_at || null,
      // The generation token scopes this launch to one task lifetime; a
      // relaunch preserves it and a fresh spawn mints a new one, so a reused
      // task id cannot absorb a previous task's incarnations. A record without
      // one stays null and the finish event reports incomplete evidence rather
      // than inferring a generation from another field.
      generation: fields.dispatch_generation || null,
      // The launch kind and whether this launch reused an already-sampled
      // durable choice are recorded so the finish event can total launches,
      // relaunches, and retries without inferring them from session or
      // subagent counts. A record that lacks either stays null and makes the
      // totals incomplete evidence.
      launch_kind: fields.dispatch_launch_kind || null,
      selection_reused: fields.dispatch_choice_reused === "1" ? true : fields.dispatch_choice_reused === "0" ? false : null,
      runtime_session: fields.dispatch_runtime_session || null,
    });
  } else {
    if (!args.outcome) fail("finish needs --outcome");
    if (args["discard-authorized"] !== undefined && !["true", "false"].includes(args["discard-authorized"])) {
      fail("finish --discard-authorized must be true or false");
    }
    const discardAuthorized = args["discard-authorized"] === "true" ? true : args["discard-authorized"] === "false" ? false : null;
    const started = Number(fields.dispatch_started_epoch);
    const finished = Math.floor(Date.now() / 1000);
    // No compatibility fallback: the generation token is the only scoping
    // evidence for this task lifetime, and a record without one is reported
    // as incomplete rather than inferred from its launch origin.
    const generation = typeof fields.dispatch_generation === "string" && fields.dispatch_generation ? fields.dispatch_generation : null;
    const launched = readRecordedLaunches(args.ledger, record.task_id, generation);
    const runtimeObserved = launched.status === "complete"
      ? collectRuntime(args.choice, fields, recordedSessions(launched.launches))
      : incompleteScopedRuntime(launched.reason);
    append(args.ledger, {
      schema_version: 1,
      event: "finish",
      event_id: eventID,
      recorded_at: nowISO(),
      task_id: record.task_id,
      spawn_gen: spawnGen,
      preset: record.preset,
      ...settings,
      finished_at: nowISO(),
      duration_seconds: Number.isFinite(started) && started > 0 && finished >= started ? finished - started : null,
      delivery_outcome: args.outcome,
      // Whether this cleanup discarded the task's local copy under explicit
      // discard authorization (--force). It is a separate axis from the
      // delivery outcome: a landed delivery whose local copy was discarded
      // under authorization is not a discarded delivery, and the two fields
      // together distinguish that case from genuinely discarded, unlanded work
      // and from a delivery that could not be proved either way.
      cleanup: { discard_authorized: discardAuthorized },
      // Explicit incarnation totals for this task generation, scoped by the
      // same generation token as the session aggregation above and independent
      // of any session or subagent count the runtime observation happens to
      // carry. A reader must not have to infer how many times the worker was
      // launched, relaunched, or retried, and a record missing either scoping
      // field reports incomplete totals instead of a guessed count.
      generation,
      totals: launchTotals(launched.launches, launched.status === "complete" ? null : launched.reason),
      runtime_observed: runtimeObserved,
      usage: runtimeObserved?.usage || { status: "unknown", reason: "no task-attributable provider usage observation was supplied" },
      // Delivery success and a bare quality status are never evidence that no
      // bug was found or escaped. A recorded defect is attributed to a specific
      // party only when exactly one known origin was recorded for this task
      // generation and no recorded defect in it lacks a proven origin.
      quality: { status: "unknown", reason: "delivery success is not evidence that no bug was found or escaped", defect_attribution: defectAttribution(args.ledger, record.task_id, generation) },
      cost: {
        kind: "subscription-quota-share",
        status: "unknown",
        weekly_usd: null,
        formula: "quota_fraction * monthly_price_usd / 4",
        billing_basis: "estimate-not-invoice",
        reason: "task quota fraction and monthly subscription price were not both observed",
      },
    });
  }
  process.exit(0);
}
if (command === "observe") {
  for (const key of ["ledger", "task"]) if (!args[key]) fail(`observe needs --${key}`);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(args.task)) fail("task id is invalid");
  if (!existsSync(args.ledger) || !readFileSync(args.ledger, "utf8").includes(`\"task_id\":\"${args.task}\"`)) {
    fail(`dispatch metrics ledger has no profiled launch for task '${args.task}'`);
  }
  const observationScope = observationGeneration(args.ledger, args.task, args.generation);
  const event = {
    schema_version: 1,
    event: "observation",
    event_id: `observation:${args.task}:${Date.now()}:${process.pid}`,
    recorded_at: nowISO(),
    task_id: args.task,
    // Defect and other later observations are stamped with the task generation
    // they describe, so a finish event for a reused task id can scope them to
    // its own lifetime instead of inheriting an earlier task's evidence.
    generation: observationScope.generation,
    generation_basis: observationScope.basis,
  };
  if (args["fast-server-verified"] && !["on", "off", "unknown"].includes(args["fast-server-verified"])) {
    fail("--fast-server-verified must be on, off, or unknown");
  }
  if (args["model-used"]) {
    event.runtime = {
      model_used: args["model-used"],
      effort_used: args["effort-used"] || null,
      fast_server_verified: args["fast-server-verified"] === "on" ? true : args["fast-server-verified"] === "off" ? false : null,
      basis: args.basis || "operator-observation",
    };
  }
  if (args.quality) {
    if (!["passed", "bug-found", "bug-escaped", "unknown"].includes(args.quality)) {
      fail("--quality must be passed, bug-found, bug-escaped, or unknown");
    }
    const defectOriginExplicit = Object.hasOwn(args, "defect-origin");
    if (defectOriginExplicit) {
      if (!["bug-found", "bug-escaped"].includes(args.quality)) {
        fail("--defect-origin applies only to a bug-found or bug-escaped quality observation");
      }
      if (!DEFECT_ORIGINS.has(args["defect-origin"])) {
        fail("--defect-origin must be original-implementation-worker, validation-correction, pre-existing-code, or unknown");
      }
    }
    // A bare quality status never implies a defect origin: without an explicit
    // --defect-origin the attribution is unknown and says why.
    event.quality = {
      status: args.quality,
      basis: args.basis || "operator-observation",
      defect_origin: defectOriginExplicit ? args["defect-origin"] : "unknown",
      defect_origin_explicit: defectOriginExplicit,
      defect_origin_basis: defectOriginExplicit
        ? args.basis || "operator-observation"
        : "no defect origin evidence was supplied with this observation",
    };
  }
  if (args.usage) {
    let usage;
    try { usage = JSON.parse(args.usage); } catch { fail("--usage must be a JSON object"); }
    if (!object(usage) || typeof usage.kind !== "string") fail("--usage must be a JSON object with a kind string");
    event.usage = { ...usage, billing_basis: "local-or-provider-observation-not-invoice" };
  }
  const suppliedCost = args["quota-fraction"] || args["monthly-price-usd"] || args["reset-days"];
  if (suppliedCost) {
    if (!args["quota-fraction"] || !args["monthly-price-usd"] || !args["reset-days"]) {
      event.cost = {
        kind: "subscription-quota-share",
        status: "unknown",
        weekly_usd: null,
        formula: "quota_fraction * monthly_price_usd / 4",
        billing_basis: "estimate-not-invoice",
        reason: "quota fraction, monthly price, and reset period are all required",
      };
    } else {
      const fraction = numeric(args["quota-fraction"], "--quota-fraction", 0, 1);
      const monthly = numeric(args["monthly-price-usd"], "--monthly-price-usd", 0, 1_000_000);
      const resetDays = numeric(args["reset-days"], "--reset-days", 0.000001, 10000);
      event.cost = {
        kind: "subscription-quota-share",
        status: resetDays === 7 ? "estimated" : "unknown",
        quota_fraction: fraction,
        monthly_price_usd: monthly,
        reset_days: resetDays,
        weekly_usd: resetDays === 7 ? fraction * monthly / 4 : null,
        formula: "quota_fraction * monthly_price_usd / 4",
        billing_basis: "estimate-not-invoice",
        reason: resetDays === 7 ? null : "reset period is not compatible with the weekly quota-share formula",
      };
    }
  }
  if (!event.runtime && !event.quality && !event.usage && !event.cost) fail("observe needs a runtime, quality, usage, or cost observation");
  append(args.ledger, event);
  process.exit(0);
}
fail("unknown dispatch metrics command");
