#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Configure the current user to use the X3 Qwen service in OpenCode and KiloCode.
set -Eeuo pipefail

label="${1:-$(hostname)}"

export HOST_LABEL="${label}"
export PROVIDER_ID="${PROVIDER_ID:-sk-hynix}"
export PROVIDER_NAME="${PROVIDER_NAME:-SK hynix}"
export MODEL_ID="${MODEL_ID:-Qwen3-Coder-480B-A35B-Instruct-FP8}"
export MODEL_NAME="${MODEL_NAME:-Qwen3-Coder-480B-A35B-Instruct-FP8}"
export BASE_URL="${BASE_URL:-http://192.168.3.73:8000/v1}"
export API_KEY="${API_KEY:-EMPTY}"
export CONTEXT_TOKENS="${CONTEXT_TOKENS:-262144}"
export INPUT_TOKENS="${INPUT_TOKENS:-253952}"
export OUTPUT_TOKENS="${OUTPUT_TOKENS:-8192}"

command -v node >/dev/null 2>&1 || {
  echo 'ERROR: Node.js is required; run 07-install-node-npm-global.sh first.' >&2
  exit 127
}

echo "[${label}] $(date -Is) host=$(hostname)"

node <<'JS'
const fs = require("fs");
const os = require("os");
const path = require("path");

const providerId = process.env.PROVIDER_ID;
const providerName = process.env.PROVIDER_NAME;
const modelId = process.env.MODEL_ID;
const modelName = process.env.MODEL_NAME;
const modelRef = `${providerId}/${modelId}`;
const baseUrl = process.env.BASE_URL;
const apiKey = process.env.API_KEY;
const context = Number(process.env.CONTEXT_TOKENS);
const inputTokens = Number(process.env.INPUT_TOKENS);
const outputTokens = Number(process.env.OUTPUT_TOKENS);
const label = process.env.HOST_LABEL;

function stripJsonComments(text) {
  let output = "";
  let index = 0;
  let inString = false;
  let escaped = false;
  while (index < text.length) {
    const char = text[index];
    const next = text[index + 1] || "";
    if (inString) {
      output += char;
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      index += 1;
      continue;
    }
    if (char === '"') {
      inString = true;
      output += char;
      index += 1;
    } else if (char === "/" && next === "/") {
      index += 2;
      while (index < text.length && !"\r\n".includes(text[index])) index += 1;
    } else if (char === "/" && next === "*") {
      index += 2;
      while (index + 1 < text.length && !(text[index] === "*" && text[index + 1] === "/")) index += 1;
      index += 2;
    } else {
      output += char;
      index += 1;
    }
  }
  return output;
}

function removeTrailingCommas(text) {
  let output = "";
  let index = 0;
  let inString = false;
  let escaped = false;
  while (index < text.length) {
    const char = text[index];
    if (inString) {
      output += char;
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      index += 1;
      continue;
    }
    if (char === '"') {
      inString = true;
      output += char;
      index += 1;
    } else if (char === ",") {
      let lookahead = index + 1;
      while (lookahead < text.length && /\s/.test(text[lookahead])) lookahead += 1;
      if (lookahead < text.length && "]}".includes(text[lookahead])) index += 1;
      else {
        output += char;
        index += 1;
      }
    } else {
      output += char;
      index += 1;
    }
  }
  return output;
}

function parseJsonc(configPath) {
  const text = fs.readFileSync(configPath, "utf8");
  const value = JSON.parse(removeTrailingCommas(stripJsonComments(text)));
  if (!value || Array.isArray(value) || typeof value !== "object") {
    throw new TypeError("top-level config is not an object");
  }
  return value;
}

function providerConfig(kind) {
  const model = {
    name: modelName,
    limit: {context, input: inputTokens, output: outputTokens},
  };
  if (kind === "kilo") {
    model.tool_call = true;
    model.reasoning = false;
  }
  return {
    npm: "@ai-sdk/openai-compatible",
    name: providerName,
    options: {baseURL: baseUrl, apiKey, timeout: 600000, chunkTimeout: 60000},
    models: {[modelId]: model},
  };
}

function timestamp() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}T${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
}

function writeConfig(configPath, schema, kind) {
  fs.mkdirSync(path.dirname(configPath), {recursive: true});
  let existing = {};
  let backupPath = null;
  if (fs.existsSync(configPath)) {
    backupPath = `${configPath}.bak.${timestamp()}`;
    fs.copyFileSync(configPath, backupPath);
    try {
      existing = parseJsonc(configPath);
    } catch (error) {
      console.log(`[${label}] existing config parse failed for ${configPath}; writing clean config: ${error.message}`);
      existing = {};
    }
  }

  const providers = existing.provider && typeof existing.provider === "object" && !Array.isArray(existing.provider)
    ? existing.provider : {};
  delete providers.solab;
  providers[providerId] = providerConfig(kind);
  existing.$schema = schema;
  existing.provider = providers;
  existing.model = modelRef;
  existing.small_model = modelRef;

  const temporaryPath = `${configPath}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(existing, null, 2)}\n`, {mode: 0o600});
  fs.renameSync(temporaryPath, configPath);
  fs.chmodSync(configPath, 0o600);
  console.log(`[${label}] wrote ${configPath}`);
  if (backupPath) console.log(`[${label}] backup ${backupPath}`);

  const verified = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const provider = verified.provider?.[providerId] || {};
  const model = provider.models?.[modelId] || {};
  const limit = model.limit || {};
  console.log(`[verify] path=${configPath}`);
  console.log(`[verify] model=${verified.model}`);
  console.log(`[verify] provider_name=${provider.name}`);
  console.log(`[verify] context=${limit.context} input=${limit.input} output=${limit.output}`);
  if (verified.model !== modelRef || verified.small_model !== modelRef || provider.name !== providerName) {
    throw new Error(`configuration verification failed for ${configPath}`);
  }
}

const home = os.homedir();
const targets = [
  [path.join(home, ".config/opencode/opencode.jsonc"), "https://opencode.ai/config.json", "opencode"],
  [path.join(home, ".config/kilocode/kilocode.jsonc"), "https://app.kilo.ai/config.json", "kilo"],
  [path.join(home, ".config/kilo/kilo.jsonc"), "https://app.kilo.ai/config.json", "kilo"],
];
for (const [configPath, schema, kind] of targets) writeConfig(configPath, schema, kind);
console.log(`[${label}] model_ref=${modelRef}`);
console.log(`[${label}] baseURL=${baseUrl}`);
JS

echo "[${label}] x3_api_health"
node <<'JS'
const apiRoot = process.env.BASE_URL.replace(/\/$/, "");
const healthRoot = apiRoot.replace(/\/v1$/, "");

async function probe() {
  try {
    const response = await fetch(`${healthRoot}/health`, {
      signal: AbortSignal.timeout(10000),
    });
    console.log(`health_http_code=${response.status}`);
  } catch (error) {
    console.error(`health_probe_failed=${error.message}`);
  }

  try {
    const response = await fetch(`${apiRoot}/models`, {
      signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const parsed = await response.json();
    const models = parsed.data || [];
    console.log(`models=${models.map((model) => model.id).join(",")}`);
    console.log(`max_model_len=${models[0]?.max_model_len ?? "unknown"}`);
  } catch (error) {
    console.error(`models_probe_failed=${error.message}`);
  }
}

probe();
JS
