#!/usr/bin/env node
// Internal structured-ledger owner for bin/fm-dispatch-metrics.sh.

import { closeSync, existsSync, fsyncSync, lstatSync, openSync, readFileSync, readdirSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

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
// Every runtime session a preset launch recorded for this task, oldest first.
// A relaunch re-mints the session id (Claude and Grok refuse a reused id), so
// the finish event must aggregate every incarnation the ledger recorded rather
// than counting only the last one.
function readRecordedSessions(ledger, taskID) {
  if (!existsSync(ledger)) return [];
  const sessions = [];
  for (const line of readFileSync(ledger, "utf8").split("\n")) {
    if (!line) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      fail(`dispatch metrics ledger ${ledger} contains malformed JSON`);
    }
    if (event.event !== "launch-prepared" || event.task_id !== taskID) continue;
    if (typeof event.runtime_session !== "string" || !event.runtime_session) continue;
    if (sessions.some((entry) => entry.session === event.runtime_session)) continue;
    sessions.push({ session: event.runtime_session, harness: event.effective?.harness ?? null });
  }
  return sessions;
}
function collectClaudeSession(session) {
  const root = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "projects");
  const matches = findNamed(root, `${session}.jsonl`, 3);
  if (matches.length !== 1) return {
    session_id: session,
    status: "unknown",
    reason: `expected one Claude transcript, found ${matches.length}`,
  };
  let model = null;
  let effort = null;
  let speed = null;
  let serviceTier = null;
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  const counted = new Set();
  let unidentified = false;
  for (const line of readFileSync(matches[0], "utf8").split("\n")) {
    if (!line) continue;
    let item;
    try { item = JSON.parse(line); } catch { continue; }
    if (item.type !== "assistant" || !object(item.message)) continue;
    model = item.message.model || model;
    effort = item.effort || effort;
    const usage = item.message.usage;
    if (!object(usage)) continue;
    const messageID = item.message.id;
    if (typeof messageID !== "string" || !messageID) {
      unidentified = true;
      continue;
    }
    if (counted.has(messageID)) continue;
    counted.add(messageID);
    totals.input_tokens += Number(usage.input_tokens) || 0;
    totals.cache_read_tokens += Number(usage.cache_read_input_tokens) || 0;
    totals.cache_creation_tokens += Number(usage.cache_creation_input_tokens) || 0;
    totals.output_tokens += Number(usage.output_tokens) || 0;
    totals.thinking_tokens += Number(usage.output_tokens_details?.thinking_tokens) || 0;
    speed = usage.speed || speed;
    serviceTier = usage.service_tier || serviceTier;
  }
  return {
    session_id: session,
    status: model ? "observed" : "unknown",
    basis: "local-claude-transcript",
    model_used: model,
    effort_used: effort,
    speed,
    service_tier: serviceTier,
    usage: !model ? null : unidentified
      ? { status: "unknown", kind: "tokens", reason: "transcript usage without a stable assistant message id cannot be deduplicated" }
      : { status: "recorded-local", kind: "tokens", responses: counted.size, ...totals, completeness: "not-proven-for-aborted-turns" },
  };
}
function incompleteRuntime(basis, observations, latest) {
  const missing = observations.filter((entry) => entry.status !== "observed" || entry.usage?.status !== "recorded-local");
  return {
    status: "unknown",
    basis,
    session_id: latest?.session_id ?? null,
    sessions: observations.map((entry) => ({ session_id: entry.session_id, status: entry.usage?.status ?? entry.status })),
    model_used: latest?.model_used ?? null,
    effort_used: latest?.effort_used ?? null,
    reason: `relaunch incarnation(s) without a complete local record: ${missing.map((entry) => entry.session_id).join(",")}`,
  };
}
function collectClaude(sessions) {
  const observations = sessions.map(collectClaudeSession);
  if (observations.length === 1) return observations[0];
  const latest = observations[observations.length - 1];
  if (observations.some((entry) => entry.status !== "observed" || entry.usage?.status !== "recorded-local")) {
    const incomplete = incompleteRuntime("local-claude-transcript", observations, latest);
    return {
      ...incomplete,
      usage: { status: "unknown", kind: "tokens", reason: incomplete.reason },
    };
  }
  const totals = { input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, output_tokens: 0, thinking_tokens: 0 };
  let responses = 0;
  for (const entry of observations) {
    responses += entry.usage.responses;
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
      ...totals,
      incarnations: observations.length,
      completeness: "not-proven-for-aborted-turns",
    },
  };
}
function collectGrokSession(session) {
  const root = join(process.env.GROK_HOME || join(homedir(), ".grok"), "sessions");
  const matches = findNamed(root, "summary.json", 3).filter((path) => path.split("/").includes(session));
  if (matches.length !== 1) return {
    session_id: session,
    status: "unknown",
    reason: `expected one Grok session summary, found ${matches.length}`,
  };
  const summary = readJson(matches[0], "Grok session summary");
  return {
    session_id: session,
    status: summary.current_model_id ? "observed" : "unknown",
    basis: "local-grok-session-summary",
    model_used: summary.current_model_id || null,
    effort_used: summary.reasoning_effort || null,
  };
}
function collectGrok(sessions) {
  const observations = sessions.map(collectGrokSession);
  if (observations.length === 1) return observations[0];
  const latest = observations[observations.length - 1];
  if (observations.some((entry) => entry.status !== "observed")) {
    return incompleteRuntime("local-grok-session-summary", observations, latest);
  }
  return {
    status: "observed",
    basis: "local-grok-session-summary",
    session_id: latest.session_id,
    sessions: observations.map((entry) => entry.session_id),
    model_used: latest.model_used,
    effort_used: latest.effort_used,
  };
}
function collectRuntime(choicePath, fields, recordedSessions) {
  const runtimePath = choicePath.replace(/\.dispatch-choice\.json$/, ".dispatch-runtime.json");
  if (existsSync(runtimePath)) return readJson(runtimePath, "dispatch runtime observation");
  const ordered = [];
  for (const entry of recordedSessions) {
    if (entry.harness !== null && entry.harness !== fields.harness) continue;
    if (!ordered.includes(entry.session)) ordered.push(entry.session);
  }
  if (fields.dispatch_runtime_session && !ordered.includes(fields.dispatch_runtime_session)) {
    ordered.push(fields.dispatch_runtime_session);
  }
  if (ordered.length === 0) return null;
  if (fields.harness === "claude") return collectClaude(ordered);
  if (fields.harness === "grok") return collectGrok(ordered);
  return null;
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
      basis: "validated-launch-control",
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
      runtime_session: fields.dispatch_runtime_session || null,
    });
  } else {
    if (!args.outcome) fail("finish needs --outcome");
    const started = Number(fields.dispatch_started_epoch);
    const finished = Math.floor(Date.now() / 1000);
    const runtimeObserved = collectRuntime(args.choice, fields, readRecordedSessions(args.ledger, record.task_id));
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
      runtime_observed: runtimeObserved,
      usage: runtimeObserved?.usage || { status: "unknown", reason: "no task-attributable provider usage observation was supplied" },
      quality: { status: "unknown", reason: "delivery success is not evidence that no bug was found or escaped" },
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
  const event = {
    schema_version: 1,
    event: "observation",
    event_id: `observation:${args.task}:${Date.now()}:${process.pid}`,
    recorded_at: nowISO(),
    task_id: args.task,
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
    event.quality = { status: args.quality, basis: args.basis || "operator-observation" };
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
