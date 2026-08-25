#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const common = require('./keylink_common');

const knownImageModels = new Set(['gpt-image-2', 'gemini-3-pro-image', 'gemini-2.5-flash-image', 'gemini-3.1-flash-image']);
const mimeTypes = { '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif', '.avif': 'image/avif', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg' };
const editInstruction = 'Edit the supplied image according to the user instruction. Preserve all content the user did not ask to change. Return the edited image itself, not a description or instructions.';

function fail(message) { throw new Error(message); }
function mimeFromBytes(bytes, fallbackPath) {
  bytes = Buffer.from(bytes).subarray(0, 16);
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.toString('ascii', 0, 6) === 'GIF87a' || bytes.toString('ascii', 0, 6) === 'GIF89a') return 'image/gif';
  if (bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  if (bytes.toString('ascii', 4, 8) === 'ftyp' && ['avif', 'avis'].includes(bytes.toString('ascii', 8, 12))) return 'image/avif';
  return mimeTypes[path.extname(fallbackPath || '').toLowerCase()];
}
function imageMime(filePath) { return mimeFromBytes(fs.readFileSync(filePath), filePath); }
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

function parseImageDataUrl(value) {
  const match = String(value).match(/^data:(image\/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=_-]+)$/i);
  if (!match) fail('Reference image data URL must contain a base64-encoded image.');
  const mime = match[1].toLowerCase();
  const bytes = Buffer.from(match[2].replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  if (!bytes.length) fail('Reference image data URL is empty.');
  return { bytes, mime, filename: `reference.${mime.split('/')[1].replace('jpeg', 'jpg')}` };
}

function filenameFromUrl(value, mime) {
  try {
    const name = path.basename(new URL(value).pathname);
    if (name && name !== '.' && name !== '/') return name;
  } catch { /* use a safe fallback */ }
  return `reference.${mime?.split('/')[1]?.replace('jpeg', 'jpg') || 'png'}`;
}

async function fetchReferenceImage(value, timeoutSec) {
  if (String(value).startsWith('data:')) return parseImageDataUrl(value);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutSec * 1000);
  try {
    const response = await fetch(value, { signal: controller.signal });
    if (!response.ok) fail(`Reference image download failed: HTTP ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (!bytes.length) fail('Reference image download returned an empty file.');
    const headerMime = response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();
    const mime = headerMime?.startsWith('image/') ? headerMime : mimeFromBytes(bytes, filenameFromUrl(value));
    if (!mime) fail('Reference image URL did not return a supported image content type.');
    return { bytes, mime, filename: filenameFromUrl(value, mime) };
  } finally { clearTimeout(timer); }
}

async function buildReferenceImage(args, inputImageValue, timeoutSec) {
  if (args.inputImagePath) {
    const input = path.resolve(args.inputImagePath);
    const bytes = fs.readFileSync(input);
    if (!bytes.length) fail(`Input image is empty: ${input}`);
    return { bytes, mime: imageMime(input), filename: path.basename(input) || 'reference.png' };
  }
  return fetchReferenceImage(inputImageValue, timeoutSec);
}

function appendFormField(form, name, value) {
  if (value !== undefined && value !== null && String(value).length) form.append(name, String(value));
}

function buildImagesEditForm(reference, args, prompt) {
  const form = new FormData();
  appendFormField(form, 'model', args.model);
  appendFormField(form, 'prompt', prompt);
  appendFormField(form, 'n', 1);
  for (const [arg, field] of [['size', 'size'], ['quality', 'quality'], ['background', 'background'], ['outputFormat', 'output_format'], ['responseFormat', 'response_format']]) {
    appendFormField(form, field, args[arg]);
  }
  const blob = new Blob([reference.bytes], { type: reference.mime });
  form.append('image', blob, reference.filename);
  return form;
}

function gcd(a, b) {
  while (b) [a, b] = [b, a % b];
  return a;
}

function aspectRatioFromSize(size) {
  const match = String(size || '').match(/^(\d+)x(\d+)$/);
  if (!match) return undefined;
  const width = Number(match[1]);
  const height = Number(match[2]);
  const divisor = gcd(width, height);
  return `${width / divisor}:${height / divisor}`;
}

function buildChatPayload(args, inputImageValue, hasInputImage) {
  const aspectRatio = args.aspectRatio || aspectRatioFromSize(args.size);
  const content = [{ type: 'text', text: args.prompt }];
  if (inputImageValue) content.push({ type: 'image_url', image_url: { url: inputImageValue } });
  const messages = [];
  if (hasInputImage) messages.push({ role: 'system', content: editInstruction });
  if (aspectRatio) messages.push({ role: 'system', content: JSON.stringify({ imageConfig: { aspectRatio } }) });
  messages.push({ role: 'user', content });
  const payload = { model: args.model, messages };
  if (aspectRatio) payload.extra_body = { imageConfig: { aspectRatio } };
  return payload;
}

function isImagesEditFallbackError(error) {
  const status = Number(error?.status);
  const details = `${error?.responseBody || ''} ${error?.message || ''}`.toLowerCase();
  if ([404, 405, 415, 501].includes(status)) return true;
  if (![400, 422].includes(status)) return false;
  return /(unsupported|not supported|not implemented|endpoint|image\s*edit|images\/edits|multipart|image is required|input_image|method not allowed)/i.test(details);
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

  const hasInputImage = Boolean(args.inputImageUrl || args.inputImagePath);
  const mode = args.endpointMode || (knownImageModels.has(args.model.toLowerCase()) ? 'images' : 'chat');
  if (!['chat', 'images'].includes(mode)) fail('--endpoint-mode must be chat or images.');
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
  const resolvedEndpoint = args.endpoint || common.endpoint(base, mode === 'chat' ? 'chat/completions' : (hasInputImage ? 'images/edits' : 'images/generations'));
  if (args.useCcswitchCredential && (route === 'codex' || !common.isKeylink(resolvedEndpoint))) fail('The CCSwitch credential can only be sent directly to keylinkclub.com.');

  let payload;
  let inputImageValue;
  if (args.inputImageUrl) {
    let inputUrl;
    try { inputUrl = new URL(args.inputImageUrl); } catch { fail('--input-image-url must be a valid HTTP(S) or image data URL.'); }
    if (!['http:', 'https:', 'data:'].includes(inputUrl.protocol) || (inputUrl.protocol === 'data:' && !args.inputImageUrl.startsWith('data:image/'))) {
      fail('--input-image-url must be a valid HTTP(S) or image data URL.');
    }
    inputImageValue = args.inputImageUrl;
  } else if (args.inputImagePath) {
    const input = path.resolve(args.inputImagePath);
    if (!fs.existsSync(input) || !fs.statSync(input).isFile()) fail(`Input image does not exist or is not a file: ${input}`);
    if (fs.statSync(input).size === 0) fail(`Input image is empty: ${input}`);
    const mime = imageMime(input);
    if (!mime) fail('Input image must be PNG, JPEG, WebP, GIF, or AVIF.');
    const value = args.dryRun ? `<omitted:${fs.statSync(input).size}-bytes>` : fs.readFileSync(input).toString('base64');
    inputImageValue = `data:${mime};base64,${value}`;
  }

  if (mode === 'chat') {
    payload = buildChatPayload(args, inputImageValue, hasInputImage);
  } else if (hasInputImage) {
    payload = { model: args.model, prompt: `${editInstruction}\nUser instruction: ${args.prompt}`, n: 1 };
    for (const [arg, field] of [['size', 'size'], ['quality', 'quality'], ['background', 'background'], ['outputFormat', 'output_format'], ['responseFormat', 'response_format']]) if (args[arg]) payload[field] = args[arg];
    if (args.dryRun) {
      if (args.inputImagePath) {
        const input = path.resolve(args.inputImagePath);
        payload.image = { field: 'image', filename: path.basename(input) || 'reference.png', contentType: imageMime(input), bytes: fs.statSync(input).size };
      } else {
        payload.image = { field: 'image', source: inputImageValue };
      }
    }
  } else {
    payload = { model: args.model, prompt: args.prompt, n: 1 };
    for (const [arg, field] of [['size', 'size'], ['quality', 'quality'], ['background', 'background'], ['outputFormat', 'output_format'], ['responseFormat', 'response_format']]) if (args[arg]) payload[field] = args[arg];
  }
  if (args.dryRun) return console.log(JSON.stringify({ Operation: hasInputImage ? 'edit' : 'generate', EndpointMode: mode, Route: route, Endpoint: resolvedEndpoint, RequestFormat: mode === 'images' && hasInputImage ? 'multipart/form-data' : 'application/json', Payload: payload }, null, 2));

  const noAuth = args.noAuth || (route === 'codex' && common.isLoopback(resolvedEndpoint) && !args.apiKey && !args.apiKeyFile);
  const key = noAuth ? undefined : common.resolveKey(args);
  const headers = {};
  if (key) headers.authorization = `Bearer ${key}`;
  let body;
  if (mode === 'images' && hasInputImage) {
    const reference = await buildReferenceImage(args, inputImageValue, timeoutSec);
    body = buildImagesEditForm(reference, args, payload.prompt);
  } else {
    headers['content-type'] = 'application/json; charset=utf-8';
    body = JSON.stringify(payload);
  }
  const canAutoChatFallback = mode === 'images' && hasInputImage && args.endpointMode === undefined && !args.endpoint;
  let activeMode = mode;
  let activeEndpoint = resolvedEndpoint;
  let activePayload = payload;
  let fallbackFromEndpoint;
  let fallbackReason;
  let response;
  try {
    response = await common.fetchJson(activeEndpoint, { method: 'POST', headers, body }, timeoutSec, key, 'Keylink request failed');
  } catch (imagesError) {
    if (!canAutoChatFallback || !isImagesEditFallbackError(imagesError)) throw imagesError;
    fallbackFromEndpoint = activeEndpoint;
    fallbackReason = `Images Edits returned HTTP ${imagesError.status}`;
    activeMode = 'chat';
    activeEndpoint = common.endpoint(base, 'chat/completions');
    activePayload = buildChatPayload(args, inputImageValue, hasInputImage);
    const fallbackHeaders = {};
    if (key) fallbackHeaders.authorization = `Bearer ${key}`;
    fallbackHeaders['content-type'] = 'application/json; charset=utf-8';
    try {
      response = await common.fetchJson(activeEndpoint, {
        method: 'POST', headers: fallbackHeaders, body: JSON.stringify(activePayload),
      }, timeoutSec, key, 'Keylink Chat fallback failed');
    } catch (chatError) {
      fail(`${imagesError.message}; Chat fallback failed: ${chatError.message}`);
    }
  }
  const image = imagePayload(response, key);
  const extension = String(args.outputFormat || 'png').replace(/^\./, '');
  const output = path.resolve(args.outputPath || `keylink-image-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15)}.${extension}`);
  if (fs.existsSync(output) && !args.overwrite) fail(`Output file already exists: ${output}. Use --overwrite to replace it.`);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  if (image.kind === 'base64') fs.writeFileSync(output, Buffer.from(image.value.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
  else {
    const downloadHeaders = {};
    if (key && new URL(image.value).host === new URL(activeEndpoint).host) downloadHeaders.authorization = `Bearer ${key}`;
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
  console.log(JSON.stringify({
    OutputPath: output, NextEditInputPath: output, Bytes: bytes, Operation: hasInputImage ? 'edit' : 'generate',
    Model: args.model, EndpointMode: activeMode, Route: route, Endpoint: activeEndpoint,
    FallbackFromEndpoint: fallbackFromEndpoint, FallbackReason: fallbackReason,
  }, null, 2));
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
