#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const common = require('./keylink_common');

const knownImageModels = new Set(['gpt-image-2', 'gemini-3-pro-image', 'gemini-2.5-flash-image', 'gemini-3.1-flash-image']);
const mimeTypes = { '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif', '.avif': 'image/avif', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg' };

function fail(message) { throw new Error(message); }
function imagePayload(response, key) {
  const first = Array.isArray(response.data) ? response.data[0] : undefined;
  if (first?.b64_json) return { kind: 'base64', value: first.b64_json };
  if (first?.url) return { kind: 'url', value: first.url };
  const json = JSON.stringify(response);
  const data = json.match(/data:image\/[A-Za-z0-9.+-]+;base64,([A-Za-z0-9+/=_-]+)/);
  if (data) return { kind: 'base64', value: data[1] };
  const urls = [...json.matchAll(/https?:\\?\/\\?\/[^"'\s<>\)]+/g)].map((match) => match[0].replaceAll('\\/', '/').replace(/\\$/, ''));
  const likely = urls.find((url) => /(\.(png|jpe?g|webp|gif|avif)(\?|$)|\/images?\/|image=)/i.test(url)) || (urls.length === 1 ? urls[0] : undefined);
  if (likely) return { kind: 'url', value: likely };
  const preview = key ? json.slice(0, 1000).split(key).join('<redacted>') : json.slice(0, 1000);
  fail(`The API response did not contain a supported image payload. Response preview: ${preview}`);
}

async function main() {
  const args = common.parseArgs(process.argv.slice(2));
  common.validateArgs(args, [
    'prompt', 'model', 'endpointMode', 'route', 'aspectRatio', 'size', 'quality', 'background', 'outputFormat',
    'responseFormat', 'inputImageUrl', 'inputImagePath', 'apiKey', 'apiKeyFile', 'baseUrl', 'proxyBaseUrl',
    'endpoint', 'outputPath', 'timeoutSec', 'overwrite', 'useCodexRoute', 'useCcswitchCredential', 'noAuth', 'dryRun',
  ], ['overwrite', 'useCodexRoute', 'useCcswitchCredential', 'noAuth', 'dryRun']);
  if (!args.prompt || !args.model) fail('--prompt and --model are required.');
  if (args.inputImageUrl && args.inputImagePath) fail('Specify either --input-image-url or --input-image-path, not both.');
  if (args.noAuth && (args.apiKey || args.apiKeyFile || args.useCcswitchCredential)) fail('Do not combine --no-auth with an API key source.');
  if (args.useCodexRoute && args.route) fail('Do not combine --use-codex-route with --route.');
  if (args.useCodexRoute && args.baseUrl) fail('Do not combine --use-codex-route with --base-url.');
  if (args.proxyBaseUrl && args.route === 'direct') fail('--proxy-base-url cannot be used with --route direct.');
  if (args.proxyBaseUrl && args.endpoint) fail('Specify either --proxy-base-url or --endpoint, not both.');
  if (args.aspectRatio && !/^\d+:\d+$/.test(args.aspectRatio)) fail('--aspect-ratio must use W:H notation.');
  if (args.responseFormat && !['url', 'b64_json'].includes(args.responseFormat)) fail('--response-format must be url or b64_json.');
  const timeoutSec = common.timeout(args.timeoutSec, 300);

  const endpointExplicit = Object.prototype.hasOwnProperty.call(args, 'endpointMode');
  const mode = args.endpointMode || (!endpointExplicit && knownImageModels.has(args.model.toLowerCase()) ? 'images' : 'chat');
  if (!['chat', 'images'].includes(mode)) fail('--endpoint-mode must be chat or images.');
  if (mode === 'images' && (args.inputImageUrl || args.inputImagePath)) fail('Images mode is text-to-image only. Use chat mode for a reference image.');
  if (mode === 'chat' && args.size) fail('Chat mode uses --aspect-ratio; --size is only for images mode.');
  if (mode === 'images' && args.aspectRatio) fail('Images mode uses --size; --aspect-ratio is only for chat mode.');

  let route = args.useCodexRoute ? 'codex' : (args.route || 'auto');
  if (args.endpoint) route = 'custom';
  if (route === 'auto') {
    if (args.baseUrl || mode === 'images') route = 'direct';
    else { try { common.codexRouteBase(args.proxyBaseUrl); route = 'codex'; } catch { route = 'direct'; } }
  }
  if (!['direct', 'codex', 'custom'].includes(route)) fail('--route must be auto, direct, or codex.');
  const base = route === 'codex' ? common.codexRouteBase(args.proxyBaseUrl) : common.directBase(args.baseUrl);
  const resolvedEndpoint = args.endpoint || common.endpoint(base, mode === 'chat' ? 'chat/completions' : 'images/generations');
  if (args.useCcswitchCredential && (route === 'codex' || !common.isKeylink(resolvedEndpoint))) fail('The CCSwitch credential can only be sent directly to keylinkclub.com.');

  let payload;
  if (mode === 'chat') {
    const content = [{ type: 'text', text: args.prompt }];
    if (args.inputImageUrl) content.push({ type: 'image_url', image_url: { url: args.inputImageUrl } });
    if (args.inputImagePath) {
      const input = path.resolve(args.inputImagePath);
      if (!fs.existsSync(input)) fail(`Input image does not exist: ${input}`);
      const mime = mimeTypes[path.extname(input).toLowerCase()] || 'application/octet-stream';
      const value = args.dryRun ? `<omitted:${fs.statSync(input).size}-bytes>` : fs.readFileSync(input).toString('base64');
      content.push({ type: 'image_url', image_url: { url: `data:${mime};base64,${value}` } });
    }
    const messages = [];
    if (args.aspectRatio) messages.push({ role: 'system', content: JSON.stringify({ imageConfig: { aspectRatio: args.aspectRatio } }) });
    messages.push({ role: 'user', content });
    payload = { model: args.model, messages };
    if (args.aspectRatio) payload.extra_body = { imageConfig: { aspectRatio: args.aspectRatio } };
  } else {
    payload = { model: args.model, prompt: args.prompt, n: 1 };
    for (const [arg, field] of [['size', 'size'], ['quality', 'quality'], ['background', 'background'], ['outputFormat', 'output_format'], ['responseFormat', 'response_format']]) if (args[arg]) payload[field] = args[arg];
  }
  if (args.dryRun) return console.log(JSON.stringify({ EndpointMode: mode, Route: route, Endpoint: resolvedEndpoint, Payload: payload }, null, 2));

  const noAuth = args.noAuth || (route === 'codex' && common.isLoopback(resolvedEndpoint) && !args.apiKey && !args.apiKeyFile);
  const key = noAuth ? undefined : common.resolveKey(args);
  const headers = { 'content-type': 'application/json; charset=utf-8' };
  if (key) headers.authorization = `Bearer ${key}`;
  const response = await common.fetchJson(resolvedEndpoint, { method: 'POST', headers, body: JSON.stringify(payload) }, timeoutSec, key, 'Keylink request failed');
  const image = imagePayload(response, key);
  const extension = String(args.outputFormat || 'png').replace(/^\./, '');
  const output = path.resolve(args.outputPath || `keylink-image-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15)}.${extension}`);
  if (fs.existsSync(output) && !args.overwrite) fail(`Output file already exists: ${output}. Use --overwrite to replace it.`);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  if (image.kind === 'base64') fs.writeFileSync(output, Buffer.from(image.value.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
  else {
    const downloadHeaders = {};
    if (key && new URL(image.value).host === new URL(resolvedEndpoint).host) downloadHeaders.authorization = `Bearer ${key}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutSec * 1000);
    try {
      const download = await fetch(image.value, { headers: downloadHeaders, signal: controller.signal });
      if (!download.ok) fail(`Image download failed: HTTP ${download.status}`);
      fs.writeFileSync(output, Buffer.from(await download.arrayBuffer()));
    } finally { clearTimeout(timer); }
  }
  const bytes = fs.statSync(output).size;
  if (!bytes) fail(`The saved image is empty: ${output}`);
  console.log(JSON.stringify({ OutputPath: output, Bytes: bytes, Model: args.model, EndpointMode: mode, Route: route, Endpoint: resolvedEndpoint }, null, 2));
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
