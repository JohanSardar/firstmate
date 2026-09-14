#!/usr/bin/env node
// Internal JSON owner for bin/fm-task-model-preset.sh.
// Validates opt-in task/model presets and makes a deterministic, durable choice.

import { createHash } from "node:crypto";
import { closeSync, existsSync, fsyncSync, linkSync, lstatSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const ALLOWED_HARNESSES = new Set(["pi", "pi-signed", "grok", "claude", "opencode"]);
const ALLOWED_EFFORTS = {
  pi: new Set(["low", "medium", "high", "xhigh", "max"]),
  "pi-signed": new Set(["low", "medium", "high", "xhigh", "max"]),
  grok: new Set(["low", "medium", "high"]),
  claude: new Set(["low", "medium", "high", "xhigh", "max"]),
};
const ROOT_KEYS = new Set(["schema_version", "seed", "presets"]);
const PRESET_KEYS = new Set(["description", "mode", "candidate", "candidates"]);
const CANDIDATE_KEYS = new Set([
  "id", "harness", "model", "effort", "fast", "weight", "available", "unavailable_reason",
]);

function fail(message, code = 1) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(code);
}

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, allowed, where) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`${where} has unknown field '${key}'`);
  }
}

function nonempty(value) {
  return typeof value === "string" && value.trim() === value && value.length > 0;
}

function weightUnits(value, where) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    fail(`${where} weight must be a positive number`);
  }
  if (value > 1_000_000 || Math.abs(value * 1_000_000 - Math.round(value * 1_000_000)) > 1e-6) {
    fail(`${where} weight must have at most six decimal places and be at most 1000000`);
  }
  return Math.round(value * 1_000_000);
}

function validateCandidate(candidate, where, weighted) {
  if (!object(candidate)) fail(`${where} must be an object`);
  exactKeys(candidate, CANDIDATE_KEYS, where);
  for (const key of ["id", "harness", "model"]) {
    if (!nonempty(candidate[key])) fail(`${where} needs non-empty ${key}`);
  }
  if (!/^[A-Za-z0-9._:/+-]+$/.test(candidate.model)) {
    fail(`${where} model must be an exact model token without whitespace`);
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(candidate.id)) {
    fail(`${where} id must use only letters, numbers, dot, underscore, or dash`);
  }
  if (!ALLOWED_HARNESSES.has(candidate.harness)) {
    fail(`${where} harness '${candidate.harness}' is not supported by task/model presets`);
  }
  if (candidate.harness === "opencode") {
    if (Object.hasOwn(candidate, "effort")) {
      fail(`${where} effort must be omitted for opencode because no verified launch flag enforces one`);
    }
    if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._:/+-]+$/.test(candidate.model)) {
      fail(`${where} OpenCode model must be an exact provider/model id`);
    }
  } else {
    if (!nonempty(candidate.effort)) fail(`${where} needs non-empty effort`);
    if (!ALLOWED_EFFORTS[candidate.harness].has(candidate.effort)) {
      fail(`${where} effort '${candidate.effort}' is unsupported for ${candidate.harness}`);
    }
  }
  if (Object.hasOwn(candidate, "fast")) {
    if (candidate.harness !== "pi" && candidate.harness !== "pi-signed") {
      fail(`${where} fast is supported only for pi and pi-signed`);
    }
    if (typeof candidate.fast !== "boolean") fail(`${where} fast must be true or false`);
  }
  if (Object.hasOwn(candidate, "available") && typeof candidate.available !== "boolean") {
    fail(`${where} available must be true or false`);
  }
  if (candidate.available === false && !nonempty(candidate.unavailable_reason)) {
    fail(`${where} unavailable candidate needs unavailable_reason`);
  }
  if (Object.hasOwn(candidate, "unavailable_reason") && !nonempty(candidate.unavailable_reason)) {
    fail(`${where} unavailable_reason must be a non-empty string`);
  }
  if (weighted) weightUnits(candidate.weight, where);
  else if (Object.hasOwn(candidate, "weight")) fail(`${where} fixed candidate must not have weight`);
}

function loadAndValidate(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    fail(`cannot read task/model preset config ${path}: ${error.message}`);
  }
  let config;
  try {
    config = JSON.parse(raw);
  } catch {
    fail(`task/model preset config ${path} is malformed JSON`);
  }
  if (!object(config)) fail("task/model preset config root must be an object");
  exactKeys(config, ROOT_KEYS, "task/model preset config");
  if (config.schema_version !== 1) fail("task/model preset config schema_version must be 1");
  if (!object(config.presets) || Object.keys(config.presets).length === 0) {
    fail("task/model preset config needs at least one preset");
  }
  let hasWeighted = false;
  for (const [name, preset] of Object.entries(config.presets)) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) fail(`preset name '${name}' is invalid`);
    if (!object(preset)) fail(`preset '${name}' must be an object`);
    exactKeys(preset, PRESET_KEYS, `preset '${name}'`);
    if (preset.mode !== "fixed" && preset.mode !== "weighted") {
      fail(`preset '${name}' mode must be fixed or weighted`);
    }
    if (Object.hasOwn(preset, "description") && !nonempty(preset.description)) {
      fail(`preset '${name}' description must be a non-empty string`);
    }
    if (preset.mode === "fixed") {
      if (!Object.hasOwn(preset, "candidate") || Object.hasOwn(preset, "candidates")) {
        fail(`fixed preset '${name}' needs candidate and must not have candidates`);
      }
      validateCandidate(preset.candidate, `preset '${name}' candidate`, false);
    } else {
      hasWeighted = true;
      if (!Array.isArray(preset.candidates) || preset.candidates.length < 2 || Object.hasOwn(preset, "candidate")) {
        fail(`weighted preset '${name}' needs at least two candidates and must not have candidate`);
      }
      const ids = new Set();
      let total = 0;
      for (let i = 0; i < preset.candidates.length; i += 1) {
        const candidate = preset.candidates[i];
        validateCandidate(candidate, `preset '${name}' candidate ${i + 1}`, true);
        if (ids.has(candidate.id)) fail(`weighted preset '${name}' repeats candidate id '${candidate.id}'`);
        ids.add(candidate.id);
        total += weightUnits(candidate.weight, `preset '${name}' candidate ${i + 1}`);
        if (!Number.isSafeInteger(total)) fail(`weighted preset '${name}' total weight is too large`);
      }
    }
  }
  if (hasWeighted && !nonempty(config.seed)) {
    fail("task/model preset config needs a non-empty seed when any preset is weighted");
  }
  if (Object.hasOwn(config, "seed") && !nonempty(config.seed)) {
    fail("task/model preset config seed must be a non-empty string");
  }
  return { config, raw, digest: createHash("sha256").update(raw).digest("hex") };
}

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

function stableChoice(config, presetName, taskID) {
  const preset = config.presets[presetName];
  if (preset.mode === "fixed") {
    return {
      mode: "fixed",
      algorithm: "fixed-v1",
      selected: preset.candidate,
      candidates: [{ id: preset.candidate.id, weight: null, available: preset.candidate.available !== false }],
      sample_sha256: null,
      bucket: null,
      total_weight_units: null,
    };
  }
  const material = `${config.seed}\u0000${presetName}\u0000${taskID}`;
  const digest = createHash("sha256").update(material).digest("hex");
  const sample = Number.parseInt(digest.slice(0, 13), 16);
  const weighted = preset.candidates.map((candidate) => ({
    candidate,
    units: weightUnits(candidate.weight, `preset '${presetName}' candidate '${candidate.id}'`),
  }));
  const total = weighted.reduce((sum, item) => sum + item.units, 0);
  const bucket = sample % total;
  let cursor = 0;
  let selected = weighted[weighted.length - 1].candidate;
  for (const item of weighted) {
    cursor += item.units;
    if (bucket < cursor) {
      selected = item.candidate;
      break;
    }
  }
  return {
    mode: "weighted",
    algorithm: "sha256-bucket-v1",
    selected,
    candidates: preset.candidates.map((candidate) => ({
      id: candidate.id,
      weight: candidate.weight,
      available: candidate.available !== false,
    })),
    sample_sha256: digest,
    bucket,
    total_weight_units: total,
  };
}

function assertChoiceFile(path) {
  let stat;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    stat = lstatSync(path);
    if (!stat.isFile()) fail(`durable preset choice ${path} must be a single-link regular file`);
    if (stat.nlink === 1) return;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
  fail(`durable preset choice ${path} must be a single-link regular file`);
}

function safeExistingChoice(path, taskID, presetName) {
  let record;
  try {
    record = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`cannot reuse durable preset choice ${path}: ${error.message}`);
  }
  if (!object(record) || record.schema_version !== 1 || record.task_id !== taskID || record.preset !== presetName || !object(record.selected)) {
    fail(`durable preset choice ${path} does not match task '${taskID}' and preset '${presetName}'`);
  }
  if (record.mode !== "fixed" && record.mode !== "weighted") {
    fail(`durable preset choice ${path} has an invalid selection mode`);
  }
  validateCandidate(record.selected, `durable preset choice ${path} selected candidate`, record.mode === "weighted");
  return record;
}

function atomicCreate(path, record) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temp = join(dirname(path), `.${basename(path)}.${process.pid}.${Date.now()}`);
  let fd;
  try {
    fd = openSync(temp, "wx", 0o600);
    writeFileSync(fd, `${JSON.stringify(record)}\n`);
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    linkSync(temp, path);
    unlinkSync(temp);
    return true;
  } catch (error) {
    if (fd !== undefined) closeSync(fd);
    try { unlinkSync(temp); } catch {}
    if (error.code === "EEXIST") return false;
    fail(`cannot publish durable preset choice ${path}: ${error.message}`);
  }
}

const [command, ...rest] = process.argv.slice(2);
if (command === "validate") {
  const args = parseArgs(rest);
  if (!args.config || Object.keys(args).length !== 1) fail("validate needs --config <path>");
  loadAndValidate(args.config);
  process.exit(0);
}
if (command === "select") {
  const args = parseArgs(rest);
  for (const key of ["config", "state-dir", "task", "preset"]) {
    if (!nonempty(args[key])) fail(`select needs --${key} <value>`);
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(args.task)) fail("task id is invalid");
  const loaded = loadAndValidate(args.config);
  const presetName = args.preset;
  if (!nonempty(presetName) || !Object.hasOwn(loaded.config.presets, presetName)) {
    fail(`task/model preset '${args.preset}' is not configured`);
  }
  const choicePath = join(args["state-dir"], `${args.task}.dispatch-choice.json`);
  let record;
  if (existsSync(choicePath)) {
    assertChoiceFile(choicePath);
    record = safeExistingChoice(choicePath, args.task, presetName);
  }
  if (!record) {
    const choice = stableChoice(loaded.config, presetName, args.task);
    record = {
      schema_version: 1,
      task_id: args.task,
      preset: presetName,
      config_sha256: loaded.digest,
      mode: choice.mode,
      algorithm: choice.algorithm,
      sample_sha256: choice.sample_sha256,
      bucket: choice.bucket,
      total_weight_units: choice.total_weight_units,
      candidates: choice.candidates,
      selected: choice.selected,
    };
    if (!atomicCreate(choicePath, record)) {
      assertChoiceFile(choicePath);
      record = safeExistingChoice(choicePath, args.task, presetName);
    }
  }
  const currentPreset = loaded.config.presets[presetName];
  const sameSelection = (candidate) => candidate.id === record.selected.id
    && candidate.harness === record.selected.harness
    && candidate.model === record.selected.model;
  let currentCandidate;
  if (currentPreset.mode === "fixed") {
    currentCandidate = sameSelection(currentPreset.candidate) ? currentPreset.candidate : null;
  } else {
    currentCandidate = currentPreset.candidates.find(sameSelection);
  }
  const availability = currentCandidate || record.selected;
  if (availability.available === false) {
    fail(`preset '${presetName}' sampled unavailable candidate '${record.selected.id}': ${availability.unavailable_reason}`, 2);
  }
  process.stdout.write(`${JSON.stringify(record)}\n`);
  process.exit(0);
}
fail("usage: fm-task-model-preset.mjs validate --config <path> | select --config <path> --state-dir <dir> --task <id> --preset <name>");
