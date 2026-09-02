'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith('--')) throw new Error(`Unexpected argument: ${token}`);
    const key = token.slice(2).replace(/-([a-z])/g, (_, char) => char.toUpperCase());
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) result[key] = true;
    else { result[key] = next; i += 1; }
  }
  return result;
}

function validateArgs(args, allowed, booleanArgs = []) {
  for (const key of Object.keys(args)) {
    if (!allowed.includes(key)) throw new Error(`Unknown option: --${key.replace(/[A-Z]/g, (char) => `-${char.toLowerCase()}`)}`);
  }
  for (const key of booleanArgs) {
    if (args[key] !== undefined && args[key] !== true) {
      throw new Error(`--${key.replace(/[A-Z]/g, (char) => `-${char.toLowerCase()}`)} does not take a value.`);
    }
  }
}

function timeout(value, fallback) {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 3600) throw new Error('--timeout-sec must be an integer from 1 to 3600.');
  return parsed;
}

function first(...values) {
  const value = values.find((item) => item !== undefined && item !== null && String(item).trim());
  return value === undefined ? undefined : String(value).trim();
}

function codexHome() {
  return first(process.env.CODEX_HOME, path.join(os.homedir(), '.codex'));
}

function readKeyFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) throw new Error(`API key file does not exist: ${resolved}`);
  const key = fs.readFileSync(resolved, 'utf8').split(/\r?\n/).find((line) => line.trim());
  if (!key) throw new Error(`API key file is empty: ${resolved}`);
  return key.trim();
}

function ccswitchDatabasePath() {
  const configured = first(process.env.CCSWITCH_DB_PATH);
  const candidates = configured ? [configured] : [
    path.join(os.homedir(), '.cc-switch', 'cc-switch.db'),
    process.env.APPDATA && path.join(process.env.APPDATA, 'com.ccswitch.desktop', 'cc-switch.db'),
    process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'com.ccswitch.desktop', 'cc-switch.db'),
    path.join(os.homedir(), 'Library', 'Application Support', 'com.ccswitch.desktop', 'cc-switch.db'),
  ].filter(Boolean);
  const found = candidates.map((item) => path.resolve(item)).find((item) => fs.existsSync(item) && fs.statSync(item).isFile());
  if (!found) throw new Error('CCSwitch database was not found. Set CCSWITCH_DB_PATH or install CCSwitch for the current user.');
  return found;
}

function ccswitchKey() {
  const helper = path.join(__dirname, 'read_ccswitch_credential.js');
  const run = spawnSync(process.execPath, [helper, ccswitchDatabasePath()], { encoding: 'utf8' });
  if (run.status !== 0) throw new Error(`CCSwitch credential lookup failed: ${first(run.stderr, run.stdout, 'unknown error')}`);
  const encoded = first(...run.stdout.trim().split(/\r?\n/).reverse());
  const key = encoded && Buffer.from(encoded, 'base64').toString('utf8').trim();
  if (!key) throw new Error('The current CCSwitch Codex provider has no API key.');
  return key;
}

function resolveKey(args) {
  if (args.apiKey) return args.apiKey;
  if (args.apiKeyFile) return readKeyFile(args.apiKeyFile);
  if (args.useCcswitchCredential) return ccswitchKey();
  const envKey = first(process.env.KEYLINK_IMAGE_API_KEY, process.env.KEYLINK_API_KEY);
  if (envKey) return envKey;
  const envFile = first(process.env.KEYLINK_IMAGE_API_KEY_FILE, process.env.KEYLINK_API_KEY_FILE);
  if (envFile) return readKeyFile(envFile);
  const defaultFile = path.join(codexHome(), 'secrets', 'keylink-image-api-key.txt');
  if (fs.existsSync(defaultFile)) return readKeyFile(defaultFile);
  throw new Error('A Keylink API key source is required.');
}

function codexRouteBase(proxyBaseUrl) {
  const override = first(proxyBaseUrl, process.env.KEYLINK_PROXY_BASE_URL);
  if (override) return override;
  const configPath = path.join(codexHome(), 'config.toml');
  if (!fs.existsSync(configPath)) throw new Error(`Codex config does not exist: ${configPath}`);
  const text = fs.readFileSync(configPath, 'utf8');
  const provider = text.match(/^\s*model_provider\s*=\s*["']([^"']+)["']/m)?.[1];
  if (!provider) throw new Error(`Codex config does not declare model_provider: ${configPath}`);
  const escaped = provider.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const sectionPattern = new RegExp(`^\\s*\\[model_providers\\.${escaped}\\]\\s*$`);
  let inProviderSection = false;
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*\[/.test(line)) {
      inProviderSection = sectionPattern.test(line);
      continue;
    }
    if (inProviderSection) {
      const base = line.match(/^\s*base_url\s*=\s*["']([^"']+)["']/)?.[1];
      if (base) return base;
    }
  }
  throw new Error(`Codex provider '${provider}' does not declare base_url in ${configPath}`);
}

function directBase(explicit) {
  return first(explicit, process.env.KEYLINK_IMAGE_BASE_URL, process.env.KEYLINK_BASE_URL, 'https://keylinkclub.com');
}

function endpoint(base, suffix) {
  const clean = base.replace(/\/$/, '');
  return clean.endsWith('/v1') ? `${clean}/${suffix}` : `${clean}/v1/${suffix}`;
}

function isLoopback(url) {
  return ['localhost', '127.0.0.1', '::1'].includes(new URL(url).hostname);
}

function isKeylink(url) {
  const host = new URL(url).hostname.toLowerCase();
  return host === 'keylinkclub.com' || host.endsWith('.keylinkclub.com');
}

async function fetchJson(url, options, timeoutSec, key, label) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Number(timeoutSec || 300) * 1000);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const text = await response.text();
    if (!response.ok) {
      const error = new Error(`HTTP ${response.status}: ${text.slice(0, 1000)}`);
      error.status = response.status;
      error.responseBody = text;
      throw error;
    }
    try { return JSON.parse(text); } catch { throw new Error(`Response was not valid JSON: ${text.slice(0, 500)}`); }
  } catch (error) {
    const safe = key ? String(error.message).split(key).join('<redacted>') : error.message;
    const wrapped = new Error(`${label}: ${safe}`);
    if (error.status !== undefined) wrapped.status = error.status;
    if (error.responseBody !== undefined) wrapped.responseBody = key ? String(error.responseBody).split(key).join('<redacted>') : error.responseBody;
    wrapped.cause = error;
    throw wrapped;
  } finally { clearTimeout(timer); }
}

module.exports = { parseArgs, validateArgs, timeout, first, resolveKey, codexRouteBase, directBase, endpoint, isLoopback, isKeylink, fetchJson };
