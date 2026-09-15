#!/usr/bin/env node
// Exact Pi thinking-level support probe, invoked only for an opt-in preset.
//
// Pi clamps an unsupported thinking level silently (installed 0.85.1:
// dist/core/sdk.js calls clampThinkingLevel with no warning), and its
// --list-models catalog exposes only a reasoning yes/no column, so the launch
// path cannot prove an exact level from the CLI alone. This probe resolves the
// requested model through the installed package's real ModelRuntime and reports
// the model's own getSupportedThinkingLevels result, which is the same surface
// tests/fm-pi-branch-live-e2e.test.sh pins. fm-spawn refuses a preset whose
// exact level the probe cannot prove.
//
// Usage:
//   fm-pi-reasoning-probe.mjs --package-dir <dir> --agent-dir <dir> \
//     --model <provider/id> --effort <level>
//
// Exit codes: 0 supported (prints "supported=<csv>"), 2 model unknown,
// 3 level unsupported, 4 probe unavailable. The caller treats every non-zero
// exit as a refusal, never as a license to launch the unproven level.

import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

function fail(message, code) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) fail(`unexpected argument '${token}'`, 1);
    const key = token.slice(2);
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) fail(`${token} needs a value`, 1);
    args[key] = argv[i + 1];
    i += 1;
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
for (const key of ["package-dir", "agent-dir", "model", "effort"]) {
  if (!args[key]) fail(`probe needs --${key}`, 1);
}
const packageDir = args["package-dir"];
const agentDir = args["agent-dir"];
const model = args.model;
const effort = args.effort;
const separator = model.indexOf("/");
if (separator <= 0 || separator === model.length - 1) {
  fail(`model '${model}' must be an exact provider/model id`, 1);
}
if (!existsSync(`${packageDir}/package.json`)) {
  fail(`installed Pi package not found at ${packageDir}`, 4);
}

let ModelRuntime, ModelRegistry, getSupportedThinkingLevels;
try {
  ({ ModelRuntime, ModelRegistry } = await import(pathToFileURL(`${packageDir}/dist/index.js`).href));
  ({ getSupportedThinkingLevels } = await import(
    pathToFileURL(`${packageDir}/node_modules/@earendil-works/pi-ai/dist/compat.js`).href
  ));
} catch (error) {
  fail(`cannot load Pi's model runtime from ${packageDir}: ${error.message}`, 4);
}
if (typeof ModelRuntime?.create !== "function" || typeof ModelRegistry !== "function"
  || typeof getSupportedThinkingLevels !== "function") {
  fail(`installed Pi at ${packageDir} does not expose the model-runtime surface this probe needs`, 4);
}

let registry;
try {
  const runtime = await ModelRuntime.create({
    authPath: `${agentDir}/auth.json`,
    modelsPath: `${agentDir}/models.json`,
  });
  registry = new ModelRegistry(runtime);
  await registry.refresh();
} catch (error) {
  fail(`cannot resolve Pi's model catalog from ${agentDir}: ${error.message}`, 4);
}
if (typeof registry?.find !== "function") {
  fail(`installed Pi at ${packageDir} exposes no model registry lookup`, 4);
}

const found = registry.find(model.slice(0, separator), model.slice(separator + 1));
if (!found) fail(`model '${model}' is not in Pi's resolved catalog`, 2);
const supported = getSupportedThinkingLevels(found);
if (!Array.isArray(supported) || supported.length === 0) {
  fail(`Pi's model runtime returned no supported thinking levels for '${model}'`, 4);
}
if (!supported.includes(effort)) {
  fail(`model '${model}' does not support thinking level '${effort}' (supported: ${supported.join(",")})`, 3);
}
process.stdout.write(`supported=${supported.join(",")}\n`);
